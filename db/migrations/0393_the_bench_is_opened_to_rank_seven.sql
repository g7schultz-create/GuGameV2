-- 0393_the_bench_is_opened_to_rank_seven
--
-- `gu_max_refinable_rank` has said what to do since 0210 wrote it:
--
--     'The highest rank of Gu the bench will attempt. Separate from
--      gu_max_droppable_rank on purpose: what the world hands out and what a
--      refiner may make are different questions. Raise this to open rank 7.'
--
-- So this raises it, and the rest of the migration is the checking that the
-- one-line change deserves.
--
-- WHAT IT OPENS. 243 rank 7 Gu, every one of which already has a recipe and a
-- required level. The level is 40, and the ladder above it was already built:
-- rank 8 wants 52 and rank 9 wants 65.
--
-- WHO CAN USE IT TODAY. clearwest at Gu Refiner 65 and m_i_y_u_k_i at 64 -
-- both of them long past 40, and both of them levelling for some time with
-- nothing above rank 6 to make. pashu0 is at 15 and everybody else is in
-- single figures, so this is not a gift to the strongest cultivator in the
-- game. It is the thing the two people who actually levelled the profession
-- have been climbing towards.
--
-- IS IT ACTUALLY MAKEABLE. Driven on clearwest before this was written: eight
-- rank 7 recipes, five attempts each, bare ingredients and no auxiliaries at
-- all - forty of forty formed, harmony at the 150 ceiling every time. Nothing
-- else was in the way, which is what made this a config change rather than a
-- feature.
--
-- WHAT IT DOES NOT OPEN. `gu_max_droppable_rank` stays at 5 and
-- `gu_max_immortal_droppable_rank` stays at 8. The world hands out what it
-- always did; this is only about the bench. That separation is the entire
-- reason 0210 made them two numbers, and a migration that quietly moved both
-- would be undoing the point of the one it is finishing.
--
-- Rank 8 and 9 stay shut, and the probe below insists on it - "opened one
-- rung" has to mean one.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 7,
    description = 'The highest rank of Gu the bench will attempt. Separate from gu_max_droppable_rank on purpose: what the world hands out and what a refiner may make are different questions. Rank 7 opened in 0393; raise this again to open rank 8, which wants Gu Refiner level 52.'
WHERE key = 'gu_max_refinable_rank';


-- ---------------------------------------------------------------------------
-- Open one rung, and only one, and one that can actually be walked
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_cap   SMALLINT := game_config_value('gu_max_refinable_rank')::smallint;
    v_bad   TEXT;
    v_who   BIGINT;
    v_gu    BIGINT;
    v_r     RECORD;
    v_got   RECORD;
    v_wins  INTEGER := 0;
    v_tries INTEGER := 0;
BEGIN
    IF v_cap <> 7 THEN
        RAISE EXCEPTION 'the bench is at rank % rather than 7', v_cap;
    END IF;

    -- The two ceilings are still two. Moving the bench must not move the world.
    IF game_config_value('gu_max_droppable_rank') <> 5 THEN
        RAISE EXCEPTION 'the drop ceiling moved with the bench';
    END IF;

    -- Every rank now open has a recipe, or "opened" opened a name with no way
    -- to make it.
    SELECT string_agg(t.name, ', ') INTO v_bad
    FROM gu_types t
    WHERE t.rank <= v_cap
      AND NOT EXISTS (SELECT 1 FROM gu_recipes r WHERE r.gu_type_id = t.gu_type_id);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these open Gu have no recipe: %', left(v_bad, 200);
    END IF;

    -- And every ingredient those recipes ask for can actually be obtained -
    -- gathered from a region or taken off something. A recipe calling for a
    -- material that exists only in the table is a rung painted on the wall.
    SELECT string_agg(DISTINCT m.name, ', ') INTO v_bad
    FROM gu_types t
    JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
    JOIN materials m ON m.code IN (r.base_material, r.secondary_material)
    WHERE t.rank = v_cap
      AND NOT EXISTS (SELECT 1 FROM region_materials rm
                      WHERE rm.material_code = m.code)
      AND NOT EXISTS (SELECT 1 FROM creature_drops cd
                      WHERE cd.material_code = m.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'rank % recipes want materials nobody can get: %', v_cap, left(v_bad, 200);
    END IF;

    -- The rung above is still shut. One rung means one.
    SELECT t.gu_type_id INTO v_gu FROM gu_types t
    WHERE t.rank = v_cap + 1 ORDER BY t.gu_type_id LIMIT 1;

    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL
      AND profession_level(p.player_id, 'gu_refining')
          >= (SELECT max(c.required_level) FROM gu_recipe_costs c
              JOIN gu_types t2 ON t2.gu_type_id = c.gu_type_id
              WHERE t2.rank = v_cap)
    ORDER BY profession_level(p.player_id, 'gu_refining') DESC
    LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE
            'nobody is levelled enough to test the bench; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        IF v_gu IS NOT NULL THEN
            BEGIN
                PERFORM refine_gu(v_who, v_gu, NULL, NULL);
                RAISE EXCEPTION 'rank % opened too', v_cap + 1;
            EXCEPTION
                WHEN check_violation THEN
                    IF SQLERRM NOT LIKE '%not been opened%' THEN
                        RAISE EXCEPTION
                            'the rung above refused for the wrong reason: %', SQLERRM;
                    END IF;
            END;
        END IF;

        -- And the rung just opened is genuinely walkable, on somebody real,
        -- with nothing but what the recipe asks for.
        PERFORM grant_material(v_who, 'spirit_stone', 1000000000);

        FOR v_r IN
            SELECT c.* FROM gu_recipe_costs c
            JOIN gu_types t ON t.gu_type_id = c.gu_type_id
            WHERE t.rank = v_cap
            ORDER BY c.gu_type_id
            LIMIT 6
        LOOP
            PERFORM grant_material(v_who, v_r.base_material,
                                   v_r.base_quantity::bigint * 3);
            PERFORM grant_material(v_who, v_r.secondary_material,
                                   v_r.secondary_quantity::bigint * 3);
            v_tries := v_tries + 1;
            SELECT * INTO v_got FROM refine_gu(v_who, v_r.gu_type_id, NULL, NULL);
            IF v_got.succeeded THEN
                v_wins := v_wins + 1;
            END IF;
        END LOOP;

        IF v_wins = 0 THEN
            RAISE EXCEPTION
                'the bench was opened to rank % and formed none of % attempts',
                v_cap, v_tries;
        END IF;

        RAISE NOTICE
            'rank % is open: % of % formed on the bare recipe, rank % still shut',
            v_cap, v_wins, v_tries, v_cap + 1;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
