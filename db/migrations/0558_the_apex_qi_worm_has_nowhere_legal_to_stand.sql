-- 0558_the_apex_qi_worm_has_nowhere_legal_to_stand
--
-- The Dao Qi Sea Gu is withdrawn. Ranks 1 to 8 stay.
--
-- Two standing rules meet at rank 9 and leave no room between them.
--
--     0209 / 0516   no single Gu may carry more than three fifths of its
--                   effect's cap, or one worm makes the other slots decoration
--     0514          value per point of aperture must CLIMB with rank, or the
--                   cheapest worm is the best worm again
--
-- `max_qi` has a flat cap of 1.0, and the rank 8 worm already sits at 0.5576 -
-- 55.8% of it. So:
--
--     worm                      magnitude   per point   % of cap
--     rank 8 (already exists)      0.5576      0.0697      55.8
--     rank 9 on the curve          0.6750      0.0750      67.5   <- breaks 0209
--     rank 9 at the 60% rule       0.6000      0.0667      60.0   <- breaks 0514
--
-- A legal rank 9 is WORSE per point of aperture than the rank 8 below it,
-- which is precisely the inversion 0514 was written to end. There is no third
-- number. The apex qi worm cannot exist while the cap is 1.0, and 0555 only
-- managed to ship one by lifting that cap on its way past - which 0557 already
-- put back, for reasons that still hold.
--
-- So the worm goes rather than the rule. `test_no_single_gu_finishes_an_effect
-- _on_its_own` found it, as it was written to.
--
-- WHAT THIS LEAVES, which is worth being plain about. Ranks 1 to 8 are real
-- and on the curve, but they TIE the existing best at each rank rather than
-- beating it - so what they add is a worm that is obviously the qi worm, not
-- more qi than the game could already give. The ceiling on casting was never
-- the worms:
--
--     the Gu lane  =  cap (1.0) x source_share (0.600)  =  0.600, for everyone
--
-- and one existing rank 8 worm already reaches 0.5576 of it. A rank 18
-- cultivator goes from 2 casts of a heavy move to 3, and cannot go further by
-- any arrangement of worms that exists or could be added.
--
-- GETTING PAST THREE IS A CAP DECISION, not a roster one. Raising `max_qi`'s
-- flat cap - say 1.0 to 1.40 - would widen the lane to 0.840, make room for an
-- apex worm at 0.84 on the curve, and take a heavy move from 2 casts to 4. It
-- would also widen every cultivator's pool at every realm, which is a balance
-- change nobody asked for and is not smuggled in here.
--
-- Deliberately NOT done: giving `max_qi` a `cap_per_rank`. 0492 lifted exactly
-- two lids and `test_only_the_two_flattening_effects_scale` holds that line.


DELETE FROM gu_region_drops
WHERE gu_type_id IN (SELECT gu_type_id FROM gu_types WHERE code = 'dao_qi_sea_gu');

DELETE FROM gu_recipes
WHERE gu_type_id IN (SELECT gu_type_id FROM gu_types WHERE code = 'dao_qi_sea_gu');

DELETE FROM gu_type_effects
WHERE gu_type_id IN (SELECT gu_type_id FROM gu_types WHERE code = 'dao_qi_sea_gu');

DELETE FROM gu_types WHERE code = 'dao_qi_sea_gu';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_rk   RECORD;
    v_prev NUMERIC := 0;
BEGIN
    -- 1. IT IS GONE, and nothing of it is left behind in the side tables.
    IF EXISTS (SELECT 1 FROM gu_types WHERE code = 'dao_qi_sea_gu') THEN
        RAISE EXCEPTION 'the apex qi worm is still on the roster';
    END IF;
    SELECT count(*) INTO v_n
    FROM gu_type_effects e
    LEFT JOIN gu_types t ON t.gu_type_id = e.gu_type_id
    WHERE t.gu_type_id IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% orphaned Gu effect row(s) left behind', v_n;
    END IF;

    -- 2. NOBODY WAS CARRYING ONE. It existed for three migrations and never
    --    dropped anywhere a player could reach, but a worm is deleted here and
    --    somebody holding one would have lost it.
    IF EXISTS (
        SELECT 1 FROM player_gu g
        LEFT JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE t.gu_type_id IS NULL
    ) THEN
        RAISE EXCEPTION 'a cultivator is holding a Gu that no longer exists';
    END IF;

    -- 3. THE LINE THAT REMAINS IS EIGHT, AND STILL CLIMBS.
    SELECT count(*) INTO v_n FROM gu_types WHERE code LIKE '%qi_sea_gu';
    IF v_n <> 8 THEN
        RAISE EXCEPTION 'the qi line has % worms, expected 8', v_n;
    END IF;

    FOR v_rk IN
        SELECT t.rank, e.magnitude / t.rank AS per_point
        FROM gu_types t JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
        WHERE t.code LIKE '%qi_sea_gu' AND e.effect_code = 'max_qi'
        ORDER BY t.rank
    LOOP
        IF v_rk.per_point <= v_prev THEN
            RAISE EXCEPTION 'the qi ladder stalls at rank %', v_rk.rank;
        END IF;
        v_prev := v_rk.per_point;
    END LOOP;

    -- 4. AND EVERY ONE OF THEM OBEYS THE THREE-FIFTHS RULE, which is the rule
    --    the apex could not.
    SELECT count(*) INTO v_n
    FROM gu_types t
    JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
    JOIN gu_effects f ON f.code = e.effect_code
    WHERE t.code LIKE '%qi_sea_gu' AND e.magnitude > 0.6 * f.cap;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% of the qi line still eat a whole ceiling', v_n;
    END IF;

    RAISE NOTICE
        'eight qi worms, ranks 1 to 8, climbing and inside every cap';
END
$probe$;
