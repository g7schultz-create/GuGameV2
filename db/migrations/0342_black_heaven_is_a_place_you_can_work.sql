-- 0342_black_heaven_is_a_place_you_can_work
--
-- 0338 put forty materials in Black Heaven and four of this schema's rules
-- immediately said the region was half-built. They were right, and every one
-- of them is a rule about a region being worth the journey:
--
--     every_region_grows_a_full_ladder_of_herbs      no herb of any tier
--     every_region_grows_a_brewable_cultivation_herb nothing to brew
--     a_cultivation_herb_grows_in_every_region       the same again
--     every_region_has_a_page_worth_reading          'Black Heaven has no mine'
--
-- None of them needs new material. The forty were already a heaven's worth of
-- things; what they were missing is which of them is a HERB and which is an
-- ORE, and in this schema that is one column each.
--
-- HERBS ARE MARKED BY HAVING A TIER, and nothing else marks them - the test
-- for the cultivation herb says so outright, noting that 76 gatherable things
-- correctly have none. So twenty-one of the forty get a tier, three to each
-- of the seven, and their gathering weight is reset to match the rung they
-- now sit on. That last part is not tidiness: `a_higher_tier_herb_is_rarer_to_
-- find` compares the heaviest weight at each tier across the whole world, and
-- a tier 7 herb left at a tier 1 weight would flatten that curve globally,
-- from one region.
--
-- The cultivation brew is covered deliberately rather than by luck. Only
-- star, time, luck, space and rule brew cultivation, and this place has
-- starlight and void - so Electrolytic Starlight, the Iron Starflower, Black
-- Hole Wood and the Void Boundary Fragment are among the ones given tiers.
-- Without that, an immortal could stand in Black Heaven and be unable to brew
-- the one kind of pill every cultivator wants.
--
-- AND EIGHT OF THEM ARE ORE, tiers 1 to 8, because a region owes a miner a
-- seam the way it owes a gatherer a herb. This is the second place in the
-- game a tier 8 seam exists, and that is the point: the Pseudo-Immortal gear
-- 0317 built wants three DIFFERENT tier 8 metals, and until now that meant
-- three separate mortal regions. Black Heaven is the immortal's answer to the
-- same problem, behind a door only they can open.
--
-- Ores keep `materials.tier` NULL - every one of the 49 ores already in the
-- game does - because that column means herb, and a thing is one or the
-- other.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Twenty-one herbs, three to a rung
-- ---------------------------------------------------------------------------

UPDATE materials m SET tier = v.tier
FROM (VALUES
    ('nether_grass', 1), ('dark_soft_silk', 1), ('dark_thread_algae', 1),
    ('black_oil', 2), ('black_iron_qi', 2), ('ghostly_wail', 2),
    ('heaven_attached_fungi', 3), ('profound_eerie_wind', 3), ('lightning_qi', 3),
    ('ghost_lantern_oil', 4), ('abyssal_bone_powder', 4), ('silent_night_silk', 4),
    ('black_hole_wood', 5), ('black_soul_water', 5), ('floating_life_fire', 5),
    ('nether_grass_essence', 6), ('night_terror_flower', 6),
    ('electrolytic_iron_starflower', 6),
    ('electrolytic_starlight', 7), ('dark_heaven_lotus_seed', 7),
    ('void_boundary_fragment', 7)
) AS v (code, tier)
WHERE m.code = v.code;

-- The weight follows the rung, not the rarity it was given when nobody knew
-- which of these were herbs. Held under the heaviest weight already at each
-- tier so the world-wide curve is not flattened from one region.
UPDATE region_materials rm SET weight = v.weight
FROM (VALUES
    (1, 7.0), (2, 6.0), (3, 3.5), (4, 2.5), (5, 1.2), (6, 0.7), (7, 0.25)
) AS v (tier, weight)
JOIN materials m ON m.tier = v.tier
WHERE rm.region_code = 'black_heaven' AND rm.material_code = m.code;


-- ---------------------------------------------------------------------------
-- And eight seams under it
-- ---------------------------------------------------------------------------

INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('black_cloud_soil',             1, 'max_hp',           'Cloudbound'),
    ('rooster_iron',                 2, 'attack_power',     'Rooster'),
    ('black_eclipse_stone',          3, 'damage_reduction', 'Eclipse'),
    ('nether_forged_dark_iron',      4, 'armor_pen',        'Nether-Forged'),
    ('heaven_metal',                 5, 'attack_power',     'Heaven-Wrought'),
    ('formation_spirit_stone',       6, 'damage_reduction', 'Formation-Bound'),
    ('abyssal_shadow_jade',          7, 'max_hp',           'Abyssal'),
    ('formation_dao_crystal',        8, 'cultivation_rate', 'Dao-Formation');

INSERT INTO region_veins (region_code, material_code, weight)
SELECT 'black_heaven', o.material_code,
       CASE o.tier WHEN 1 THEN 8.0 WHEN 2 THEN 6.0 WHEN 3 THEN 4.0
                   WHEN 4 THEN 2.5 WHEN 5 THEN 1.5 WHEN 6 THEN 0.8
                   WHEN 7 THEN 0.3 ELSE 0.10 END
FROM ores o
WHERE o.material_code IN (
    'black_cloud_soil','rooster_iron','black_eclipse_stone',
    'nether_forged_dark_iron','heaven_metal','formation_spirit_stone',
    'abyssal_shadow_jade','formation_dao_crystal');


-- ---------------------------------------------------------------------------
-- A gatherer, a brewer and a miner all have something to do here
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    -- A herb at every rung.
    SELECT string_agg(t.tier::text, ', ') INTO bad
    FROM generate_series(1, 7) AS t (tier)
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm JOIN materials m ON m.code = rm.material_code
        WHERE rm.region_code = 'black_heaven' AND m.tier = t.tier);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Black Heaven grows no herb at tier(s) %', bad;
    END IF;

    -- Something that brews into cultivation.
    IF NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = 'black_heaven'
          AND ppk.kind IN ('cultivation', 'cultivation_rate')
          AND m.tier IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'nothing in Black Heaven brews into cultivation';
    END IF;

    -- Ore from one to eight, the way every region owes a miner.
    SELECT count(DISTINCT o.tier) INTO n
    FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = 'black_heaven';
    IF n <> 8 THEN
        RAISE EXCEPTION 'Black Heaven runs % ore tiers, not 8', n;
    END IF;

    -- No ore carries a herb's tier.
    SELECT string_agg(m.code, ', ') INTO bad
    FROM ores o JOIN materials m ON m.code = o.material_code
    WHERE m.tier IS NOT NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are both ore and herb: %', bad;
    END IF;

    -- And the world-wide rarity curve still falls.
    IF EXISTS (
        SELECT 1 FROM (
            SELECT m.tier, max(rm.weight) AS w,
                   LAG(max(rm.weight)) OVER (ORDER BY m.tier) AS above
            FROM region_materials rm JOIN materials m ON m.code = rm.material_code
            WHERE m.tier IS NOT NULL GROUP BY m.tier
        ) t WHERE t.above IS NOT NULL AND t.w > t.above
    ) THEN
        RAISE EXCEPTION 'a higher tier of herb is now commoner than a lower one';
    END IF;

    RAISE NOTICE 'Black Heaven grows herbs at every rung and hides eight seams';
END;
$probe$;
