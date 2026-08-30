-- 0004_techniques
--
-- Techniques and killer moves: the things a cultivator actually uses in a turn.
--
-- A technique's Path typing is what makes combat work - it selects which
-- attainment bonus applies (spec section 2) and which row of path_matchups is
-- consulted. Weakness is a property of the TECHNIQUE, not of the attacker's
-- primary Path, which is the whole reason cultivating several Paths pays off.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- techniques
-- ---------------------------------------------------------------------------
-- Definitions, covering both hand-authored canonical content and killer moves
-- generated for a player (a Grandmaster benefit, spec section 8). One table
-- rather than two: combat only ever needs "a technique definition", and
-- splitting them would mean every join in the damage pipeline becoming a union.
-- `created_by` is what distinguishes them - NULL means canonical content.

CREATE TABLE techniques (
    technique_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- Stable handle for canonical content, so seeds and tests can refer to a
    -- technique without knowing its generated id. NULL for player-created
    -- moves, which have no meaning outside their owner. UNIQUE tolerates many
    -- NULLs in Postgres, so this needs no partial index.
    code          TEXT UNIQUE,

    name          TEXT     NOT NULL,

    -- Gates use behind cultivation realm (spec section 9: cultivation
    -- determines rank restrictions).
    rank          SMALLINT NOT NULL DEFAULT 1
                  CHECK (rank BETWEEN 1 AND 9),

    -- 'attack'  - deals damage, consults the matchup chart
    -- 'support' - buffs, heals, sets up
    -- 'defense' - mitigation and resistance
    -- 'utility' - analysis, escape, everything else (e.g. Wisdom Path's
    --             enemy-reading from spec section 7)
    category      TEXT     NOT NULL
                  CHECK (category IN ('attack', 'support', 'defense', 'utility')),

    -- Step one of the damage pipeline, before attainment and matchup are
    -- applied. Zero for techniques that do not deal damage.
    base_power    INTEGER  NOT NULL DEFAULT 0 CHECK (base_power >= 0),

    -- Cost as a fraction of max qi rather than a flat number, so a technique
    -- stays meaningfully priced as a cultivator's pool grows by orders of
    -- magnitude across realms.
    qi_cost_pct   NUMERIC(6, 4) NOT NULL DEFAULT 0
                  CHECK (qi_cost_pct >= 0 AND qi_cost_pct <= 1),

    accuracy      NUMERIC(6, 4) NOT NULL DEFAULT 1
                  CHECK (accuracy > 0 AND accuracy <= 1),

    cooldown_turns SMALLINT NOT NULL DEFAULT 0 CHECK (cooldown_turns >= 0),

    -- Open-ended rider effects: burns, stuns, lifesteal, defence penetration.
    -- Genuinely schemaless - each Path's effects differ - and never filtered on
    -- in the damage hot path, so JSONB is the right call here rather than a
    -- wide table of mostly-NULL columns.
    effects       JSONB    NOT NULL DEFAULT '{}'::jsonb,

    description   TEXT     NOT NULL DEFAULT '',

    -- NULL = canonical content shared by everyone. Set = a killer move created
    -- by this player. CASCADE because a generated move has no meaning once its
    -- creator is gone; canonical rows are unaffected, having a NULL here.
    created_by    BIGINT   REFERENCES players (player_id) ON DELETE CASCADE,

    -- Reproduces a generated move exactly, for debugging a "why did I get
    -- this" report without storing the whole generator's intermediate state.
    generation_seed BIGINT,

    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A canonical technique must be addressable by code; a generated one must
    -- not pretend to be canonical content.
    CONSTRAINT techniques_canonical_has_code
        CHECK ((created_by IS NULL) = (code IS NOT NULL))
);

CREATE TRIGGER techniques_set_updated_at
    BEFORE UPDATE ON techniques
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX techniques_created_by_idx ON techniques (created_by)
    WHERE created_by IS NOT NULL;
CREATE INDEX techniques_rank_idx ON techniques (rank, category);

COMMENT ON TABLE techniques IS
    'Technique definitions. created_by NULL = canonical content; set = a player-generated killer move.';


-- ---------------------------------------------------------------------------
-- technique_paths
-- ---------------------------------------------------------------------------
-- A technique's Path typing, one row per Path. Most have one; dual-Path moves
-- like "Blazing Heaven Sword" (Sword + Fire) have two, and the design leaves
-- room for more.
--
-- `weight` implements spec section 5: an even split reproduces the simple
-- average of attainment bonuses, and an uneven one (0.70 Sword / 0.30 Fire)
-- gives the weighted formula rare moves are meant to use. Weights must total
-- exactly 1 per technique - enforced below, because a typo here silently
-- inflates or deflates every hit the move ever lands.

CREATE TABLE technique_paths (
    technique_id BIGINT NOT NULL REFERENCES techniques (technique_id) ON DELETE CASCADE,
    path_code    TEXT   NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    weight       NUMERIC(6, 4) NOT NULL DEFAULT 1
                 CHECK (weight > 0 AND weight <= 1),

    PRIMARY KEY (technique_id, path_code)
);

CREATE INDEX technique_paths_path_idx ON technique_paths (path_code);


-- Row-level CHECKs cannot see sibling rows, so the "weights sum to 1" rule
-- needs a constraint trigger. DEFERRABLE INITIALLY DEFERRED so it fires once at
-- COMMIT rather than mid-INSERT: inserting a 0.70/0.30 pair would otherwise
-- fail on the first row, when the total is legitimately still 0.70.
CREATE OR REPLACE FUNCTION check_technique_path_weights()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    target_id BIGINT := COALESCE(NEW.technique_id, OLD.technique_id);
    total     NUMERIC;
BEGIN
    SELECT COALESCE(SUM(weight), 0) INTO total
    FROM technique_paths
    WHERE technique_id = target_id;

    -- Zero rows is the legitimate mid-transaction state of deleting a
    -- technique, whose own CASCADE removes these rows. Only a non-empty set
    -- that fails to total 1 is an error.
    IF total <> 0 AND total <> 1 THEN
        RAISE EXCEPTION
            'technique % has Path weights totalling %, must be exactly 1',
            target_id, total;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER technique_paths_weights_sum_to_one
    AFTER INSERT OR UPDATE OR DELETE ON technique_paths
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_technique_path_weights();

COMMENT ON TABLE technique_paths IS
    'Path typing per technique. Weights must total exactly 1 - enforced by a deferred constraint trigger.';


-- ---------------------------------------------------------------------------
-- player_techniques
-- ---------------------------------------------------------------------------
-- Which techniques a player knows, and how well. Separate from `techniques`
-- because comprehension is per-player: two cultivators can know the same
-- canonical move to very different depth.

CREATE TABLE player_techniques (
    player_id     BIGINT      NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    technique_id  BIGINT      NOT NULL REFERENCES techniques (technique_id) ON DELETE CASCADE,

    -- Per-player mastery of this specific move, distinct from Path attainment
    -- (which covers the whole Path). Spec section 8 lists better technique
    -- comprehension as a Master-tier benefit.
    comprehension INTEGER     NOT NULL DEFAULT 0 CHECK (comprehension >= 0),

    times_used    BIGINT      NOT NULL DEFAULT 0 CHECK (times_used >= 0),
    learned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, technique_id)
);

CREATE TRIGGER player_techniques_set_updated_at
    BEFORE UPDATE ON player_techniques
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- FK index for the CASCADE, and it answers "who knows this technique?".
CREATE INDEX player_techniques_technique_idx ON player_techniques (technique_id);


-- ---------------------------------------------------------------------------
-- player_loadout
-- ---------------------------------------------------------------------------
-- The techniques carried into a fight. Battles are turn-based with no
-- switching, so the loadout is committed before the fight starts and is the
-- player's entire answer to whatever they meet - which is exactly what makes
-- Path coverage a real decision rather than an afterthought.
--
-- Slot-per-row rather than four columns on `players`: the slot count becomes a
-- balance number instead of a schema change, and the FK to player_techniques
-- makes equipping a move you do not know impossible rather than merely checked.

CREATE TABLE player_loadout (
    player_id    BIGINT      NOT NULL,
    slot_index   SMALLINT    NOT NULL CHECK (slot_index BETWEEN 0 AND 15),
    technique_id BIGINT      NOT NULL,

    equipped_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, slot_index),

    -- Composite FK: guarantees the player actually knows this technique, and
    -- un-learning it clears the slot automatically.
    FOREIGN KEY (player_id, technique_id)
        REFERENCES player_techniques (player_id, technique_id) ON DELETE CASCADE,

    -- The same move twice would be a wasted slot and a UI bug waiting to
    -- happen, so it is prevented rather than validated.
    CONSTRAINT player_loadout_no_duplicates UNIQUE (player_id, technique_id)
);

COMMENT ON TABLE player_loadout IS
    'Techniques carried into battle. Composite FK to player_techniques makes equipping an unknown move impossible.';
