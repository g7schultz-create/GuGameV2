-- 0135_the_cauldron_can_finally_overfill
--
-- `brew` has computed a batch size since 0059 and it has never once come out
-- above 1. Twelve pills brewed in the game's life, every one of them a single.
--
--     batch := LEAST(alchemy_max_batch,                          -- 5
--                    1 + floor((total - floor_p)
--                        / (floor_p * alchemy_batch_divisor)))   -- 2
--
-- The idea is sound: overfill the pot past a grade's floor and the surplus
-- becomes extra pills rather than waste. The arithmetic never gets the chance,
-- because the grade is the highest tier the potency reaches - so overshooting
-- PROMOTES the pill before it ever fills the cauldron. At a divisor of 2 a
-- second pill wants three times the floor, and every tier in this game starts
-- less than twice the one below it:
--
--     tier 4   floor 36   two pills at 108   but tier 5 begins at  70
--     tier 5   floor 70   two pills at 210   but tier 6 begins at 130
--     tier 6   floor 130  two pills at 390   but tier 7 begins at 240
--
-- Only tier 7 could ever batch, having nothing above it, and nobody has
-- reached tier 7.
--
-- The tightest ratio between neighbouring tiers is 1.85 (tier 6 to 7), so the
-- second pill has to land inside that. A divisor of 0.5 puts it at 1.5x the
-- floor, which leaves a real band in every tier: at tier 6, 195 potency is two
-- pills and 240 is one of the next tier up. Overfilling deliberately - but not
-- so far that you tier up - becomes a thing worth aiming at, which is what the
-- mechanic was for.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 0.5,
    description = 'Overfill past a grade''s floor by this many multiples of it for each extra pill. At 0.5 a second pill lands at 1.5x the floor, inside every tier band; the old 2 needed 3x, which always tiered the pill up instead.'
WHERE key = 'alchemy_batch_divisor';


-- The band has to exist in every tier, or this is the same bug with a
-- different number in it. For each tier, the potency that buys a second pill
-- must fall short of the tier above.
DO $$
DECLARE
    shut  SMALLINT;
    top   SMALLINT;
    divis NUMERIC := game_config_value('alchemy_batch_divisor');
BEGIN
    SELECT max(tier) INTO top FROM pill_tiers;

    SELECT a.tier INTO shut
    FROM pill_tiers a
    JOIN pill_tiers b ON b.tier = a.tier + 1
    WHERE a.potency_required * (1 + divis) >= b.potency_required
    ORDER BY a.tier
    LIMIT 1;

    IF shut IS NOT NULL THEN
        RAISE EXCEPTION
            'tier % still tiers up before it can double: % potency doubles it, % is the next tier',
            shut,
            (SELECT potency_required * (1 + divis) FROM pill_tiers WHERE tier = shut),
            (SELECT potency_required FROM pill_tiers WHERE tier = shut + 1);
    END IF;

    -- And the ceiling has to be reachable at the top, where there is no next
    -- tier to run into - otherwise `alchemy_max_batch` is still a number
    -- nobody will see.
    IF (SELECT potency_required FROM pill_tiers WHERE tier = top)
       * (1 + divis * (game_config_value('alchemy_max_batch') - 1)) <= 0 THEN
        RAISE EXCEPTION 'the maximum batch is unreachable at the top tier';
    END IF;
END;
$$;
