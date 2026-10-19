-- 0317_pseudo_immortal_gear
--
-- Tier 8. The first rung above the ceiling this game has had since equipment
-- existed, and the reason it is being added now: rank 9 beasts drop legendary
-- parts since 0316, and the best metal is what caps a piece - so without a
-- tier above 7 the deepest hunting in the game feeds a forge that cannot use
-- it.
--
-- IT IS DELIBERATELY AWKWARD TO MAKE. Every other tier is reached by having
-- enough potency and a good enough metal. This one asks for four things at
-- once, and missing any of them simply means you made a tier 7:
--
--     the metal      at least `pseudo_immortal_kinds` DIFFERENT tier 8 ores
--     the depth      at least `pseudo_immortal_each` of every one of them
--     the bulk       `pseudo_immortal_fodder` potency of everything else
--     the smith      a Blacksmith who has reached the new forge_tier step
--
-- MISSING ONE CAPS YOU AT SEVEN RATHER THAN REFUSING. A refusal would be
-- tidier to write and worse to receive: tier 8 ore is perfectly good tier 7
-- material, and a forge that threw an error rather than making the piece
-- would leave a smith unable to use their best metal at all until they had
-- everything. Silently making the tier 7 they can make is the kinder failure
-- - and `pseudo_immortal_shortfall` exists so a screen can say, before the
-- hammer falls, which of the four is missing.
--
-- THE POTENCY JUMP IS THE POINT. The ladder climbs 4, 12, 28, 60, 120, 230,
-- 400 - about 1.75x a rung. Tier 8 asks 1200, which is three times tier 7
-- rather than the 1.75 the curve would predict. Magnitude goes 0.80 to 1.15,
-- which is the same 1.45x step every other rung takes. More work for a normal
-- amount of reward is what makes it a summit rather than a treadmill.
--
-- Forward-only. Do not edit once applied.


-- Two ceilings, both written as 7, and they have to move together: the ore
-- constraint tracks the equipment ladder, so loosening one without the other
-- would leave metal that cannot be made into anything or a tier nothing can
-- be made of. `player_equipment.tier` is a foreign key to this table, so it
-- follows on its own.
ALTER TABLE equipment_tiers DROP CONSTRAINT equipment_tiers_tier_check;
ALTER TABLE equipment_tiers ADD CONSTRAINT equipment_tiers_tier_check
    CHECK (tier >= 1 AND tier <= 8);

ALTER TABLE ores DROP CONSTRAINT ores_tier_check;
ALTER TABLE ores ADD CONSTRAINT ores_tier_check CHECK (tier >= 1 AND tier <= 8);

INSERT INTO equipment_tiers (tier, potency_required, base_magnitude)
VALUES (8, 1200.00, 1.1500);


INSERT INTO game_config (key, value, description) VALUES
    ('pseudo_immortal_kinds', 3,
     'How many DIFFERENT tier 8 metals a Pseudo-Immortal piece needs. One '
     'seam is a lucky find; three is an expedition.'),
    ('pseudo_immortal_each', 3,
     'How many of EACH of those metals. The dial that makes the tier cost '
     'months rather than one good day.'),
    ('pseudo_immortal_fodder', 600,
     'Potency that must come from everything that is NOT tier 8 ore. A '
     'Pseudo-Immortal piece is mostly ordinary material held together by a '
     'little of something that should not exist.');


-- ---------------------------------------------------------------------------
-- The metal itself: one seam a region, rarer than the epic seams above them
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
SELECT v.code, v.name,
       (SELECT category FROM materials WHERE code = 'blazing_sunsteel'),
       'legendary', v.path, v.emoji, v.descr
FROM (VALUES
  ('glacier_heart_adamant','Glacier Heart Adamant','ice','\U0001f9ca',
   'The cold in it is not temperature. Smiths who rush this one lose fingers.'),
  ('sun_core_adamant','Sun Core Adamant','fire','\U0001f7e0',
   'It was never underground. Something put it there, and the hole is still glassy.'),
  ('leviathan_spine_ore','Leviathan Spine Ore','water','\U0001f30a',
   'Mined in sections, numbered, because it matters which way round they go.'),
  ('plague_sovereign_ore','Plague Sovereign Ore','poison','\U0001f7e2',
   'Green all the way through. The seam is bad ground and everything above it is dead.'),
  ('heavenly_origin_adamant','Heavenly Origin Adamant','heaven','✨',
   'Ore from before there were ores. It does not answer to the usual furnace.')
) AS v(code, name, path, emoji, descr);

-- `signature` is the effect the metal lends a piece, not its Path - a
-- foreign key into gu_effects. The tier 7 seams carry Damage Reduction,
-- Attack Power, Armour Penetration and Cultivation Speed between them, so
-- these five spread across the same axes rather than inventing new ones.
INSERT INTO ores (material_code, tier, signature, word)
SELECT v.code, 8, v.sig, v.word
FROM (VALUES
  ('glacier_heart_adamant','damage_reduction','Glacier-Heart'),
  ('sun_core_adamant','attack_power','Sun-Core'),
  ('leviathan_spine_ore','max_hp','Leviathan'),
  ('plague_sovereign_ore','armor_pen','Plague-Sovereign'),
  ('heavenly_origin_adamant','cultivation_rate','Origin-Heaven')
) AS v(code, sig, word);

INSERT INTO region_veins (region_code, material_code, weight) VALUES
  ('northern','glacier_heart_adamant',0.10),
  ('western','sun_core_adamant',0.10),
  ('eastern','leviathan_spine_ore',0.10),
  ('southern','plague_sovereign_ore',0.10),
  ('central','heavenly_origin_adamant',0.10);


-- ---------------------------------------------------------------------------
-- A smith deep enough to attempt it
-- ---------------------------------------------------------------------------

-- The existing rungs sit at 6, 14, 26, 42 and 60, which carries a smith from
-- tier 2 to tier 7. Eighty-five is a long way past the last of them, on
-- purpose.
INSERT INTO profession_steps (ladder, step, level_required) VALUES ('forge_tier', 6, 85);

CREATE OR REPLACE FUNCTION smith_tier_cap(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(8, game_config_value('forge_base_tier')
                    + ladder_steps('forge_tier', p_level))::smallint;
$$;


-- ---------------------------------------------------------------------------
-- What is missing, in words, before anybody swings a hammer
-- ---------------------------------------------------------------------------

CREATE FUNCTION pseudo_immortal_shortfall(
    p_ores TEXT[], p_ore_qtys INTEGER[],
    p_parts TEXT[], p_part_qtys INTEGER[],
    p_level SMALLINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    kinds   INTEGER;
    fewest  INTEGER;
    fodder  NUMERIC;
    want_k  INTEGER := game_config_value('pseudo_immortal_kinds')::integer;
    want_e  INTEGER := game_config_value('pseudo_immortal_each')::integer;
    want_f  NUMERIC := game_config_value('pseudo_immortal_fodder');
    short   TEXT := '';
BEGIN
    SELECT count(*), COALESCE(min(u.quantity), 0)
    INTO kinds, fewest
    FROM unnest(p_ores, p_ore_qtys) AS u (code, quantity)
    JOIN ores o ON o.material_code = u.code
    WHERE o.tier >= 8;

    -- Everything that is not tier 8 metal, counted the way the forge counts
    -- it: ore by tier squared, parts by grade squared.
    SELECT COALESCE((SELECT sum(o.tier::numeric ^ 2 * u.quantity)
                     FROM unnest(p_ores, p_ore_qtys) AS u (code, quantity)
                     JOIN ores o ON o.material_code = u.code
                     WHERE o.tier < 8), 0)
         + COALESCE((SELECT sum(material_grade(m.rarity)::numeric ^ 2 * u.quantity)
                     FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
                     JOIN materials m ON m.code = u.code), 0)
    INTO fodder;

    IF smith_tier_cap(p_level) < 8 THEN
        short := short || ' a Blacksmith of 85';
    END IF;
    IF kinds < want_k THEN
        short := short || ' ' || (want_k - kinds) || ' more kind(s) of tier 8 metal';
    END IF;
    IF fewest < want_e THEN
        short := short || ' ' || want_e || ' of each tier 8 metal (fewest is '
                       || fewest || ')';
    END IF;
    IF fodder < want_f THEN
        short := short || ' ' || round(want_f - fodder) || ' more potency of other material';
    END IF;

    RETURN NULLIF(trim(short), '');
END;
$$;

COMMENT ON FUNCTION pseudo_immortal_shortfall(TEXT[], INTEGER[], TEXT[], INTEGER[], SMALLINT) IS
    'What stands between this anvil and a Pseudo-Immortal piece, or NULL if nothing does.';


-- ---------------------------------------------------------------------------
-- And the forge holds the line
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    grade := LEAST(tier_by_pot, best_tier, smith_tier_cap(skill));';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'forge';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the forge no longer picks its tier where it did';
    END IF;

    body := replace(body, anchor, anchor || '

    -- Tier 8 is not reached by potency alone. Falling short of any of its
    -- four conditions quietly makes the tier 7 this anvil CAN make, because
    -- tier 8 metal is good tier 7 metal and refusing outright would leave a
    -- smith unable to use their best find at all.
    IF grade >= 8 AND pseudo_immortal_shortfall(
            p_ores, p_ore_qtys, p_parts, p_part_qtys, skill) IS NOT NULL THEN
        grade := 7;
    END IF;');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The rung exists, and is out of reach without all four
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    said TEXT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM equipment_tiers WHERE tier = 8) THEN
        RAISE EXCEPTION 'there is no tier 8 to forge';
    END IF;
    IF (SELECT count(*) FROM ores WHERE tier = 8) <> 5 THEN
        RAISE EXCEPTION 'the tier 8 seams are not all there';
    END IF;

    -- A level 84 smith cannot, a level 85 smith can.
    IF smith_tier_cap(84::smallint) >= 8 THEN
        RAISE EXCEPTION 'a smith below 85 can reach tier 8';
    END IF;
    IF smith_tier_cap(85::smallint) <> 8 THEN
        RAISE EXCEPTION 'a smith of 85 still cannot reach tier 8';
    END IF;

    -- An anvil with one tier 8 ore and nothing else is short on three counts.
    said := pseudo_immortal_shortfall(
        ARRAY['glacier_heart_adamant'], ARRAY[1],
        ARRAY[]::text[], ARRAY[]::integer[], 85::smallint);
    IF said IS NULL THEN
        RAISE EXCEPTION 'one lump of metal was enough for a Pseudo-Immortal piece';
    END IF;
    RAISE NOTICE 'one lump short by:%', said;

    -- And a properly stocked anvil is short on none.
    said := pseudo_immortal_shortfall(
        ARRAY['glacier_heart_adamant','sun_core_adamant','leviathan_spine_ore'],
        ARRAY[3, 3, 3],
        -- Common parts are grade 1, so they contribute 1 each: six hundred
        -- of them is exactly the fodder threshold, which is the point of the
        -- threshold. Three hundred and fifty apiece clears it.
        ARRAY['beast_blood','bone_fragment'], ARRAY[350, 350],
        85::smallint);
    IF said IS NOT NULL THEN
        RAISE EXCEPTION 'a full anvil was still short:%', said;
    END IF;

    RAISE NOTICE 'three metals, three of each, and a sack of fodder is enough';
END;
$$;
