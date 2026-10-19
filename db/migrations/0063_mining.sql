-- 0063_mining
--
-- Ore comes out of the ground, and it is not foraged.
--
-- A SIDE TABLE, NOT A COLUMN. 0017 settled how this schema says what a
-- material is: "where they differ is where they come from, and that is
-- expressed by which side table references them - `region_materials` for
-- gathering, `creature_drops` for beast." An ore is a material with a row in
-- `ores`, the same way a creature drop is a material with a row in
-- `creature_drops`.
--
-- AND DELIBERATELY NOT `materials.tier`. 0056 wrote that a gathering material
-- with a tier is a HERB, and `brew()` enforces exactly that - it checks
-- `m.tier IS NOT NULL` and refuses everything else. Giving ore a tier in that
-- column would put iron in a cauldron. The forging tier lives in `ores.tier`
-- where nothing alchemical will ever read it.
--
-- THIRTEEN ORES WERE ALREADY IN THE GROUND. Iron ore, dark iron, copper
-- shavings, gold ore and the rest have been gatherable since 0017, and four Gu
-- recipes are built on them. They are promoted, not moved: they stay in
-- `region_materials`, so no recipe becomes unbuyable, and they join
-- `region_veins` as well, so a miner gets them faster and in bulk. 0039's
-- lesson - a price nobody can pay is not a price - is what makes this the only
-- safe direction.
--
-- A VEIN IS NOT EXCLUSIVE. A herb grows in one region, by unique index, and
-- that is what makes travelling a decision for an alchemist. The design
-- document asks for the opposite here: "regional identity should affect
-- availability without forcing every resource to be region-exclusive." So iron
-- turns up in three regions and everything at Tier 3 and above turns up in
-- one, and the table has no unique index to say otherwise.
--
-- THE LEVEL GATE IS A FILTER, NOT A FAILURE. A miner draws only from the
-- veins they can actually work. Rolling a Tier 6 seam and being told to come
-- back in twenty levels would spend a cooldown on nothing; the screen says how
-- deep the region goes instead.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- ores
-- ---------------------------------------------------------------------------
-- What a metal is, as far as a forge is concerned: how deep it sits, what it
-- is known for, and the word its name contributes to whatever gets made.
--
-- `signature` is why a Tier 3 ore is still worth mining at Tier 6. The design
-- document is explicit - "do not make higher-tier ore automatically invalidate
-- every specialized lower-tier material" - and a tier number alone cannot
-- honour that, because a bigger number always wins. A signature can: Mirage
-- Silver is the only western metal that buys evasion, at any tier.

CREATE TABLE ores (
    material_code TEXT PRIMARY KEY REFERENCES materials (code) ON DELETE CASCADE,

    tier          SMALLINT NOT NULL CHECK (tier BETWEEN 1 AND 7),

    -- What this metal is known for, in the shared effect vocabulary. An item
    -- forged from it always carries some of this, whatever else goes in.
    signature     TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    -- What it contributes to a forged item's name. 'Sunsteel' -> 'Profound
    -- Sunsteel Fang Saber'.
    word          TEXT NOT NULL
);

CREATE INDEX ores_tier_idx      ON ores (tier);
CREATE INDEX ores_signature_idx ON ores (signature);

COMMENT ON TABLE ores IS
    'A material with a row here is an ore. The forging tier lives here rather than in materials.tier, which means herb and is read by brew().';

-- Beast materials are not dug up. The split 0017 drew is enforced on this
-- table the same way it is enforced on creature_drops.
CREATE FUNCTION check_ore_is_gathering_material()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.material_code) <> 'gathering' THEN
        RAISE EXCEPTION 'an ore is a gathering material, and % is not', NEW.material_code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER ores_are_gathering_materials
    BEFORE INSERT OR UPDATE ON ores
    FOR EACH ROW EXECUTE FUNCTION check_ore_is_gathering_material();


-- ---------------------------------------------------------------------------
-- region_veins
-- ---------------------------------------------------------------------------

CREATE TABLE region_veins (
    region_code   TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    material_code TEXT NOT NULL REFERENCES ores (material_code) ON DELETE CASCADE,

    weight        NUMERIC(8, 4) NOT NULL DEFAULT 1 CHECK (weight > 0),

    PRIMARY KEY (region_code, material_code)
);

CREATE INDEX region_veins_material_idx ON region_veins (material_code);

COMMENT ON TABLE region_veins IS
    'What can be mined where. Unlike herbs, an ore may run under several regions - the design asks for identity without exclusivity.';


-- ---------------------------------------------------------------------------
-- The thirteen already in the ground
-- ---------------------------------------------------------------------------
-- Every one of these stays gatherable. Four Gu recipes are built on gold ore,
-- copper shavings, dark iron and mountain rock, and mining is not allowed to
-- put a rank 1 recipe behind a Miner level.

INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('spirit_stone',      1, 'cultivation_rate', 'Spirit'),
    ('iron_ore',          1, 'attack_power',     'Iron'),
    ('metal_ore',         1, 'attack_power',     'Steel'),
    ('copper_shavings',   1, 'multi_hit',        'Copper'),
    ('tide_stone',        1, 'dodge',            'Tide'),
    ('mountain_rock',     1, 'damage_reduction', 'Mountain'),
    ('human_qi_stone',    2, 'max_hp',           'Mortal'),
    ('dark_iron',         2, 'damage_reduction', 'Dark'),
    ('gold_ore',          2, 'crit_damage',      'Gold'),
    ('silver_sand',       2, 'dodge',            'Silver'),
    ('jade_shavings',     2, 'max_hp',           'Jade'),
    ('refinement_stone',  3, 'crit_rate',        'Refined'),
    ('purple_crystal',    3, 'crit_damage',      'Purple');


-- ---------------------------------------------------------------------------
-- Twenty-six deeper seams
-- ---------------------------------------------------------------------------
-- Five regional identities, straight out of the design document: central is
-- balanced and Qi-conductive, northern is dense and durable, southern is
-- strange and poisonous, western is raw metal and fire, eastern is water and
-- the deep.
--
-- `tier` stays NULL on every one of these. They are ore, not herb.

INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
VALUES
    -- Central Continent - balanced, Qi-conductive, the refinement metals.
    ('spirit_iron', 'Spirit Iron', 'gathering', 'uncommon', 'metal', '⛓️',
     'Iron that lay beside a Qi vein long enough to have opinions.'),
    ('nine_palace_alloy', 'Nine Palace Alloy', 'gathering', 'rare', 'formation', '🔯',
     'Smelted in nine pours. The ninth decides whether the other eight were worth making.'),
    ('heavenly_mandate_iron', 'Heavenly Mandate Iron', 'gathering', 'rare', 'heaven', '🌩️',
     'Struck by lightning while still ore, which is either a blessing or a warning.'),
    ('dao_marrow_ore', 'Dao Marrow Ore', 'gathering', 'epic', 'rule', '📜',
     'There is a grain in it, and the grain is an argument.'),
    ('primordial_origin_ore', 'Primordial Origin Ore', 'gathering', 'epic', 'qi', '💠',
     'Older than the continent standing on it, and not obviously finished forming.'),

    -- Northern Plains - dense, durable, cold.
    ('bloodrust_ore', 'Bloodrust Ore', 'gathering', 'uncommon', 'blood', '🩸',
     'Rusts red in a season with no water anywhere near it.'),
    ('thunder_veined_steel', 'Thunder-Veined Steel', 'gathering', 'rare', 'lightning', '⚡',
     'Hums before a storm and is quiet for a day afterwards.'),
    ('war_god_steel', 'War God Steel', 'gathering', 'rare', 'strength', '💪',
     'Every ingot comes out of a battlefield that is still being argued about.'),
    ('mammoth_bone_ore', 'Mammoth Bone Ore', 'gathering', 'epic', 'bone', '🦴',
     'Bone that stayed under the ice until it became mineral, and kept the shape anyway.'),
    ('everwinter_adamant', 'Everwinter Adamant', 'gathering', 'epic', 'ice', '❄️',
     'A cold a forge argues with rather than removes.'),

    -- Southern Border - strange crystals, poisonous ores, minerals that are
    -- not entirely mineral.
    ('venom_vein_crystal', 'Venom Vein Crystal', 'gathering', 'uncommon', 'poison', '☠️',
     'The green lines in it move, if you watch for an hour.'),
    ('bonestone', 'Bonestone', 'gathering', 'rare', 'bone', '💀',
     'Quarried in slabs the quarry would plainly rather keep.'),
    ('living_jade', 'Living Jade', 'gathering', 'rare', 'transformation', '🟩',
     'Warm, and slightly the wrong shape each time somebody measures it.'),
    ('soulstone_ore', 'Soulstone Ore', 'gathering', 'epic', 'soul', '👻',
     'Quiet, and then not, and the smiths who work it do not discuss which.'),
    ('myriad_venom_crystal', 'Myriad Venom Crystal', 'gathering', 'epic', 'poison', '💜',
     'Every poison of the Southern Border, grown into a lattice.'),

    -- Western Desert - the best raw metal on the map, and fire.
    ('magma_iron', 'Magma Iron', 'gathering', 'uncommon', 'fire', '🌋',
     'Poured rather than dug. The desert does half the smelting for you.'),
    ('desert_gold_vein', 'Desert Gold Vein', 'gathering', 'rare', 'metal', '🪙',
     'A seam that runs a mile and stays three fingers wide the whole way.'),
    ('mirage_silver', 'Mirage Silver', 'gathering', 'rare', 'illusion', '🫧',
     'Weighs less than it looks, and looks like less than it is.'),
    ('blazing_sunsteel', 'Blazing Sunsteel', 'gathering', 'epic', 'fire', '☀️',
     'Holds the day''s heat all night and gives none of it back.'),
    ('golden_crow_ore', 'Golden Crow Ore', 'gathering', 'epic', 'light', '🌟',
     'Fell rather than formed. The crater is still warm.'),

    -- Eastern Sea - water minerals, pearls, the metals of the deep.
    ('tidal_bronze', 'Tidal Bronze', 'gathering', 'uncommon', 'water', '🌀',
     'Green with the sea, and stronger for it.'),
    ('pearl_sand_ore', 'Pearl Sand Ore', 'gathering', 'uncommon', 'water', '⚪',
     'Sifted rather than mined, which the miners resent and do anyway.'),
    ('abyssal_iron', 'Abyssal Iron', 'gathering', 'rare', 'water', '🔷',
     'Cold at a depth where cold has stopped being about temperature.'),
    ('stormtide_alloy', 'Stormtide Alloy', 'gathering', 'rare', 'lightning', '⛈️',
     'Made where a storm meets a reef, by the storm.'),
    ('dragon_whale_ore', 'Dragon Whale Ore', 'gathering', 'epic', 'bone', '🐋',
     'What a dragon whale leaves behind, given long enough, is a mine.'),
    ('sea_god_adamant', 'Sea God Adamant', 'gathering', 'epic', 'water', '🌊',
     'The sea has been trying to wear it down for as long as there has been a sea.');

INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('spirit_iron',           2, 'max_hp',           'Spiritsteel'),
    ('nine_palace_alloy',     4, 'damage_reduction', 'Nine-Palace'),
    ('heavenly_mandate_iron', 5, 'attack_power',     'Mandate'),
    ('dao_marrow_ore',        6, 'armor_pen',        'Dao-Marrow'),
    ('primordial_origin_ore', 7, 'cultivation_rate', 'Origin'),

    ('bloodrust_ore',         3, 'lifesteal',        'Bloodrust'),
    ('thunder_veined_steel',  4, 'multi_hit',        'Thunderveined'),
    ('war_god_steel',         5, 'attack_power',     'War-God'),
    ('mammoth_bone_ore',      6, 'max_hp',           'Mammoth'),
    ('everwinter_adamant',    7, 'damage_reduction', 'Everwinter'),

    ('venom_vein_crystal',    3, 'armor_pen',        'Venomvein'),
    ('bonestone',             4, 'damage_reduction', 'Bonestone'),
    ('living_jade',           5, 'lifesteal',        'Living Jade'),
    ('soulstone_ore',         6, 'cultivation_rate', 'Soulstone'),
    ('myriad_venom_crystal',  7, 'armor_pen',        'Myriad-Venom'),

    ('magma_iron',            3, 'attack_power',     'Magma'),
    ('desert_gold_vein',      4, 'crit_rate',        'Desert-Gold'),
    ('mirage_silver',         5, 'dodge',            'Mirage'),
    ('blazing_sunsteel',      6, 'crit_damage',      'Sunsteel'),
    ('golden_crow_ore',       7, 'attack_power',     'Golden-Crow'),

    ('tidal_bronze',          2, 'dodge',            'Tidal'),
    ('pearl_sand_ore',        3, 'max_hp',           'Pearlsand'),
    ('abyssal_iron',          4, 'damage_reduction', 'Abyssal'),
    ('stormtide_alloy',       5, 'multi_hit',        'Stormtide'),
    ('dragon_whale_ore',      6, 'max_hp',           'Dragon-Whale'),
    ('sea_god_adamant',       7, 'damage_reduction', 'Sea-God');


-- ---------------------------------------------------------------------------
-- Where the seams run
-- ---------------------------------------------------------------------------
-- Every region reaches all seven tiers, so no region is a dead end for a
-- miner. Weight falls with tier on the same ladder herbs use - 8, 6, 4, 2.5,
-- 1.5, 0.8, 0.3 - because for ore as for herbs the tier IS the scarcity.

INSERT INTO region_veins (region_code, material_code, weight)
SELECT v.region, o.material_code,
       (ARRAY[8, 6, 4, 2.5, 1.5, 0.8, 0.3])[o.tier]
FROM (VALUES
    ('central','spirit_stone'),('central','iron_ore'),('central','metal_ore'),
    ('central','human_qi_stone'),('central','spirit_iron'),
    ('central','refinement_stone'),('central','purple_crystal'),
    ('central','nine_palace_alloy'),('central','heavenly_mandate_iron'),
    ('central','dao_marrow_ore'),('central','primordial_origin_ore'),

    ('northern','iron_ore'),('northern','dark_iron'),('northern','bloodrust_ore'),
    ('northern','thunder_veined_steel'),('northern','war_god_steel'),
    ('northern','mammoth_bone_ore'),('northern','everwinter_adamant'),

    ('southern','mountain_rock'),('southern','iron_ore'),('southern','jade_shavings'),
    ('southern','venom_vein_crystal'),('southern','bonestone'),
    ('southern','living_jade'),('southern','soulstone_ore'),
    ('southern','myriad_venom_crystal'),

    ('western','metal_ore'),('western','copper_shavings'),('western','iron_ore'),
    ('western','gold_ore'),('western','silver_sand'),('western','magma_iron'),
    ('western','desert_gold_vein'),('western','mirage_silver'),
    ('western','blazing_sunsteel'),('western','golden_crow_ore'),

    ('eastern','tide_stone'),('eastern','tidal_bronze'),('eastern','pearl_sand_ore'),
    ('eastern','abyssal_iron'),('eastern','stormtide_alloy'),
    ('eastern','dragon_whale_ore'),('eastern','sea_god_adamant')
) AS v (region, material)
JOIN ores o ON o.material_code = v.material;


-- ---------------------------------------------------------------------------
-- The profession, and its dials
-- ---------------------------------------------------------------------------
-- Mining is the third profession, which is again what 0038's sparse
-- `player_professions` rows bought: an INSERT, not a table.

INSERT INTO professions (code, name, exp_per_level, description) VALUES
    ('mining', 'Miner', 120,
     'Works the veins under a region for ore. Level decides how deep a seam can be worked and how much comes out of it.');

INSERT INTO game_config (key, value, description) VALUES
    ('mine_cooldown_minutes', 0.5,
     'PLACEHOLDER - wait between mining swings. Held at the testing value the other world actions use.'),
    ('mine_yield_min', 1,
     'PLACEHOLDER - fewest units a vein gives up.'),
    ('mine_yield_max', 3,
     'PLACEHOLDER - most units a vein gives up before bonuses.'),
    ('mining_base_tier', 1,
     'Deepest vein a Miner at level 1 can work.'),
    ('mining_levels_per_tier', 4,
     'Miner levels per additional tier of depth.'),
    ('mining_yield_per_level', 0.02,
     'PLACEHOLDER - extra yield per Miner level, added to the same fraction stack everything else uses.'),
    ('mining_exp_per_tier', 20,
     'PLACEHOLDER - Miner EXP per tier of the ore brought up.'),
    ('mine_rich_chance', 0.08,
     'PLACEHOLDER - chance a swing opens a rich seam.'),
    ('mine_rich_multiplier', 2,
     'PLACEHOLDER - what a rich seam multiplies the yield by.');

-- Depth, from level. A function rather than a column on `ores`, so the whole
-- gate retunes with one config row instead of thirty-nine.
CREATE FUNCTION mining_tier_cap(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(7,
        game_config_value('mining_base_tier')
        + floor(p_level / game_config_value('mining_levels_per_tier'))
    )::smallint;
$$;

COMMENT ON FUNCTION mining_tier_cap(SMALLINT) IS
    'How deep a Miner of this level can work, askable for a level nobody has reached.';


-- ---------------------------------------------------------------------------
-- mine
-- ---------------------------------------------------------------------------
-- The same weighted draw gather() uses, over the veins this miner can
-- actually work, and it reports what it could not reach as well as what it
-- got - "this region goes to Tier 6" is the thing a miner most wants to know
-- and the one thing a yield line cannot say.

CREATE FUNCTION mine(p_player_id BIGINT)
RETURNS TABLE (
    material_code TEXT,
    material_name TEXT,
    rarity        TEXT,
    emoji         TEXT,
    ore_tier      SMALLINT,
    quantity      BIGINT,
    held          BIGINT,
    rich          BOOLEAN,
    exp_gained    BIGINT,
    level_after   SMALLINT,
    tier_cap      SMALLINT,
    deepest       SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    skill   SMALLINT;
    cap     SMALLINT;
    deep    SMALLINT;
    picked  TEXT;
    grade   SMALLINT;
    lo      NUMERIC := game_config_value('mine_yield_min');
    hi      NUMERIC := game_config_value('mine_yield_max');
    struck  BOOLEAN := random() < game_config_value('mine_rich_chance');
    amount  BIGINT;
    total   BIGINT;
    gained  BIGINT;
    lvl     SMALLINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    skill := profession_level(p_player_id, 'mining');
    cap   := mining_tier_cap(skill);

    SELECT max(o.tier) INTO deep
    FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = here;

    IF deep IS NULL THEN
        RAISE EXCEPTION 'there is no stone worth breaking in %', here
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT rv.material_code, o.tier INTO picked, grade
    FROM region_veins rv
    JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = here AND o.tier <= cap
    ORDER BY -ln(random()) / rv.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'every vein here is deeper than you can work'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same additive stack as gathering. A Gu that finds more in a forage
    -- finds more in a seam; a second yield stat granted by nothing would be a
    -- word in the vocabulary with no speaker.
    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1)))
        * (1 + COALESCE((SELECT b.gathering_bonus FROM player_manual_bonuses b
                         WHERE b.player_id = p_player_id), 0)
             + gu_stat(p_player_id, 'gathering_yield')
             + skill * game_config_value('mining_yield_per_level'))
    ));

    IF struck THEN
        amount := round(amount * game_config_value('mine_rich_multiplier'));
    END IF;

    total  := grant_material(p_player_id, picked, amount);

    gained := GREATEST(5, grade * game_config_value('mining_exp_per_tier'));
    lvl    := grant_profession_exp(p_player_id, 'mining', gained, TRUE);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, m.emoji, grade, amount, total, struck,
           gained, lvl, cap, deep
    FROM materials m WHERE m.code = picked;
END;
$$;

COMMENT ON FUNCTION mine(BIGINT) IS
    'One swing at the veins under a region, filtered to the depth this Miner can reach.';
