-- 0005_bestiary
--
-- Enemy species, their Path interactions, and what each player has discovered
-- about them (spec sections 6 and 7).
--
-- The design point this table set exists to serve: a player should NOT know a
-- creature's weaknesses on sight. They find them by attacking with different
-- Paths and reading the result, or by deducing them with Wisdom Path. So the
-- truth about a species and each player's knowledge of that truth are separate
-- things, and the game reads the second when deciding what to show.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- creature_species
-- ---------------------------------------------------------------------------
-- The catalogue of things that can be fought. Instances of them in an actual
-- battle live in the encounter tables; this is the definition.

CREATE TABLE creature_species (
    species_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    code        TEXT     NOT NULL UNIQUE,
    name        TEXT     NOT NULL,

    rank        SMALLINT NOT NULL DEFAULT 1 CHECK (rank BETWEEN 1 AND 9),

    -- 'beast'  - ordinary wild encounter
    -- 'elite'  - tougher, gates dungeon progress
    -- 'boss'   - dungeon or expedition boss
    -- 'world'  - shared world boss many players damage at once
    kind        TEXT     NOT NULL DEFAULT 'beast'
                CHECK (kind IN ('beast', 'elite', 'boss', 'world')),

    -- Base stats before rank/level scaling is applied at spawn time.
    base_hp     INTEGER  NOT NULL CHECK (base_hp > 0),
    base_attack INTEGER  NOT NULL DEFAULT 0 CHECK (base_attack >= 0),
    base_defense INTEGER NOT NULL DEFAULT 0 CHECK (base_defense >= 0),
    base_speed  INTEGER  NOT NULL DEFAULT 0 CHECK (base_speed >= 0),

    description TEXT     NOT NULL DEFAULT '',

    -- Bespoke mechanics: enrage thresholds, phase changes, spawn conditions.
    -- Open-ended by nature and never filtered on, so JSONB rather than a wide
    -- table of columns only bosses would use.
    traits      JSONB    NOT NULL DEFAULT '{}'::jsonb,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER creature_species_set_updated_at
    BEFORE UPDATE ON creature_species
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX creature_species_rank_idx ON creature_species (rank, kind);


-- ---------------------------------------------------------------------------
-- creature_paths
-- ---------------------------------------------------------------------------
-- What a creature IS, Path-wise. Two jobs: it types the creature's own attacks,
-- and it is the DEFAULT defender type for incoming techniques - so a Wood Path
-- beast inherits the whole chart's opinion of Wood without anyone listing its
-- weaknesses by hand.

CREATE TABLE creature_paths (
    species_id BIGINT  NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,
    path_code  TEXT    NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,
    is_primary BOOLEAN NOT NULL DEFAULT TRUE,

    PRIMARY KEY (species_id, path_code)
);

CREATE INDEX creature_paths_path_idx ON creature_paths (path_code);

-- At most one primary Path per species. A partial UNIQUE index expresses this
-- directly; a CHECK could not, since it cannot see sibling rows.
CREATE UNIQUE INDEX creature_paths_one_primary_idx
    ON creature_paths (species_id)
    WHERE is_primary;


-- ---------------------------------------------------------------------------
-- creature_path_modifiers
-- ---------------------------------------------------------------------------
-- Per-species overrides for INCOMING damage of a given Path.
--
-- Resolution order when a technique of Path P hits a creature:
--     1. a row here for (species, P)            -- explicit, wins
--     2. otherwise path_matchups (P -> creature's own Path)   -- derived
--     3. otherwise neutral
--
-- Both layers are needed. The chart alone cannot express the spec's example
-- bestiary entry - the Nine Distortion Wolf resists Sword and Earth, which is a
-- fact about that beast's hide rather than about its Path. The chart alone also
-- cannot express immunity, which has no chart equivalent at all.

CREATE TABLE creature_path_modifiers (
    species_id  BIGINT NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,
    path_code   TEXT   NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    -- References the same tunable magnitudes the chart uses, so a species
    -- override rebalances along with everything else. 'immunity' is the one
    -- interaction only this table can express; it is added below.
    interaction TEXT   NOT NULL REFERENCES matchup_interactions (code) ON DELETE RESTRICT,

    -- Shown once discovered: "The creature's metallic scales resist your Sword
    -- Path attack."
    flavour_text TEXT,

    PRIMARY KEY (species_id, path_code)
);

CREATE INDEX creature_path_modifiers_path_idx ON creature_path_modifiers (path_code);
CREATE INDEX creature_path_modifiers_interaction_idx ON creature_path_modifiers (interaction);

-- Total damage negation, which the ordinary advantage/resistance scale has no
-- way to express. Spec section 7 lists hidden immunities as something high
-- Wisdom attainment can reveal.
INSERT INTO matchup_interactions (code, name, damage_modifier, sort_order)
VALUES ('immunity', 'Immunity', -1.0000, 5);

COMMENT ON TABLE creature_path_modifiers IS
    'Explicit per-species incoming-damage overrides. Beats the derived chart lookup; the only place immunity can be expressed.';


-- ---------------------------------------------------------------------------
-- player_bestiary
-- ---------------------------------------------------------------------------
-- One row per species a player has met. Counters only; what they have *learned*
-- is the next table.

CREATE TABLE player_bestiary (
    player_id        BIGINT      NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    species_id       BIGINT      NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,

    times_encountered INTEGER    NOT NULL DEFAULT 0 CHECK (times_encountered >= 0),
    times_defeated    INTEGER    NOT NULL DEFAULT 0 CHECK (times_defeated >= 0),

    first_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, species_id)
);

CREATE INDEX player_bestiary_species_idx ON player_bestiary (species_id);


-- ---------------------------------------------------------------------------
-- player_bestiary_paths
-- ---------------------------------------------------------------------------
-- The discovery log: one row per (player, species, Path) fact the player has
-- uncovered. Presence of a row means "this player knows how that species reacts
-- to that Path"; the interaction itself is never copied here, it is read from
-- creature_path_modifiers at display time.
--
-- Storing knowledge as presence rather than as a copy of the value is what
-- keeps a rebalance honest: retune a species and every player's bestiary shows
-- the new truth, instead of thousands of stale snapshots of the old one.
--
-- "Unknown Traits: 2" is then a count difference, not a stored number.

CREATE TABLE player_bestiary_paths (
    player_id      BIGINT      NOT NULL,
    species_id     BIGINT      NOT NULL,
    path_code      TEXT        NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    -- 'combat'  - learned the hard way, by landing a technique of this Path
    -- 'insight' - deduced via Wisdom Path attainment (spec section 7)
    -- 'shared'  - told by another player, or a sect bestiary
    discovered_via TEXT        NOT NULL DEFAULT 'combat'
                   CHECK (discovered_via IN ('combat', 'insight', 'shared')),

    discovered_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, species_id, path_code),

    -- Composite FK: a discovery cannot exist for a species the player has never
    -- encountered, and it disappears with the bestiary entry.
    FOREIGN KEY (player_id, species_id)
        REFERENCES player_bestiary (player_id, species_id) ON DELETE CASCADE
);

CREATE INDEX player_bestiary_paths_path_idx ON player_bestiary_paths (path_code);

COMMENT ON TABLE player_bestiary_paths IS
    'Discovery log. A row means the player knows this species'' reaction to this Path; the value is read live, never copied.';


-- ---------------------------------------------------------------------------
-- Convenience view: a species' full incoming-damage profile
-- ---------------------------------------------------------------------------
-- Resolves the two-layer lookup described above once, so combat and the
-- bestiary UI cannot drift apart by implementing the precedence differently.
-- Only non-neutral interactions appear - neutral remains the absent-row default
-- everywhere in this schema.

CREATE VIEW creature_incoming_paths AS
WITH derived AS (
    -- Layer 2: whatever the chart says about attacking this creature's Path.
    --
    -- DISTINCT ON collapses dual-typed creatures, where one attacking Path can
    -- match both of their types. The most attacker-favourable interaction wins
    -- rather than the two stacking - stacking is how Pokemon reaches 4x, and
    -- spec section 3 is explicit that even 2x is too extreme once attainment,
    -- Dao Marks, equipment and crits are all multiplying too.
    SELECT DISTINCT ON (cp.species_id, pm.attacker_path)
        cp.species_id,
        pm.attacker_path AS path_code,
        pm.interaction
    FROM creature_paths cp
    JOIN paths p  ON p.code = cp.path_code AND p.uses_matchups
    JOIN path_matchups pm ON pm.defender_path = cp.path_code
    JOIN matchup_interactions mi ON mi.code = pm.interaction
    ORDER BY cp.species_id, pm.attacker_path, mi.damage_modifier DESC
)
SELECT
    o.species_id,
    o.path_code,
    o.interaction,
    TRUE AS is_override,
    o.flavour_text
FROM creature_path_modifiers o

UNION ALL

SELECT
    d.species_id,
    d.path_code,
    d.interaction,
    FALSE,
    NULL
FROM derived d
WHERE NOT EXISTS (
    SELECT 1
    FROM creature_path_modifiers o
    WHERE o.species_id = d.species_id
      AND o.path_code  = d.path_code
);

COMMENT ON VIEW creature_incoming_paths IS
    'Resolved incoming-damage profile per species: explicit overrides win over the derived type chart.';
