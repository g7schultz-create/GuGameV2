-- 0258_one_tolerance_wherever_it_is_earned
--
-- Refining Tolerance has three readers and two of them cannot see most of the
-- ways it is granted.
--
-- `refine_forecast` reads it through `player_stat`, which is every source a
-- cultivator has. `forge` and `brew` read it through `physique_stat`, which is
-- the physique's own table and nothing else. So the effect softens a Path
-- conflict when you refine pages, and does nothing at the anvil or the
-- cauldron - for three Gu, and for the Destiny 0254 added, and for anything
-- else that ever grants it.
--
-- That is the failure this project keeps finding wearing a new coat. It is not
-- an effect nobody reads; it is an effect read three times from two different
-- pockets. The audit in 0255 missed it because it asked whether every effect
-- HAD a reader and never asked whether every reader looked in the same place.
--
-- These two are the only readers in the database that reach past `player_stat`
-- for a narrower source - checked, not assumed - so this is the whole of it.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src  TEXT;
    old  TEXT;
    each TEXT;
BEGIN
    FOREACH each IN ARRAY ARRAY['forge', 'brew'] LOOP
        SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = each;

        old := 'relief := LEAST(1, physique_stat(p_player_id, ''refine_conflict_relief''));';

        IF position(old IN src) = 0 THEN
            RAISE EXCEPTION '% no longer reads its tolerance the old way', each;
        END IF;

        EXECUTE replace(src, old,
            'relief := LEAST(1, player_stat(p_player_id, ''refine_conflict_relief''));');
    END LOOP;
END;
$$;


DO $$
DECLARE
    narrow TEXT;
    who    BIGINT;
BEGIN
    -- Every reader of every effect now looks in the same pocket.
    SELECT string_agg(p.proname, ', ') INTO narrow
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname <> 'player_stat'
      AND p.prosrc ~ '(gu_stat|equipment_stat|physique_stat|root_stat|dwelling_stat|manual_stat|destiny_stat)\(';

    IF narrow IS NOT NULL THEN
        RAISE EXCEPTION
            'these read a narrower source than the effect is granted from: %',
            narrow;
    END IF;

    -- And a granted tolerance actually reaches the anvil.
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to measure with; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        DELETE FROM player_destinies WHERE player_id = who AND rank = 2;
        INSERT INTO player_destinies (player_id, rank, code, offered, chosen_at)
        VALUES (who, 2, 'hundred_refinements',
                ARRAY['hundred_refinements'], now());

        IF player_stat(who, 'refine_conflict_relief') <= 0 THEN
            RAISE EXCEPTION 'a written tolerance is worth nothing';
        END IF;

        IF position('player_stat(p_player_id, ''refine_conflict_relief'')' IN
                    (SELECT prosrc FROM pg_proc WHERE proname = 'forge')) = 0 THEN
            RAISE EXCEPTION 'the anvil still cannot see it';
        END IF;
        IF position('player_stat(p_player_id, ''refine_conflict_relief'')' IN
                    (SELECT prosrc FROM pg_proc WHERE proname = 'brew')) = 0 THEN
            RAISE EXCEPTION 'the cauldron still cannot see it';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
