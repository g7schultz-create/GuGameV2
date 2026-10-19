-- 0349_what_the_heavenly_court_keeps
--
-- Fifteen beasts, the Heavenly Court General, and the same hundred and
-- sixty-six Gu that fall in Black Heaven.
--
-- THE GU LIST IS IDENTICAL, so not one new row goes into `gu_types`. The
-- hundred and fifty-one that 0341 derived are already there and the fifteen
-- that predate them are already there; this is a hundred and sixty-six rows
-- in `gu_region_drops` and nothing else. Minting a second Celestial Wall Gu
-- so that White Heaven could have 'its own' would give the refinery two
-- things a player cannot tell apart.
--
-- THE BEASTS ARE PITCHED WHERE BLACK HEAVEN'S ARE, to the number, because
-- both heavens are danger 6 and both are behind the same rank 10 door. 0347
-- set that curve against a measured Dewberry Immortal - 49,866,080 body,
-- 5,609,882 armour, 163,324,671 a turn - and the shape is:
--
--     the radiant    3.5 - 6 turns to fell,   4-5% of the body a bite
--     Ancient        8 - 12 turns,            6-7%
--     Immemorial     14 - 18 turns,           8-10%
--     the General    20 turns,                12%
--
-- A second heaven at the same danger rating that was quietly softer would
-- make one of them the place you farm and the other the place you visit.
--
-- THE GENERAL'S GU IS THE ONE THAT WAS ASKED FOR, and it is worth saying out
-- loud that it is a modest one: Heaven's Will Gu is rank 2, uncommon,
-- cultivation - four ranks under the Soul Demon King Gu the other heaven's
-- boss hands over, and well under what a cultivator felling a 3.3 billion
-- health General would expect. The name is enormous in the source material
-- and the catalogue entry is small. It is wired as specified rather than
-- quietly swapped for something grander, because which Gu a boss drops is
-- not mine to change.
--
-- Forward-only. Do not edit once applied.


INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    -- The radiant, which is the gentle end of a place with no gentle end.
    ('cloud_heaven_crane', 'Cloud Heaven Crane', 9, 'beast',
     570000000, 4900000, 1520000, 200,
     'It stands in the qi rivers the way a heron stands in a stream.'),
    ('radiant_white_lion', 'Radiant White Lion', 9, 'beast',
     660000000, 5200000, 1610000, 175,
     'Too bright to look at directly, which is most of the problem.'),
    ('heavenly_light_whale', 'Heavenly Light Whale', 9, 'beast',
     750000000, 5500000, 1710000, 130,
     'Swims the cloud sea. The sea is not water and it does not care.'),
    ('white_cloud_serpent', 'White Cloud Serpent', 9, 'beast',
     860000000, 5800000, 1800000, 185,
     'Indistinguishable from the weather until the moment it is not.'),
    ('aurora_deer', 'Aurora Deer', 9, 'beast',
     980000000, 6100000, 1890000, 210,
     'The lights above it are not above it. They are its.'),

    -- Ancient.
    ('ancient_cloud_phoenix', 'Ancient Cloud Phoenix', 9, 'beast',
     1300000000, 7300000, 2260000, 195,
     'It has burned down and come back more times than the Court has records.'),
    ('ancient_nine_colored_lion', 'Ancient Nine-Coloured Lion', 9, 'beast',
     1450000000, 7700000, 2390000, 170,
     'Nine colours, and each one of them is doing something different to you.'),
    ('ancient_heavenly_light_whale', 'Ancient Heavenly Light Whale', 9, 'beast',
     1600000000, 8100000, 2510000, 140,
     'Old enough that the cloud sea has worn channels around it.'),
    ('ancient_aurora_serpent', 'Ancient Aurora Serpent', 9, 'beast',
     1800000000, 8500000, 2640000, 180,
     'The lights it trails have been mistaken for a Heavenly Court decree.'),
    ('ancient_white_heaven_crane', 'Ancient White Heaven Crane', 9, 'beast',
     2000000000, 8900000, 2760000, 205,
     'It was here before the Court was, and it is not deferential.'),

    -- Immemorial.
    ('immemorial_white_heaven_phoenix', 'Immemorial White Heaven Phoenix', 9, 'beast',
     2300000000, 9700000, 3010000, 190,
     'The white heaven takes its colour from this thing and not the other way.'),
    ('immemorial_radiance_beast', 'Immemorial Radiance Beast', 9, 'beast',
     2450000000, 10300000, 3190000, 165,
     'There is no shape to it. There is only how much of the sky it is using.'),
    ('immemorial_cloud_sea_whale', 'Immemorial Cloud Sea Whale', 9, 'beast',
     2600000000, 11000000, 3410000, 145,
     'The cloud sea has tides because of this and for no other reason.'),
    ('immemorial_heavenly_lion', 'Immemorial Heavenly Lion', 9, 'beast',
     2750000000, 11600000, 3600000, 175,
     'The Heavenly Court keeps a lion on its banners. This is why.'),
    ('immemorial_aurora_beast', 'Immemorial Aurora Beast', 9, 'beast',
     2900000000, 12200000, 3780000, 200,
     'Every aurora anybody has ever seen was this, further off.'),

    -- And what the Court sends when it is done being patient.
    ('heavenly_court_general', 'Heavenly Court General', 9, 'boss',
     3300000000, 14600000, 4530000, 215,
     'Not a beast. A rank and a mandate, wearing whatever it needs to.');


INSERT INTO creature_regions (species_id, region_code, weight)
SELECT cs.species_id, 'white_heaven',
       CASE
           WHEN cs.code LIKE 'immemorial_%' THEN 0.6
           WHEN cs.code LIKE 'ancient_%'    THEN 2.5
           WHEN cs.kind = 'boss'            THEN 1.0
           ELSE 8.0
       END
FROM creature_species cs
WHERE cs.code IN (
    'cloud_heaven_crane','radiant_white_lion','heavenly_light_whale',
    'white_cloud_serpent','aurora_deer','ancient_cloud_phoenix',
    'ancient_nine_colored_lion','ancient_heavenly_light_whale',
    'ancient_aurora_serpent','ancient_white_heaven_crane',
    'immemorial_white_heaven_phoenix','immemorial_radiance_beast',
    'immemorial_cloud_sea_whale','immemorial_heavenly_lion',
    'immemorial_aurora_beast','heavenly_court_general');


INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, d.material_code, d.chance, d.lo, d.hi
FROM creature_species cs
JOIN (VALUES
    ('cloud_heaven_crane',              'phoenix_down',        0.45, 1, 2),
    ('radiant_white_lion',              'titan_hide',          0.40, 1, 2),
    ('heavenly_light_whale',            'dragon_whale_heart',  0.35, 1, 2),
    ('white_cloud_serpent',             'phoenix_down',        0.40, 1, 3),
    ('aurora_deer',                     'abyssal_core',        0.40, 2, 3),
    ('ancient_cloud_phoenix',           'phoenix_down',        0.55, 3, 5),
    ('ancient_nine_colored_lion',       'titan_hide',          0.50, 2, 4),
    ('ancient_heavenly_light_whale',    'dragon_whale_heart',  0.50, 2, 4),
    ('ancient_aurora_serpent',          'primordial_blood',    0.40, 1, 3),
    ('ancient_white_heaven_crane',      'immortal_soul_ember', 0.45, 2, 4),
    ('immemorial_white_heaven_phoenix', 'phoenix_down',        0.65, 5, 9),
    ('immemorial_radiance_beast',       'sovereign_fang',      0.45, 2, 4),
    ('immemorial_cloud_sea_whale',      'dragon_whale_heart',  0.60, 4, 7),
    ('immemorial_heavenly_lion',        'titan_hide',          0.60, 4, 7),
    ('immemorial_aurora_beast',         'primordial_blood',    0.55, 3, 6),
    ('heavenly_court_general',          'sovereign_fang',      0.90, 8, 14)
) AS d (code, material_code, chance, lo, hi) ON d.code = cs.code;


-- Something a hunt can never roll, which is what `boss_drops` is for.
INSERT INTO boss_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, v.code, v.chance, v.lo, v.hi
FROM creature_species cs
JOIN (VALUES
    ('nine_heavenly_star_sweat',  0.80, 2, 5),
    ('earthly_limit_astral_qi',   0.60, 1, 3)
) AS v (code, chance, lo, hi) ON TRUE
WHERE cs.code = 'heavenly_court_general';


UPDATE creature_species
SET signature_gu_type_id = (SELECT gu_type_id FROM gu_types WHERE code = 'heaven_s_will_gu')
WHERE code = 'heavenly_court_general';


-- ---------------------------------------------------------------------------
-- The same hundred and sixty-six, in the other heaven
-- ---------------------------------------------------------------------------

INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
SELECT 'white_heaven', d.gu_type_id, d.weight
FROM gu_region_drops d WHERE d.region_code = 'black_heaven';


-- ---------------------------------------------------------------------------
-- As hard as the other heaven, and worth the same walk
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n    INTEGER;
    bad  TEXT;
    crest BIGINT;
BEGIN
    SELECT count(*) INTO n
    FROM creature_regions cr WHERE cr.region_code = 'white_heaven';
    IF n <> 16 THEN
        RAISE EXCEPTION 'expected fifteen beasts and a General, found %', n;
    END IF;

    SELECT count(*) INTO n
    FROM gu_region_drops WHERE region_code = 'white_heaven';
    IF n <> 166 THEN
        RAISE EXCEPTION 'expected 166 Gu in White Heaven, linked %', n;
    END IF;

    -- Neither heaven is the soft one. Matched rung for rung against the
    -- curve 0347 measured, so the choice between them is about what drops
    -- rather than about which is easier.
    SELECT string_agg(a.name || ' vs ' || b.name, ', ') INTO bad
    FROM (
        SELECT cs.name, cs.base_hp,
               row_number() OVER (ORDER BY cs.base_hp) AS n
        FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cr.region_code = 'white_heaven'
    ) a
    JOIN (
        SELECT cs.name, cs.base_hp,
               row_number() OVER (ORDER BY cs.base_hp) AS n
        FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cr.region_code = 'black_heaven'
    ) b ON b.n = a.n
    WHERE a.base_hp <> b.base_hp;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'the heavens are not matched: %', bad;
    END IF;

    -- Every one of them leaves something behind.
    SELECT string_agg(cs.name, ', ') INTO bad
    FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'white_heaven'
      AND NOT EXISTS (SELECT 1 FROM creature_drops d WHERE d.species_id = cs.species_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these drop nothing: %', bad;
    END IF;

    SELECT signature_gu_type_id INTO crest
    FROM creature_species WHERE code = 'heavenly_court_general';
    IF crest IS NULL THEN
        RAISE EXCEPTION 'the General is known for nothing';
    END IF;

    RAISE NOTICE
        'White Heaven matches Black Heaven rung for rung; the General carries %',
        (SELECT name FROM gu_types WHERE gu_type_id = crest);
END;
$probe$;
