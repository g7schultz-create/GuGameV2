-- 0470_two_swings_at_the_same_seam
--
-- `delve_record` throws the moment a tile hands over the same thing twice:
--
--     ON CONFLICT DO UPDATE command cannot affect row a second time
--
-- A seam is worth two strikes and both of them draw from the same region's
-- veins, so two pulls of Cloud Soil in one tile is the ordinary case rather
-- than an unlucky one. Postgres will not let a single INSERT settle the same
-- key twice, however the conflict clause is written.
--
-- The fix is to add the rows up BEFORE offering them to the table. The haul
-- is a tally; a tally of two piles of the same thing is one pile.
--
-- Found by `test_the_lift_ends_with_the_delve`, which walks a delve far
-- enough to work a seam twice - which is also why that test was written to
-- walk rather than to assert about a function.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION delve_record(p_delve_id bigint, p_found jsonb)
RETURNS void
LANGUAGE sql
AS $fn$
    INSERT INTO delve_haul (delve_id, what, how_many)
    -- Grouped first: a seam is two strikes and both may bring back the same
    -- stone, and one statement may not settle one key twice.
    SELECT p_delve_id, e ->> 'what', sum((e ->> 'how_many')::bigint)
    FROM jsonb_array_elements(COALESCE(p_found, '[]'::jsonb)) e
    WHERE e ->> 'what' IS NOT NULL
      AND COALESCE((e ->> 'how_many')::bigint, 0) > 0
    GROUP BY e ->> 'what'
    ON CONFLICT (delve_id, what) DO UPDATE
    SET how_many = delve_haul.how_many + EXCLUDED.how_many;
$fn$;


-- ---------------------------------------------------------------------------
-- One tile may hand over the same thing twice
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p   BIGINT;
    v_id  BIGINT;
    v_one BIGINT;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
        ORDER BY p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- A delve row to hang a tally on, without walking anything.
        INSERT INTO delve_runs
            (player_id, region_code, width, height, at_x, at_y, actions_left)
        VALUES (v_p, (SELECT code FROM regions ORDER BY code LIMIT 1),
                5, 6, 2, 5, 1)
        RETURNING delve_id INTO v_id;

        -- The shape that threw: one find list naming the same thing twice.
        PERFORM delve_record(v_id, jsonb_build_array(
            jsonb_build_object('what', 'Cloud Soil', 'how_many', 30),
            jsonb_build_object('what', 'Cloud Soil', 'how_many', 20),
            jsonb_build_object('what', 'White Snow Iron', 'how_many', 7)));

        SELECT h.how_many INTO v_one FROM delve_haul h
        WHERE h.delve_id = v_id AND h.what = 'Cloud Soil';
        IF v_one <> 50 THEN
            RAISE EXCEPTION
                'two strikes at one seam tallied % rather than 50', v_one;
        END IF;

        -- And a second tile still adds to what is already there.
        PERFORM delve_record(v_id, jsonb_build_array(
            jsonb_build_object('what', 'Cloud Soil', 'how_many', 5)));

        SELECT h.how_many INTO v_one FROM delve_haul h
        WHERE h.delve_id = v_id AND h.what = 'Cloud Soil';
        IF v_one <> 55 THEN
            RAISE EXCEPTION 'the second tile left the tally at %', v_one;
        END IF;

        RAISE NOTICE 'two strikes and a second tile tally to %', v_one;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
