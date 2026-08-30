-- 0006_cultivation_physique
--
-- The other two progression pillars (spec section 9).
--
--                  CULTIVATION
--                       |
--                Realm / Essence
--                       v
--   PATH ATTAINMENT -> CHARACTER <- PHYSIQUE TRAINING
--
-- Cultivation sets realm, essence and which technique ranks are usable at all.
-- Physique sets HP, defence, physical strength and regeneration. Both can be
-- aimed at a specific Path, trading some of their own progress for insight that
-- feeds player_path_attainment (spec sections 10 and 11) - which is what makes
-- "what do I train tonight" a real decision rather than a single obvious click.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- realms
-- ---------------------------------------------------------------------------
-- The cultivation ladder. `realm_id` is the ordinal and the key, for the same
-- reason attainment_tiers.tier is: progression comparisons should be integer
-- comparisons, not name lookups.

CREATE TABLE realms (
    realm_id             SMALLINT PRIMARY KEY,
    code                 TEXT     NOT NULL UNIQUE,
    name                 TEXT     NOT NULL,

    -- Rank 1-9, the coarse tier. Gates technique use directly:
    -- techniques.rank <= realms.rank.
    rank                 SMALLINT NOT NULL CHECK (rank BETWEEN 1 AND 9),

    -- Sub-step within a rank.
    stage                TEXT     NOT NULL CHECK (stage IN ('early', 'middle', 'peak')),

    -- Cumulative, not incremental, so deriving a realm from a cultivation total
    -- is one indexed range scan.
    cultivation_required BIGINT   NOT NULL CHECK (cultivation_required >= 0),

    -- Caps conferred by reaching this realm.
    essence_capacity     BIGINT   NOT NULL CHECK (essence_capacity > 0),
    qi_capacity          BIGINT   NOT NULL CHECK (qi_capacity > 0),

    UNIQUE (rank, stage)
);

COMMENT ON TABLE realms IS
    'The cultivation ladder. realm_id is the ordinal; gate content with rank, not with names.';


-- ---------------------------------------------------------------------------
-- physiques
-- ---------------------------------------------------------------------------
-- Innate bodies. Spec section 11: a rare physique can modify how physique
-- training interacts with Paths - Great Strength True Martial Physique favours
-- Strength training, Northern Dark Ice Soul Physique favours Ice.

CREATE TABLE physiques (
    physique_id     SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            TEXT     NOT NULL UNIQUE,
    name            TEXT     NOT NULL,

    -- Rarity band, purely for roll weighting and display.
    tier            TEXT     NOT NULL DEFAULT 'common'
                    CHECK (tier IN ('common', 'uncommon', 'rare', 'epic', 'legendary')),

    -- The Path this body is attuned to, if any. Training toward it earns the
    -- bonus below. RESTRICT so retiring a Path cannot silently orphan a
    -- physique's defining trait.
    affinity_path   TEXT     REFERENCES paths (code) ON DELETE RESTRICT,

    -- Multiplier on insight earned when training toward affinity_path.
    -- Meaningless without one, which the constraint below enforces.
    affinity_bonus  NUMERIC(6, 4) NOT NULL DEFAULT 1
                    CHECK (affinity_bonus > 0),

    -- Multipliers on the physique pillar's stat output.
    hp_multiplier       NUMERIC(6, 4) NOT NULL DEFAULT 1 CHECK (hp_multiplier > 0),
    defense_multiplier  NUMERIC(6, 4) NOT NULL DEFAULT 1 CHECK (defense_multiplier > 0),
    strength_multiplier NUMERIC(6, 4) NOT NULL DEFAULT 1 CHECK (strength_multiplier > 0),

    description     TEXT     NOT NULL DEFAULT '',
    traits          JSONB    NOT NULL DEFAULT '{}'::jsonb,

    -- A bonus with nothing to apply to is a data-entry mistake, not a valid row.
    CONSTRAINT physiques_affinity_bonus_needs_a_path
        CHECK (affinity_path IS NOT NULL OR affinity_bonus = 1)
);

CREATE INDEX physiques_affinity_path_idx ON physiques (affinity_path);


-- ---------------------------------------------------------------------------
-- player_cultivation
-- ---------------------------------------------------------------------------
-- Exactly one row per player. A separate table rather than columns on `players`
-- because `players` is identity and is finished - this is the rule that stops
-- it growing back into the 120-column table the old game ended up with.

CREATE TABLE player_cultivation (
    player_id    BIGINT      PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    realm_id     SMALLINT    NOT NULL DEFAULT 1 REFERENCES realms (realm_id) ON DELETE RESTRICT,

    -- Cumulative lifetime progress; realm_id is derived from it and stored
    -- alongside, kept in step on write.
    cultivation  BIGINT      NOT NULL DEFAULT 0 CHECK (cultivation >= 0),

    -- Current pools. Caps come from the realm, so they are not duplicated here;
    -- a breakthrough raising them takes effect the moment realm_id changes.
    essence      BIGINT      NOT NULL DEFAULT 0 CHECK (essence >= 0),
    qi           BIGINT      NOT NULL DEFAULT 0 CHECK (qi >= 0),

    -- Governs accrual rate. Rolled at character creation.
    aptitude     SMALLINT    NOT NULL DEFAULT 50 CHECK (aptitude BETWEEN 1 AND 100),

    -- Idle accrual is computed from elapsed time rather than by a ticking job,
    -- so this is the "last settled" marker.
    last_tick_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER player_cultivation_set_updated_at
    BEFORE UPDATE ON player_cultivation
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX player_cultivation_realm_idx ON player_cultivation (realm_id);

-- Leaderboards, and "who is strong enough for this raid".
CREATE INDEX player_cultivation_progress_idx ON player_cultivation (cultivation DESC);


-- ---------------------------------------------------------------------------
-- player_physique
-- ---------------------------------------------------------------------------
-- The body pillar's contribution to combat stats, kept separate from
-- cultivation's so the two can be reasoned about - and rebalanced -
-- independently. Equipment and buffs layer on top at combat time; these columns
-- are this pillar's output only, never a cached grand total.

CREATE TABLE player_physique (
    player_id    BIGINT      PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    -- Innate body, if the player has rolled one. RESTRICT so a physique still
    -- held by someone cannot be deleted out from under them.
    physique_id  SMALLINT    REFERENCES physiques (physique_id) ON DELETE RESTRICT,

    physique_xp  BIGINT      NOT NULL DEFAULT 0 CHECK (physique_xp >= 0),
    body_level   SMALLINT    NOT NULL DEFAULT 1 CHECK (body_level >= 1),

    max_hp       BIGINT      NOT NULL DEFAULT 100 CHECK (max_hp > 0),
    current_hp   BIGINT      NOT NULL DEFAULT 100 CHECK (current_hp >= 0),
    defense      BIGINT      NOT NULL DEFAULT 0 CHECK (defense >= 0),
    strength     BIGINT      NOT NULL DEFAULT 0 CHECK (strength >= 0),

    -- HP regenerated per minute out of combat.
    regeneration NUMERIC(10, 2) NOT NULL DEFAULT 1 CHECK (regeneration >= 0),

    last_tick_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Healing past the cap is a bug that hides itself; make it impossible.
    CONSTRAINT player_physique_hp_within_cap CHECK (current_hp <= max_hp)
);

CREATE TRIGGER player_physique_set_updated_at
    BEFORE UPDATE ON player_physique
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX player_physique_physique_idx ON player_physique (physique_id);


-- ---------------------------------------------------------------------------
-- training_sessions
-- ---------------------------------------------------------------------------
-- Backs `/cultivate path:strength duration:8h` and `/train physique
-- path:strength` (spec sections 10 and 11).
--
-- A session is a claim on a span of time, resolved when the player comes back.
-- Storing the intent and resolving later - rather than granting rewards up
-- front - is what makes the duration meaningful and keeps a disconnect or a
-- restart from costing anything.
--
-- `path_code` NULL means pure training: full XP, no insight. Set means the
-- Path-focused trade: reduced XP (game_config.path_cultivation_xp_rate /
-- path_physique_xp_rate) in exchange for insight and a Dao Mark chance.

CREATE TABLE training_sessions (
    session_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    player_id       BIGINT      NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    kind            TEXT        NOT NULL CHECK (kind IN ('cultivation', 'physique')),

    path_code       TEXT        REFERENCES paths (code) ON DELETE RESTRICT,

    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    ends_at         TIMESTAMPTZ NOT NULL,
    resolved_at     TIMESTAMPTZ,

    -- What was actually granted, written at resolution. Kept for the summary
    -- embed and for answering "where did this insight come from" later.
    outcome         JSONB,

    -- Snapshotted at resolution so a later rebalance cannot retroactively
    -- change what a past session appeared to pay out.
    xp_granted      BIGINT,
    insight_granted BIGINT,
    dao_marks_granted INTEGER,

    CONSTRAINT training_sessions_ends_after_start CHECK (ends_at > started_at),

    -- Resolution is all-or-nothing: either it has happened and the figures are
    -- present, or it has not and they are all absent. Half-resolved rows are
    -- the kind of thing that quietly double-pays.
    CONSTRAINT training_sessions_resolution_is_complete CHECK (
        (resolved_at IS NULL
            AND xp_granted IS NULL
            AND insight_granted IS NULL
            AND dao_marks_granted IS NULL)
        OR
        (resolved_at IS NOT NULL
            AND xp_granted IS NOT NULL
            AND insight_granted IS NOT NULL
            AND dao_marks_granted IS NOT NULL)
    ),

    -- Insight is Path-specific, so a pure session cannot have granted any.
    CONSTRAINT training_sessions_insight_requires_a_path CHECK (
        path_code IS NOT NULL OR COALESCE(insight_granted, 0) = 0
    )
);

-- One unresolved session per player: without this, two commands racing would
-- both open a session and both pay out for the same span of wall-clock time.
CREATE UNIQUE INDEX training_sessions_one_active_per_player_idx
    ON training_sessions (player_id)
    WHERE resolved_at IS NULL;

-- FK index, and it serves the player's own training history.
CREATE INDEX training_sessions_player_idx ON training_sessions (player_id, started_at DESC);
CREATE INDEX training_sessions_path_idx ON training_sessions (path_code);

-- The sweep that finds sessions ready to pay out.
CREATE INDEX training_sessions_due_idx
    ON training_sessions (ends_at)
    WHERE resolved_at IS NULL;

COMMENT ON TABLE training_sessions IS
    'A claim on a span of time, resolved on return. path_code NULL = pure training: full XP, no insight.';


-- ---------------------------------------------------------------------------
-- Seed: the realm ladder
-- ---------------------------------------------------------------------------
-- Generated rather than typed: 9 ranks x 3 stages, with the curve stated once
-- as an expression instead of 27 hand-entered numbers that could drift out of
-- order. All figures are PLACEHOLDER - the design doc gives no curve.

INSERT INTO realms (realm_id, code, name, rank, stage, cultivation_required, essence_capacity, qi_capacity)
SELECT
    ordinal::smallint,
    'rank' || rank || '_' || stage,
    'Rank ' || rank || ' ' || initcap(stage),
    rank::smallint,
    stage,
    -- Cumulative. Flat 0 for the starting realm, then ~1.9x per stage.
    CASE WHEN ordinal = 1 THEN 0
         ELSE round(1000 * power(1.9, ordinal - 2))::bigint
    END,
    round(1000 * power(2.0, rank - 1))::bigint,
    round(500 * power(2.0, rank - 1))::bigint
FROM (
    SELECT
        rank,
        stage,
        (rank - 1) * 3 + stage_ord AS ordinal
    FROM generate_series(1, 9) AS rank,
         unnest(ARRAY['early', 'middle', 'peak']) WITH ORDINALITY AS s(stage, stage_ord)
) AS ladder;


-- ---------------------------------------------------------------------------
-- Seed: physiques
-- ---------------------------------------------------------------------------
-- The two the design doc names by way of example, plus a baseline so a
-- character without a rare body still has a valid row to point at.

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier, description)
VALUES
    ('mortal_body', 'Mortal Body', 'common', NULL, 1.0,
     1.0, 1.0, 1.0,
     'An ordinary body, unremarkable in every direction.'),

    ('great_strength_true_martial', 'Great Strength True Martial Physique', 'legendary', 'strength', 1.5,
     1.3, 1.2, 1.6,
     'A body forged for raw power. Strength Path training bites far deeper.'),

    ('northern_dark_ice_soul', 'Northern Dark Ice Soul Physique', 'legendary', 'ice', 1.5,
     1.2, 1.4, 1.0,
     'A frozen soul-body. Ice Path training and Ice resistance come naturally.');
