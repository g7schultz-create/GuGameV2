-- 0430_the_bench_is_opened_to_rank_nine
--
-- `gu_max_refinable_rank` has been 7 since 0393, and its own description ends
-- "raise this again to open rank 8, which wants Gu Refiner level 52". Both
-- ranks above it are opened here, because the two refiners who would use them
-- are already past the level for either:
--
--     clearwest      Gu Refiner 74      rank 9 wants 65
--     m_i_y_u_k_i.   Gu Refiner 71      rank 8 wants 52
--
-- They have been capped at rank 7 by a number rather than by their own skill
-- for a while now, which is the point at which a ceiling stops being a goal
-- and starts being a wall.
--
-- WHAT IS BEHIND IT. 74 recipes at rank 8 and 15 at rank 9, and every one of
-- them is really craftable: all 31 materials the rank 8 recipes ask for, and
-- all 20 the rank 9 recipes ask for, are dropped by something in the world.
-- None is a name in a table with no route to it. That is worth checking
-- rather than assuming - 0411 had to go back and fill six forge parts that
-- had stopped existing at rank 10, and a rank opened onto unobtainable
-- ingredients is the same disappointment with more steps.
--
-- THE LEVEL IS STILL THE GATE, and it is a real one: `refine_gu` refuses on
-- `required_level` before it looks at anything else, so opening the bench
-- hands rank 8 to nobody who has not earned Gu Refiner 52. Two people can use
-- this today out of thirty; the next nearest is level 19.
--
-- `gu_max_droppable_rank` is deliberately left at 5. What the world hands out
-- and what a refiner may make are different questions - 0393 said so and it
-- is still true. Rank 8 and 9 Gu are things somebody makes, not things that
-- fall out of a beast.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 9, description =
    'The highest rank of Gu the bench will attempt. Separate from gu_max_droppable_rank on purpose: what the world hands out and what a refiner may make are different questions. Rank 7 opened in 0393 and ranks 8 and 9 in 0430; rank 9 is the top of the recipe book, so this number has nowhere further to go until somebody writes rank 10 recipes.'
WHERE key = 'gu_max_refinable_rank';


-- ---------------------------------------------------------------------------
-- The whole book is open, and the level is what keeps it shut
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_top   SMALLINT;
    v_bad   TEXT;
    v_who   BIGINT;
    v_type  BIGINT;
    r       RECORD;
BEGIN
    SELECT max(c."rank") INTO v_top FROM gu_recipe_costs c;

    IF game_config_value('gu_max_refinable_rank') < v_top THEN
        RAISE EXCEPTION 'the book goes to rank % and the bench stops at %',
            v_top, game_config_value('gu_max_refinable_rank');
    END IF;

    -- Nothing newly opened asks for a material the world never hands over.
    SELECT string_agg(DISTINCT x.code, ', ') INTO v_bad
    FROM (
        SELECT c.base_material AS code FROM gu_recipe_costs c WHERE c."rank" >= 8
        UNION ALL
        SELECT c.secondary_material FROM gu_recipe_costs c
        WHERE c."rank" >= 8 AND c.secondary_material IS NOT NULL
    ) x
    WHERE NOT EXISTS (SELECT 1 FROM creature_drops cd WHERE cd.material_code = x.code)
      AND NOT EXISTS (SELECT 1 FROM region_materials rm WHERE rm.material_code = x.code);

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'rank 8 and 9 recipes want materials nothing drops: %', v_bad;
    END IF;

    -- And the level gate still bites. Somebody shallow must still be refused.
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL
          AND profession_level(p.player_id, 'gu_refining') < 52
        ORDER BY p.player_id LIMIT 1;

        SELECT c.gu_type_id INTO v_type FROM gu_recipe_costs c
        WHERE c."rank" = 8 ORDER BY c.gu_type_id LIMIT 1;

        IF v_who IS NULL OR v_type IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        BEGIN
            PERFORM refine_gu(v_who, v_type, ARRAY[]::text[], ARRAY[]::integer[]);
            RAISE EXCEPTION 'a shallow refiner was allowed at a rank 8 recipe';
        EXCEPTION WHEN check_violation THEN
            -- Refused, which is the point. It may refuse on the level or on
            -- the materials; what matters is that the BENCH no longer refuses.
            IF SQLERRM LIKE '%bench has not been opened%' THEN
                RAISE EXCEPTION 'the bench still refuses rank 8 outright';
            END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT c."rank", count(*) AS recipes, min(c.required_level) AS wants_level,
               (SELECT count(*) FROM players p
                WHERE p.deleted_at IS NULL
                  AND profession_level(p.player_id, 'gu_refining')
                      >= min(c.required_level)) AS who_can
        FROM gu_recipe_costs c WHERE c."rank" >= 7
        GROUP BY c."rank" ORDER BY c."rank"
    LOOP
        RAISE NOTICE 'rank % : % recipes, Gu Refiner %, % cultivator(s) qualify',
            r."rank", r.recipes, r.wants_level, r.who_can;
    END LOOP;
END;
$probe$;
