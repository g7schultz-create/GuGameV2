-- 0194_a_quickening_worth_swallowing
--
-- The rate pills were the weakest thing in the cauldron for what they cost.
-- A grade 6 Quickened Cultivation pill read:
--
--     +114 - +35% for 114 hours of cultivation, 247 banked in total.
--
-- 114 hours is five days of play, and +35% of clearwest's 3,200/hr is 1,120 -
-- so the whole pill was worth about 128,000 cultivation, against a Ninefold
-- Dao Blossom brew handing over 4,056 in one lump. Better, but not by the
-- margin the ingredients deserve: a grade 6 rate pill takes 130 potency and
-- five days of patience to beat a lump you swallow instantly.
--
-- The ladder moves up a hundred points at every grade that has one:
--
--     tier 5:   25%  ->  125%
--     tier 6:   35%  ->  135%
--     tier 7:   50%  ->  150%
--
-- Grades 1-4 stay at zero because they cannot make a rate pill at all -
-- `pill_kinds.min_tier` is 5 for both rate kinds, and below it they fall back
-- to the flat `cultivation` and `insight`.
--
-- BOTH RATE KINDS MOVE. `attainment_rate` reads the same `pill_tiers.rate_bonus`
-- column as `cultivation_rate`; splitting them would mean a per-kind ladder,
-- and the call was to buff both together rather than build one.
--
-- NOTHING IN ANYBODY'S BAG IS EDITED, AND NOTHING NEEDS TO BE. `take_pill`
-- reads the bonus out of `pill_tiers` at the moment of swallowing, not out of
-- the pill - so the 40 unconsumed tier 5 rate pills clearwest is holding
-- become +125% on their own.
--
-- Hours already banked keep the rate they were banked at: `grant_boost` stores
-- an hours-weighted average magnitude on `player_boosts`, so the 246.84 hours
-- sitting at 0.3255 are not retroactively improved. That is correct - they
-- were paid for at the old rate - and it means the change is visible on the
-- next pill rather than as a silent jump in a number nobody swallowed.
--
-- Forward-only. Do not edit once applied.


UPDATE pill_tiers SET rate_bonus = 1.2500 WHERE tier = 5;
UPDATE pill_tiers SET rate_bonus = 1.3500 WHERE tier = 6;
UPDATE pill_tiers SET rate_bonus = 1.5000 WHERE tier = 7;


DO $$
DECLARE
    got   NUMERIC;
    thin  TEXT;
    who   BIGINT;
    pill  BIGINT;
    before NUMERIC;
    after  NUMERIC;
BEGIN
    -- The number that was asked for, at the grade it was asked about.
    SELECT rate_bonus INTO got FROM pill_tiers WHERE tier = 6;
    IF got <> 1.35 THEN
        RAISE EXCEPTION 'grade 6 pays % rather than 1.35', got;
    END IF;

    -- A higher grade must still be worth more, or the ladder has a rung that
    -- goes down and nobody can see it coming.
    SELECT string_agg(a.tier || ' >= ' || b.tier, ', ') INTO thin
    FROM pill_tiers a JOIN pill_tiers b ON b.tier = a.tier + 1
    WHERE a.rate_bonus >= b.rate_bonus AND b.rate_bonus > 0;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'the rate ladder does not climb: %', thin;
    END IF;

    -- Grades that cannot make a rate pill must not advertise a rate. Stated
    -- against `pill_kinds.min_tier` rather than against the number 5.
    SELECT string_agg(pt.tier::text, ', ') INTO thin
    FROM pill_tiers pt
    WHERE pt.rate_bonus > 0
      AND pt.tier < (SELECT min(pk.min_tier) FROM pill_kinds pk
                     WHERE pk.code IN ('cultivation_rate', 'attainment_rate'));

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these grades pay a rate they cannot brew: %', thin;
    END IF;

    -- ---- and a pill somebody is holding actually pays it ------------------
    SELECT p.owner_id, p.pill_id INTO who, pill
    FROM player_pills p
    WHERE p.kind = 'cultivation_rate' AND p.quantity > 0
    ORDER BY p.tier DESC, p.pill_id
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds a rate pill; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT COALESCE(b.magnitude, 0), COALESCE(b.hours_left, 0)
        INTO before, after
        FROM (SELECT 1) _ LEFT JOIN player_boosts b
             ON b.player_id = who AND b.kind = 'cultivation_rate';

        PERFORM take_pill(who, pill);

        SELECT b.magnitude INTO after FROM player_boosts b
        WHERE b.player_id = who AND b.kind = 'cultivation_rate';

        -- `grant_boost` blends by hours, so the average must move UP toward
        -- the new rate even when a large old balance is dragging on it.
        IF after <= before THEN
            RAISE EXCEPTION
                'swallowing a rate pill did not raise the boost: % -> %',
                before, after;
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
