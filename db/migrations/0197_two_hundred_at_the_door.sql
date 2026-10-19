-- 0197_two_hundred_at_the_door
--
-- 0194 moved the rate ladder to 125/135/150. This moves the base to 200 and
-- lets the grades climb from there:
--
--     tier 5:  125%  ->  200%
--     tier 6:  135%  ->  215%
--     tier 7:  150%  ->  240%
--
-- The steps keep the shape the ladder already had - 125/135/150 climbs by
-- 1.00 / 1.08 / 1.20 and so does 200/215/240 - so a grade is worth the same
-- proportion more than the grade below it as it always was. What changed is
-- the floor.
--
-- Grade is the axis, not realm. A rate pill is already worth more at a high
-- realm without help, because it multiplies `cultivation_per_hour`, and that
-- carries `realm_cultivation_scale` inside it: the same +200% is 6,400/hr to
-- a rank 4 cultivator and far more to a rank 6 one. Scaling the PERCENTAGE by
-- realm as well would have compounded the two.
--
-- Both rate kinds move, as in 0194: `attainment_rate` reads the same
-- `pill_tiers.rate_bonus`.
--
-- Nothing in a bag is edited. `take_pill` reads the ladder when the pill is
-- swallowed, and hours already banked keep the rate they were banked at,
-- because `grant_boost` stores an hours-weighted average.
--
-- Forward-only. Do not edit once applied.


UPDATE pill_tiers SET rate_bonus = 2.0000 WHERE tier = 5;
UPDATE pill_tiers SET rate_bonus = 2.1500 WHERE tier = 6;
UPDATE pill_tiers SET rate_bonus = 2.4000 WHERE tier = 7;


DO $$
DECLARE
    base NUMERIC;
    thin TEXT;
    step NUMERIC;
BEGIN
    -- The base that was asked for, at the lowest grade that can brew a rate
    -- pill - found through `pill_kinds.min_tier` rather than written as 5.
    SELECT pt.rate_bonus INTO base
    FROM pill_tiers pt
    WHERE pt.tier = (SELECT min(pk.min_tier) FROM pill_kinds pk
                     WHERE pk.code IN ('cultivation_rate', 'attainment_rate'));

    IF base <> 2.00 THEN
        RAISE EXCEPTION 'the base grade pays % rather than 2.00', base;
    END IF;

    -- Still climbs.
    SELECT string_agg(a.tier || ' >= ' || b.tier, ', ') INTO thin
    FROM pill_tiers a JOIN pill_tiers b ON b.tier = a.tier + 1
    WHERE a.rate_bonus >= b.rate_bonus AND b.rate_bonus > 0;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'the rate ladder does not climb: %', thin;
    END IF;

    -- And climbs by the proportions it always did, so raising the floor did
    -- not quietly flatten the difference between a grade 5 and a grade 7.
    SELECT round(max(pt.rate_bonus) / min(pt.rate_bonus), 2) INTO step
    FROM pill_tiers pt WHERE pt.rate_bonus > 0;

    IF step <> 1.20 THEN
        RAISE EXCEPTION
            'the top grade is now %x the bottom rather than 1.20x', step;
    END IF;

    -- Grades that cannot brew a rate pill must not advertise a rate.
    SELECT string_agg(pt.tier::text, ', ') INTO thin
    FROM pill_tiers pt
    WHERE pt.rate_bonus > 0
      AND pt.tier < (SELECT min(pk.min_tier) FROM pill_kinds pk
                     WHERE pk.code IN ('cultivation_rate', 'attainment_rate'));

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these grades pay a rate they cannot brew: %', thin;
    END IF;
END;
$$;
