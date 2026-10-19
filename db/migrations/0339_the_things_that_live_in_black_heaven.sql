-- 0339_the_things_that_live_in_black_heaven
--
-- Fifteen primeval soul beasts in three tiers - the ordinary dark, the
-- Ancient, and the Immemorial - and the Shadow Demon King over all of them.
--
-- ALL OF THEM ARE RANK 9, which is not laziness. `compute_creature_damage`
-- divides an attack by `defense_scale x creature_defense_scale_per_rank ^
-- (rank - 1)`, which at rank 7 is 245,760 and at rank 9 is 3,932,160 - so the
-- SAME attack lands sixteen times harder from a rank 9 creature than a rank
-- 7 one against the same armour. Spreading these across ranks 7 to 9 would
-- have made the weakest tier hit hardest per point of attack and the tiering
-- would have run backwards. The tiers are in the numbers instead.
--
-- SIZED AGAINST WHAT AN IMMORTAL ACTUALLY IS. Measured rather than guessed:
-- the Sovereign Nine-Tail Fox, rank 9 with 1,180,000 attack, hits clearwest
-- for 717,211 - about one fortieth of a 31,528,235 body. So the tiers are
-- pitched at what they should cost an immortal in blows:
--
--     the dark        1.5M - 2.2M attack     twenty-odd blows to fell them
--     Ancient         3.0M - 4.5M            a dozen
--     Immemorial      6.0M - 9.0M            five or six
--
-- AND `base_hp` IS AN INTEGER, which is the ceiling that decided the top of
-- the range. 2,147,483,647 is as large as a creature can be in this schema,
-- so the Immemorial Abyssal Demon Beast stands at 2,100,000,000 and there is
-- deliberately nothing above it short of the King.
--
-- THEY OUTWEIGH THE WEAKEST WORLD BOSS, AND THAT IS ALLOWED HERE.
-- `test_a_world_beast_is_not_something_you_blunder_into` holds that nothing
-- huntable may outweigh the smallest thing in the 'world' and 'boss' kinds -
-- 9,431,148 - because, in 0315's words, 'nothing you can blunder into should
-- outweigh the thing the whole server turns up for'. Black Heaven cannot be
-- blundered into. It has a door on it that asks for rank 10, and the rule's
-- reason does not reach through that door. The test is amended alongside this
-- migration to exempt gated regions rather than weakened to let these in.
--
-- WHAT THEY DROP IS ALREADY IN THE GAME. `creature_drops` takes beast-
-- category materials and the forty things that grow here are gathering
-- materials, so these fall back on the legendary parts 0316 put in the deep
-- country - void fangs, soul embers, abyssal cores - which are what a
-- primeval soul beast would leave behind anyway.
--
-- Forward-only. Do not edit once applied.


INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    -- The dark, which is the gentle end of this place.
    ('nether_shadow_wolf', 'Nether Shadow Wolf', 9, 'beast',
     150000000, 1500000, 470000, 180,
     'It has no shadow of its own. It borrows the one you brought.'),
    ('ghost_lantern_beast', 'Ghost Lantern Beast', 9, 'beast',
     180000000, 1620000, 500000, 150,
     'The light it carries is the last thing several people saw.'),
    ('black_eclipse_serpent', 'Black Eclipse Serpent', 9, 'beast',
     210000000, 1780000, 560000, 165,
     'Long enough that the head and the tail hunt separately.'),
    ('night_terror_beast', 'Night Terror Beast', 9, 'beast',
     250000000, 1950000, 610000, 140,
     'It is waiting when you sleep, and it was waiting before that.'),
    ('abyssal_bone_beast', 'Abyssal Bone Beast', 9, 'beast',
     300000000, 2200000, 690000, 120,
     'Bone all the way through, and none of the bones are its own.'),

    -- Ancient.
    ('ancient_ghost_emperor_beast', 'Ancient Ghost Emperor Beast', 9, 'beast',
     550000000, 3000000, 940000, 130,
     'It ruled something, once. It has not been told that it stopped.'),
    ('ancient_nether_dragon', 'Ancient Nether Dragon', 9, 'beast',
     650000000, 3300000, 1030000, 175,
     'Coils through the dark the way a dragon elsewhere coils through cloud.'),
    ('ancient_eclipse_wolf', 'Ancient Eclipse Wolf', 9, 'beast',
     780000000, 3700000, 1160000, 200,
     'Hunts in a pack of one, and the pack is still a pack.'),
    ('ancient_night_terror_beast', 'Ancient Night Terror Beast', 9, 'beast',
     900000000, 4100000, 1280000, 145,
     'The younger sort is a nightmare. This is the thing nightmares are of.'),
    ('ancient_abyssal_serpent', 'Ancient Abyssal Serpent', 9, 'beast',
     1050000000, 4500000, 1400000, 160,
     'It came up from somewhere below Black Heaven, which should not exist.'),

    -- Immemorial.
    ('immemorial_nether_shadow_beast', 'Immemorial Nether Shadow Beast', 9, 'beast',
     1400000000, 6000000, 1880000, 190,
     'Older than the dark it lives in, and less forgiving.'),
    ('immemorial_black_heaven_dragon', 'Immemorial Black Heaven Dragon', 9, 'beast',
     1600000000, 6800000, 2130000, 185,
     'The heaven is named after it, and not the other way about.'),
    ('immemorial_ghost_emperor_beast', 'Immemorial Ghost Emperor Beast', 9, 'beast',
     1800000000, 7500000, 2350000, 135,
     'Every ghost in Black Heaven answers to it, including the unwilling.'),
    ('immemorial_eternal_night_beast', 'Immemorial Eternal Night Beast', 9, 'beast',
     1950000000, 8200000, 2570000, 155,
     'Where it walks the dark is a little darker, and stays that way.'),
    ('immemorial_abyssal_demon_beast', 'Immemorial Abyssal Demon Beast', 9, 'beast',
     2100000000, 9000000, 2820000, 170,
     'The largest thing this world can hold. Something made sure of that.'),

    -- And the thing the region is organised around.
    ('shadow_demon_king', 'Shadow Demon King', 9, 'boss',
     2100000000, 12000000, 3800000, 210,
     'Spectral Soul left a great deal behind. This is the part that moves.');


INSERT INTO creature_regions (species_id, region_code, weight)
SELECT cs.species_id, 'black_heaven',
       CASE
           WHEN cs.code LIKE 'immemorial_%' THEN 0.6
           WHEN cs.code LIKE 'ancient_%'    THEN 2.5
           WHEN cs.kind = 'boss'            THEN 1.0
           ELSE 8.0
       END
FROM creature_species cs
WHERE cs.code IN (
    'nether_shadow_wolf','ghost_lantern_beast','black_eclipse_serpent',
    'night_terror_beast','abyssal_bone_beast','ancient_ghost_emperor_beast',
    'ancient_nether_dragon','ancient_eclipse_wolf','ancient_night_terror_beast',
    'ancient_abyssal_serpent','immemorial_nether_shadow_beast',
    'immemorial_black_heaven_dragon','immemorial_ghost_emperor_beast',
    'immemorial_eternal_night_beast','immemorial_abyssal_demon_beast',
    'shadow_demon_king');


-- What they leave behind: the deep-country legendaries from 0316, which are
-- beast-category and so allowed here, and which read like the remains of a
-- primeval soul beast without anything new having to be invented.
INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, d.material_code, d.chance, d.lo, d.hi
FROM creature_species cs
JOIN (VALUES
    ('nether_shadow_wolf',             'void_fang',           0.45, 1, 2),
    ('ghost_lantern_beast',            'immortal_soul_ember', 0.35, 1, 2),
    ('black_eclipse_serpent',          'void_fang',           0.40, 1, 3),
    ('night_terror_beast',             'abyssal_core',        0.40, 1, 2),
    ('abyssal_bone_beast',             'abyssal_core',        0.45, 2, 4),
    ('ancient_ghost_emperor_beast',    'immortal_soul_ember', 0.50, 2, 4),
    ('ancient_nether_dragon',          'dragon_whale_heart',  0.40, 1, 3),
    ('ancient_eclipse_wolf',           'void_fang',           0.55, 3, 5),
    ('ancient_night_terror_beast',     'primordial_blood',    0.40, 1, 3),
    ('ancient_abyssal_serpent',        'abyssal_core',        0.55, 3, 6),
    ('immemorial_nether_shadow_beast', 'sovereign_fang',      0.45, 2, 4),
    ('immemorial_black_heaven_dragon', 'dragon_whale_heart',  0.55, 3, 6),
    ('immemorial_ghost_emperor_beast', 'immortal_soul_ember', 0.60, 4, 7),
    ('immemorial_eternal_night_beast', 'primordial_blood',    0.55, 3, 6),
    ('immemorial_abyssal_demon_beast', 'sovereign_fang',      0.65, 5, 9),
    ('shadow_demon_king',              'sovereign_fang',      0.90, 8, 14)
) AS d (code, material_code, chance, lo, hi) ON d.code = cs.code;


-- ---------------------------------------------------------------------------
-- Fifteen and a King, all of them worth an immortal's attention
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n       INTEGER;
    bad     TEXT;
    softest BIGINT;
    hardest BIGINT;
BEGIN
    SELECT count(*) INTO n
    FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'black_heaven';
    IF n <> 16 THEN
        RAISE EXCEPTION 'expected fifteen beasts and a King, found %', n;
    END IF;

    -- The tiers climb, and the King stands over all of them.
    SELECT min(base_hp) INTO softest FROM creature_species
    WHERE code LIKE 'immemorial_%';
    SELECT max(base_hp) INTO hardest FROM creature_species
    WHERE code LIKE 'ancient_%';
    IF softest <= hardest THEN
        RAISE EXCEPTION
            'the weakest Immemorial (%) is no heavier than the strongest Ancient (%)',
            softest, hardest;
    END IF;

    -- Nothing here outgrew the integer that holds it.
    SELECT string_agg(name, ', ') INTO bad
    FROM creature_species WHERE base_hp >= 2147483647;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are at the integer ceiling: %', bad;
    END IF;

    -- And every one of them leaves something behind.
    SELECT string_agg(cs.name, ', ') INTO bad
    FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'black_heaven'
      AND NOT EXISTS (SELECT 1 FROM creature_drops d WHERE d.species_id = cs.species_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these drop nothing: %', bad;
    END IF;

    RAISE NOTICE 'fifteen beasts and the Shadow Demon King stand in Black Heaven';
END;
$probe$;
