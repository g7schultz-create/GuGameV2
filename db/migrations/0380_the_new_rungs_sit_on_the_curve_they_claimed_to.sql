-- 0380_the_new_rungs_sit_on_the_curve_they_claimed_to
--
-- 0379 added page tiers 11 to 15 and put them a little off the line the first
-- ten sit on. The suite caught it, and the rule it caught me breaking is a
-- good one:
--
--     a page's power midpoint IS the manual budget it pays for, x100
--
-- Tier 7 pages run 32 to 58 - midpoint 45 - and a tier 7 manual distributes
-- 0.45. Tier 3 is 11 to 19, midpoint 15, against 0.15. The two ladders are the
-- same ladder read in two units, which is what lets a refiner look at a pile
-- of pages and know what it is worth without a table.
--
-- I built the new page powers off the tier BELOW them at a flat x1.22 and the
-- budgets off theirs at x1.21, so the two curves drifted apart by a little
-- more at every rung - tier 11 came out at a midpoint of 102.5 against a
-- budget of 99. Small, and exactly the kind of small that is a different rule
-- by tier 15.
--
-- Re-cut from the budgets, which are the side that matters: the midpoint is
-- now the budget, exactly, at all five new rungs. The spread around it keeps
-- the same shape the old rungs have - roughly a quarter either side.
--
-- Forward-only. Do not edit once applied.


UPDATE page_tiers SET power_min = 76,  power_max = 122 WHERE tier = 11;
UPDATE page_tiers SET power_min = 92,  power_max = 148 WHERE tier = 12;
UPDATE page_tiers SET power_min = 111, power_max = 179 WHERE tier = 13;
UPDATE page_tiers SET power_min = 135, power_max = 217 WHERE tier = 14;
UPDATE page_tiers SET power_min = 163, power_max = 263 WHERE tier = 15;


-- ---------------------------------------------------------------------------
-- Every rung, old and new, reads the same in both units
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    -- The rule the suite is asserting, asserted here so the migration proves
    -- its own fix rather than deferring to a test run afterwards.
    SELECT string_agg('tier ' || pt.tier || ': midpoint '
                      || ((pt.power_min + pt.power_max) / 2.0)
                      || ' vs budget ' || (mt.bonus_budget * 100), ', ')
    INTO bad
    FROM page_tiers pt
    JOIN manual_tiers mt ON mt.tier = pt.tier
    WHERE abs((pt.power_min + pt.power_max) / 2.0 - mt.bonus_budget * 100) > 2;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs read differently in the two units: %', bad;
    END IF;

    -- And both ladders still only climb.
    SELECT count(*) INTO n FROM (
        SELECT power_max, lag(power_max) OVER (ORDER BY tier) AS below
        FROM page_tiers
    ) t WHERE t.below IS NOT NULL AND t.power_max <= t.below;
    IF n > 0 THEN
        RAISE EXCEPTION '% page rungs stopped climbing', n;
    END IF;

    SELECT count(*) INTO n FROM (
        SELECT power_min, lag(power_min) OVER (ORDER BY tier) AS below
        FROM page_tiers
    ) t WHERE t.below IS NOT NULL AND t.power_min <= t.below;
    IF n > 0 THEN
        RAISE EXCEPTION '% page floors stopped climbing', n;
    END IF;

    RAISE NOTICE
        'all % rungs read the same in page power and manual budget',
        (SELECT count(*) FROM page_tiers);
END;
$probe$;
