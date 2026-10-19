-- 0204_a_key_and_nine_doors
--
-- The foundation for dungeons: what you need to get in, and what is waiting.
-- The run itself - the party, the rounds, the fight - is 0205. This migration
-- adds nothing that moves.
--
-- ONE DOOR PER REALM. A dungeon is named for the realm it was built for and
-- carries a boss of that rank, so "which dungeon" is the same question as
-- "how far along am I". Any of the nine may be entered by anybody: a Qi
-- Condensation cultivator may walk into the Dao Realm's door, and the numbers
-- below are what happens to them. Being carried by a strong party is a
-- legitimate way in, and overreaching alone is a legitimate way to die.
--
-- FOUR DIFFICULTIES, and they only move two numbers - the boss's health and
-- what it pays. A difficulty that also changed the rules would be four fights
-- to balance instead of one.
--
-- THE KEY IS A MATERIAL, which is the whole reason it can be traded: 0148's
-- `trade_set_material` already moves materials between cultivators, so a key
-- needs no trading code of its own. It is `currency` and registered in
-- `currency_materials`, so the furnace and the cauldron refuse to melt or brew
-- it the same way they refuse Spirit Stones.
--
-- One key every twelve hours, and `cooldown_status` finds it on its own -
-- that function reads every `%_cooldown_minutes` in `game_config`, so naming
-- the config is the whole registration. It shows up in /cooldowns with no
-- code change at all.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The key
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, emoji, description) VALUES
    ('dungeon_key', 'Dungeon Key', 'currency', 'rare', '🗝️',
     'Cut for one door and one door only, and it does not care which. Somebody '
     'worked out how to make them faster than the dungeons can be emptied, '
     'which is why they change hands so often.');

INSERT INTO currency_materials (material_code, note) VALUES
    ('dungeon_key',
     'Opens a dungeon. Not ore, not a herb - the furnace and the cauldron '
     'refuse it.');

INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_key_cooldown_minutes', 720,
     'Twelve hours between keys. `cooldown_status` reads every '
     '%_cooldown_minutes in this table, so naming it here is the whole '
     'registration - it appears in /cooldowns without a line of code.'),
    ('dungeon_key_per_claim', 1,
     'Keys handed over per claim. One, so a party of five is four people who '
     'each waited or one person who traded for four.'),
    ('dungeon_party_max', 5,
     'Raiders in one run, the leader included.'),
    ('dungeon_party_hp_step', 0.60,
     'Extra boss health per raider beyond the first, as a fraction. Five '
     'raiders face 3.4x a solo run - enough that a party is worth having and '
     'not so much that it is the only way in.');

INSERT INTO cooldown_display (action, label, emoji, section, sort_order) VALUES
    ('dungeon_key', 'Dungeon Key', '🗝️', 'Gathering', 40);


-- ---------------------------------------------------------------------------
-- What lives behind the doors
-- ---------------------------------------------------------------------------

-- A dungeon boss is its own kind. It is not a world boss (nobody announces it
-- and it does not expire), not an elite (it is not wandering around), and not
-- a rogue.
ALTER TABLE creature_species DROP CONSTRAINT creature_species_kind_check;
ALTER TABLE creature_species ADD CONSTRAINT creature_species_kind_check
    CHECK (kind = ANY (ARRAY['beast', 'elite', 'boss', 'world', 'rogue',
                             'dungeon']));

-- Health continues the curve the existing bosses draw - 1,400 at rank 3,
-- 18,000 at rank 7 - and attack and defence sit near a third and a seventh of
-- it. These are the SOLO numbers; a party multiplies the health and not the
-- damage, so five raiders share a bigger pool while each still takes a
-- rank-appropriate hit.
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed,
     description)
VALUES
    ('dungeon_hollow_sentinel', 'Hollow Sentinel', 1, 'dungeon',
     900, 46, 26, 18,
     'Something was set here to guard a door and then forgotten by whoever '
     'set it. It has not stopped.'),

    ('dungeon_marrow_choir', 'Marrow Choir', 2, 'dungeon',
     2600, 105, 58, 22,
     'Nine skulls on nine stalks, and they do not agree about the tune. The '
     'disagreement is what hurts.'),

    ('dungeon_ashen_magistrate', 'Ashen Magistrate', 3, 'dungeon',
     7200, 240, 130, 26,
     'Still holding court over a room with no floor left. It will read the '
     'charges whether or not anybody is listening.'),

    ('dungeon_tidebound_colossus', 'Tidebound Colossus', 4, 'dungeon',
     21000, 560, 300, 24,
     'Chained standing up, in a chamber that floods twice an hour. Neither '
     'the chains nor the water have finished the job.'),

    ('dungeon_severed_star', 'The Severed Star', 5, 'dungeon',
     62000, 1300, 690, 30,
     'A piece of sky that was cut down and has been trying to get back up '
     'ever since. It is closer than it was.'),

    ('dungeon_grave_of_wills', 'Grave of Wills', 6, 'dungeon',
     185000, 3050, 1580, 28,
     'Everyone who died reaching for the thing at the bottom is still here, '
     'and they have stopped being separate people.'),

    ('dungeon_lacquered_tyrant', 'The Lacquered Tyrant', 7, 'dungeon',
     540000, 7100, 3600, 34,
     'Sealed in resin at the height of its power, by people who were very '
     'careful and not careful enough.'),

    ('dungeon_hour_that_did_not_pass', 'The Hour That Did Not Pass', 8, 'dungeon',
     1580000, 16500, 8200, 40,
     'A moment that refused to end, and has spent the centuries since '
     'growing teeth.'),

    ('dungeon_first_gu', 'The First Gu', 9, 'dungeon',
     4600000, 38000, 18500, 44,
     'The oldest thing anybody has found a door to. It is not clear that it '
     'is trapped in there, or that the door was meant to keep it in.');


INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path_code, v.is_primary
FROM (VALUES
    ('dungeon_hollow_sentinel',      'metal',          TRUE),
    ('dungeon_hollow_sentinel',      'formation',      FALSE),
    ('dungeon_marrow_choir',         'bone',           TRUE),
    ('dungeon_marrow_choir',         'soul',           FALSE),
    ('dungeon_ashen_magistrate',     'rule',           TRUE),
    ('dungeon_ashen_magistrate',     'fire',           FALSE),
    ('dungeon_tidebound_colossus',   'water',          TRUE),
    ('dungeon_tidebound_colossus',   'strength',       FALSE),
    ('dungeon_severed_star',         'star',           TRUE),
    ('dungeon_severed_star',         'light',          FALSE),
    ('dungeon_grave_of_wills',       'soul',           TRUE),
    ('dungeon_grave_of_wills',       'enslavement',    FALSE),
    ('dungeon_lacquered_tyrant',     'refinement',     TRUE),
    ('dungeon_lacquered_tyrant',     'poison',         FALSE),
    ('dungeon_hour_that_did_not_pass','time',          TRUE),
    ('dungeon_hour_that_did_not_pass','space',         FALSE),
    ('dungeon_first_gu',             'heaven',         TRUE),
    ('dungeon_first_gu',             'transformation', FALSE)
) AS v(code, path_code, is_primary)
JOIN creature_species s ON s.code = v.code;


-- ---------------------------------------------------------------------------
-- The doors
-- ---------------------------------------------------------------------------

CREATE TABLE dungeons (
    dungeon_id  SMALLINT PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    realm_rank  SMALLINT NOT NULL UNIQUE
        CHECK (realm_rank BETWEEN 1 AND 9),
    species_id  BIGINT NOT NULL REFERENCES creature_species (species_id),
    stone_cost  BIGINT NOT NULL CHECK (stone_cost >= 0),
    jade_cost   BIGINT NOT NULL CHECK (jade_cost >= 0),
    description TEXT NOT NULL DEFAULT ''
);

CREATE INDEX dungeons_species_idx ON dungeons (species_id);

-- Stones climb with the realm; the jade is flat and small, because jade is
-- the scarce currency and a door should not be the thing that drains it.
INSERT INTO dungeons
    (dungeon_id, code, name, realm_rank, species_id, stone_cost, jade_cost,
     description)
SELECT v.id, v.code, v.name, v.rank, s.species_id, v.stones, v.jade, v.blurb
FROM (VALUES
    (1, 'sunken_armoury',   'The Sunken Armoury',    1, 'dungeon_hollow_sentinel',
        200::bigint, 1::bigint,
        'A storeroom that outlasted the war it was stocked for.'),
    (2, 'ossuary_stair',    'The Ossuary Stair',     2, 'dungeon_marrow_choir',
        600, 1,
        'Nine hundred steps down, and every one of them is somebody.'),
    (3, 'court_of_cinders', 'The Court of Cinders',  3, 'dungeon_ashen_magistrate',
        1800, 1,
        'Judgement is still being handed down here, to nobody in particular.'),
    (4, 'drowned_keep',     'The Drowned Keep',      4, 'dungeon_tidebound_colossus',
        5000, 2,
        'It floods twice an hour and something in it has learned to wait.'),
    (5, 'fallen_sky',       'Where the Sky Fell',    5, 'dungeon_severed_star',
        14000, 2,
        'A crater with a light still burning at the bottom of it.'),
    (6, 'grave_of_wills',   'The Grave of Wills',    6, 'dungeon_grave_of_wills',
        40000, 3,
        'Everyone who came for the thing at the bottom is still here.'),
    (7, 'resin_palace',     'The Resin Palace',      7, 'dungeon_lacquered_tyrant',
        110000, 4,
        'Sealed by careful people. Not quite careful enough.'),
    (8, 'stopped_hour',     'The Stopped Hour',      8, 'dungeon_hour_that_did_not_pass',
        300000, 5,
        'A moment that refused to end and grew teeth in the meantime.'),
    (9, 'first_burrow',     'The First Burrow',      9, 'dungeon_first_gu',
        800000, 8,
        'The oldest door anybody has found. It opens outward.')
) AS v(id, code, name, rank, species, stones, jade, blurb)
JOIN creature_species s ON s.code = v.species;


CREATE TABLE dungeon_difficulties (
    code       TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    hp_scale   NUMERIC(6,3) NOT NULL CHECK (hp_scale > 0),
    reward_scale NUMERIC(6,3) NOT NULL CHECK (reward_scale > 0),
    sort_order SMALLINT NOT NULL
);

-- Health and pay, and nothing else. The pay rises faster than the health, or
-- the harder rooms would be a worse hourly rate for a longer fight.
INSERT INTO dungeon_difficulties (code, name, hp_scale, reward_scale, sort_order)
VALUES
    ('normal', 'Normal', 1.000, 1.000, 10),
    ('hard',   'Hard',   1.800, 2.200, 20),
    ('hell',   'Hell',   3.400, 4.800, 30),
    ('insane', 'Insane', 6.500, 11.000, 40);


CREATE FUNCTION dungeon_boss_hp(
    p_dungeon_id SMALLINT, p_difficulty TEXT, p_raiders INTEGER
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, round(
        s.base_hp
        * (SELECT d.hp_scale FROM dungeon_difficulties d WHERE d.code = p_difficulty)
        * (1 + game_config_value('dungeon_party_hp_step')
               * GREATEST(0, p_raiders - 1))
    ))::bigint
    FROM dungeons dg
    JOIN creature_species s ON s.species_id = dg.species_id
    WHERE dg.dungeon_id = p_dungeon_id;
$$;

COMMENT ON FUNCTION dungeon_boss_hp(SMALLINT, TEXT, INTEGER) IS
    'The pool a party shares. Health scales with the party; the boss''s damage '
    'does not, so a fifth raider is help rather than a fifth of a health bar.';


DO $$
DECLARE
    thin TEXT;
BEGIN
    -- Every realm has a door, and every door has something behind it of its
    -- own rank. Stated over `realms` so a tenth realm would have to answer.
    SELECT string_agg(DISTINCT r.rank::text, ', ') INTO thin
    FROM realms r
    WHERE NOT EXISTS (SELECT 1 FROM dungeons d WHERE d.realm_rank = r.rank);

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these realms have no dungeon: %', thin;
    END IF;

    SELECT string_agg(d.name, ', ') INTO thin
    FROM dungeons d
    JOIN creature_species s ON s.species_id = d.species_id
    WHERE s.rank <> d.realm_rank OR s.kind <> 'dungeon';

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these doors hold the wrong thing: %', thin;
    END IF;

    -- Costs climb with the realm, so a deeper door is never the cheap one.
    SELECT string_agg(a.name, ', ') INTO thin
    FROM dungeons a JOIN dungeons b ON b.realm_rank = a.realm_rank + 1
    WHERE b.stone_cost <= a.stone_cost;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these doors cost no more than the one below: %', thin;
    END IF;

    -- A harder room must pay better per point of health, or nobody sane picks
    -- it. This is the whole justification for four difficulties.
    SELECT string_agg(d.name, ', ') INTO thin
    FROM dungeon_difficulties d
    JOIN dungeon_difficulties e ON e.sort_order = (
        SELECT min(x.sort_order) FROM dungeon_difficulties x
        WHERE x.sort_order > d.sort_order)
    WHERE e.reward_scale / e.hp_scale <= d.reward_scale / d.hp_scale;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'the step above these pays worse per hit point: %', thin;
    END IF;

    -- The key must be refused by the crafts, like the other currencies.
    IF NOT EXISTS (SELECT 1 FROM currency_materials WHERE material_code = 'dungeon_key')
    THEN
        RAISE EXCEPTION 'the key can be melted or brewed';
    END IF;

    -- And it must show up in /cooldowns without anybody writing code.
    IF NOT EXISTS (
        SELECT 1 FROM game_config WHERE key = 'dungeon_key_cooldown_minutes')
    THEN
        RAISE EXCEPTION 'the key has no clock';
    END IF;

    -- A party of five faces more than a solo run but not five times more.
    IF dungeon_boss_hp(4::smallint, 'normal', 5)
       <= dungeon_boss_hp(4::smallint, 'normal', 1)
    THEN
        RAISE EXCEPTION 'a party does not raise the pool';
    END IF;
    IF dungeon_boss_hp(4::smallint, 'normal', 5)
       >= dungeon_boss_hp(4::smallint, 'normal', 1) * 5
    THEN
        RAISE EXCEPTION 'a fifth raider brings nothing but their own health bar';
    END IF;
END;
$$;
