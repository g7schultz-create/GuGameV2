-- 0007_battles
--
-- The battle engine's state: battles, their combatants, the append-only action
-- log, and shared world bosses.
--
-- Battles are turn-based with no switching. A battle here covers PvE and PvP
-- duels ('dungeon' is reserved as a kind; the run/stage tables around it come
-- later). World bosses are deliberately NOT battles: many players hitting one
-- shared HP pool over hours is a different shape from a turn-based fight, and
-- forcing it into the battles table would bend both.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- battles
-- ---------------------------------------------------------------------------

CREATE TABLE battles (
    battle_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    kind        TEXT        NOT NULL
                CHECK (kind IN ('pve', 'duel', 'dungeon')),

    status      TEXT        NOT NULL DEFAULT 'active'
                CHECK (status IN ('active', 'complete', 'fled', 'expired')),

    -- Which side won, once it is over. NULL on a completed battle means a
    -- draw. Sides rather than combatants so a future 2v2 needs no schema
    -- change.
    winner_side SMALLINT    CHECK (winner_side IN (0, 1)),

    -- Every random roll in the battle derives from this, so a disputed fight
    -- can be replayed exactly from the log.
    rng_seed    BIGINT      NOT NULL,

    turn_number INTEGER     NOT NULL DEFAULT 1 CHECK (turn_number >= 1),

    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at    TIMESTAMPTZ,

    -- 'active' and 'has an end time' are mutually exclusive, in both
    -- directions - a battle cannot be over without a timestamp, nor carry one
    -- while still running.
    CONSTRAINT battles_ended_matches_status
        CHECK ((status = 'active') = (ended_at IS NULL)),

    -- A verdict only makes sense on a finished battle.
    CONSTRAINT battles_winner_only_when_over
        CHECK (winner_side IS NULL OR status <> 'active')
);

CREATE INDEX battles_active_idx ON battles (started_at) WHERE status = 'active';

COMMENT ON TABLE battles IS
    'Turn-based fights: PvE and duels (dungeon reserved). World bosses live in their own tables.';


-- ---------------------------------------------------------------------------
-- battle_combatants
-- ---------------------------------------------------------------------------
-- One row per participant. Exactly one of player_id / species_id is set - a
-- combatant is a player or a creature, never both, never neither.
--
-- `snapshot` is the reproducibility contract the duel design needs: the
-- combatant's derived stats (attack, defense, attainment bonuses, loadout...)
-- frozen at battle start. Combat reads the snapshot, not the live tables, so a
-- fight stays consistent mid-battle and a finished result still explains
-- itself after both sides have changed their builds.

CREATE TABLE battle_combatants (
    battle_id    BIGINT   NOT NULL REFERENCES battles (battle_id) ON DELETE CASCADE,
    combatant_no SMALLINT NOT NULL CHECK (combatant_no BETWEEN 0 AND 7),

    side         SMALLINT NOT NULL CHECK (side IN (0, 1)),

    -- RESTRICT for the same reason as the audit log: battle history involves
    -- other people, and deleting an account must not rewrite their opponents'
    -- records. Account removal is a soft delete on players anyway.
    player_id    BIGINT   REFERENCES players (player_id) ON DELETE RESTRICT,
    species_id   BIGINT   REFERENCES creature_species (species_id) ON DELETE RESTRICT,

    snapshot     JSONB    NOT NULL,

    max_hp       BIGINT   NOT NULL CHECK (max_hp > 0),
    current_hp   BIGINT   NOT NULL CHECK (current_hp >= 0),
    current_qi   BIGINT   NOT NULL DEFAULT 0 CHECK (current_qi >= 0),

    PRIMARY KEY (battle_id, combatant_no),

    CONSTRAINT battle_combatants_exactly_one_kind
        CHECK ((player_id IS NULL) <> (species_id IS NULL)),

    CONSTRAINT battle_combatants_hp_within_cap
        CHECK (current_hp <= max_hp),

    -- The same player twice in one battle is a bug, not a feature.
    CONSTRAINT battle_combatants_player_once_per_battle
        UNIQUE (battle_id, player_id)
);

CREATE INDEX battle_combatants_player_idx  ON battle_combatants (player_id);
CREATE INDEX battle_combatants_species_idx ON battle_combatants (species_id);

COMMENT ON COLUMN battle_combatants.snapshot IS
    'Derived stats frozen at battle start. Combat reads this, never the live tables.';


-- ---------------------------------------------------------------------------
-- player_active_battle
-- ---------------------------------------------------------------------------
-- The "one fight at a time" rule, as a claim table. A row exists while the
-- player is in an active battle and is deleted when it ends; the primary key
-- is the whole enforcement. A partial index on battles cannot express this,
-- because the player association lives in battle_combatants.
--
-- World boss attacks take no claim - hitting the shared boss does not lock a
-- player out of duelling.

CREATE TABLE player_active_battle (
    player_id  BIGINT      PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,
    battle_id  BIGINT      NOT NULL REFERENCES battles (battle_id) ON DELETE CASCADE,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_active_battle_battle_idx ON player_active_battle (battle_id);

COMMENT ON TABLE player_active_battle IS
    'One row while a player is in an active battle; the PK is the one-fight-at-a-time rule.';


-- ---------------------------------------------------------------------------
-- battle_actions
-- ---------------------------------------------------------------------------
-- Append-only log, one row per thing that happened. This is both the combat
-- log the players read and the replay record: every resolved number is stored,
-- so the fight can be audited without re-running the damage pipeline against
-- tables that may have been rebalanced since.
--
-- technique_id is SET NULL rather than RESTRICT because player-created killer
-- moves CASCADE away with their creator; the log keeps its own copy of the
-- name and the resolved numbers, so history stays legible when that happens.

CREATE TABLE battle_actions (
    action_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    battle_id        BIGINT   NOT NULL,
    actor_no         SMALLINT NOT NULL,
    turn_number      INTEGER  NOT NULL CHECK (turn_number >= 1),

    action           TEXT     NOT NULL
                     CHECK (action IN ('technique', 'pass', 'flee', 'system')),

    technique_id     BIGINT   REFERENCES techniques (technique_id) ON DELETE SET NULL,
    technique_name   TEXT,

    target_no        SMALLINT,

    -- The damage pipeline's stages, as they resolved (see 0008). Stored, not
    -- recomputed: a later rebalance must not rewrite what a past hit did.
    base_power       INTEGER,
    attainment_bonus NUMERIC(6, 4),
    matchup_modifier NUMERIC(6, 4),
    damage           BIGINT   CHECK (damage IS NULL OR damage >= 0),

    -- Set when this action revealed a weakness/resistance (spec section 6);
    -- the app mirrors it into player_bestiary_paths in the same transaction.
    discovered_path  TEXT     REFERENCES paths (code) ON DELETE RESTRICT,

    detail           JSONB    NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    FOREIGN KEY (battle_id, actor_no)
        REFERENCES battle_combatants (battle_id, combatant_no) ON DELETE CASCADE,
    FOREIGN KEY (battle_id, target_no)
        REFERENCES battle_combatants (battle_id, combatant_no) ON DELETE CASCADE,

    -- A technique action must say which technique, by name at minimum - the id
    -- may be nulled later, the name may not.
    CONSTRAINT battle_actions_technique_is_named
        CHECK (action <> 'technique' OR technique_name IS NOT NULL)
);

-- Serves both composite FKs (same leading columns) and "replay this battle".
CREATE INDEX battle_actions_battle_idx    ON battle_actions (battle_id, actor_no);
CREATE INDEX battle_actions_target_idx    ON battle_actions (battle_id, target_no);
CREATE INDEX battle_actions_replay_idx    ON battle_actions (battle_id, turn_number, action_id);
CREATE INDEX battle_actions_technique_idx ON battle_actions (technique_id);
CREATE INDEX battle_actions_discovery_idx ON battle_actions (discovered_path);

COMMENT ON TABLE battle_actions IS
    'Append-only combat log. Resolved numbers are stored so history survives rebalancing.';


-- ---------------------------------------------------------------------------
-- world_boss_instances
-- ---------------------------------------------------------------------------
-- A spawned world boss: one shared HP pool, attacked by many players over its
-- lifetime, no turn structure.

CREATE TABLE world_boss_instances (
    instance_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    species_id  BIGINT      NOT NULL REFERENCES creature_species (species_id) ON DELETE RESTRICT,

    max_hp      BIGINT      NOT NULL CHECK (max_hp > 0),
    current_hp  BIGINT      NOT NULL CHECK (current_hp >= 0),

    spawned_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at  TIMESTAMPTZ NOT NULL,

    status      TEXT        NOT NULL DEFAULT 'alive'
                CHECK (status IN ('alive', 'defeated', 'expired')),
    ended_at    TIMESTAMPTZ,

    CONSTRAINT world_boss_hp_within_cap    CHECK (current_hp <= max_hp),
    CONSTRAINT world_boss_expiry_after_spawn CHECK (expires_at > spawned_at),
    CONSTRAINT world_boss_ended_matches_status
        CHECK ((status = 'alive') = (ended_at IS NULL)),

    -- 'defeated' means exactly that - a boss cannot be marked down with HP
    -- still in the pool.
    CONSTRAINT world_boss_defeated_means_zero_hp
        CHECK (status <> 'defeated' OR current_hp = 0)
);

CREATE INDEX world_boss_instances_species_idx ON world_boss_instances (species_id);

-- One living instance per species. Two simultaneous copies of the same boss
-- would split the server's damage meaninglessly; different species may coexist.
CREATE UNIQUE INDEX world_boss_one_alive_per_species_idx
    ON world_boss_instances (species_id)
    WHERE status = 'alive';


-- ---------------------------------------------------------------------------
-- world_boss_contributions
-- ---------------------------------------------------------------------------
-- Per-player damage tally against one instance. Drives the damage ranking and
-- the reward sweep; rewarded_at rather than a boolean so "when" is answerable
-- and double-payment is visible.

CREATE TABLE world_boss_contributions (
    instance_id     BIGINT      NOT NULL REFERENCES world_boss_instances (instance_id) ON DELETE CASCADE,
    player_id       BIGINT      NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    damage_dealt    BIGINT      NOT NULL DEFAULT 0 CHECK (damage_dealt >= 0),
    attacks         INTEGER     NOT NULL DEFAULT 0 CHECK (attacks >= 0),
    highest_hit     BIGINT      NOT NULL DEFAULT 0 CHECK (highest_hit >= 0),

    first_attack_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_attack_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    rewarded_at     TIMESTAMPTZ,

    PRIMARY KEY (instance_id, player_id)
);

CREATE INDEX world_boss_contributions_player_idx ON world_boss_contributions (player_id);

-- The damage ranking, read every time the boss UI renders.
CREATE INDEX world_boss_contributions_ranking_idx
    ON world_boss_contributions (instance_id, damage_dealt DESC);
