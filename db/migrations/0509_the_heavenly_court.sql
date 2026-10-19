-- 0509_the_heavenly_court
--
-- Phase 5 of the Venerable spec: "A min_rank 19 region with veins, growth
-- and creatures that carry real tables. Delve and travel pick it up for
-- free." 0504 made room for it and 0506/0508 gave the trades a ninth band
-- to work; this is the place itself.
--
-- THE HEAVENLY COURT is the body that rules the immortal world, so its
-- growth is bureaucratic rather than elemental - decrees, rosters, seals,
-- summonses - and every material is keyed to a Path, the way every tier 12
-- material is, so the apex band feeds the Paths a Venerable actually walks
-- instead of being generic. Twelve growths at tier 13, five ores at tier 9.
--
-- min_rank 19, danger 7. The spec says "Danger 7 unless there is a reason
-- not to", and there is not: both heavens are danger 6 and this is a rank
-- above them.
--
-- NOBODY CAN GO THERE YET, and that is correct rather than unfinished. The
-- gate reads `player_standing`, which is realm rank or Venerable rank,
-- whichever is higher - so the Court opens by itself the day the tribulation
-- ships and somebody passes it. Until then it is content waiting, and every
-- standing test that asks whether a region is complete can see it.
--
-- WHAT THE CREATURE NUMBERS ARE NOW. They are a SHAPE, not an absolute:
-- 0502 and 0503 size a body against the party that meets it and 0505 and
-- 0507 floor the bite at a share of the body. So these continue the rank 18
-- template - hp 5.12e11, atk 6.98e8, def 3.31e8 - at one rank above, and
-- what matters is that they sit over rank 18 and in proportion to each
-- other rather than that any one number is right.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The place
-- ---------------------------------------------------------------------------

INSERT INTO regions (code, name, danger_level, description, emoji, sort_order, min_rank)
VALUES ('heavenly_court', 'The Heavenly Court', 7,
        'Where the immortal world is governed. Nine halls of decree above the two heavens, and the only ground a Venerable has not already walked.',
        '🏛', 80, 19);


-- ---------------------------------------------------------------------------
-- What grows there
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, description, path_code, emoji, tier) VALUES
    ('court_decree_jade', 'Court Decree Jade', 'gathering', 'extreme', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'rule', '📜', 13),
    ('longevity_heaven_dew', 'Longevity Heaven Dew', 'gathering', 'extreme', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'time', '💧', 13),
    ('immortal_roster_ink', 'Immortal Roster Ink', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'painting', '🖋', 13),
    ('nine_tribulation_ash', 'Nine Tribulation Ash', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'fire', '🌫', 13),
    ('dao_tribunal_incense', 'Dao Tribunal Incense', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'wisdom', '🕯', 13),
    ('venerable_relic_shard', 'Venerable''s Relic Shard', 'gathering', 'extreme', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'heaven', '🗿', 13),
    ('heavenly_seal_wax', 'Heavenly Seal Wax', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'formation', '🔴', 13),
    ('unwritten_fate_silk', 'Unwritten Fate Silk', 'gathering', 'extreme', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'luck', '🧵', 13),
    ('first_sovereign_breath', 'First Sovereign''s Breath', 'gathering', 'extreme', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'qi', '🌬', 13),
    ('aeon_court_lotus', 'Aeon Court Lotus', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'wood', '🪷', 13),
    ('edict_bearing_feather', 'Edict-Bearing Feather', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'wind', '🪶', 13),
    ('white_jade_summons', 'White Jade Summons', 'gathering', 'divine', 'Taken from the halls of the Heavenly Court. The thirteenth band, and the only one above the heavens.', 'light', '🏷', 13);

INSERT INTO region_materials (region_code, material_code, weight) VALUES
    ('heavenly_court', 'court_decree_jade', 0.40),
    ('heavenly_court', 'longevity_heaven_dew', 0.40),
    ('heavenly_court', 'immortal_roster_ink', 0.90),
    ('heavenly_court', 'nine_tribulation_ash', 0.90),
    ('heavenly_court', 'dao_tribunal_incense', 0.90),
    ('heavenly_court', 'venerable_relic_shard', 0.40),
    ('heavenly_court', 'heavenly_seal_wax', 0.90),
    ('heavenly_court', 'unwritten_fate_silk', 0.40),
    ('heavenly_court', 'first_sovereign_breath', 0.40),
    ('heavenly_court', 'aeon_court_lotus', 0.90),
    ('heavenly_court', 'edict_bearing_feather', 0.90),
    ('heavenly_court', 'white_jade_summons', 0.90);


-- ---------------------------------------------------------------------------
-- What is under it
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, description, path_code, emoji, tier) VALUES
    ('court_foundation_stone', 'Court Foundation Stone', 'gathering', 'extreme', 'Cut from under the Heavenly Court. The ninth ore band, which exists in no other ground.', NULL, '🪨', NULL),
    ('edict_iron', 'Edict Iron', 'gathering', 'extreme', 'Cut from under the Heavenly Court. The ninth ore band, which exists in no other ground.', NULL, '⚙', NULL),
    ('sovereign_vein_gold', 'Sovereign Vein Gold', 'gathering', 'extreme', 'Cut from under the Heavenly Court. The ninth ore band, which exists in no other ground.', NULL, '🟡', NULL),
    ('tribunal_crystal', 'Tribunal Crystal', 'gathering', 'extreme', 'Cut from under the Heavenly Court. The ninth ore band, which exists in no other ground.', NULL, '🔷', NULL),
    ('unmoving_pillar_jade', 'Unmoving Pillar Jade', 'gathering', 'extreme', 'Cut from under the Heavenly Court. The ninth ore band, which exists in no other ground.', NULL, '🟢', NULL);

-- `signature` is the stat the metal lends a forged piece, and `word` the
-- name it puts on one. Every tier 8 ore carries both; these continue that.
INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('court_foundation_stone', 9, 'base_defense', 'Court-Founded'),
    ('edict_iron', 9, 'base_strength', 'Edict-Forged'),
    ('sovereign_vein_gold', 9, 'cultivation_rate', 'Sovereign-Veined'),
    ('tribunal_crystal', 9, 'crit_damage', 'Tribunal-Cut'),
    ('unmoving_pillar_jade', 9, 'base_hp', 'Pillar-Set');

INSERT INTO region_veins (region_code, material_code, weight) VALUES
    ('heavenly_court', 'court_foundation_stone', 3.00),
    ('heavenly_court', 'edict_iron', 2.40),
    ('heavenly_court', 'sovereign_vein_gold', 1.60),
    ('heavenly_court', 'tribunal_crystal', 0.80),
    ('heavenly_court', 'unmoving_pillar_jade', 0.50);


-- ---------------------------------------------------------------------------
-- What lives there
-- ---------------------------------------------------------------------------

INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense, base_speed, description, traits)
VALUES
    ('court_executor', 'Heavenly Court Executor', 9, 19, 'rogue', 1024000000000, 1186000000, 562000000, 72,
     'An officer of the Heavenly Court, and a peer of anybody who has business there.', '{}'),
    ('roster_keeper', 'Keeper of the Immortal Roster', 9, 19, 'rogue', 942080000000, 1091120000, 517040000, 72,
     'An officer of the Heavenly Court, and a peer of anybody who has business there.', '{}'),
    ('tribunal_arbiter', 'Dao Tribunal Arbiter', 9, 19, 'rogue', 983040000000, 1138560000, 539520000, 72,
     'An officer of the Heavenly Court, and a peer of anybody who has business there.', '{}'),
    ('edict_hound', 'Edict Hound', 9, 19, 'beast', 307200000000, 355800000, 168600000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('censer_moth', 'Censer Moth', 9, 19, 'beast', 225280000000, 260920000, 123640000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('summons_crane', 'White Jade Summons Crane', 9, 19, 'beast', 348160000000, 403240000, 191080000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('seal_tortoise', 'Seal-Bearing Tortoise', 9, 19, 'beast', 430080000000, 498120000, 236040000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('ledger_serpent', 'Ledger Serpent', 9, 19, 'beast', 286720000000, 332080000, 157360000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('gate_lion', 'Court Gate Lion', 9, 19, 'beast', 471040000000, 545560000, 258520000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('incense_ape', 'Incense Hall Ape', 9, 19, 'beast', 266240000000, 308360000, 146120000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('fate_silk_spider', 'Fate Silk Spider', 9, 19, 'beast', 245760000000, 284640000, 134880000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('pillar_wyrm', 'Pillar Wyrm', 9, 19, 'beast', 512000000000, 593000000, 281000000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('aeon_lotus_spirit', 'Aeon Lotus Spirit', 9, 19, 'beast', 204800000000, 237200000, 112400000, 68,
     'Kept, or tolerated, in the halls of the Heavenly Court.', '{}'),
    ('longevity_heaven_warden', 'Warden of Longevity Heaven', 9, 19, 'boss', 2252800000000, 2609200000, 1236400000, 78,
     'The hall that answers to nobody below it.', '{}');

-- Every creature stands on one primary Path, which is what
-- `compute_creature_damage` reads to work out what resists it.
INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT cs.species_id, v.path, TRUE
FROM (VALUES
    ('court_executor', 'rule'),
    ('roster_keeper', 'painting'),
    ('tribunal_arbiter', 'wisdom'),
    ('edict_hound', 'rule'),
    ('censer_moth', 'fire'),
    ('summons_crane', 'light'),
    ('seal_tortoise', 'formation'),
    ('ledger_serpent', 'time'),
    ('gate_lion', 'metal'),
    ('incense_ape', 'wisdom'),
    ('fate_silk_spider', 'luck'),
    ('pillar_wyrm', 'earth'),
    ('aeon_lotus_spirit', 'wood'),
    ('longevity_heaven_warden', 'heaven')
) AS v(code, path)
JOIN creature_species cs ON cs.code = v.code;

INSERT INTO creature_regions (species_id, region_code, weight)
SELECT cs.species_id, 'heavenly_court',
       CASE cs.kind WHEN 'beast' THEN 4.00 WHEN 'rogue' THEN 1.20 ELSE 0.40 END
FROM creature_species cs WHERE cs.immortal_rank = 19;

-- And what comes off them. `creature_drops` takes BEAST materials only -
-- a trigger says so, because 0359 found `explore` reading drop rows at
-- random and handing out immortal essence as scavenge. So the Court gets
-- its own beast parts rather than dropping its growth, which is gathered.
INSERT INTO materials (code, name, category, rarity, description, path_code, emoji, tier) VALUES
    ('edict_sinew', 'Edict Sinew', 'beast', 'extreme', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', 'rule', '🪢', NULL),
    ('warden_scale', 'Warden Scale', 'beast', 'extreme', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', 'heaven', '🛡', NULL),
    ('censer_ash_gland', 'Censer Ash Gland', 'beast', 'divine', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', 'fire', '🟤', NULL),
    ('summons_plume', 'Summons Plume', 'beast', 'divine', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', 'light', '🪶', NULL),
    ('ledger_fang', 'Ledger Fang', 'beast', 'divine', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', 'time', '🦷', NULL),
    ('court_marrow', 'Court Marrow', 'beast', 'extreme', 'Taken off something that served the Heavenly Court. Nothing below the Court carries it.', NULL, '🦴', NULL);

INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, m.code,
       CASE cs.kind WHEN 'boss' THEN 0.60 WHEN 'rogue' THEN 0.35 ELSE 0.20 END,
       1,
       CASE cs.kind WHEN 'boss' THEN 4 WHEN 'rogue' THEN 2 ELSE 1 END
FROM creature_species cs
CROSS JOIN LATERAL (
    SELECT mm.code FROM materials mm
    JOIN creature_paths cp ON cp.species_id = cs.species_id AND cp.is_primary
    WHERE mm.category = 'beast' AND mm.code IN ('edict_sinew', 'warden_scale', 'censer_ash_gland', 'summons_plume', 'ledger_fang', 'court_marrow')
      AND (mm.path_code = cp.path_code OR mm.path_code IS NULL)
) m
WHERE cs.immortal_rank = 19;

-- Anything whose Path no Court part matches still drops one, because a
-- creature that drops nothing is a creature not worth the turn.
INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, 'edict_sinew', 0.25, 1, 2
FROM creature_species cs
WHERE cs.immortal_rank = 19
  AND NOT EXISTS (SELECT 1 FROM creature_drops cd WHERE cd.species_id = cs.species_id)
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- And the worms that fall there
-- ---------------------------------------------------------------------------

-- The same list the heavens hand out, for the reason 0349 gave when White
-- Heaven got it: minting a third copy of a Gu so the Court could have 'its
-- own' would give the refinery things a player cannot tell apart. The Court
-- is a harder place to stand, not a different catalogue.
INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
SELECT 'heavenly_court', d.gu_type_id, d.weight
FROM gu_region_drops d WHERE d.region_code = 'black_heaven'
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- A region as complete as the two below it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n     INTEGER;
    v_bh    INTEGER;
    v_bad   TEXT;
BEGIN
    -- Complete on every axis a region is keyed by, measured against Black
    -- Heaven rather than against a number I chose.
    SELECT count(*) INTO v_n FROM region_materials WHERE region_code = 'heavenly_court';
    IF v_n < 12 THEN RAISE EXCEPTION 'the Court grows only % things', v_n; END IF;

    SELECT count(*) INTO v_n FROM region_veins WHERE region_code = 'heavenly_court';
    IF v_n < 5 THEN RAISE EXCEPTION 'the Court has only % veins', v_n; END IF;

    SELECT count(*) INTO v_n FROM creature_regions WHERE region_code = 'heavenly_court';
    IF v_n < 14 THEN RAISE EXCEPTION 'only % creatures live in the Court', v_n; END IF;

    SELECT count(*) INTO v_n FROM gu_region_drops WHERE region_code = 'heavenly_court';
    SELECT count(*) INTO v_bh FROM gu_region_drops WHERE region_code = 'black_heaven';
    IF v_n <> v_bh THEN
        RAISE EXCEPTION 'the Court drops % worms against Black Heaven''s %', v_n, v_bh;
    END IF;

    -- Nothing is painted on the wall: every material the Court grows or
    -- holds is reachable by the thing that is supposed to reach it.
    SELECT string_agg(m.code, ', ') INTO v_bad
    FROM materials m
    WHERE m.tier = 13
      AND NOT EXISTS (SELECT 1 FROM region_materials rm WHERE rm.material_code = m.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'tier 13 growth nobody can gather: %', v_bad;
    END IF;

    SELECT string_agg(o.material_code, ', ') INTO v_bad
    FROM ores o
    WHERE o.tier = 9
      AND NOT EXISTS (SELECT 1 FROM region_veins rv WHERE rv.material_code = o.material_code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'band 9 ore in no vein: %', v_bad;
    END IF;

    -- A miner who can reach band 9 finds it only here, which is what makes
    -- the band worth the rung 0506 added.
    SELECT count(DISTINCT rv.region_code) INTO v_n
    FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
    WHERE o.tier = 9;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'band 9 ore is in % regions, wanted only the Court', v_n;
    END IF;

    -- Every creature has a primary Path, which the damage pipeline reads.
    SELECT string_agg(cs.code, ', ') INTO v_bad
    FROM creature_species cs
    WHERE cs.immortal_rank = 19
      AND NOT EXISTS (SELECT 1 FROM creature_paths cp
                      WHERE cp.species_id = cs.species_id AND cp.is_primary);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Court creatures with no primary Path: %', v_bad;
    END IF;

    -- And they drop something, or killing them is a waste of a turn.
    SELECT string_agg(cs.code, ', ') INTO v_bad
    FROM creature_species cs
    WHERE cs.immortal_rank = 19
      AND NOT EXISTS (SELECT 1 FROM creature_drops cd WHERE cd.species_id = cs.species_id);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Court creatures that drop nothing: %', v_bad;
    END IF;

    -- The Court stands above the heavens, compared LIKE WITH LIKE. The
    -- first version of this asked whether the weakest rank 19 beast beat
    -- the biggest rank 18 anything, which is a dungeon boss at 1.13e12 -
    -- a comparison between a hall ape and The Last Apricot.
    SELECT string_agg(x.kind || ': 19 tops out at ' || x.ours
                      || ' against 18''s ' || x.theirs, ', ')
    INTO v_bad
    FROM (
        SELECT a.kind, max(a.base_hp) AS ours,
               (SELECT max(b.base_hp) FROM creature_species b
                WHERE b.immortal_rank = 18 AND b.kind = a.kind) AS theirs
        FROM creature_species a
        WHERE a.immortal_rank = 19 GROUP BY a.kind
    ) x
    WHERE x.theirs IS NOT NULL AND x.ours <= x.theirs;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the Court does not stand above the heavens - %', v_bad;
    END IF;

    -- SHUT, and shut to everybody, until somebody ascends. A region nobody
    -- can reach is correct here; a region nobody can EVER reach is not, so
    -- the gate is checked against standing rather than assumed.
    SELECT count(*) INTO v_n FROM players p
    WHERE p.deleted_at IS NULL AND player_standing(p.player_id) >= 19;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators can already walk into the Court', v_n;
    END IF;

    IF (SELECT min_rank FROM regions WHERE code = 'heavenly_court')
       > (SELECT max(rank) FROM venerable_ranks) THEN
        RAISE EXCEPTION 'the Court is gated above the top of the ladder';
    END IF;

    RAISE NOTICE
        'the Heavenly Court: % growths, % veins, % creatures, % worms, shut until rank 19',
        (SELECT count(*) FROM region_materials WHERE region_code = 'heavenly_court'),
        (SELECT count(*) FROM region_veins WHERE region_code = 'heavenly_court'),
        (SELECT count(*) FROM creature_regions WHERE region_code = 'heavenly_court'),
        (SELECT count(*) FROM gu_region_drops WHERE region_code = 'heavenly_court');
END;
$probe$;
