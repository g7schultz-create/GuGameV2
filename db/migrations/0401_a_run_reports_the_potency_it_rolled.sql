-- 0401_a_run_reports_the_potency_it_rolled
--
-- 0400's `refine_many` returns harmony and stars and forgets potency, which
-- `render_result` prints on every single refinement. So the bench screen had
-- to invent the missing field, and a display that invents a number is a
-- display that will one day invent the wrong one - the run of ONE goes through
-- the same screen a single refinement always did, and that screen was handed a
-- NULL where a potency belonged.
--
-- The run reports the best it rolled, which is the same thing `best_harmony`
-- and `best_stars` already report and for the same reason: across several
-- attempts the interesting number is the best the bench managed.
--
-- The return type moves, so this DROPs and recreates. The body is lifted with
-- `pg_get_functiondef` and patched rather than retyped - four replacements,
-- each asserted to match exactly once.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'refine_many';

    IF body IS NULL THEN
        RAISE EXCEPTION 'refine_many is missing';
    END IF;

    -- ---- what it hands back -----------------------------------------------
    anchor := 'best_stars smallint, made jsonb)';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine_many does not return what 0400 gave it';
    END IF;
    body := replace(body, anchor,
        'best_stars smallint, best_potency numeric, made jsonb)');

    -- ---- somewhere to keep it ---------------------------------------------
    anchor := '    v_stars  SMALLINT := 0;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine_many no longer declares its stars';
    END IF;
    body := replace(body, anchor, concat(
        '    v_stars  SMALLINT := 0;', chr(10),
        '    v_pot    NUMERIC := 0;'));

    -- ---- taken off each attempt, beside the stars -------------------------
    anchor := '            v_stars  := GREATEST(v_stars, COALESCE(v_one.stars_made, 1));';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine_many no longer tracks its stars in the loop';
    END IF;
    body := replace(body, anchor, concat(
        '            v_stars  := GREATEST(v_stars, COALESCE(v_one.stars_made, 1));', chr(10),
        '            v_pot    := GREATEST(v_pot, COALESCE(v_one.potency_score, 0));'));

    -- ---- and reported --------------------------------------------------
    anchor := '           COALESCE(v_lvl, v_skill), v_best, v_worst, v_stars,';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine_many no longer reports where it did';
    END IF;
    body := replace(body, anchor,
        '           COALESCE(v_lvl, v_skill), v_best, v_worst, v_stars, v_pot,');

    DROP FUNCTION refine_many(BIGINT, BIGINT, TEXT[], INTEGER[], INTEGER);
    EXECUTE body;
END;
$patch$;


COMMENT ON FUNCTION refine_many(BIGINT, BIGINT, TEXT[], INTEGER[], INTEGER) IS
    'Works a run of refinements through refine_gu, after checking the whole run is affordable. Reports the best harmony, stars and potency the bench managed.';


-- ---------------------------------------------------------------------------
-- A run of one carries everything a single refinement did
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_single TEXT;
    v_run    TEXT;
    v_missing TEXT;
BEGIN
    -- Every column the single-refinement screen reads must be answerable from
    -- a run, or the screen goes back to inventing one.
    v_single := pg_get_function_result(
        (SELECT oid FROM pg_proc WHERE proname = 'refine_gu'));
    v_run := pg_get_function_result(
        (SELECT oid FROM pg_proc WHERE proname = 'refine_many'));

    IF v_run NOT LIKE '%best_potency%' THEN
        RAISE EXCEPTION 'a run still does not report a potency';
    END IF;
    IF v_run NOT LIKE '%best_harmony%' OR v_run NOT LIKE '%best_stars%' THEN
        RAISE EXCEPTION 'a run lost a column it used to report';
    END IF;

    -- The four the bench screen actually prints for one refinement.
    FOREACH v_missing IN ARRAY ARRAY['harmony', 'stars', 'potency', 'exp_gained']
    LOOP
        IF v_run NOT LIKE '%' || v_missing || '%' THEN
            RAISE EXCEPTION
                'a run cannot answer for %, which the screen prints', v_missing;
        END IF;
    END LOOP;

    RAISE NOTICE 'a run answers for everything a single refinement did';
END;
$probe$;
