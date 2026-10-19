-- 0316_the_deep_country_drops_something_worth_the_walk
--
-- Two faults, both mine, both from 0314.
--
-- ONE: the rarity ladder runs nine bands and beast parts stopped at the
-- third. Every one of the 46 was common, uncommon or rare, so a rank 9 beast
-- dropped exactly the grade a rank 1 boar does - more of it, never better.
-- Ores already reached epic; parts never had. Legendary and everything above
-- it held no materials at all.
--
-- TWO: all fourteen new beasts drew from ONE seven-material spine, because
-- that made the 3-to-7 scaling easy to write. The cost was that 39 of the 46
-- parts still dropped only from rank 1 and 2 creatures - including the three
-- most distinctive in the game: Moth Wing Dust is the only source of Extra
-- Strikes, Tiger Fang the only Critical Rate, and Pearl the only part
-- carrying three effects at once.
--
-- WHY THIS IS SAFE FOR CRAFTING. `forge` caps a piece at
-- `LEAST(tier_by_pot, best_tier, smith_tier_cap(skill))`, and `best_tier` is
-- the best ORE - "the best metal is still the ceiling". Parts only add
-- potency and decide which effects a piece carries, so richer parts cannot
-- inflate equipment tier past 7. Ore contributes `tier^2` and parts
-- contribute `grade^2`, which is why the new ores below are a TIER up and the
-- new parts are a GRADE up: each is raised on the axis its own side is
-- measured by.
--
-- ORES ARE DELIBERATELY NOT TOUCHED HERE, and the schema is why. `ores` has
-- CHECK (tier BETWEEN 1 AND 7), matching `equipment_tiers` exactly - so ores
-- are not behind parts at all, they already reach the ceiling of what a forge
-- can use. Giving them "the same treatment" would mean raising that ceiling,
-- which is a balance decision about the whole game rather than a content gap,
-- and it is not one to make inside a migration about beast drops.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Parts worth carrying home
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
SELECT v.code, v.name,
       (SELECT category FROM materials WHERE code = 'beast_core'),
       v.rarity, v.path, v.emoji, v.descr
FROM (VALUES
  ('skyrending_horn','Skyrending Horn','epic','lightning','⚡',
   'Taken from something that used the sky as a tool rather than a roof.'),
  ('titan_hide','Titan Hide','epic','earth','\U0001f7eb',
   'Thicker than the animal needed. Whatever it was expecting never came.'),
  ('void_fang','Void Fang','epic','shadow','\U0001f5a4',
   'The tooth is present. What it bit is not, and has not been for some time.'),
  ('phoenix_down','Phoenix Down','epic','fire','\U0001fab6',
   'Still warm. It has been still warm for four hundred years.'),
  ('abyssal_core','Abyssal Core','epic','qi','\U0001f7e3',
   'A beast that lived deep enough grows one of these instead of a heart.'),
  ('dragon_whale_heart','Dragon Whale Heart','legendary','water','\U0001f499',
   'It is the size of a hall and it is still, very faintly, going.'),
  ('immortal_soul_ember','Immortal Soul Ember','legendary','soul','\U0001f505',
   'What is left when a soul refuses the usual arrangement. It does not cool.'),
  ('primordial_blood','Primordial Blood','legendary','blood','\U0001f7e5',
   'Older than blood is supposed to be. It remembers being something else.'),
  ('sovereign_fang','Sovereign Fang','legendary','strength','\U0001f9b7',
   'One tooth, from something that never needed a second.')
) AS v(code, name, rarity, path, emoji, descr);

INSERT INTO beast_parts (material_code, part) VALUES
  ('skyrending_horn','horn'), ('titan_hide','hide'), ('void_fang','fang'),
  ('phoenix_down','feather'), ('abyssal_core','core'),
  ('dragon_whale_heart','core'), ('immortal_soul_ember','soul'),
  ('primordial_blood','blood'), ('sovereign_fang','fang');


-- ---------------------------------------------------------------------------
-- What each beast actually leaves, instead of one shared spine
-- ---------------------------------------------------------------------------

DELETE FROM creature_drops cd
USING creature_species cs
WHERE cs.species_id = cd.species_id AND cs.kind = 'beast' AND cs.rank >= 3;

WITH pairs (beast, part) AS (VALUES
  -- rank 3: three apiece, the shallow end of the shelf
  ('ash_maned_lion','wolf_pelt'), ('ash_maned_lion','wolf_fang'),
  ('ash_maned_lion','beast_blood'),
  ('grey_silt_crocodile','crab_carapace'), ('grey_silt_crocodile','shark_tooth'),
  ('grey_silt_crocodile','desert_scale'),

  -- rank 4
  ('nine_lined_tiger','tiger_fang'), ('nine_lined_tiger','wolf_pelt'),
  ('nine_lined_tiger','beast_horn'), ('nine_lined_tiger','mirage_pelt'),
  ('bronze_shell_tortoise','turtle_shell'), ('bronze_shell_tortoise','tortoise_shell_plate'),
  ('bronze_shell_tortoise','crystal_carapace'), ('bronze_shell_tortoise','bone_fragment'),

  -- rank 5
  ('frost_maw_wolf','frost_scale'), ('frost_maw_wolf','wolf_fang'),
  ('frost_maw_wolf','wolf_pelt'), ('frost_maw_wolf','beast_blood'),
  ('frost_maw_wolf','gilded_carapace'),
  ('cinder_plume_hawk','eagle_feather'), ('cinder_plume_hawk','moth_wing_dust'),
  ('cinder_plume_hawk','golden_crow_essence'), ('cinder_plume_hawk','beast_horn'),
  ('cinder_plume_hawk','blood_coral'),

  -- rank 6
  ('stone_sinew_ape','skull_fragment'), ('stone_sinew_ape','bone_spear_tip'),
  ('stone_sinew_ape','crystal_carapace'), ('stone_sinew_ape','black_boar_tusk'),
  ('stone_sinew_ape','vitality_sap'), ('stone_sinew_ape','beast_core'),
  ('drowned_bell_eel','fish_scale_shard'), ('drowned_bell_eel','pearl'),
  ('drowned_bell_eel','snake_gall'), ('drowned_bell_eel','crab_carapace'),
  ('drowned_bell_eel','blood_coral'), ('drowned_bell_eel','soul_crystal'),

  -- rank 7: epic opens here
  ('thunder_horn_bull','skyrending_horn'), ('thunder_horn_bull','thunder_horn'),
  ('thunder_horn_bull','crescent_horn'), ('thunder_horn_bull','beast_horn'),
  ('thunder_horn_bull','wolf_pelt'), ('thunder_horn_bull','iron_bone'),
  ('thunder_horn_bull','vitality_sap'),
  ('hollow_mountain_bear','titan_hide'), ('hollow_mountain_bear','mirage_pelt'),
  ('hollow_mountain_bear','skull_fragment'), ('hollow_mountain_bear','bone_spear_tip'),
  ('hollow_mountain_bear','crystal_carapace'), ('hollow_mountain_bear','beast_core'),
  ('hollow_mountain_bear','lingzhi_meat'),

  -- rank 8
  ('sky_scaled_python','void_fang'), ('sky_scaled_python','snake_gall'),
  ('sky_scaled_python','poison_heart'), ('sky_scaled_python','venom_sac'),
  ('sky_scaled_python','fish_scale_shard'), ('sky_scaled_python','dragon_scale'),
  ('sky_scaled_python','soul_pearl'),
  ('ember_bone_rhinoceros','phoenix_down'), ('ember_bone_rhinoceros','golden_crow_essence'),
  ('ember_bone_rhinoceros','scorpion_stinger'), ('ember_bone_rhinoceros','centipede_venom'),
  ('ember_bone_rhinoceros','iron_bone'), ('ember_bone_rhinoceros','beast_core'),
  ('ember_bone_rhinoceros','dragon_whale_bone'),

  -- rank 9: the only place legendary falls
  ('primordial_dragon_whale','dragon_whale_heart'),
  ('primordial_dragon_whale','primordial_blood'),
  ('primordial_dragon_whale','abyssal_core'),
  ('primordial_dragon_whale','dragon_whale_bone'),
  ('primordial_dragon_whale','dragon_scale'),
  ('primordial_dragon_whale','pearl'),
  ('primordial_dragon_whale','soul_pearl'),
  ('sovereign_ninetail_fox','immortal_soul_ember'),
  ('sovereign_ninetail_fox','sovereign_fang'),
  ('sovereign_ninetail_fox','heroic_soul'),
  ('sovereign_ninetail_fox','tormented_soul'),
  ('sovereign_ninetail_fox','soul_crystal'),
  ('sovereign_ninetail_fox','mirage_pelt'),
  ('sovereign_ninetail_fox','footless_bird')
)
INSERT INTO creature_drops
    (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, p.part,
       -- Rarer things fall less often and in smaller numbers. The rank adds a
       -- little on top, so a deep beast is worth opening twice.
       CASE material_grade(m.rarity)
            WHEN 1 THEN 0.95 WHEN 2 THEN 0.80 WHEN 3 THEN 0.55
            WHEN 4 THEN 0.35 ELSE 0.20 END,
       CASE WHEN material_grade(m.rarity) >= 4 THEN 1 ELSE 2 END,
       GREATEST(1, CASE material_grade(m.rarity)
            WHEN 1 THEN 5 WHEN 2 THEN 4 WHEN 3 THEN 3
            WHEN 4 THEN 2 ELSE 1 END) + cs.rank / 4
FROM pairs p
JOIN creature_species cs ON cs.code = p.beast
JOIN materials m ON m.code = p.part;


-- ---------------------------------------------------------------------------
-- The ladder reaches where it did not
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bad TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM beast_parts bp JOIN materials m
                   ON m.code = bp.material_code WHERE m.rarity = 'legendary') THEN
        RAISE EXCEPTION 'beast parts still stop below legendary';
    END IF;
    -- Every new part and ore is reachable: a drop table or a seam.
    SELECT string_agg(m.code, ' ') INTO bad
    FROM materials m
    WHERE m.code IN ('skyrending_horn','titan_hide','void_fang','phoenix_down',
                     'abyssal_core','dragon_whale_heart','immortal_soul_ember',
                     'primordial_blood','sovereign_fang')
      AND NOT EXISTS (SELECT 1 FROM creature_drops cd WHERE cd.material_code = m.code);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these new parts drop from nothing: %', bad;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- The orphaned parts have somewhere deep to come from
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    stranded INTEGER;
    was      INTEGER := 39;
    n        INTEGER;
BEGIN
    -- Parts that only rank 1 and 2 creatures drop. 39 before this.
    SELECT count(*) INTO stranded
    FROM beast_parts bp
    WHERE NOT EXISTS (
        SELECT 1 FROM creature_drops cd
        JOIN creature_species cs ON cs.species_id = cd.species_id
        WHERE cd.material_code = bp.material_code AND cs.rank >= 3);

    IF stranded >= was THEN
        RAISE EXCEPTION
            '% parts still drop only from rank 1 and 2 creatures', stranded;
    END IF;

    -- And the three most distinctive are among those now reachable deep.
    FOR n IN
        SELECT 1 FROM (VALUES ('moth_wing_dust'), ('tiger_fang'), ('pearl')) v(c)
        WHERE NOT EXISTS (
            SELECT 1 FROM creature_drops cd
            JOIN creature_species cs ON cs.species_id = cd.species_id
            WHERE cd.material_code = v.c AND cs.rank >= 3)
    LOOP
        RAISE EXCEPTION 'the distinctive parts are still shallow-only';
    END LOOP;

    RAISE NOTICE
        'parts reachable only at rank 1-2: % (was %)', stranded, was;
END;
$$;


-- ---------------------------------------------------------------------------
-- And every beast still drops LEAST(7, rank) kinds
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(cs.name || ' drops ' || d.n || ' at rank ' || cs.rank, ', ')
    INTO bad
    FROM creature_species cs
    JOIN LATERAL (SELECT count(*) AS n FROM creature_drops
                  WHERE species_id = cs.species_id) d ON TRUE
    WHERE cs.kind = 'beast' AND cs.rank >= 3 AND d.n <> LEAST(7, cs.rank);

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'wrong number of drops: %', bad;
    END IF;
END;
$$;
