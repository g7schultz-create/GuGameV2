-- 0042_material_emoji
--
-- Materials get a face.
--
-- `/explore` and `/gather` announce a find with a rarity dot and a name, which
-- tells you how lucky you were and not what you are holding. Every other thing
-- in this game arrives with a picture - Paths, Gu, Gu effects, regions - and
-- 0014 already wrote down why it is a column: the same reason `rarities.colour`
-- is one. A dict in the bot is a second list of the content that has to be
-- edited beside every migration that adds to the first.
--
-- A default is kept so a material added tomorrow renders SOMETHING, and a test
-- asserts nothing shipped is still wearing it.
--
-- WHILE ADJACENT: 0036 wrote its two emoji defaults as '\N{BUG}', which is a
-- Python escape and not a PostgreSQL one - the stored default is the literal
-- eight characters. Every Gu and every effect was given an explicit emoji, so
-- nothing has ever rendered it, and the first row added without one would have
-- printed `\N{BUG}` on the card. Corrected here rather than left as a trap.
--
-- Forward-only. Do not edit once applied.

ALTER TABLE materials ADD COLUMN emoji TEXT NOT NULL DEFAULT '📦';

COMMENT ON COLUMN materials.emoji IS
    'What the material looks like on a card. A column and not a dict in the bot, for the reason 0014 gives about paths.emoji.';

ALTER TABLE gu_types  ALTER COLUMN emoji SET DEFAULT '🐛';
ALTER TABLE gu_effects ALTER COLUMN emoji SET DEFAULT '🐛';

UPDATE materials m SET emoji = v.emoji
FROM (VALUES
    -- Central Continent
    ('refinement_stone','⚗️'),('wisdom_flower','🌼'),('rule_fragment','📜'),
    ('spirit_rice','🍚'),('human_qi_stone','🗿'),('crescent_stone','🌙'),
    ('imperial_lotus_seed','🪷'),('purple_crystal','🔮'),('aspiring_stone','💫'),
    ('chilling_grass','❄️'),('nine_palace_flowers','🏵️'),('jade_apicot_blossom','🌸'),
    ('autumn_voice_grass','🍂'),('brave_heart_fragment','❤️‍🔥'),('spirit_stone','💠'),
    -- Western Desert
    ('fire_stone','🔥'),('desert_sand','🏜️'),('gold_ore','🪙'),
    ('mirage_sand','🫧'),('golden_root','🫚'),('gold_dust','✨'),
    ('awakening_crystal','👁️'),('sand_storm_core','🌪️'),('oasis_water','🏝️'),
    ('flame_sand','🌋'),('metal_ore','⛏️'),('copper_shavings','🥉'),
    ('silver_sand','🥈'),('iron_filing','🧲'),('fire_spirit_stone','🕯️'),
    -- Eastern Sea
    ('coral','🪸'),('deep_sea_essence','🌊'),('star_shell','🐚'),
    ('water_spirit_stone','💧'),('sea_salt','🧂'),('tide_stone','🌀'),
    ('ocean_crystal','🔷'),('star_fragment','⭐'),('cloud_mist_stone','☁️'),
    -- Northern Plains
    ('wind_grass','🍃'),('strength_stone','💪'),('blood_flower','🌺'),
    ('strength_herb','🌿'),('iron_ore','⛓️'),('dark_iron','🔩'),
    ('autumn_leaf','🍁'),('storm_crystal','⛈️'),('frozen_essence','🧊'),
    ('grassland_herbs','🌾'),('thunder_stone','⚡'),('temporal_dust','⏳'),
    -- Southern Border
    ('spirit_grass','🌱'),('jade_leaf','🟢'),('jade_bamboo','🎋'),
    ('poison_herb','🧪'),('mountain_rock','🪨'),('earth_spirit_stone','🟫'),
    ('moon_orchid','🌷'),('jade_shavings','🟩'),('wine_grass','🍶'),
    ('hope_flower','🌻'),('spring_water','💦'),('purified_water','🚰'),
    ('nine_leaf_vitality_grass','☘️'),('life_breath_grass','🌬️'),
    ('six_divine_grass','🌟'),('young_autumn_grass','🥬'),
    ('water_chestnut_grass','🌰'),('skull_stones','💀'),('worry_stones','⚫'),
    ('milk_tea_flower','🍵'),('earth_treasury_flower','💰'),('clear_chance_grass','🍀'),
    ('steep_cliff_grass','⛰️'),('shame_plum','🟣'),('pain_crystal','💢'),
    ('tree_bark','🪵'),
    -- Beast materials
    ('beast_blood','🩸'),('beast_core','🔶'),('beast_horn','🦌'),
    ('black_boar_tusk','🐗'),('blood_coral','❤️'),('boar_tusk','🐖'),
    ('bone_fragment','🦴'),('bone_spear_tip','🗡️'),('centipede_venom','🐛'),
    ('cicada_essence','🦗'),('cicada_shell','🪲'),('crab_carapace','🦀'),
    ('crystal_carapace','💎'),('desert_scale','🦎'),('dragon_scale','🐉'),
    ('dragon_whale_bone','🐋'),('eagle_feather','🪶'),('fish_scale_shard','🐟'),
    ('footless_bird','🕊️'),('gilded_carapace','🟨'),('golden_crow_essence','☀️'),
    ('heroic_soul','👻'),('iron_bone','⚙️'),('life_essence','💚'),
    ('lingzhi_meat','🍄'),('mirage_pelt','🌫️'),('moth_wing_dust','🦋'),
    ('pearl','⚪'),('poison_heart','💜'),('scorpion_stinger','🦂'),
    ('shark_tooth','🦈'),('skull_fragment','☠️'),('snake_gall','🐍'),
    ('soul_crystal','🔹'),('soul_pearl','🔘'),('tiger_fang','🐅'),
    ('tormented_soul','😖'),('tortoise_shell_plate','🛡️'),('turtle_shell','🐢'),
    ('venom_sac','🧫'),('vitality_sap','🍯'),('wolf_fang','🐺'),('wolf_pelt','🧥')
) AS v (code, emoji)
WHERE m.code = v.code;
