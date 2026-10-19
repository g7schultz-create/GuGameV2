-- 0411_half_the_forge_stops_existing_at_rank_ten
--
-- Six of the twelve parts a forge can put in a piece cannot be got at all once
-- a cultivator crosses into the immortal realms:
--
--     bone    attack_power 0.50, damage_reduction 0.50
--     heart   lifesteal 0.40,    max_hp 0.60
--     horn    armor_pen 0.70,    attack_power 0.30
--     scale   damage_reduction 0.70, max_hp 0.30
--     shell   damage_reduction 1.00        <- the only pure reduction part
--     venom   armor_pen 0.50,    lifesteal 0.50
--
-- Black Heaven and White Heaven between them drop fang, soul, blood, core,
-- feather and hide, and nothing else. Every route out of those regions reads
-- the same table - `/explore`, hunting, and `horde_spill_parts`, which fills a
-- horde chest from `creature_regions` joined to `creature_drops` - so at rank
-- 10 half the forge's vocabulary goes quiet at once, in every one of them.
-- A cultivator who wants damage reduction on a piece of armour has hide and
-- core, and shell, scale and bone have simply stopped being in the world.
--
-- Taken one region at a time it is worse than six, and the probe at the foot
-- of this migration is what said so - the first draft of this file fixed the
-- six they are missing TOGETHER and was refused for it. White Heaven is short
-- those six. Black Heaven is short EIGHT: it has no hide and no feather
-- either, both of which only ever came from White Heaven's cranes and lions.
-- So the two rosters are filled separately, to what each one actually lacks.
--
-- WHERE IT CAME FROM, which is worth writing down because it is not a design
-- decision anybody made. The two regions carry fifty species and only thirty-
-- two of them drop anything. The other EIGHTEEN - 'Ashen Vein Wanderer',
-- 'Marrow Feast Tyrant', 'Jade Tribunal Renegade' and the rest, all of them
-- later additions sitting at the high end of the species table - were given
-- names, ranks and regions and never given a drop. They have been walking
-- around dropping nothing since the day they were added.
--
-- So the six missing parts go to the eighteen empty rosters, which costs the
-- regions no new creatures and takes nothing away from the thirty-two that
-- already pay. Both regions get all six, so neither becomes the only place to
-- forge a particular piece. Where a name already said what it was made of it
-- was taken at its word: the Marrow Feast Tyrant drops bone, the Grave Tide
-- Revenant drops bone, the Ashen Vein Wanderer drops venom.
--
-- WHAT IT DOES NOT DO. It does not raise what an immortal region pays. These
-- eighteen paid nothing at all, so every chance here is new income rather
-- than income moved, but it is a part per species the way the other thirty-two
-- are, at chances inside the 0.35-0.65 band they already sit in - the 0.90
-- is left to the two region bosses, where it was.
--
-- It also does not invent a material. All eighteen drops are parts that
-- already exist and already drop in the five starting regions; what was
-- missing was any way to go on getting them after rank 10.
--
-- Forward-only. Do not edit once applied.


INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, want.material_code, want.chance, want.lo, want.hi
FROM (VALUES
    -- ---- Black Heaven -----------------------------------------------------
    -- Eight parts across nine rosters. Bone twice, because it is the one
    -- that was asked for and the one two of these names already describe.
    ('Ashen Vein Wanderer',          'venom_sac',            0.60, 2, 5),
    ('Corpse Lantern Heretic',       'poison_heart',         0.50, 2, 4),
    ('Sable Court Exile',            'mirage_pelt',          0.50, 2, 4),
    ('Grave Tide Revenant',          'bone_fragment',        0.65, 3, 6),
    ('Marrow Feast Tyrant',          'iron_bone',            0.45, 1, 3),
    ('Eclipse Throne Usurper',       'skyrending_horn',      0.40, 1, 2),
    ('Abyssal Crown Devourer',       'dragon_scale',         0.45, 1, 3),
    ('Nightfall Sovereign',          'moth_wing_dust',       0.55, 2, 5),
    ('Black Heaven Demon Venerable', 'crystal_carapace',     0.50, 2, 4),
    -- ---- White Heaven -----------------------------------------------------
    ('Fallen Rites Ascetic',         'poison_heart',         0.50, 2, 4),
    ('Cloud Register Deserter',      'dragon_scale',         0.45, 1, 3),
    ('Broken Mandate Envoy',         'crescent_horn',        0.50, 2, 4),
    ('Jade Tribunal Renegade',       'tortoise_shell_plate', 0.50, 2, 4),
    ('Star Charter Apostate',        'snake_gall',           0.50, 2, 4),
    ('Radiant Decree Outcast',       'skyrending_horn',      0.40, 1, 2),
    ('Empyrean Seal Breaker',        'gilded_carapace',      0.50, 2, 4),
    ('Immortal Court Fugitive',      'iron_bone',            0.45, 1, 3),
    ('White Heaven Rebel Venerable', 'dragon_whale_bone',    0.50, 2, 4)
) AS want (species_name, material_code, chance, lo, hi)
JOIN creature_species cs ON cs.name = want.species_name;


-- ---------------------------------------------------------------------------
-- Every part the forge knows can be got at every depth
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad  TEXT;
    v_rows INTEGER;
    r      RECORD;
BEGIN
    -- The join above is on a name. If one is ever renamed the INSERT would
    -- quietly do less than it says, so the eighteen are counted back. Counting
    -- the REGION's drops instead would not have worked: these species carry
    -- non-beast drops too, so that total was already 50 before this ran.
    SELECT count(*) INTO v_rows
    FROM creature_drops cd
    JOIN creature_species cs ON cs.species_id = cd.species_id
    JOIN beast_parts bp ON bp.material_code = cd.material_code
    WHERE cs.name IN (
        'Ashen Vein Wanderer', 'Corpse Lantern Heretic', 'Sable Court Exile',
        'Grave Tide Revenant', 'Marrow Feast Tyrant', 'Eclipse Throne Usurper',
        'Abyssal Crown Devourer', 'Nightfall Sovereign',
        'Black Heaven Demon Venerable', 'Fallen Rites Ascetic',
        'Cloud Register Deserter', 'Broken Mandate Envoy',
        'Jade Tribunal Renegade', 'Star Charter Apostate',
        'Radiant Decree Outcast', 'Empyrean Seal Breaker',
        'Immortal Court Fugitive', 'White Heaven Rebel Venerable');
    IF v_rows <> 18 THEN
        RAISE EXCEPTION
            'only % of the eighteen empty rosters were filled', v_rows;
    END IF;

    -- No creature in either region is still walking around dropping nothing.
    SELECT string_agg(cs.name, ', ') INTO v_bad
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code IN ('black_heaven', 'white_heaven')
      AND NOT EXISTS (SELECT 1 FROM creature_drops cd
                      WHERE cd.species_id = cs.species_id);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still drop nothing: %', v_bad;
    END IF;

    -- And the thing this migration is for: both immortal regions can pay
    -- every part the forge is able to read. This is the assertion that would
    -- have failed before it and must never fail again.
    FOR r IN SELECT unnest(ARRAY['black_heaven', 'white_heaven']) AS region LOOP
        SELECT string_agg(p.part, ', ') INTO v_bad
        FROM (SELECT DISTINCT part FROM beast_parts) p
        WHERE NOT EXISTS (
            SELECT 1 FROM creature_regions cr
            JOIN creature_drops cd ON cd.species_id = cr.species_id
            JOIN beast_parts bp ON bp.material_code = cd.material_code
            WHERE cr.region_code = r.region AND bp.part = p.part
        );
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION '% still cannot pay: %', r.region, v_bad;
        END IF;
    END LOOP;

    -- Nothing here outbids the region bosses, who are meant to be the 0.90.
    IF EXISTS (
        SELECT 1 FROM creature_drops cd
        JOIN creature_regions cr ON cr.species_id = cd.species_id
        JOIN creature_species cs ON cs.species_id = cd.species_id
        WHERE cr.region_code IN ('black_heaven', 'white_heaven')
          AND cd.chance > 0.65
          AND cs.name NOT IN ('Shadow Demon King', 'Heavenly Court General')
    ) THEN
        RAISE EXCEPTION 'something ordinary now drops more often than a king';
    END IF;

    FOR r IN
        SELECT cr.region_code AS region, count(DISTINCT bp.part) AS parts,
               count(*) AS drops
        FROM creature_regions cr
        JOIN creature_drops cd ON cd.species_id = cr.species_id
        JOIN beast_parts bp ON bp.material_code = cd.material_code
        WHERE cr.region_code IN ('black_heaven', 'white_heaven')
        GROUP BY 1 ORDER BY 1
    LOOP
        RAISE NOTICE '% now pays % of the 12 parts, across % drops',
            rpad(r.region, 14), r.parts, r.drops;
    END LOOP;
END;
$probe$;
