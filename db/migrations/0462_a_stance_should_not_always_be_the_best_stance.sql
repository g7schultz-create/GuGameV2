-- 0462_a_stance_should_not_always_be_the_best_stance
--
-- 0461 tripled a stance's effects and clamped them at each kind's cap. A
-- hundred and fifty simulated forges say the clamp is not an edge case, it is
-- the outcome:
--
--     Set 50%   Warded 60%   Warded 60%   Warded 60%   Set 50%   Warded 60%
--
-- Every one at the ceiling. The arithmetic was there to be read and I did not
-- read it. The draw is already
--
--     cap x 0.25 x LEAST(2, power_grade) x (0.7 .. 1.3)
--
-- which at power_grade 2 or better is cap x 0.35 to cap x 0.65. Times three is
-- cap x 1.05 to cap x 1.95 - so the clamp fires on every single stance a
-- competent cultivator forges, and two stances of the same kind are identical
-- however well or badly either was forged.
--
-- THAT COSTS THE THING ITS WHOLE POINT. A forge is a sequence of choices and a
-- quality roll; if every stance lands on the same number, none of that reaches
-- the result. The cap stops being a ceiling somebody climbs to and becomes the
-- floor everybody starts on.
--
-- SO THE MULTIPLE COMES DOWN TO 1.8, which puts the range at
--
--     power_grade 1.0    cap x 0.32 to cap x 0.59
--     power_grade 2.0+   cap x 0.63 to cap x 1.17, clamped only at the top
--
-- A stance is still worth about double the same roll hung off an attack, which
-- is the trade it is paying fifteen per cent of its damage for. What it is no
-- longer is automatic.
--
-- THE PROBE NOW CHECKS BOTH ENDS. 0461 asserted that the cap is reachable,
-- which it was - far too reachable. The complementary property was the one
-- missing: a poorly forged stance must land strictly below the ceiling, or
-- there is no difference between forging well and forging at all.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1.8,
    description = 'How much larger a stance''s effects are than the same roll hung off an attack. Was 3.0 in 0461, which clamped every stance a competent cultivator forged to the kind''s cap - see 0462. At 1.8 only the best forges reach the ceiling.'
WHERE key = 'enlighten_stance_effect_multiple';


-- ---------------------------------------------------------------------------
-- A stance can reach the cap and must not start there
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_mult NUMERIC;
    b      RECORD;
    v_low  NUMERIC;
    v_high NUMERIC;
BEGIN
    v_mult := game_config_value('enlighten_stance_effect_multiple');

    FOR b IN SELECT code, cap FROM battle_effect_kinds ORDER BY code LOOP
        -- The worst forge that can produce this kind: power_grade 1, the
        -- bottom of the random band.
        v_low  := b.cap * 0.25 * 1.0 * 0.7 * v_mult;
        -- The best: power_grade at or past the ceiling the draw applies, top
        -- of the band.
        v_high := b.cap * 0.25 * 2.0 * 1.3 * v_mult;

        IF v_low >= b.cap THEN
            RAISE EXCEPTION
                'the weakest % stance already sits at the cap (% against %)',
                b.code, round(v_low, 3), b.cap;
        END IF;

        IF v_high < b.cap THEN
            RAISE EXCEPTION
                'no % stance can ever reach its cap (% against %)',
                b.code, round(v_high, 3), b.cap;
        END IF;

        -- And the trade has to be worth taking: a stance must beat the same
        -- roll left hanging off an attack by a real margin.
        IF v_mult < 1.5 THEN
            RAISE EXCEPTION
                'a stance is barely better than a rider at a multiple of %',
                v_mult;
        END IF;

        RAISE NOTICE
            '  % : cap %, a stance lands between % and %',
            rpad(b.code, 11), b.cap, round(v_low, 3),
            round(LEAST(b.cap, v_high), 3);
    END LOOP;
END;
$probe$;
