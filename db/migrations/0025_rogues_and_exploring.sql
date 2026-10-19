-- 0025_rogues_and_exploring
--
-- Three changes, all about where pages come from.
--
-- 1. THE PAGE DROP TABLES GO. 0023 built `creature_page_drops` and
--    `region_page_drops` and left them empty, expecting pages to fall off
--    beasts and out of the ground. They do not: a manual page is written by a
--    person, and the only people out here are rogue cultivators. Dropping the
--    tables rather than leaving them unused - they encode a rule that is no
--    longer the rule, and an empty table with a wrong idea in it is worse than
--    no table.
--
-- 2. ROGUE CULTIVATORS. They are `creature_species` rows with kind 'rogue',
--    not a parallel enemy table. That is the whole reason they can be fought:
--    hunt() already resolves a fight against a species, and a second enemy
--    type with its own combat path is a second combat path to keep in step.
--    What makes them rogues is the kind, the loot, and that you do not choose
--    to meet them.
--
-- 3. EXPLORING. A third thing to do in a region, beside gathering and hunting.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Pages no longer fall off beasts or out of the ground
-- ---------------------------------------------------------------------------

DROP FUNCTION roll_page_drops(BIGINT, BIGINT, TEXT);
DROP TABLE creature_page_drops;
DROP TABLE region_page_drops;


-- ---------------------------------------------------------------------------
-- 'rogue' joins the creature kinds
-- ---------------------------------------------------------------------------

ALTER TABLE creature_species DROP CONSTRAINT creature_species_kind_check;

ALTER TABLE creature_species
    ADD CONSTRAINT creature_species_kind_check
    CHECK (kind IN ('beast', 'elite', 'boss', 'world', 'rogue'));

COMMENT ON COLUMN creature_species.kind IS
    'beast/elite/boss/world are wildlife; rogue is a hostile cultivator, fought through the same pipeline but never chosen.';


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('rogue_spawn_chance', 0.10,
     'PLACEHOLDER - chance any gather, hunt or explore is interrupted by a rogue cultivator.'),
    ('rogue_page_min', 1,
     'PLACEHOLDER - fewest pages a beaten rogue yields.'),
    ('rogue_page_max', 3,
     'PLACEHOLDER - most pages a beaten rogue yields.'),
    ('rogue_page_tier_spread', 2,
     'A rogue of rank N carries pages of tier N to N+this. Their own cultivation is the ceiling on what they were carrying.'),
    ('explore_cooldown_minutes', 15,
     'PLACEHOLDER - wait between explorations.'),
    ('explore_spirit_stone_min', 2,
     'PLACEHOLDER - fewest spirit stones a find yields.'),
    ('explore_spirit_stone_max', 9,
     'PLACEHOLDER - most spirit stones a find yields.');


-- ---------------------------------------------------------------------------
-- The rogues
-- ---------------------------------------------------------------------------
-- Cultivators who took to the road, ranked 1 to 4. Their stats sit above the
-- wildlife of the same rank - a person who cultivates is harder than a boar -
-- which is what makes an ambush an event rather than a delay.

INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('rogue_wanderer', 'Wandering Rogue Cultivator', 1, 'rogue',
     380, 24, 18, 20,
     'Left a sect, or was left by one. Carries everything they own and most of it is paper.'),

    ('rogue_blade_drifter', 'Blade Drifter', 1, 'rogue',
     340, 27, 12, 26,
     'Sells the sword and keeps the manuals, which is the wrong way round and they know it.'),

    ('rogue_herb_thief', 'Herb Thief', 1, 'rogue',
     300, 20, 14, 30,
     'Works the same slopes you do, and got there first.'),

    ('rogue_poison_adept', 'Wandering Poison Adept', 2, 'rogue',
     520, 34, 20, 24,
     'Does not need to win the fight, only to still be standing at the end of it.'),

    ('rogue_ash_ascetic', 'Ash Ascetic', 2, 'rogue',
     600, 31, 28, 14,
     'Burned their own sect records. Will explain why at length.'),

    ('rogue_bone_collector', 'Bone Collector', 3, 'rogue',
     900, 48, 34, 18,
     'Reads the dead more carefully than the living, and pays better attention to both.'),

    ('rogue_storm_exile', 'Storm Exile', 3, 'rogue',
     820, 54, 26, 34,
     'Exiled for a technique they refuse to stop using.'),

    ('rogue_shadow_inheritor', 'Shadow Inheritor', 4, 'rogue',
     1400, 74, 44, 32,
     'Someone left them an inheritance. Whoever it was is not around to be asked about it.');

INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path_code, v.is_primary
FROM (VALUES
    ('rogue_wanderer',         'human',     TRUE),
    ('rogue_blade_drifter',    'sword',     TRUE),
    ('rogue_herb_thief',       'theft',     TRUE),
    ('rogue_herb_thief',       'wood',      FALSE),
    ('rogue_poison_adept',     'poison',    TRUE),
    ('rogue_ash_ascetic',      'fire',      TRUE),
    ('rogue_ash_ascetic',      'refinement',FALSE),
    ('rogue_bone_collector',   'bone',      TRUE),
    ('rogue_bone_collector',   'soul',      FALSE),
    ('rogue_storm_exile',      'lightning', TRUE),
    ('rogue_storm_exile',      'wind',      FALSE),
    ('rogue_shadow_inheritor', 'shadow',    TRUE),
    ('rogue_shadow_inheritor', 'illusion',  FALSE)
) AS v (species_code, path_code, is_primary)
JOIN creature_species s ON s.code = v.species_code;

-- A cultivator's body is not a beast's, so they yield the same beast materials
-- only where it makes sense - and mostly they yield what they were carrying,
-- which is pages.
INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT s.species_id, v.material, v.chance, v.lo, v.hi
FROM (VALUES
    ('rogue_wanderer',         'beast_blood',   0.40, 1, 2),
    ('rogue_blade_drifter',    'beast_blood',   0.40, 1, 2),
    ('rogue_herb_thief',       'beast_blood',   0.35, 1, 1),
    ('rogue_poison_adept',     'venom_sac',     0.45, 1, 2),
    ('rogue_ash_ascetic',      'heroic_soul',   0.20, 1, 1),
    ('rogue_bone_collector',   'bone_fragment', 0.60, 2, 4),
    ('rogue_bone_collector',   'tormented_soul',0.25, 1, 1),
    ('rogue_storm_exile',      'beast_core',    0.30, 1, 1),
    ('rogue_shadow_inheritor', 'soul_crystal',  0.40, 1, 2),
    ('rogue_shadow_inheritor', 'heroic_soul',   0.30, 1, 1)
) AS v (species_code, material, chance, lo, hi)
JOIN creature_species s ON s.code = v.species_code;

-- Rogues wander: every region, weighted by how lawless it is. They are never
-- placed for /hunt to find - that command lists what LIVES here, and a rogue
-- is passing through - but creature_regions is what a spawn draws from.
INSERT INTO creature_regions (species_id, region_code, weight)
SELECT s.species_id, r.code,
       CASE r.danger_level WHEN 2 THEN 4 WHEN 3 THEN 6 ELSE 10 END
FROM creature_species s
CROSS JOIN regions r
WHERE s.kind = 'rogue'
  AND s.rank <= CASE r.danger_level WHEN 2 THEN 2 WHEN 3 THEN 2 ELSE 4 END;


-- ---------------------------------------------------------------------------
-- spawn_rogue
-- ---------------------------------------------------------------------------
-- Whether this action is interrupted, and by whom. Called at the top of
-- gathering, hunting and exploring; returns NULL almost always.
--
-- The rogue is drawn from those placed in this region, weighted, so a lawless
-- region produces both more ambushes and worse ones.

CREATE FUNCTION spawn_rogue(p_region TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    found BIGINT;
BEGIN
    IF random() >= game_config_value('rogue_spawn_chance') THEN
        RETURN NULL;
    END IF;

    SELECT s.species_id INTO found
    FROM creature_regions cr
    JOIN creature_species s ON s.species_id = cr.species_id
    WHERE cr.region_code = p_region AND s.kind = 'rogue'
    ORDER BY -ln(random()) / cr.weight
    LIMIT 1;

    RETURN found;
END;
$$;

COMMENT ON FUNCTION spawn_rogue(TEXT) IS
    'A rogue cultivator interrupting an action, or NULL. Drawn from the rogues placed in the region, weighted by its lawlessness.';


-- ---------------------------------------------------------------------------
-- rogue_pages
-- ---------------------------------------------------------------------------
-- What a beaten rogue was carrying. The only source of manual pages in the
-- game: a page is written by a person, so it comes off a person.
--
-- Tier is bounded by the rogue's own rank - they were not carrying anything
-- they could not read.

CREATE FUNCTION rogue_pages(p_player_id BIGINT, p_species_id BIGINT, p_region TEXT)
RETURNS SETOF BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    r        SMALLINT;
    is_rogue BOOLEAN;
    lo       SMALLINT;
    hi       SMALLINT;
    n        INTEGER;
BEGIN
    SELECT rank, kind = 'rogue' INTO r, is_rogue
    FROM creature_species WHERE species_id = p_species_id;

    IF NOT COALESCE(is_rogue, FALSE) THEN
        RETURN;
    END IF;

    lo := GREATEST(1, r);
    hi := LEAST(7, r + game_config_value('rogue_page_tier_spread')::smallint);

    n := game_config_value('rogue_page_min')
         + floor(random() * (game_config_value('rogue_page_max')
                             - game_config_value('rogue_page_min') + 1));

    FOR i IN 1..n LOOP
        RETURN NEXT mint_page(p_player_id, lo, hi, NULL, NULL, p_region);
    END LOOP;

    RETURN;
END;
$$;

COMMENT ON FUNCTION rogue_pages(BIGINT, BIGINT, TEXT) IS
    'Pages off a beaten rogue, tier bounded by their rank. Returns nothing for anything that is not a rogue.';


-- ---------------------------------------------------------------------------
-- explore
-- ---------------------------------------------------------------------------
-- The third thing to do in a region. Gathering takes what grows, hunting takes
-- what lives, exploring takes what was left lying around.
--
-- Outcomes are weighted rows rather than a CASE, so retuning what exploring is
-- worth - or adding a new kind of find - is an INSERT.

CREATE TABLE explore_outcomes (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    weight      NUMERIC(6, 2) NOT NULL CHECK (weight >= 0)
);

INSERT INTO explore_outcomes (code, name, description, weight) VALUES
    ('spirit_stones', 'Spirit stones',
     'A cache, a corpse, or a seam nobody worked out.', 30),
    ('gathering',     'Growing thing',
     'Something worth taking, missed by whoever came through last.', 34),
    ('beast',         'Remains',
     'A kill somebody else made and did not finish stripping.', 18),
    ('nothing',       'Nothing',
     'Ground, weather, and the walk back.', 18);

CREATE FUNCTION explore(p_player_id BIGINT)
RETURNS TABLE (
    outcome       TEXT,
    outcome_name  TEXT,
    material_code TEXT,
    material_name TEXT,
    rarity        TEXT,
    quantity      BIGINT,
    held          BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    here   TEXT;
    pick   TEXT;
    mat    TEXT;
    amount BIGINT;
    total  BIGINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    SELECT o.code INTO pick
    FROM explore_outcomes o
    WHERE o.weight > 0
    ORDER BY -ln(random()) / o.weight
    LIMIT 1;

    IF pick = 'spirit_stones' THEN
        mat    := 'spirit_stone';
        amount := game_config_value('explore_spirit_stone_min')
                  + floor(random() * (game_config_value('explore_spirit_stone_max')
                                      - game_config_value('explore_spirit_stone_min') + 1));

    ELSIF pick = 'gathering' THEN
        SELECT rm.material_code INTO mat
        FROM region_materials rm
        WHERE rm.region_code = here
        ORDER BY -ln(random()) / rm.weight
        LIMIT 1;
        amount := 1 + floor(random() * 2);

    ELSIF pick = 'beast' THEN
        -- Whatever the local wildlife is made of, taken off something already
        -- dead rather than something you killed.
        SELECT cd.material_code INTO mat
        FROM creature_regions cr
        JOIN creature_drops cd ON cd.species_id = cr.species_id
        WHERE cr.region_code = here
        ORDER BY random()
        LIMIT 1;
        amount := 1 + floor(random() * 2);
    END IF;

    IF mat IS NULL THEN
        RETURN QUERY SELECT 'nothing'::text,
                            (SELECT o.name FROM explore_outcomes o WHERE o.code = 'nothing'),
                            NULL::text, NULL::text, NULL::text, 0::bigint, 0::bigint;
        RETURN;
    END IF;

    total := grant_material(p_player_id, mat, amount);

    RETURN QUERY
    SELECT pick,
           (SELECT o.name FROM explore_outcomes o WHERE o.code = pick),
           m.code, m.name, m.rarity, amount, total
    FROM materials m WHERE m.code = mat;
END;
$$;

COMMENT ON FUNCTION explore(BIGINT) IS
    'One exploration of the current region. Outcome weights live in explore_outcomes, so retuning it is an UPDATE.';
