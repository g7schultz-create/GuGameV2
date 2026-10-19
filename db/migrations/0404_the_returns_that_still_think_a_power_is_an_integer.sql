-- 0404_the_returns_that_still_think_a_power_is_an_integer
--
-- m_i_y_u_k_i cannot refine. `/refine` raises
--
--     structure of query does not match function result type
--     PL/pgSQL function refine_technique_preview line 50 at RETURN QUERY
--
-- whenever the pile would teach a technique - which is every pile they care
-- about, since they are holding thirty-four technique pages up to tier 14.
--
-- IT IS MY OWN BREAKAGE FROM 0394. That migration widened
-- `techniques.base_power` to bigint. `refine_technique_preview` declares
-- `power integer` and selects that column straight into it, and a plpgsql
-- RETURN QUERY matches its declared shape exactly rather than coercing. The
-- screen asks for the preview before it will draw the confirm, so the whole
-- command dies on a function that only ever reported a number.
--
-- 0403 swept for narrow CASTS and found one. It did not sweep for narrow
-- RETURN COLUMNS, which is the same mistake wearing a different hat, and this
-- is the fifth time in three days that this 32-bit ceiling has been found by a
-- player rather than by me. So the sweep is widened to both, and the test that
-- carries it is widened with it.
--
-- TWO FUNCTIONS, AND ONLY ONE OF THEM IS ON FIRE.
--
--   `refine_technique_preview` is broken right now. plpgsql, RETURN QUERY,
--     declared integer, handed a bigint.
--
--   `compute_creature_damage` is not, yet. It declares `base_power integer`
--     and reads `creature_species.base_attack` - widened to bigint by 0347 -
--     into an INTEGER local. The largest creature in the game hits for
--     819,200,000, which is 38 per cent of the way to the ceiling, so it works
--     today and stops working the first time anything is written above The
--     Last Apricot. It has been flagged and left alone more than once. It is
--     being fixed now rather than after somebody's fight crashes.
--
--   `technique_shelf` selects the same widened column into an integer column
--     too, and is LANGUAGE sql, which coerces instead of refusing. It is
--     wrong in the same way and harmless in practice; it is left alone rather
--     than dropped and recreated for a cast Postgres is already doing.
--
-- Both return types move, so both DROP and recreate. Bodies are lifted and
-- patched, never retyped.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    -- ---- the one that is broken -------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'refine_technique_preview';

    IF body IS NULL THEN
        RAISE EXCEPTION 'refine_technique_preview is missing';
    END IF;

    anchor := 'name text, power integer, rank smallint';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'refine_technique_preview does not return what 0379 gave it';
    END IF;

    body := replace(body, anchor, 'name text, power bigint, rank smallint');

    -- Both early returns pad the row out with typed NULLs, and the fifth of
    -- them is the column that just moved. A RETURN QUERY matches its declared
    -- shape on EVERY branch, not only the one that carries a real answer -
    -- which is what the first draft of this migration learned the hard way.
    anchor := 'NULL::bigint, NULL::text, NULL::integer, NULL::smallint, NULL::text';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 2 THEN
        RAISE EXCEPTION
            'refine_technique_preview no longer pads two branches the way it did';
    END IF;
    body := replace(body, anchor,
        'NULL::bigint, NULL::text, NULL::bigint, NULL::smallint, NULL::text');

    DROP FUNCTION refine_technique_preview(BIGINT, BIGINT[]);
    EXECUTE body;

    -- ---- and the one that is one dungeon away from it ---------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_creature_damage';

    IF body IS NULL THEN
        RAISE EXCEPTION 'compute_creature_damage is missing';
    END IF;

    anchor := 'RETURNS TABLE(base_power integer, attainment_bonus numeric, matchup_modifier numeric, pre_defense numeric, final_damage bigint)';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_creature_damage does not return what it did';
    END IF;
    body := replace(body, anchor,
        'RETURNS TABLE(base_power bigint, attainment_bonus numeric, matchup_modifier numeric, pre_defense numeric, final_damage bigint)');

    -- The local that reads `base_attack`, which 0347 widened underneath it.
    anchor := '    atk           INTEGER;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_creature_damage no longer declares atk once';
    END IF;
    body := replace(body, anchor, '    atk           BIGINT;');

    DROP FUNCTION compute_creature_damage(BIGINT, BIGINT, NUMERIC, BIGINT);
    EXECUTE body;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The preview answers, and nothing in the damage path is narrow any more
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_ids  BIGINT[];
    v_pv   RECORD;
    v_bad  TEXT;
    v_n    INTEGER := 0;
BEGIN
    -- Narrow RETURN COLUMNS, which 0403's sweep did not look at.
    SELECT string_agg(p.proname || ' -> ' || pg_get_function_result(p.oid), ' | ')
    INTO v_bad
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prorettype = 'record'::regtype
      AND pg_get_function_result(p.oid) ~ '(power|damage|attack|thews) integer'
      AND p.prosrc ~ 'RETURN QUERY';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these still hand a power back through an integer: %', left(v_bad, 300);
    END IF;

    -- And narrow LOCALS reading a column that is not one.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prosrc ~ 'atk\s+INTEGER|tech_base\s+INTEGER|thews\s+INTEGER';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still read a power into an integer: %', v_bad;
    END IF;

    -- THE REPORT: every pile of technique pages anybody holds, previewed.
    FOR v_who IN
        SELECT DISTINCT mp.owner_id FROM manual_pages mp
        WHERE mp.page_type = 'technique' AND mp.consumed_at IS NULL
    LOOP
        SELECT array_agg(page_id) INTO v_ids FROM (
            SELECT mp.page_id FROM manual_pages mp
            WHERE mp.owner_id = v_who AND mp.consumed_at IS NULL
              AND mp.page_type = 'technique'
            ORDER BY mp.tier DESC LIMIT 7) x;

        SELECT * INTO v_pv FROM refine_technique_preview(v_who, v_ids);
        v_n := v_n + 1;

        RAISE NOTICE '% : carries=% %',
            rpad((SELECT p.discord_name FROM players p
                  WHERE p.player_id = v_who), 14),
            v_pv.carries, COALESCE(v_pv.name, v_pv.reason);
    END LOOP;

    IF v_n = 0 THEN
        RAISE NOTICE 'nobody holds a technique page; the tests carry this';
    END IF;

    -- And a creature still swings, through the function whose return moved.
    PERFORM compute_creature_damage(
        (SELECT species_id FROM creature_species ORDER BY base_attack DESC LIMIT 1),
        (SELECT player_id FROM players WHERE deleted_at IS NULL LIMIT 1),
        1::numeric, 0::bigint);
END;
$probe$;
