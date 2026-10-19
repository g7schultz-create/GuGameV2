-- 0508_the_furnace_sets_a_ceiling_on_what_a_tier_may_cost
--
-- 0506 priced the ninth gear band at 3,600 potency, keeping the x3 jump tier
-- 8 made, on the reasoning that "the ninth band should be a project rather
-- than the next level up". A standing invariant says it may not be:
--
--     test_melting_is_never_the_better_use_of_ore_you_could_forge
--     "The furnace competes with nothing on purpose. An efficient tier 1
--      forging is 60 EXP for 4 potency; if smelting ever paid more per
--      potency than the worst forging, the anvil would become the slow way
--      to do the furnace's job."
--
--     smelting pays 0.25 a potency; tier 9 forging paid 0.15
--
-- Forge EXP is `tier * forge_exp_per_tier`, which is linear, while I made the
-- potency cost triple. So the ninth band was the worst value on the anvil and
-- a smith holding tier 9 ore would have been better off melting it - which is
-- the one thing the furnace is designed never to be.
--
-- The invariant BOUNDS the curve, which is the useful thing here:
--
--     9 * 60 / potency > 0.25   ->   potency < 2,160
--
-- So the ninth band costs 1,900 - a 1.58x step on tier 8 rather than 3x -
-- and forging it pays 0.284 a potency against smelting's 0.25. The magnitude
-- stays 1.65, so the band is still the best gear in the game; it is the
-- COST that the furnace caps, and the cap is a real design rule rather than
-- an accident. "A project rather than the next level up" has to be bought
-- with the ore's scarcity instead, which is what a rank 19 region is for.
--
-- AND THE MINER TEST WAS READING A CONSTANT. `test_a_deeper_miner_reaches_deeper`
-- asserts `tier_cap == 8 and deepest == 8`, hardcoded, two lines under a
-- comment that says "read from the ladder". It is updated to derive both: the
-- cap from `mining_tier_cap`, and the depth from the ore that region actually
-- has - because the ninth band's ore exists only in the Heavenly Court, so
-- the Eastern Sea's deepest stays 8 while a miner's reach becomes 9. A test
-- that hardcoded either would have gone red for the right change twice.
--
-- Forward-only. Do not edit once applied.

UPDATE equipment_tiers SET potency_required = 1900.00 WHERE tier = 9;


DO $probe$
DECLARE
    v_rate  NUMERIC;
    v_worst NUMERIC;
    v_tier  RECORD;
    v_n     INTEGER;
BEGIN
    v_rate := game_config_value('smelt_exp_per_potency');

    SELECT min((et.tier * game_config_value('forge_exp_per_tier'))
               / et.potency_required)
    INTO v_worst FROM equipment_tiers et;

    IF v_rate >= v_worst THEN
        RAISE EXCEPTION
            'smelting pays % a potency and the worst forging pays % - the furnace is the better anvil',
            v_rate, v_worst;
    END IF;

    -- The band is still the best gear in the game, which is the half of 0506
    -- that was right.
    SELECT tier, potency_required, base_magnitude INTO v_tier
    FROM equipment_tiers ORDER BY tier DESC LIMIT 1;
    IF v_tier.tier <> 9 THEN
        RAISE EXCEPTION 'the top gear band is % rather than 9', v_tier.tier;
    END IF;

    -- And the curve still only climbs on both columns.
    SELECT count(*) INTO v_n
    FROM equipment_tiers a JOIN equipment_tiers b ON b.tier = a.tier + 1
    WHERE b.potency_required <= a.potency_required
       OR b.base_magnitude <= a.base_magnitude;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'the gear curve stopped climbing at % places', v_n;
    END IF;

    -- Every band pays better on the anvil than in the furnace, not just the
    -- new one - worth checking all nine rather than the one I touched.
    SELECT count(*) INTO v_n FROM equipment_tiers et
    WHERE (et.tier * game_config_value('forge_exp_per_tier'))
          / et.potency_required <= v_rate;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% gear bands are worth melting rather than forging', v_n;
    END IF;

    RAISE NOTICE
        'band 9 costs % potency for % magnitude; forging it pays % against smelting %',
        v_tier.potency_required, v_tier.base_magnitude,
        round((9 * game_config_value('forge_exp_per_tier')) / v_tier.potency_required, 3),
        v_rate;
END;
$probe$;
