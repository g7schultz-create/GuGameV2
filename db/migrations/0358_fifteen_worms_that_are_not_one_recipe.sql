-- 0358_fifteen_worms_that_are_not_one_recipe
--
-- 0357 derived its recipes the way 0346 does - best Path affinity for the
-- herb, best affinity beast part from something within two ranks - and eight
-- of the fifteen came out holding the same two ingredients. Every strength
-- worm and every earth worm landed on black cloud soil and a beast horn,
-- because 'best affinity' has exactly one winner per Path and both Paths
-- happen to rank the same material first.
--
-- Mechanically that is legal and the game is already full of it: three
-- thousand recipes share four hundred pairs, and one pair is worn by
-- fifty-three worms. Refining picks the WORM and reads its recipe, so a shared
-- pair never makes anything ambiguous or unreachable.
--
-- It still misses the point. These fifteen exist because Sinew had fifteen
-- worms and no spread, and a Venerable's arm that is gathered exactly like the
-- rank 2 ox worm is the same redundancy the last four migrations have been
-- removing, moved from the effect list to the shopping list.
--
-- So the assignment becomes greedy rather than independent: walk the fifteen
-- in order, and give each the best-affinity ingredient NO OTHER ONE OF THEM
-- has already taken. Affinity still chooses - a Metal worm still gets the most
-- Metal thing left - it is simply not allowed to choose the same thing twice.
-- Fifteen distinct herbs and fifteen distinct parts out of 205 and 55, so
-- nothing is scraping the bottom of either list to be different.
--
-- Only the fifteen from 0357 are touched. The rest of the catalogue keeps the
-- pairs it has.
--
-- Forward-only. Do not edit once applied.


DO $assign$
DECLARE
    g        RECORD;
    herb     TEXT;
    part     TEXT;
    taken_h  TEXT[] := ARRAY[]::TEXT[];
    taken_p  TEXT[] := ARRAY[]::TEXT[];
    mine     TEXT[] := ARRAY[
        'wild_ox_strength_gu','iron_arm_gu','stone_sinew_gu','bear_might_gu',
        'tiger_force_gu','bronze_muscle_gu','titan_thew_gu','war_ox_gu',
        'mountain_lifting_gu','iron_bull_gu','giant_sinew_gu','primordial_arm_gu',
        'heaven_lifting_gu','titan_heart_gu','venerable_strength_gu'];
BEGIN
    -- Deliberately ordered: the strongest worm chooses first, so if the pool
    -- ever did run thin it is the rank 2 ox that settles, not the Venerable.
    FOR g IN
        SELECT gu_type_id, code, rank, path_code
        FROM gu_types WHERE code = ANY(mine)
        ORDER BY rank DESC, code
    LOOP
        SELECT m.code INTO herb
        FROM materials m
        WHERE m.category = 'gathering'
          AND NOT (m.code = ANY(taken_h))
          AND EXISTS (SELECT 1 FROM region_materials rm WHERE rm.material_code = m.code)
        ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
        LIMIT 1;

        SELECT m.code INTO part
        FROM materials m
        WHERE m.category = 'beast'
          AND NOT (m.code = ANY(taken_p))
          AND EXISTS (SELECT 1 FROM creature_drops d
                      JOIN creature_species s ON s.species_id = d.species_id
                      WHERE d.material_code = m.code AND s.rank <= g.rank + 2)
        ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
        LIMIT 1;

        IF herb IS NULL OR part IS NULL THEN
            RAISE EXCEPTION 'nothing left to build % out of', g.code;
        END IF;

        UPDATE gu_recipes
        SET base_material = herb, secondary_material = part
        WHERE gu_type_id = g.gu_type_id;

        taken_h := taken_h || herb;
        taken_p := taken_p || part;
    END LOOP;
END;
$assign$;


-- ---------------------------------------------------------------------------
-- Fifteen worms, fifteen recipes, and affinity still doing the choosing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n    INTEGER;
    bad  TEXT;
    r    RECORD;
    mine TEXT[] := ARRAY[
        'wild_ox_strength_gu','iron_arm_gu','stone_sinew_gu','bear_might_gu',
        'tiger_force_gu','bronze_muscle_gu','titan_thew_gu','war_ox_gu',
        'mountain_lifting_gu','iron_bull_gu','giant_sinew_gu','primordial_arm_gu',
        'heaven_lifting_gu','titan_heart_gu','venerable_strength_gu'];
BEGIN
    -- The whole complaint, stated as an assertion.
    SELECT count(DISTINCT (r2.base_material, r2.secondary_material)) INTO n
    FROM gu_recipes r2 JOIN gu_types g ON g.gu_type_id = r2.gu_type_id
    WHERE g.code = ANY(mine);
    IF n <> 15 THEN
        RAISE EXCEPTION 'the fifteen share recipes: only % distinct pairs', n;
    END IF;

    -- Still a real recipe, not merely a different one: the trigger's rule is
    -- re-checked here because an UPDATE that satisfied it is not the same
    -- claim as the ingredients being the right KIND.
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_recipes r2
    JOIN gu_types g ON g.gu_type_id = r2.gu_type_id
    JOIN materials b ON b.code = r2.base_material
    JOIN materials s ON s.code = r2.secondary_material
    WHERE g.code = ANY(mine)
      AND (b.category <> 'gathering' OR s.category <> 'beast');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are built out of the wrong kind of thing: %', bad;
    END IF;

    -- Every base can actually be gathered and every part actually dropped, so
    -- 'distinct' did not quietly mean 'unobtainable'.
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_recipes r2
    JOIN gu_types g ON g.gu_type_id = r2.gu_type_id
    WHERE g.code = ANY(mine)
      AND (NOT EXISTS (SELECT 1 FROM region_materials rm
                       WHERE rm.material_code = r2.base_material)
       OR  NOT EXISTS (SELECT 1 FROM creature_drops d
                       JOIN creature_species sp ON sp.species_id = d.species_id
                       WHERE d.material_code = r2.secondary_material
                         AND sp.rank <= g.rank + 2));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cannot be sourced: %', bad;
    END IF;

    -- And affinity is still choosing rather than being overridden by the
    -- distinctness rule: a Metal worm should not be gathering something Metal
    -- has no opinion about while a Metal herb sits unused.
    SELECT count(*) INTO n
    FROM gu_recipes r2
    JOIN gu_types g ON g.gu_type_id = r2.gu_type_id
    WHERE g.code = ANY(mine)
      AND material_affinity(r2.base_material, g.path_code) > 0;
    IF n < 12 THEN
        RAISE EXCEPTION
            'only % of the fifteen gather something their Path cares about', n;
    END IF;

    FOR r IN
        SELECT g.rank, g.name, r2.base_material, r2.secondary_material
        FROM gu_recipes r2 JOIN gu_types g ON g.gu_type_id = r2.gu_type_id
        WHERE g.code = ANY(mine) ORDER BY g.rank, g.name
    LOOP
        RAISE NOTICE 'r% % : % + %',
            r.rank, r.name, r.base_material, r.secondary_material;
    END LOOP;
END;
$probe$;
