-- 0050_epic_outranks_rare
--
-- An Epic physique had a lower top stat than a Rare one.
--
-- 0049 took its numbers from the design spec's tier baselines - Rare +10%,
-- Epic +14% - without checking them against the Rare physiques that actually
-- shipped, which reach +15%. So Blood Tyrant Body's 1.15 HP beat every Epic
-- body's best stat, and a player rolling up the ladder would have watched
-- their best number go down.
--
-- The spec's baselines are a starting point for simulation, which it says
-- itself. The ladder that has to hold is the one in the database:
--
--     rare 1.15 -> epic 1.16 -> legendary 1.18 -> mythic 1.22 -> divine 1.25
--
-- Only the Epic band moves. Its total package was already ahead of Rare's
-- (3.33 against 3.25, and every band's total was already monotone) - it was
-- the single headline number that read wrong, which is the one a player
-- compares.
--
-- Found by a test asserting the ladder climbs, which is now in the suite for
-- both measures.
--
-- Forward-only. Do not edit once applied.

UPDATE physiques SET
    hp_multiplier       = CASE WHEN hp_multiplier       = 1.1400 THEN 1.1600 ELSE hp_multiplier END,
    defense_multiplier  = CASE WHEN defense_multiplier  = 1.1400 THEN 1.1600 ELSE defense_multiplier END,
    strength_multiplier = CASE WHEN strength_multiplier = 1.1400 THEN 1.1600 ELSE strength_multiplier END
WHERE tier = 'epic';
