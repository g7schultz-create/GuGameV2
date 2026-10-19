-- 0056_regional_herbs
--
-- Thirty-five herbs, seven tiers, five regions - and alchemy's whole input.
--
-- WHY A TIER AND NOT JUST A RARITY. Materials already band by `rarity`, which
-- answers "how often do I find this". A herb also has to answer "how strong is
-- what I brew from it", and those are different questions: a Tier 7 herb is
-- rare BECAUSE it is potent, but a pill's grade has to be read off the
-- ingredients rather than off how lucky the gathering was. So `tier` is a
-- column, nullable, and a material with one is a herb. Nothing else changes -
-- herbs are `gathering` materials, so `gather()`, `region_materials` and the
-- category trigger all carry them with no edit at all.
--
-- ZONE EXCLUSIVITY BECOMES A RULE. 0017 wrote that 77 gathering materials sit
-- across five regions "with zero overlap: nothing gatherable in one region is
-- gatherable in another", and that is what makes "which region" a decision.
-- It has been true by care rather than by constraint for thirty-nine
-- migrations. Alchemy is about to make it load-bearing - a pill's ingredients
-- are a claim about where somebody has travelled - so it is a UNIQUE index now.
--
-- WEIGHTED DOWN THE TIERS. 8, 6, 4, 2.5, 1.5, 0.8, 0.3 - a Tier 7 herb turns
-- up around one gather in three hundred against a Tier 1's one in nine. The
-- doc asks that higher tiers be meaningfully rarer, and weight is where that
-- lives rather than in a gate.
--
-- ONE HERB WAS ALREADY IN THE GROUND. `jade_apicot_blossom` has been Central
-- and Wood since 0017 and is exactly the roster's Central Tier 2. It is
-- promoted rather than duplicated - and its display name loses the typo it has
-- been carrying, while the code, which is an identifier, keeps it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- tier
-- ---------------------------------------------------------------------------

ALTER TABLE materials ADD COLUMN tier SMALLINT
    CHECK (tier IS NULL OR tier BETWEEN 1 AND 7);

CREATE INDEX materials_tier_idx ON materials (tier) WHERE tier IS NOT NULL;

COMMENT ON COLUMN materials.tier IS
    'Alchemical grade, 1-7. A gathering material with one is a herb; NULL is everything that is not.';

-- The rule 0017 stated and never enforced. A material grows in one region.
CREATE UNIQUE INDEX region_materials_one_region_each ON region_materials (material_code);


-- ---------------------------------------------------------------------------
-- The roster
-- ---------------------------------------------------------------------------

UPDATE materials SET name = 'Jade Apricot Blossom', tier = 2
WHERE code = 'jade_apicot_blossom';

INSERT INTO materials (code, name, category, rarity, path_code, tier, emoji, description)
SELECT v.code, v.name, 'gathering', v.rarity, v.path, v.tier, v.emoji, v.note
FROM (VALUES
    -- Central Continent: balanced, and the best supporting ingredients there are.
    ('spirit_dew_grass','Spirit Dew Grass','common','qi',1::smallint,'🌾',
     'Collected before dawn or not at all.'),
    ('clear_mind_orchid','Clear Mind Orchid','uncommon','wisdom',3,'🌸',
     'Studied beside, rather than eaten. Most of its use is in the sitting still.'),
    ('golden_meridian_root','Golden Meridian Root','uncommon','human',4,'🫚',
     'Shaped like the channels it is meant to widen, which is either meaningful or a coincidence people have decided about.'),
    ('seven_star_lotus','Seven-Star Lotus','rare','star',5,'🪷',
     'Seven petals, and they do not open on the same night.'),
    ('heavenly_essence_ginseng','Heavenly Essence Ginseng','rare','heaven',6,'🌿',
     'Old enough that digging it up is a decision about somebody else''s inheritance.'),
    ('ninefold_dao_blossom','Ninefold Dao Blossom','epic','rule',7,'🏵️',
     'Nine rings of petals, and every ring is a rule about the next one.'),

    -- Northern Plains: combat, the body, and cold.
    ('frostbite_grass','Frostbite Grass','common','ice',1,'❄️',
     'Picked with bare hands by people who regret it.'),
    ('ironblood_thistle','Ironblood Thistle','common','blood',2,'🥀',
     'Bleeds when cut, which is not something a thistle should do.'),
    ('white_wolf_root','White Wolf Root','uncommon','strength',3,'🐺',
     'Grows where a pack has denned. Nobody has established which causes which.'),
    ('glacier_heart_flower','Glacier Heart Flower','uncommon','ice',4,'🧊',
     'Warm to the touch, in the middle of a glacier, and nobody likes it.'),
    ('war_gods_blood_ginseng','War God''s Blood Ginseng','rare','blood',5,'🍷',
     'Found on old battlefields and only on the ones that mattered.'),
    ('ancient_frost_marrow_root','Ancient Frost Marrow Root','rare','bone',6,'☃️',
     'What it is rooted in is not soil and everybody involved knows it.'),
    ('heaven_eating_wolf_lotus','Heaven-Eating Wolf Lotus','epic','enslavement',7,'🌙',
     'Beasts bring it things. It has never been established what it gives them back.'),

    -- Southern Border: the strangest biology on the map.
    ('green_venom_leaf','Green Venom Leaf','common','poison',1,'🍃',
     'The first poison anybody learns, and the first one anybody survives.'),
    ('coiling_vine_root','Coiling Vine Root','common','wood',2,'🌿',
     'Pulls up in one piece if you follow it, and it is always longer than that.'),
    ('serpent_tongue_orchid','Serpent-Tongue Orchid','uncommon','poison',3,'🐍',
     'Splits at the tip and tastes the air. Botanists have stopped arguing about it.'),
    ('hundred_beast_fruit','Hundred Beast Fruit','uncommon','transformation',4,'🍐',
     'No two of them are the same fruit, on the same tree, in the same season.'),
    ('thousand_year_lingzhi','Thousand-Year Lingzhi','rare','wood',5,'🍄',
     'Not a thousand years. Long enough that the difference stopped being checkable.'),
    ('myriad_form_ginseng','Myriad Form Ginseng','rare','transformation',6,'🫑',
     'Dug up as one shape and arrives home as another, and the diggers have stopped mentioning it.'),
    ('ten_thousand_poison_heartflower','Ten Thousand Poison Heartflower','epic','poison',7,'💜',
     'Every venom in the Southern Border, and it grew them all itself.'),

    -- Western Desert: half botanical, half mineral.
    ('ember_cactus_flower','Ember Cactus Flower','common','fire',1,'🌵',
     'Opens at the hottest hour, which is when nobody is out to see it.'),
    ('sandroot','Sandroot','common','earth',2,'🟫',
     'Holds a dune together. Taking it is a small argument with the desert.'),
    ('sunfire_date','Sunfire Date','uncommon','fire',3,'🌰',
     'Sweet, and then not. The second part lasts longer.'),
    ('golden_ore_vine','Golden Ore Vine','uncommon','metal',4,'🪙',
     'A plant that has eaten enough metal to be worth smelting.'),
    ('mirage_blossom','Mirage Blossom','rare','illusion',5,'🫧',
     'Reached four times out of five. The fifth is the one that was there.'),
    ('earthfire_dragon_root','Earthfire Dragon Root','rare','fire',6,'🌋',
     'Rooted into something under the sand that is still warm.'),
    ('nine_suns_desert_lotus','Nine Suns Desert Lotus','epic','light',7,'☀️',
     'Casts nine shadows and there is one sun. Nobody has explained it and few have tried twice.'),

    -- Eastern Sea: healing, the soul, and a great deal of water.
    ('blue_kelp_grass','Blue Kelp Grass','common','water',1,'🌊',
     'Washes up in quantity. Worth the walk and not much more.'),
    ('pearl_dew_lily','Pearl Dew Lily','common','water',2,'🤍',
     'Holds one drop of fresh water in a place that has none.'),
    ('moon_tide_coral_flower','Moon-Tide Coral Flower','uncommon','light',3,'🪸',
     'Blooms on the tide rather than on the season.'),
    ('deep_sea_spirit_moss','Deep Sea Spirit Moss','uncommon','soul',4,'👻',
     'Grows on wrecks, and grows better on the ones with people still in them.'),
    ('azure_dragon_seaweed','Azure Dragon Seaweed','rare','transformation',5,'🐉',
     'Long enough to be mistaken for something, and it does not discourage the mistake.'),
    ('abyssal_soul_lotus','Abyssal Soul Lotus','rare','soul',6,'🌑',
     'Down where the light stops. It is not clear what it is doing with the dark.'),
    ('immortal_tide_heartflower','Immortal Tide Heartflower','epic','space',7,'🌌',
     'The tide it answers is not this sea''s, and the moon it answers is not the one up there.')
) AS v (code, name, rarity, path, tier, emoji, note);


-- ---------------------------------------------------------------------------
-- Where each grows
-- ---------------------------------------------------------------------------
-- Weight falls with tier rather than with rarity, because for a herb the tier
-- IS the scarcity: 8, 6, 4, 2.5, 1.5, 0.8, 0.3.

INSERT INTO region_materials (region_code, material_code, weight)
SELECT v.region, m.code,
       (ARRAY[8, 6, 4, 2.5, 1.5, 0.8, 0.3])[m.tier]
FROM (VALUES
    ('central','spirit_dew_grass'),('central','clear_mind_orchid'),
    ('central','golden_meridian_root'),('central','seven_star_lotus'),
    ('central','heavenly_essence_ginseng'),('central','ninefold_dao_blossom'),

    ('northern','frostbite_grass'),('northern','ironblood_thistle'),
    ('northern','white_wolf_root'),('northern','glacier_heart_flower'),
    ('northern','war_gods_blood_ginseng'),('northern','ancient_frost_marrow_root'),
    ('northern','heaven_eating_wolf_lotus'),

    ('southern','green_venom_leaf'),('southern','coiling_vine_root'),
    ('southern','serpent_tongue_orchid'),('southern','hundred_beast_fruit'),
    ('southern','thousand_year_lingzhi'),('southern','myriad_form_ginseng'),
    ('southern','ten_thousand_poison_heartflower'),

    ('western','ember_cactus_flower'),('western','sandroot'),
    ('western','sunfire_date'),('western','golden_ore_vine'),
    ('western','mirage_blossom'),('western','earthfire_dragon_root'),
    ('western','nine_suns_desert_lotus'),

    ('eastern','blue_kelp_grass'),('eastern','pearl_dew_lily'),
    ('eastern','moon_tide_coral_flower'),('eastern','deep_sea_spirit_moss'),
    ('eastern','azure_dragon_seaweed'),('eastern','abyssal_soul_lotus'),
    ('eastern','immortal_tide_heartflower')
) AS v (region, material)
JOIN materials m ON m.code = v.material;
