-- 0123_a_purse_worth_opening
--
-- Jade has never flowed. Sixty-one pieces generated in the game's whole life,
-- twenty-one held across five cultivators, and not one auction listing ever -
-- because the auction house, the protection costs and the rerolls are all
-- priced in a currency nobody has enough of to spend.
--
-- The repeatable faucet was the problem. A rogue carried jade 3% of the time
-- and a rogue only turns up on a 10% ambush roll, so the real rate was
--
--     0.10 x 0.03 = 0.003 - one piece every three hundred hunts
--
-- which is indistinguishable from zero at the rate anybody plays. Ten percent
-- makes it one in a hundred: still thin, still the smallest tap in the game,
-- but a number a player will actually see turn up.
--
-- The daily is the tap that fires reliably, so it is the one doing the real
-- work: three to seven a day becomes eight to twenty. A reroll is five, so a
-- day's purse is now a roll or two rather than most of one.
--
-- These were all marked PLACEHOLDER in their own descriptions - written as
-- "some number, to be tuned once there is data". There is data now.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 0.10,
    description = 'Chance a beaten rogue was carrying any at all. Behind a 10% ambush roll, so about one hunt in a hundred pays.'
WHERE key = 'jade_rogue_chance';

UPDATE game_config SET value = 2,
    description = 'Spirit Jade off a beaten rogue cultivator. The only repeatable faucet, and therefore still the smallest.'
WHERE key = 'jade_rogue_purse';

UPDATE game_config SET value = 8,
    description = 'Spirit Jade on the first day of a run.'
WHERE key = 'daily_jade_base';

UPDATE game_config SET value = 20,
    description = 'Most one daily purse pays, however long the run.'
WHERE key = 'daily_jade_max';

UPDATE game_config SET value = 2,
    description = 'Further Spirit Jade per consecutive day. A week-long run reaches the ceiling.'
WHERE key = 'daily_jade_streak_step';
