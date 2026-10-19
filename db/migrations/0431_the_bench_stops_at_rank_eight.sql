-- 0431_the_bench_stops_at_rank_eight
--
-- 0430 opened the bench to 9 and this closes it back to 8, which is the
-- decision rather than a correction of one: rank 9 is Fate Gu, Destiny Gu,
-- Derivation Gu and the three Dao Gu, and those are not things a refiner
-- should be able to sit down and make.
--
-- NOBODY LOSES ANYTHING. The bench stood open for about fifteen minutes and
-- not one rank 9 Gu was refined in that time - the two cultivators deep enough
-- to try were not at a bench. So this takes nothing back off anybody, which is
-- the only reason it can be a plain config change rather than an unpicking.
--
-- Rank 8 stays open. It is 74 recipes at Gu Refiner 52, every ingredient of
-- which the world actually drops, and it was the rank the 0393 note pointed
-- at in the first place.
--
-- WHAT THIS DOES NOT DO, and it is worth knowing before anybody assumes rank 9
-- is now unreachable: there are already 54 rank 9 Gu in the world, and they
-- did not come from the bench. Every one was FOUND, 32 in Black Heaven and 22
-- in White Heaven. The immortal regions hand them out directly, and that route
-- is untouched here. Closing the bench governs what a refiner may MAKE; it
-- says nothing about what the deep regions give. If rank 9 Gu are meant to be
-- rarer than they are, the dial is in those regions' drop tables and not in
-- this number.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 8, description =
    'The highest rank of Gu the bench will attempt. Separate from gu_max_droppable_rank on purpose: what the world hands out and what a refiner may make are different questions. Rank 7 opened in 0393, 8 and 9 in 0430, and 9 was closed again in 0431 - Fate Gu and the Dao Gu are found, not made. Rank 9 recipes still exist and are still refused here.'
WHERE key = 'gu_max_refinable_rank';


-- ---------------------------------------------------------------------------
-- Rank 8 is open, rank 9 is shut, and neither is a surprise
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_type BIGINT;
    v_said TEXT;
    r      RECORD;
BEGIN
    IF game_config_value('gu_max_refinable_rank') <> 8 THEN
        RAISE EXCEPTION 'the bench stops at % rather than 8',
            game_config_value('gu_max_refinable_rank');
    END IF;

    -- The deepest refiner in the game must be refused at rank 9 by the BENCH,
    -- not by their level - they are past the level, and a message about
    -- levelling would send them on a climb that changes nothing.
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL
        ORDER BY profession_level(p.player_id, 'gu_refining') DESC LIMIT 1;

        SELECT c.gu_type_id INTO v_type FROM gu_recipe_costs c
        WHERE c."rank" = 9 ORDER BY c.gu_type_id LIMIT 1;

        IF v_who IS NULL OR v_type IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        BEGIN
            PERFORM refine_gu(v_who, v_type, ARRAY[]::text[], ARRAY[]::integer[]);
            RAISE EXCEPTION 'a rank 9 Gu was refined after the bench was shut';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;

        IF v_said NOT LIKE '%bench has not been opened%' THEN
            RAISE EXCEPTION
                'rank 9 was refused for the wrong reason: %', v_said;
        END IF;

        -- And rank 8 is genuinely open for the same person: whatever stops
        -- them there, it is no longer the bench.
        SELECT c.gu_type_id INTO v_type FROM gu_recipe_costs c
        WHERE c."rank" = 8 ORDER BY c.gu_type_id LIMIT 1;

        BEGIN
            PERFORM refine_gu(v_who, v_type, ARRAY[]::text[], ARRAY[]::integer[]);
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM LIKE '%bench has not been opened%' THEN
                RAISE EXCEPTION 'rank 8 was shut along with rank 9';
            END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing was taken away: no rank 9 Gu was ever refined.
    RAISE NOTICE
        '% rank 9 Gu exist, all of them found rather than made', (
        SELECT count(*) FROM player_gu pg
        JOIN gu_types t ON t.gu_type_id = pg.gu_type_id WHERE t."rank" >= 9);

    FOR r IN
        SELECT COALESCE(pg.found_in, '(made at a bench)') AS source, count(*) AS n
        FROM player_gu pg
        JOIN gu_types t ON t.gu_type_id = pg.gu_type_id
        WHERE t."rank" >= 9 GROUP BY 1 ORDER BY 2 DESC
    LOOP
        RAISE NOTICE '  % : %', rpad(r.source, 22), r.n;
    END LOOP;
END;
$probe$;
