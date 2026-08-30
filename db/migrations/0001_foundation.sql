-- 0001_foundation
--
-- Player identity and the shared conventions every later migration builds on.
-- Deliberately small: this layer is game-agnostic, so it can be settled before
-- the core systems are designed. Everything game-specific arrives in 0002+.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- Conventions used throughout this schema
-- ---------------------------------------------------------------------------
--
--   * Surrogate integer PKs (`<thing>_id`), never a natural key. The Discord
--     snowflake lives in a UNIQUE column instead of being the primary key, so
--     it appears exactly once in the whole database rather than being copied
--     into every child row as an unconstrained BIGINT.
--   * TIMESTAMPTZ for every point in time, never an epoch integer. Postgres
--     does the arithmetic, comparisons read as dates, and `now()` is the
--     default rather than something each caller computes.
--   * Every foreign key is declared, and every foreign key gets an index.
--     Postgres indexes the referenced side automatically but never the
--     referencing side, and an unindexed FK makes the parent's delete scan.
--   * ON DELETE CASCADE for rows that are meaningless without their parent;
--     ON DELETE RESTRICT where losing the row would destroy history.
--   * JSONB only for genuinely open-ended payloads. Anything ever filtered,
--     sorted, or summed gets a real column.


-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
-- A DEFAULT only fires on INSERT, so `updated_at` has to be maintained by a
-- trigger or it silently freezes at creation time. One shared function, then
-- one trigger per table that wants it - cheaper to attach than to remember.

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_updated_at() IS
    'BEFORE UPDATE trigger: stamps NEW.updated_at with now(). Attach to any table with an updated_at column.';


-- ---------------------------------------------------------------------------
-- players
-- ---------------------------------------------------------------------------
-- One row per Discord account. Intentionally holds identity and nothing else:
-- progression, currencies, stats and per-system state all live in their own
-- tables keyed by player_id. The old game grew a single ~120-column `players`
-- table because every feature added its columns here; the fix is that this
-- table is finished, and features extend the schema sideways instead.

CREATE TABLE players (
    player_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Discord snowflakes exceed 2^32, so BIGINT is required, not a nicety.
    discord_id    BIGINT      NOT NULL UNIQUE,

    -- Cached from Discord for display in embeds and leaderboards without a
    -- fetch. Refreshed opportunistically; treat Discord as the real source.
    discord_name  TEXT        NOT NULL,

    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Touched on every command. Drives inactivity cleanup and "who is playing"
    -- without needing a separate events table to answer it.
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Soft delete. A hard DELETE would cascade away a player's whole history,
    -- including the audit trail of moderation actions taken against them, so
    -- account removal sets this and every gameplay query filters on it.
    deleted_at    TIMESTAMPTZ
);

CREATE TRIGGER players_set_updated_at
    BEFORE UPDATE ON players
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The hot path: every single command resolves a Discord ID to a player. The
-- UNIQUE on discord_id already indexes it; this partial index keeps that lookup
-- on the far smaller set of live accounts as deleted rows accumulate.
CREATE INDEX players_active_idx
    ON players (discord_id)
    WHERE deleted_at IS NULL;

COMMENT ON TABLE  players IS
    'One row per Discord account. Identity only - progression lives in per-system tables keyed by player_id.';
COMMENT ON COLUMN players.deleted_at IS
    'Soft delete. NULL means active; gameplay queries must filter on this.';


-- ---------------------------------------------------------------------------
-- admin_audit_log
-- ---------------------------------------------------------------------------
-- Append-only record of privileged actions (granting currency, resetting a
-- character, editing another player's state). Exists from day one because the
-- moment it is needed is always after the thing it would have recorded.

CREATE TABLE admin_audit_log (
    audit_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- RESTRICT, not CASCADE: deleting an account must never quietly erase the
    -- record of what was done to or by it. Nullable because an action can be
    -- taken by the system itself rather than by a person.
    actor_id    BIGINT      REFERENCES players (player_id) ON DELETE RESTRICT,
    target_id   BIGINT      REFERENCES players (player_id) ON DELETE RESTRICT,

    -- Snapshotted at write time. Discord names change, and an audit entry has
    -- to still read correctly years later even if the account is gone.
    actor_name  TEXT        NOT NULL,
    target_name TEXT,

    -- Stable machine-readable verb, e.g. 'grant_currency', 'reset_character'.
    action      TEXT        NOT NULL,

    -- Free-form per-action payload: amounts, before/after values, reason. JSONB
    -- rather than TEXT because these do get queried when investigating.
    detail      JSONB       NOT NULL DEFAULT '{}'::jsonb,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Both FK columns need their own index or the RESTRICT above forces a seq scan
-- of the whole log on every player delete.
CREATE INDEX admin_audit_log_actor_idx  ON admin_audit_log (actor_id);
CREATE INDEX admin_audit_log_target_idx ON admin_audit_log (target_id);

-- The two ways this table is actually read: recent activity overall, and the
-- history of one action type.
CREATE INDEX admin_audit_log_recent_idx ON admin_audit_log (created_at DESC);
CREATE INDEX admin_audit_log_action_idx ON admin_audit_log (action, created_at DESC);

COMMENT ON TABLE admin_audit_log IS
    'Append-only log of privileged actions. Never updated or deleted.';
