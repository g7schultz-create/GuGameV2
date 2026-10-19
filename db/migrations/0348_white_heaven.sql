-- 0348_white_heaven
--
-- The second heaven, and the second region behind a rank 10 door. Everything
-- 0337 built for Black Heaven is reused as it stands: `regions.min_rank` is
-- 10, the gate in `begin_travel` already reads it, the travel screen already
-- draws the lock, and `roll_gu_drop` already knows a gated region hands out
-- Immortal Gu. A new heaven really is one row and its contents.
--
-- THIRTY-FIVE OF THE FORTY-THREE. Eight of the listed materials already grow
-- in Black Heaven, and `region_materials` carries a UNIQUE called
-- `one_region_each` - a gathering material comes from exactly one place in
-- the world, which is what makes going somewhere mean something.
--
-- Two of those eight are ORE rather than herb, and `region_veins` has no such
-- rule - three ores were already in two regions before this - so Formation
-- Spirit Stone and the Formation Dao Crystal are dug in both heavens. The
-- other six stay Black Heaven's: Earth Hole Traveling Flame, the Void
-- Boundary Fragment, both tidal waters, Pill Azure Incense and Refinement
-- Water. If they are meant to be found in both, they need to stop being
-- gathering materials, and that is a bigger decision than this migration.
--
-- EIGHT SEAMS OF ITS OWN, tiers 1 to 8, so White Heaven owes its miner what
-- every other region does - and it is the third place in the game a tier 8
-- is dug, which matters to anybody assembling Pseudo-Immortal gear out of
-- three different metals.
--
-- AND A COMMON CULTIVATION HERB WITHOUT INVENTING ONE. Black Heaven needed a
-- forty-first material for this because none of its forty was common. White
-- Heaven has floating dust, which is exactly the sort of nothing that rule
-- wants: star Path, common, tier 1, and in every cauldron up there.
--
-- Forward-only. Do not edit once applied.


INSERT INTO regions (code, name, danger_level, description, emoji, sort_order, min_rank)
VALUES (
    'white_heaven', 'White Heaven', 6,
    'A radiant realm above the clouds where heavenly qi runs in rivers. The '
    'seat of the Heavenly Court''s true power, and it does not pretend '
    'otherwise.',
    '☁️', 70, 10
);

-- Twelve hours from everywhere, as Black Heaven is: what is crossed is the
-- gap and not the ground. 'black_heaven' sorts before 'white_heaven', so the
-- pair between the two heavens is stored that way round.
INSERT INTO region_routes (origin, destination, travel_hours)
SELECT LEAST('white_heaven', r.code), GREATEST('white_heaven', r.code), 12.00
FROM regions r WHERE r.code <> 'white_heaven';


INSERT INTO materials (code, name, category, rarity, path_code, emoji, tier, description) VALUES
    -- Ore. `materials.tier` stays NULL on these: that column means herb.
    ('cloud_soil', 'Cloud Soil', 'gathering', 'rare', 'earth', '🟫', NULL,
     'Soil that never touched ground. It holds a shape if asked nicely.'),
    ('light_sand', 'Light Sand', 'gathering', 'uncommon', 'light', '🏜️', NULL,
     'Runs through the fingers and keeps shining on the way down.'),
    ('soft_jade_sand', 'Soft Jade Sand', 'gathering', 'rare', 'earth', '🏖️', NULL,
     'Jade that gave up being solid somewhere above the clouds.'),
    ('white_snow_iron', 'White Snow Iron', 'gathering', 'rare', 'metal', '🔩', NULL,
     'Cold to the hammer and colder after it.'),
    ('heaven_flying_jade', 'Heaven Flying Jade', 'gathering', 'epic', 'heaven', '💠', NULL,
     'It has to be netted rather than dug.'),
    ('heavenly_white_snow_iron', 'Heavenly White Snow Iron', 'gathering', 'epic', 'metal', '⚙️', NULL,
     'The good snow iron, and there is a great deal less of it.'),
    ('heavenly_crystal', 'Heavenly Crystal', 'gathering', 'legendary', 'light', '💎', NULL,
     'Grown in the rivers of qi, one facet a century.'),
    ('eight_sided_diamond_star_fragment', 'Eight-Sided Diamond Star Fragment',
     'gathering', 'legendary', 'star', '🔶', NULL,
     'Eight faces, and the eighth is not where the others say it should be.'),

    -- Herbs, tier 1 to 7.
    ('white_heaven_floating_dust', 'White Heaven Floating Dust', 'gathering', 'common', 'star', '✨', 1,
     'Worth nothing and in every cauldron up here.'),
    ('light_shine_fungus', 'Light Shine Fungus', 'gathering', 'uncommon', 'wood', '🍄', 1,
     'Grows on the underside of clouds, which should not be possible.'),
    ('white_wine_turnip', 'White Wine Turnip', 'gathering', 'uncommon', 'food', '🥕', 1,
     'Tastes of the wine before the turnip. Immortals are fond of it.'),
    ('heavenly_white_snow', 'Heavenly White Snow', 'gathering', 'uncommon', 'ice', '🌨️', 2,
     'It falls upward as often as not.'),
    ('heavenly_dew', 'Heavenly Dew', 'gathering', 'uncommon', 'water', '🫧', 2,
     'Collected off the grass of a place with no grass.'),
    ('quiet_rain', 'Quiet Rain', 'gathering', 'uncommon', 'water', '🌧️', 2,
     'Rain that makes no sound landing. The silence is the useful part.'),
    ('flowing_light_fruits', 'Flowing Light Fruits', 'gathering', 'rare', 'light', '🍊', 3,
     'The light inside moves when the fruit does not.'),
    ('flower_light_fruits', 'Flower Light Fruits', 'gathering', 'rare', 'wood', '🌺', 3,
     'Flowers and fruits at once, and neither ever finishes.'),
    ('pearl_thread_water', 'Pearl Thread Water', 'gathering', 'rare', 'water', '📿', 3,
     'Beads on a thread of water, and the thread holds.'),
    ('splendid_cloud', 'Splendid Cloud', 'gathering', 'rare', 'wind', '☁️', 4,
     'Cut from the good clouds. There is a difference and immortals can see it.'),
    ('cold_warm_snowing_sand', 'Cold Warm Snowing Sand', 'gathering', 'rare', 'ice', '❄️', 4,
     'Cold in one hand and warm in the other, reliably.'),
    ('black_white_water', 'Black White Water', 'gathering', 'rare', 'water', '⚫', 4,
     'Two waters in one vessel that have never once mixed.'),
    ('tooth_gap_water', 'Tooth Gap Water', 'gathering', 'rare', 'water', '🪣', 4,
     'Named for where it is found, which nobody enjoys explaining.'),
    ('aurora_light', 'Aurora Light', 'gathering', 'epic', 'light', '🌈', 5,
     'Bottled where the sky bends. It keeps bending in the bottle.'),
    ('heaven_qi', 'Heaven Qi', 'gathering', 'epic', 'qi', '💨', 5,
     'The rivers up here are made of this, and they are rivers.'),
    ('frost_jade_essence', 'Frost Jade Essence', 'gathering', 'epic', 'ice', '🧊', 5,
     'Jade pressed until only the cold is left.'),
    ('purple_spiritual_light', 'Purple Spiritual Light', 'gathering', 'epic', 'light', '🟣', 5,
     'The one colour the Heavenly Court reserves for itself.'),
    ('jade_sky_colored_jade_bamboo', 'Jade Sky Coloured Jade Bamboo', 'gathering', 'epic', 'wood', '🎋', 5,
     'It grows a joint each time somebody above notices it.'),
    ('heavenly_chasm', 'Heavenly Chasm', 'gathering', 'epic', 'space', '🕳️', 6,
     'A gap in the cloud floor that is deeper than the cloud is thick.'),
    ('nine_colored_water', 'Nine Coloured Water', 'gathering', 'epic', 'water', '💧', 6,
     'Nine, counted carefully, and never the same nine twice.'),
    ('snow_lotus_essence', 'Snow Lotus Essence', 'gathering', 'legendary', 'ice', '🪷', 6,
     'One lotus to a century and most of it is thrown away.'),
    ('heavenly_wind_qi', 'Heavenly Wind Qi', 'gathering', 'epic', 'wind', '🌬️', 6,
     'The wind that moves the qi rivers, taken off the top of one.'),
    ('cloud_phoenix_fragment', 'Cloud Phoenix Fragment', 'gathering', 'legendary', 'fire', '🪶', 7,
     'Not a feather. A piece of the burning it does instead of moulting.'),
    ('true_dragon_heavenly_water', 'True Dragon Heavenly Water', 'gathering', 'legendary', 'water', '🐉', 7,
     'A true dragon drank, and this is what it did not finish.'),
    ('nine_heavenly_star_sweat', 'Nine Heavenly Star Sweat', 'gathering', 'legendary', 'star', '🌟', 7,
     'Stars labour. This is the proof and it is worth a great deal.'),
    ('earthly_limit_astral_qi', 'Earthly Limit Astral Qi', 'gathering', 'legendary', 'star', '🌌', 7,
     'Where the earth stops mattering. Immortals bottle the line itself.'),
    ('light_of_the_immemorial_era', 'Light of the Immemorial Era', 'gathering', 'legendary', 'light', '🌠', 7,
     'It left something a very long time ago and has not arrived anywhere.');


INSERT INTO region_materials (region_code, material_code, weight)
SELECT 'white_heaven', m.code,
       CASE m.tier WHEN 1 THEN 7.0 WHEN 2 THEN 6.0 WHEN 3 THEN 3.5
                   WHEN 4 THEN 2.5 WHEN 5 THEN 1.2 WHEN 6 THEN 0.7
                   WHEN 7 THEN 0.25
                   ELSE CASE m.rarity WHEN 'uncommon' THEN 6.0
                                      WHEN 'rare'     THEN 3.5
                                      WHEN 'epic'     THEN 1.2
                                      ELSE 0.25 END END
FROM materials m
WHERE m.code IN (
    'cloud_soil','light_sand','soft_jade_sand','white_snow_iron',
    'heaven_flying_jade','heavenly_white_snow_iron','heavenly_crystal',
    'eight_sided_diamond_star_fragment','white_heaven_floating_dust',
    'light_shine_fungus','white_wine_turnip','heavenly_white_snow',
    'heavenly_dew','quiet_rain','flowing_light_fruits','flower_light_fruits',
    'pearl_thread_water','splendid_cloud','cold_warm_snowing_sand',
    'black_white_water','tooth_gap_water','aurora_light','heaven_qi',
    'frost_jade_essence','purple_spiritual_light','jade_sky_colored_jade_bamboo',
    'heavenly_chasm','nine_colored_water','snow_lotus_essence',
    'heavenly_wind_qi','cloud_phoenix_fragment','true_dragon_heavenly_water',
    'nine_heavenly_star_sweat','earthly_limit_astral_qi',
    'light_of_the_immemorial_era');


INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('cloud_soil',                        1, 'max_hp',           'Cloudborn'),
    ('light_sand',                        2, 'attack_power',     'Lightsand'),
    ('soft_jade_sand',                    3, 'damage_reduction', 'Softjade'),
    ('white_snow_iron',                   4, 'armor_pen',        'Snow-Iron'),
    ('heaven_flying_jade',                5, 'cultivation_rate', 'Skyborne'),
    ('heavenly_white_snow_iron',          6, 'attack_power',     'Heaven-Snow'),
    ('heavenly_crystal',                  7, 'damage_reduction', 'Heaven-Crystal'),
    ('eight_sided_diamond_star_fragment', 8, 'max_hp',           'Eight-Sided');

INSERT INTO region_veins (region_code, material_code, weight)
SELECT 'white_heaven', o.material_code,
       CASE o.tier WHEN 1 THEN 8.0 WHEN 2 THEN 6.0 WHEN 3 THEN 4.0
                   WHEN 4 THEN 2.5 WHEN 5 THEN 1.5 WHEN 6 THEN 0.8
                   WHEN 7 THEN 0.3 ELSE 0.10 END
FROM ores o
WHERE o.material_code IN (
    'cloud_soil','light_sand','soft_jade_sand','white_snow_iron',
    'heaven_flying_jade','heavenly_white_snow_iron','heavenly_crystal',
    'eight_sided_diamond_star_fragment',
    -- Shared with Black Heaven, which `region_veins` allows and
    -- `region_materials` would not.
    'formation_spirit_stone','formation_dao_crystal');


-- ---------------------------------------------------------------------------
-- A heaven a gatherer, a brewer and a miner can all work
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    SELECT string_agg(t.tier::text, ', ') INTO bad
    FROM generate_series(1, 7) AS t (tier)
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm JOIN materials m ON m.code = rm.material_code
        WHERE rm.region_code = 'white_heaven' AND m.tier = t.tier);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'White Heaven grows no herb at tier(s) %', bad;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = 'white_heaven'
          AND ppk.kind = 'cultivation' AND m.rarity = 'common'
    ) THEN
        RAISE EXCEPTION 'White Heaven grows no common cultivation herb';
    END IF;

    SELECT count(DISTINCT o.tier) INTO n
    FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = 'white_heaven';
    IF n <> 8 THEN
        RAISE EXCEPTION 'White Heaven runs % ore tiers, not 8', n;
    END IF;

    -- Every pair of regions still has a road between them.
    SELECT string_agg(a.code || '/' || b.code, ', ') INTO bad
    FROM regions a CROSS JOIN regions b
    WHERE a.code < b.code
      AND NOT EXISTS (SELECT 1 FROM region_routes rr
                      WHERE rr.origin = a.code AND rr.destination = b.code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'no route between: %', bad;
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

    RAISE NOTICE 'White Heaven: 35 materials, herbs at every rung, eight seams';
END;
$probe$;
