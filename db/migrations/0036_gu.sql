-- 0036_gu
--
-- Gu: the equippable half of a build.
--
-- APERTURE CAPACITY, NOT SLOTS. A fixed number of slots makes every build the
-- same shape - the question is only which eight Gu are best. A capacity that
-- Gu consume by SIZE makes it a different question: six cheap Rank 1 Gu, or
-- two expensive ones and room for nothing else. That is where a build comes
-- from, and it is also how a Gu Master's aperture works in the source.
--
-- EFFECTS ARE ROWS. The design spec asks for "a general ability schema instead
-- of hard-coding every Gu", and this is it: `gu_effects` is the vocabulary,
-- `gu_type_effects` is what each Gu says in that vocabulary, and the combat
-- code reads named totals. A new effect is a row plus one consumer; it is
-- never a schema change, and a Gu that grants something nothing consumes yet
-- is marked as such rather than quietly doing nothing.
--
-- EVERY EFFECT IS CAPPED. Six crit Gu must not make a 100% crit rate. The cap
-- lives beside the effect, so the ceiling is data and retuning it is an
-- UPDATE. Caps are also what stop one build from being every build.
--
-- MULTI-HIT PAYS FOR ITSELF. Extra strikes land at a fraction of the first,
-- and defence subtracts from EVERY strike - so a multi-hit build wants armour
-- penetration in a way a big-hit build does not. The two axes the request asks
-- for pull in different directions on purpose.
--
-- HARMONY IS ON THE INSTANCE, unused today. Killer-move fusion will consume
-- 10-100 Gu behind one leader, and how well they combine is the same question
-- refinement already answers for pages - `pair_harmony()` is waiting. Storing
-- it now means the Gu dropping today are fusable later; adding it afterwards
-- would mean every Gu minted before the feature was worthless in it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- gu_effects
-- ---------------------------------------------------------------------------

CREATE TABLE gu_effects (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',

    -- Ceiling on the summed magnitude across everything equipped.
    cap         NUMERIC(6, 4) NOT NULL CHECK (cap > 0),

    -- Whether anything reads it yet. Four of these are recorded and rendered
    -- and consumed by nothing; a Gu that says so beats one that lies.
    is_live     BOOLEAN NOT NULL DEFAULT TRUE,

    emoji       TEXT NOT NULL DEFAULT '\N{BUG}',
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO gu_effects (code, name, description, cap, is_live, emoji, sort_order) VALUES
    ('attack_power', 'Attack Power',
     'Damage on every strike you land.', 2.0000, TRUE, '⚔️', 10),
    ('multi_hit', 'Extra Strikes',
     'Chance of another strike. Extra strikes land lighter, and defence bites each one.',
     2.0000, TRUE, '🌀', 20),
    ('crit_rate', 'Critical Rate',
     'Chance a strike lands critically.', 0.6000, TRUE, '🎯', 30),
    ('crit_damage', 'Critical Damage',
     'How much harder a critical strike lands, above the base half again.',
     2.0000, TRUE, '💥', 40),
    ('armor_pen', 'Armour Penetration',
     'Defence ignored. Worth most to a build that strikes often.',
     0.7500, TRUE, '🗡️', 50),
    ('lifesteal', 'Life Steal',
     'Fraction of the damage you deal that returns as health.',
     0.4000, TRUE, '🩸', 60),
    ('dodge', 'Evasion',
     'Chance to take nothing from an incoming blow.', 0.4000, TRUE, '💨', 70),
    ('damage_reduction', 'Damage Reduction',
     'Fraction turned aside from every blow that does land.', 0.5000, TRUE, '🛡️', 80),
    ('max_hp', 'Maximum HP',
     'A larger body to spend.', 1.0000, TRUE, '❤️', 90),
    ('cultivation_rate', 'Cultivation Speed',
     'Faster accrual while carried.', 1.0000, TRUE, '🌿', 100),
    ('gathering_yield', 'Gathering Yield',
     'More from a forage.', 1.0000, TRUE, '🌱', 110),
    ('shield', 'Shield',
     'Absorbs damage before health does. No shield system exists yet.',
     1.0000, FALSE, '🔷', 120),
    ('heal', 'Restoration',
     'Healing over a fight. Nothing heals mid-battle yet.', 1.0000, FALSE, '💚', 130),
    ('resource_find', 'Fortune',
     'Better finds while exploring. Nothing reads it yet.', 1.0000, FALSE, '🍀', 140),
    ('suppression', 'Suppression',
     'Interferes with an enemy''s abilities. Creatures have no abilities to suppress yet.',
     1.0000, FALSE, '🌑', 150);

COMMENT ON TABLE gu_effects IS
    'The vocabulary a Gu speaks in, with the ceiling on each. A new effect is a row plus one consumer, never a schema change.';


-- ---------------------------------------------------------------------------
-- gu_types
-- ---------------------------------------------------------------------------
-- Content. A player's copy is an instance in `player_gu`, because two copies
-- of the same Gu differ by stars and by harmony - and because killer-move
-- fusion will want to consume a hundred of them individually.

CREATE TABLE gu_types (
    gu_type_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    code        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,

    path_code   TEXT NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,
    rank        SMALLINT NOT NULL DEFAULT 1 CHECK (rank BETWEEN 1 AND 9),
    rarity      TEXT NOT NULL REFERENCES rarities (code) ON DELETE RESTRICT,

    category    TEXT NOT NULL DEFAULT 'attack'
                CHECK (category IN ('attack', 'defense', 'support',
                                    'cultivation', 'utility')),

    -- What it costs of the aperture. This is the whole build constraint.
    size        SMALLINT NOT NULL DEFAULT 1 CHECK (size BETWEEN 1 AND 12),

    emoji       TEXT NOT NULL DEFAULT '\N{BUG}',
    description TEXT NOT NULL DEFAULT ''
);

CREATE INDEX gu_types_path_idx   ON gu_types (path_code);
CREATE INDEX gu_types_rarity_idx ON gu_types (rarity);
CREATE INDEX gu_types_rank_idx   ON gu_types (rank, size);

CREATE TABLE gu_type_effects (
    gu_type_id  BIGINT NOT NULL REFERENCES gu_types (gu_type_id) ON DELETE CASCADE,
    effect_code TEXT   NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    -- The one-star value. Stars scale it; see gu_star_step.
    magnitude   NUMERIC(6, 4) NOT NULL CHECK (magnitude > 0),

    PRIMARY KEY (gu_type_id, effect_code)
);

CREATE INDEX gu_type_effects_effect_idx ON gu_type_effects (effect_code);


-- ---------------------------------------------------------------------------
-- player_gu
-- ---------------------------------------------------------------------------
-- Instances. Duplicates do NOT merge on their own: killer-move fusion needs a
-- pile of them, and a system that silently ate your tenth copy would have eaten
-- the fodder for the thing the copies are for.

CREATE TABLE player_gu (
    gu_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    owner_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    gu_type_id BIGINT NOT NULL REFERENCES gu_types (gu_type_id) ON DELETE RESTRICT,

    stars      SMALLINT NOT NULL DEFAULT 1 CHECK (stars BETWEEN 1 AND 5),

    -- For fusion, which does not exist yet. Rolled at the moment it drops so
    -- today's Gu are usable in tomorrow's killer moves.
    harmony    SMALLINT NOT NULL DEFAULT 50 CHECK (harmony BETWEEN 0 AND 150),

    found_in   TEXT REFERENCES regions (code) ON DELETE SET NULL,
    got_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_gu_owner_idx ON player_gu (owner_id);
CREATE INDEX player_gu_type_idx  ON player_gu (gu_type_id);
CREATE INDEX player_gu_region_idx ON player_gu (found_in);

COMMENT ON COLUMN player_gu.harmony IS
    'How readily this Gu combines with others. Unread until killer-move fusion exists; stored now so Gu found today are fodder tomorrow.';


-- ---------------------------------------------------------------------------
-- The aperture
-- ---------------------------------------------------------------------------

ALTER TABLE realms ADD COLUMN gu_capacity SMALLINT NOT NULL DEFAULT 3
    CHECK (gu_capacity > 0);

UPDATE realms SET gu_capacity = 2 + rank + CASE WHEN stage = 'peak' THEN 1 ELSE 0 END;

COMMENT ON COLUMN realms.gu_capacity IS
    'Aperture size. Gu consume it by their own size, so a build is a knapsack rather than a list of slots.';

CREATE TABLE player_gu_equipped (
    gu_id       BIGINT PRIMARY KEY REFERENCES player_gu (gu_id) ON DELETE CASCADE,
    player_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    equipped_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_gu_equipped_player_idx ON player_gu_equipped (player_id);

CREATE FUNCTION gu_capacity_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT r.gu_capacity
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;
$$;

CREATE FUNCTION gu_used_by(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(t.size), 0)::smallint
    FROM player_gu_equipped e
    JOIN player_gu g ON g.gu_id = e.gu_id
    JOIN gu_types t ON t.gu_type_id = g.gu_type_id
    WHERE e.player_id = p_player_id;
$$;

-- The capacity rule is a trigger, not a count the caller performs: two
-- commands racing would both pass a check and both equip. Same reasoning as
-- the two-manual limit being a primary key.
CREATE FUNCTION enforce_gu_capacity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    owner    BIGINT;
    incoming SMALLINT;
BEGIN
    SELECT g.owner_id, t.size INTO owner, incoming
    FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id
    WHERE g.gu_id = NEW.gu_id;

    IF owner IS DISTINCT FROM NEW.player_id THEN
        RAISE EXCEPTION 'that Gu is not yours' USING ERRCODE = 'check_violation';
    END IF;

    IF gu_used_by(NEW.player_id) + incoming > gu_capacity_of(NEW.player_id) THEN
        RAISE EXCEPTION 'your aperture holds % and this needs % more',
            gu_capacity_of(NEW.player_id), incoming
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER player_gu_equipped_respects_the_aperture
    BEFORE INSERT ON player_gu_equipped
    FOR EACH ROW EXECUTE FUNCTION enforce_gu_capacity();


-- ---------------------------------------------------------------------------
-- What the equipped Gu are worth
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('gu_star_step', 0.25,
     'PLACEHOLDER - how much each star above the first adds to a Gu''s magnitude.'),
    ('gu_multi_hit_power', 0.55,
     'PLACEHOLDER - what an extra strike lands for, as a fraction of the first.'),
    ('gu_crit_damage_base', 0.50,
     'PLACEHOLDER - a critical strike''s bonus before any crit_damage effect.'),
    ('gu_drop_chance', 0.02,
     'PLACEHOLDER - chance a kill yields a Gu, before the regional table.');

CREATE VIEW player_gu_stats AS
SELECT
    e.player_id,
    te.effect_code,
    LEAST(
        ef.cap,
        sum(te.magnitude * (1 + game_config_value('gu_star_step') * (g.stars - 1)))
    ) AS total,
    sum(te.magnitude * (1 + game_config_value('gu_star_step') * (g.stars - 1)))
        > ef.cap AS capped
FROM player_gu_equipped e
JOIN player_gu g       ON g.gu_id = e.gu_id
JOIN gu_type_effects te ON te.gu_type_id = g.gu_type_id
JOIN gu_effects ef     ON ef.code = te.effect_code
GROUP BY e.player_id, te.effect_code, ef.cap;

COMMENT ON VIEW player_gu_stats IS
    'Summed equipped magnitudes per effect, already capped. `capped` says the ceiling is being wasted.';

CREATE FUNCTION gu_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT s.total FROM player_gu_stats s
         WHERE s.player_id = p_player_id AND s.effect_code = p_effect),
        0
    );
$$;


-- ---------------------------------------------------------------------------
-- The catalog
-- ---------------------------------------------------------------------------
-- The 26 regional Gu from the monster roster, plus nine from the Gu catalog
-- that give the six build axes somewhere to go. Every one of the six - extra
-- strikes, raw damage, evasion, penetration, criticals, life steal - has at
-- least three Gu at different sizes, so a build is assembled rather than
-- picked.

INSERT INTO gu_types (code, name, path_code, rank, rarity, category, size, emoji, description) VALUES
    -- Central Continent
    ('bookworm', 'Bookworm', 'wisdom', 1, 'common', 'cultivation', 1, '📖',
     'Eats paper and leaves the meaning behind.'),
    ('moonlight_gu', 'Moonlight Gu', 'light', 1, 'common', 'attack', 1, '🌙',
     'Throws a crescent of cold light. The first attack Gu most cultivators hold.'),
    ('hope_gu', 'Hope Gu', 'dream', 1, 'uncommon', 'cultivation', 1, '🕯️',
     'Keeps a cultivator at it on the days the numbers do not move.'),
    ('rice_bag_grass_gu', 'Rice Bag Grass Gu', 'food', 1, 'common', 'utility', 1, '🌾',
     'A bag that is also a plant. Holds more than it should.'),
    ('liquor_worm', 'Liquor Worm', 'food', 1, 'rare', 'cultivation', 1, '🍶',
     'Improves the quality of what you take in, which improves everything after.'),
    ('signal_gu', 'Signal Gu', 'human', 1, 'common', 'utility', 1, '📡',
     'One half hears what the other half is told.'),

    -- Western Desert
    ('ghost_fire_gu', 'Ghost Fire Gu', 'soul', 1, 'uncommon', 'attack', 2, '👻',
     'A cold flame that takes something back from what it burns.'),
    ('stone_skin_gu', 'Stone Skin Gu', 'earth', 1, 'common', 'defense', 1, '🪨',
     'The first layer of armour a desert cultivator learns to wear.'),
    ('golden_needle_gu', 'Golden Needle Gu', 'metal', 1, 'uncommon', 'attack', 1, '📍',
     'Thin enough to find the gap in anything.'),
    ('golden_centipede_gu', 'Golden Centipede Gu', 'metal', 1, 'rare', 'attack', 2, '🐛',
     'A hundred legs, and every one of them arrives.'),

    -- Eastern Sea
    ('fish_scale_gu', 'Fish Scale Gu', 'water', 1, 'common', 'defense', 1, '🐟',
     'You are harder to catch hold of than you were.'),
    ('fish_enslavement_gu', 'Fish Enslavement Gu', 'enslavement', 1, 'uncommon', 'utility', 1, '🎣',
     'The shoal brings you things. Nobody has explained why.'),
    ('cleansing_water_gu', 'Cleansing Water Gu', 'water', 1, 'uncommon', 'defense', 1, '💧',
     'Washes out what a fight leaves in you.'),
    ('scale_armor_gu', 'Scale Armor Gu', 'water', 1, 'uncommon', 'defense', 2, '🐠',
     'Overlapping plates, and every one of them is a fish.'),
    ('icicle_gu', 'Icicle Gu', 'ice', 1, 'common', 'attack', 1, '🧊',
     'Sharpened by the cold rather than by hand, and it shows in the edge.'),

    -- Northern Plains
    ('bear_strength_gu', 'Bear Strength Gu', 'strength', 1, 'uncommon', 'attack', 2, '🐻',
     'Borrowed shoulders. They do not care what you were lifting before.'),
    ('wolf_enslavement_gu', 'Wolf Enslavement Gu', 'enslavement', 1, 'uncommon', 'attack', 1, '🐺',
     'Something else bites at the same time you do.'),
    ('big_strength_gu', 'Big Strength Gu', 'strength', 1, 'common', 'attack', 1, '💪',
     'The plainest Gu in the north, and the one most northerners are carrying.'),
    ('bronze_skin_gu', 'Bronze Skin Gu', 'metal', 1, 'uncommon', 'defense', 2, '🥉',
     'Heavier than stone skin and worth the weight.'),
    ('carapace_gu', 'Carapace Gu', 'earth', 1, 'common', 'defense', 1, '🪲',
     'A shell that grows with you, slowly, and never quite fits.'),

    -- Southern Border
    ('poison_needle_gu', 'Poison Needle Gu', 'poison', 1, 'common', 'attack', 1, '🪡',
     'The needle is the delivery. The needle is not the point.'),
    ('grass_puppet_gu', 'Grass Puppet Gu', 'wood', 1, 'uncommon', 'defense', 2, '🎎',
     'Something shaped like you stands where you were.'),
    ('mudskin_toad', 'Mudskin Toad', 'earth', 1, 'common', 'defense', 1, '🐸',
     'A layer of mud, applied constantly, by a toad.'),
    ('jade_skin_gu', 'Jade Skin Gu', 'wood', 2, 'uncommon', 'defense', 2, '🟢',
     'The skin goes jade-hard, and stays that way through the poison.'),
    ('bone_bamboo_gu', 'Bone Bamboo Gu', 'bone', 1, 'uncommon', 'attack', 1, '🎋',
     'Splits along the grain, into a point.'),
    ('venom_sac_gu', 'Venom Sac Gu', 'poison', 1, 'common', 'attack', 1, '🧪',
     'What it takes out of them goes somewhere.'),

    -- From the catalog, for the build axes the regional set leaves thin.
    ('white_boar_gu', 'White Boar Gu', 'strength', 1, 'uncommon', 'attack', 1, '🐗',
     'Permanent, in the way that a scar is permanent.'),
    ('black_boar_gu', 'Black Boar Gu', 'strength', 1, 'uncommon', 'attack', 1, '🐖',
     'The other half of a pair nobody sells together.'),
    ('copper_skin_gu', 'Copper Skin Gu', 'strength', 1, 'uncommon', 'defense', 1, '🟤',
     'Hardens the skin. Turns green eventually, which is said to be fine.'),
    ('water_spider_gu', 'Water Spider Gu', 'water', 1, 'common', 'defense', 1, '🕷️',
     'You stand on things you should be standing in.'),
    ('brute_force_longhorn_beetle_gu', 'Brute Force Longhorn Beetle Gu', 'strength', 1,
     'uncommon', 'attack', 2, '🪳',
     'All of the strength, none of the technique, and it does not apologise.'),
    ('moonshadow_gu', 'Moonshadow Gu', 'light', 2, 'rare', 'attack', 2, '🌘',
     'Finds the moment a guard is somewhere else.'),
    ('spiral_bone_spear_gu', 'Spiral Bone Spear Gu', 'bone', 2, 'uncommon', 'attack', 2, '🦴',
     'It turns as it travels, and armour stops meaning much.'),
    ('all_out_effort_gu', 'All-Out Effort Gu', 'strength', 3, 'epic', 'attack', 3, '🔥',
     'Everything you have been holding back, at once, once.'),
    ('battle_bone_wheel', 'Battle Bone Wheel', 'bone', 4, 'legendary', 'attack', 4, '☸️',
     'Three passes before it comes back to your hand. Sometimes four.');

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT t.gu_type_id, v.effect, v.magnitude
FROM (VALUES
    ('bookworm',            'cultivation_rate', 0.0400),
    ('moonlight_gu',        'attack_power',     0.0600),
    ('hope_gu',             'cultivation_rate', 0.0500),
    ('rice_bag_grass_gu',   'gathering_yield',  0.1000),
    ('liquor_worm',         'cultivation_rate', 0.0800),
    ('signal_gu',           'gathering_yield',  0.0600),
    ('signal_gu',           'resource_find',    0.0500),

    ('ghost_fire_gu',       'lifesteal',        0.0800),
    ('stone_skin_gu',       'damage_reduction', 0.0500),
    ('golden_needle_gu',    'armor_pen',        0.1200),
    ('golden_centipede_gu', 'multi_hit',        0.1500),

    ('fish_scale_gu',       'dodge',            0.0600),
    ('fish_enslavement_gu', 'gathering_yield',  0.0800),
    ('cleansing_water_gu',  'max_hp',           0.0600),
    ('scale_armor_gu',      'damage_reduction', 0.0800),
    ('icicle_gu',           'attack_power',     0.0500),
    ('icicle_gu',           'crit_rate',        0.0300),

    ('bear_strength_gu',    'attack_power',     0.1000),
    ('wolf_enslavement_gu', 'multi_hit',        0.1000),
    ('big_strength_gu',     'attack_power',     0.0600),
    ('bronze_skin_gu',      'damage_reduction', 0.0700),
    ('carapace_gu',         'damage_reduction', 0.0400),
    ('carapace_gu',         'max_hp',           0.0400),

    ('poison_needle_gu',    'armor_pen',        0.0800),
    ('grass_puppet_gu',     'dodge',            0.0800),
    ('mudskin_toad',        'damage_reduction', 0.0500),
    ('jade_skin_gu',        'damage_reduction', 0.1000),
    ('jade_skin_gu',        'max_hp',           0.0500),
    ('bone_bamboo_gu',      'crit_rate',        0.0800),
    ('venom_sac_gu',        'lifesteal',        0.0500),

    ('white_boar_gu',       'attack_power',     0.0800),
    ('black_boar_gu',       'attack_power',     0.0700),
    ('black_boar_gu',       'max_hp',           0.0300),
    ('copper_skin_gu',      'damage_reduction', 0.0600),
    ('water_spider_gu',     'dodge',            0.0700),
    ('brute_force_longhorn_beetle_gu', 'attack_power', 0.1200),
    ('moonshadow_gu',       'crit_rate',        0.1000),
    ('moonshadow_gu',       'suppression',      0.1000),
    ('spiral_bone_spear_gu','armor_pen',        0.2000),
    ('spiral_bone_spear_gu','attack_power',     0.0500),
    ('all_out_effort_gu',   'attack_power',     0.2000),
    ('all_out_effort_gu',   'crit_damage',      0.2500),
    ('battle_bone_wheel',   'multi_hit',        0.3500),
    ('battle_bone_wheel',   'attack_power',     0.1000)
) AS v (gu_code, effect, magnitude)
JOIN gu_types t ON t.code = v.gu_code;


-- ---------------------------------------------------------------------------
-- Where they come from
-- ---------------------------------------------------------------------------
-- The roster document is explicit: material drops are common because materials
-- feed Gu refinement, and whole Gu are rare - 0.5-2% on an ordinary kill. Gu
-- refinement from materials is the intended main source and does not exist
-- yet; this is the drip that makes the system playable before it does.

CREATE TABLE gu_region_drops (
    region_code TEXT   NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    gu_type_id  BIGINT NOT NULL REFERENCES gu_types (gu_type_id) ON DELETE CASCADE,

    weight      NUMERIC(6, 2) NOT NULL DEFAULT 10 CHECK (weight > 0),

    PRIMARY KEY (region_code, gu_type_id)
);

CREATE INDEX gu_region_drops_gu_idx ON gu_region_drops (gu_type_id);

INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
SELECT v.region, t.gu_type_id, v.weight
FROM (VALUES
    ('central', 'bookworm', 10), ('central', 'moonlight_gu', 10),
    ('central', 'hope_gu', 6), ('central', 'rice_bag_grass_gu', 10),
    ('central', 'liquor_worm', 3), ('central', 'signal_gu', 10),

    ('western', 'ghost_fire_gu', 6), ('western', 'stone_skin_gu', 10),
    ('western', 'golden_needle_gu', 6), ('western', 'golden_centipede_gu', 3),
    ('western', 'copper_skin_gu', 6),

    ('eastern', 'fish_scale_gu', 10), ('eastern', 'fish_enslavement_gu', 6),
    ('eastern', 'cleansing_water_gu', 6), ('eastern', 'scale_armor_gu', 6),
    ('eastern', 'icicle_gu', 10), ('eastern', 'water_spider_gu', 10),

    ('northern', 'bear_strength_gu', 6), ('northern', 'wolf_enslavement_gu', 6),
    ('northern', 'big_strength_gu', 10), ('northern', 'bronze_skin_gu', 6),
    ('northern', 'carapace_gu', 10), ('northern', 'white_boar_gu', 6),
    ('northern', 'black_boar_gu', 6),
    ('northern', 'brute_force_longhorn_beetle_gu', 4),
    ('northern', 'all_out_effort_gu', 1), ('northern', 'battle_bone_wheel', 1),

    ('southern', 'poison_needle_gu', 10), ('southern', 'grass_puppet_gu', 6),
    ('southern', 'mudskin_toad', 10), ('southern', 'jade_skin_gu', 4),
    ('southern', 'bone_bamboo_gu', 6), ('southern', 'venom_sac_gu', 10),
    ('southern', 'spiral_bone_spear_gu', 3), ('southern', 'moonshadow_gu', 2)
) AS v (region, gu_code, weight)
JOIN gu_types t ON t.code = v.gu_code;

CREATE FUNCTION grant_gu(p_player_id BIGINT, p_gu_type_id BIGINT, p_region TEXT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_id BIGINT;
BEGIN
    INSERT INTO player_gu (owner_id, gu_type_id, harmony, found_in)
    VALUES (p_player_id, p_gu_type_id,
            30 + floor(random() * 71)::smallint,   -- 30-100, room to be lucky
            p_region)
    RETURNING gu_id INTO new_id;

    RETURN new_id;
END;
$$;

CREATE FUNCTION roll_gu_drop(p_player_id BIGINT, p_region TEXT, p_rank SMALLINT DEFAULT 1)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    picked BIGINT;
BEGIN
    IF random() >= game_config_value('gu_drop_chance') THEN
        RETURN NULL;
    END IF;

    -- Nothing hands out a Gu of a higher rank than the thing guarding it.
    SELECT d.gu_type_id INTO picked
    FROM gu_region_drops d
    JOIN gu_types t ON t.gu_type_id = d.gu_type_id
    WHERE d.region_code = p_region
      AND t.rank <= GREATEST(p_rank, 1)
    ORDER BY -ln(random()) / d.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN grant_gu(p_player_id, picked, p_region);
END;
$$;

COMMENT ON FUNCTION roll_gu_drop(BIGINT, TEXT, SMALLINT) IS
    'A whole Gu off a corpse: rare, regional, and never above the rank of what dropped it.';


-- ---------------------------------------------------------------------------
-- Gu reach the damage pipeline
-- ---------------------------------------------------------------------------
-- Through the same external hook 0008 left for "Dao Marks, equipment and
-- buffs", which 0013 filled with traits and 0022 with manuals. Additive, like
-- everything else: a +5% race, a +4% manual and a +10% Gu make +19%.

CREATE OR REPLACE FUNCTION player_external_multiplier(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT 1
    + COALESCE((
        SELECT SUM(tp.weight * (
            COALESCE((SELECT rpb.damage_bonus
                      FROM player_character pc
                      JOIN race_path_bonuses rpb
                        ON rpb.race_code = pc.race_code AND rpb.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT rob.damage_bonus
                      FROM player_character pc
                      JOIN root_path_bonuses rob
                        ON rob.root_code = pc.root_code AND rob.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT ppb.damage_bonus
                      FROM player_physique pp
                      JOIN physique_path_bonuses ppb
                        ON ppb.physique_id = pp.physique_id AND ppb.path_code = tp.path_code
                      WHERE pp.player_id = p_player_id), 0)
        ))
        FROM technique_paths tp
        WHERE tp.technique_id = p_technique_id
    ), 0)
    + COALESCE((SELECT b.attack_bonus FROM player_manual_bonuses b
                WHERE b.player_id = p_player_id), 0)
    + gu_stat(p_player_id, 'attack_power');
$$;


-- ---------------------------------------------------------------------------
-- HP reads the Gu too
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    base_def  NUMERIC := game_config_value('physique_base_defense');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    base_str  NUMERIC := game_config_value('physique_base_strength');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
    man_hp      NUMERIC := 0;
    man_def     NUMERIC := 0;
    man_str     NUMERIC := 0;
    new_level   SMALLINT;
    new_max_hp  BIGINT;
    hp_gained   BIGINT;
BEGIN
    SELECT * INTO row_before FROM player_physique WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    SELECT tr.hp_multiplier, tr.defense_multiplier, tr.strength_multiplier
    INTO mult_hp, mult_def, mult_str
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;

    SELECT b.hp_bonus, b.defense_bonus, b.strength_bonus
    INTO man_hp, man_def, man_str
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0)
                + gu_stat(p_player_id, 'max_hp');
    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0);
    mult_str := COALESCE(mult_str, 1) + COALESCE(man_str, 0);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = round((base_def + def_rate * (new_level - 1)) * mult_def),
        strength    = round((base_str + str_rate * (new_level - 1)) * mult_str)
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- Cultivation and gathering read them
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION gather(p_player_id BIGINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, rarity TEXT, quantity BIGINT, held BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    picked  TEXT;
    lo      NUMERIC := game_config_value('gather_yield_min');
    hi      NUMERIC := game_config_value('gather_yield_max');
    bonus   NUMERIC := 0;
    amount  BIGINT;
    total   BIGINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    SELECT rm.material_code INTO picked
    FROM region_materials rm
    WHERE rm.region_code = here
    ORDER BY -ln(random()) / rm.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'nothing grows in %', here USING ERRCODE = 'check_violation';
    END IF;

    SELECT b.gathering_bonus INTO bonus
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1)))
        * (1 + COALESCE(bonus, 0) + gu_stat(p_player_id, 'gathering_yield'))
    ));
    total  := grant_material(p_player_id, picked, amount);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, amount, total
    FROM materials m WHERE m.code = picked;
END;
$$;
