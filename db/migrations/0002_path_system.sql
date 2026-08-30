-- 0002_path_system
--
-- Paths, the type-matchup chart, attainment tiers, and per-player attainment.
--
-- This is the spine of combat: a technique's Path decides which attainment
-- bonus applies and which matchup modifier is looked up. Everything here is
-- reference data plus one player-state table; the numbers live in rows rather
-- than in Python so they can be rebalanced without a deploy.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- paths
-- ---------------------------------------------------------------------------
-- Deliberate exception to the surrogate-key convention in 0001: this is small,
-- enum-like reference data that is joined by nearly every combat table and
-- hand-authored constantly in content seeds. A TEXT code means a raw row of
-- `technique_paths` reads as 'fire' instead of '7', which matters far more
-- here than four bytes per FK. Display text lives in `name`, so renaming a
-- Path for flavour never touches the key.

CREATE TABLE paths (
    code        TEXT     PRIMARY KEY,
    name        TEXT     NOT NULL UNIQUE,

    -- 'combat'  - ordinary Path, participates in the matchup chart
    -- 'special' - Human/Heaven; in the chart but with bespoke rules on top
    -- 'exotic'  - Dream, Food, Rule...; value comes from unique mechanics
    --             rather than type advantage (spec section 12)
    category    TEXT     NOT NULL
                CHECK (category IN ('combat', 'special', 'exotic')),

    -- Whether a technique of this Path consults the matchup chart at all.
    -- Exotic Paths default to false: they resolve through their own mechanics.
    uses_matchups BOOLEAN NOT NULL DEFAULT TRUE,

    description TEXT     NOT NULL DEFAULT '',
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

COMMENT ON TABLE paths IS
    'The Path types. TEXT primary key on purpose - enum-like reference data authored by hand.';


-- ---------------------------------------------------------------------------
-- matchup_interactions
-- ---------------------------------------------------------------------------
-- The configurable constants the spec asks for (section 3), as rows. Combat
-- code names an interaction; the magnitude is looked up here, so rebalancing
-- "advantage" from +25% to +20% is one UPDATE rather than a hunt through the
-- damage pipeline.

CREATE TABLE matchup_interactions (
    code            TEXT          PRIMARY KEY,
    name            TEXT          NOT NULL,

    -- Added to the matchup multiplier: +0.2500 means x1.25 damage.
    -- Signed, so 'resistance' is simply negative.
    damage_modifier NUMERIC(6, 4) NOT NULL,

    sort_order      SMALLINT      NOT NULL DEFAULT 0
);

COMMENT ON COLUMN matchup_interactions.damage_modifier IS
    'Signed additive modifier. +0.2500 = +25% damage; -0.2000 = -20%.';


-- ---------------------------------------------------------------------------
-- path_matchups
-- ---------------------------------------------------------------------------
-- Directed attacker -> defender, exactly like a Pokemon attack chart. Both
-- columns of the design chart are written from the attacker's side, so the two
-- directions of a pairing are independent facts: Fire->Wood being an advantage
-- says nothing about Wood->Fire. Neutral is the default and is stored as an
-- ABSENT ROW, which is what keeps the table at ~108 rows instead of 23x23=529.

CREATE TABLE path_matchups (
    attacker_path TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,
    defender_path TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,
    interaction   TEXT NOT NULL REFERENCES matchup_interactions (code) ON DELETE RESTRICT,

    -- Flavour for the combat log: "The creature's metallic scales resist your
    -- Sword Path attack." Optional; the UI falls back to generic wording.
    flavour_text  TEXT,

    PRIMARY KEY (attacker_path, defender_path),

    -- A Path is never strong or weak against itself.
    CONSTRAINT path_matchups_not_reflexive CHECK (attacker_path <> defender_path)
);

-- The PK already covers lookups by attacker. This covers the other direction:
-- "what is this creature weak to?", which is how the bestiary reads the chart.
CREATE INDEX path_matchups_defender_idx ON path_matchups (defender_path);
CREATE INDEX path_matchups_interaction_idx ON path_matchups (interaction);

COMMENT ON TABLE path_matchups IS
    'Directed attacker->defender type chart. Absent row = neutral. The two directions are independent.';


-- ---------------------------------------------------------------------------
-- attainment_tiers
-- ---------------------------------------------------------------------------
-- Uninitiated .. Supreme Grandmaster. `tier` is the ordinal AND the primary
-- key so that "at least Grandmaster" is `tier >= 6` - an integer comparison,
-- not a lookup of rank names.

CREATE TABLE attainment_tiers (
    tier             SMALLINT      PRIMARY KEY,
    code             TEXT          NOT NULL UNIQUE,
    name             TEXT          NOT NULL UNIQUE,

    -- Multiplier applied to techniques of the Path (spec section 1).
    damage_bonus     NUMERIC(6, 4) NOT NULL DEFAULT 0,

    -- Incoming damage reduction when hit BY this Path (spec section 8: Path
    -- resistance is a Grandmaster benefit).
    resistance_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,

    -- Cumulative insight to reach this tier from zero. Cumulative rather than
    -- incremental so deriving a tier is one indexed range scan.
    insight_required BIGINT        NOT NULL DEFAULT 0,

    CONSTRAINT attainment_tiers_tier_range CHECK (tier BETWEEN 0 AND 100)
);

COMMENT ON COLUMN attainment_tiers.tier IS
    'Ordinal and PK. Gate abilities with `tier >= n` rather than by rank name.';


-- ---------------------------------------------------------------------------
-- player_path_attainment
-- ---------------------------------------------------------------------------
-- One row per Path a player has actually touched. Sparse on purpose: a missing
-- row means Uninitiated, so a new player starts with zero rows rather than 28.
--
-- This is the table that would have been 28 columns on `players` in the old
-- design. Adding a Path is now an INSERT into `paths`, not a migration.

CREATE TABLE player_path_attainment (
    player_id       BIGINT      NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    path_code       TEXT        NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    -- Raw accumulated progress. `tier` is derived from this against
    -- attainment_tiers, but stored too: it is read on every single damage
    -- calculation, and recomputing it per hit is a join the hot path does not
    -- need. Kept in step on write, never edited independently.
    insight         BIGINT      NOT NULL DEFAULT 0,
    tier            SMALLINT    NOT NULL DEFAULT 0
                    REFERENCES attainment_tiers (tier) ON DELETE RESTRICT,

    -- Path-specific Dao Marks (spec section 9). Lives here rather than in its
    -- own table because it is always read together with attainment.
    dao_marks       INTEGER     NOT NULL DEFAULT 0,

    -- Total seconds of cultivation/training aimed at this Path. Drives the
    -- "Strength Path Insight: +8 hours" line in the spec's session summary.
    seconds_trained BIGINT      NOT NULL DEFAULT 0,

    first_gained_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, path_code),

    CONSTRAINT player_path_attainment_insight_nonneg CHECK (insight >= 0),
    CONSTRAINT player_path_attainment_marks_nonneg   CHECK (dao_marks >= 0)
);

CREATE TRIGGER player_path_attainment_set_updated_at
    BEFORE UPDATE ON player_path_attainment
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The PK's leading player_id already serves "show me this player's profile".
-- This serves the other direction: Path leaderboards, and "who has Grandmaster
-- Blood Path?" for matchmaking and sect recruitment.
CREATE INDEX player_path_attainment_by_path_idx
    ON player_path_attainment (path_code, tier DESC, insight DESC);

-- FK index for the RESTRICT above.
CREATE INDEX player_path_attainment_tier_idx ON player_path_attainment (tier);

COMMENT ON TABLE player_path_attainment IS
    'Sparse: a missing row means Uninitiated. Adding a Path is an INSERT into paths, not a migration.';
COMMENT ON COLUMN player_path_attainment.tier IS
    'Derived from insight via attainment_tiers, denormalised because it is read on every damage calculation.';


-- ---------------------------------------------------------------------------
-- game_config
-- ---------------------------------------------------------------------------
-- Global tunables the spec explicitly wants configurable rather than hard-coded
-- (the matchup cap in section 5, the cultivation trade-offs in sections 10-11).
-- Typed as NUMERIC because every value so far is a rate or a multiplier; add a
-- second table if non-numeric settings ever appear rather than stringifying.

CREATE TABLE game_config (
    key         TEXT          PRIMARY KEY,
    value       NUMERIC       NOT NULL,
    description TEXT          NOT NULL DEFAULT '',
    updated_at  TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE TRIGGER game_config_set_updated_at
    BEFORE UPDATE ON game_config
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
