-- 0174_an_affix_you_can_actually_forge
--
-- A forge reaction fires when the ORE's Path and a BEAST PART's Path are the
-- pair named in `forge_reactions`. Auditing all eight against the materials
-- that actually exist:
--
--   Magmaforged  lvl 8    8 pairings, cheapest ore tier 1   fine
--   Steamveil    lvl 8   15 pairings, tier 1                fine
--   Venomsteel   lvl 12  42 pairings, tier 1                fine
--   Soulbleed    lvl 15   7 pairings, tier 3                fine
--   Stormbound   lvl 10  10 pairings, cheapest tier 4       really level 14
--   Frostfire    lvl 10   1 pairing,  cheapest tier 7       really level 60
--   Darksteel    lvl 12   NO PAIRING AT ALL
--   Duskbound    lvl 15   NO PAIRING AT ALL
--
-- Two affixes could not be made by anybody, and they are the two at the top
-- of the ladder - the ones a smith levels toward. A third, Frostfire, says 10
-- and means 60, because the only pairing is Everwinter Adamant (the sole Ice
-- ore, tier 7) with Golden Crow Essence, and tier 7 ore wants a tier 7 anvil.
--
-- One cause underneath all of it: some Paths have ore and no beast part, or a
-- part and no ore, and Shadow had neither. Four materials close it.
--
--   Nightsilver     tier 2 Shadow ore     -> Darksteel with any Metal part
--                                            Duskbound with the Light part
--   Crescent Horn   Light beast part      -> Duskbound
--   Frost Scale     Ice beast part        -> Frostfire with tier 3 Magma Iron
--   Thunder Horn    Lightning beast part  -> Stormbound with tier 1 Water ore
--
-- Every one hangs off a creature that already exists and a vein in a region
-- that already exists. Nothing new to hunt, only something to keep off it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
VALUES
    ('nightsilver', 'Nightsilver', 'gathering', 'uncommon', 'shadow',
     '\N{NEW MOON SYMBOL}',
     'Pulled out of a seam the lamp would not reach. It is bright once it is '
     'up, which is the part nobody believes until they see it.'),

    ('crescent_horn', 'Crescent Horn', 'beast', 'uncommon', 'light',
     '\N{SPARKLES}',
     'Grown in the shape of the moon it was grown under, and it keeps a little '
     'of the light it was named for.'),

    ('frost_scale', 'Frost Scale', 'beast', 'common', 'ice',
     '\N{SNOWFLAKE}',
     'Cold to hold long after the thing wearing it stopped being cold to it.'),

    ('thunder_horn', 'Thunder Horn', 'beast', 'uncommon', 'lightning',
     '\N{HIGH VOLTAGE SIGN}',
     'The hair stands up on the arm holding it. It has not finished.');


-- Shadow's ore. Dodge for its signature, because what shadow does to a blow
-- is not stop it.
INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('nightsilver', 2, 'dodge', 'Nightsilver');

INSERT INTO region_veins (region_code, material_code, weight) VALUES
    ('northern', 'nightsilver', 0.7000),
    ('eastern',  'nightsilver', 0.9000);


INSERT INTO beast_parts (material_code, part) VALUES
    ('crescent_horn', 'horn'),
    ('frost_scale',   'scale'),
    ('thunder_horn',  'horn');


-- Off creatures that already carry the Path, at rates that sit beside what
-- each already drops rather than above it.
INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, v.material_code, v.chance, v.lo, v.hi
FROM (VALUES
    ('Crescent-Horn Deer',    'crescent_horn', 0.3500, 1, 2),
    ('Frost Snake',           'frost_scale',   0.4500, 1, 2),
    ('Chilling Grass Mantis', 'frost_scale',   0.3000, 1, 1),
    ('Frost-Maned Ape',       'frost_scale',   0.5000, 1, 3),
    ('Thunderhorn Goat',      'thunder_horn',  0.4000, 1, 2),
    ('Storm Eagle',           'thunder_horn',  0.2500, 1, 1)
) AS v (creature, material_code, chance, lo, hi)
JOIN creature_species cs ON cs.name = v.creature;


-- The check whose absence let two affixes sit in the table unmakeable, and a
-- third advertise a tenth of its real requirement. An affix must have a
-- pairing, and its cheapest pairing must use ore that a smith of exactly its
-- own `min_level` is allowed to work.

DO $$
DECLARE
    broken TEXT;
BEGIN
    WITH pairing AS (
        SELECT r.word, r.min_level, min(o.tier) AS cheapest, count(*) AS ways
        FROM forge_reactions r
        JOIN ores o ON TRUE
        JOIN materials om ON om.code = o.material_code
        JOIN beast_parts bp ON TRUE
        JOIN materials pm ON pm.code = bp.material_code
        WHERE (r.path_a = om.path_code AND r.path_b = pm.path_code)
           OR (r.path_b = om.path_code AND r.path_a = pm.path_code)
        GROUP BY r.word, r.min_level
    )
    SELECT string_agg(
               r.word || ' ('
               || CASE WHEN p.ways IS NULL THEN 'no pairing at all'
                       ELSE 'cheapest ore is tier ' || p.cheapest
                            || ', level ' || r.min_level || ' works tier '
                            || smith_tier_cap(r.min_level) END
               || ')', ', ' ORDER BY r.min_level)
    INTO broken
    FROM forge_reactions r
    LEFT JOIN pairing p ON p.word = r.word
    WHERE p.ways IS NULL
       OR p.cheapest > smith_tier_cap(r.min_level);

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION 'these affixes cannot be forged at the level they '
                        'claim: %', broken;
    END IF;
END;
$$;


-- And the new materials have to be gettable, or this is the same fault in a
-- different table: a Path with an ore nobody can mine is a Path with no ore.

DO $$
DECLARE
    orphan TEXT;
BEGIN
    SELECT string_agg(m.name, ', ') INTO orphan
    FROM materials m
    WHERE m.code IN ('nightsilver', 'crescent_horn', 'frost_scale', 'thunder_horn')
      AND NOT EXISTS (SELECT 1 FROM region_veins v WHERE v.material_code = m.code)
      AND NOT EXISTS (SELECT 1 FROM creature_drops d WHERE d.material_code = m.code);

    IF orphan IS NOT NULL THEN
        RAISE EXCEPTION 'nothing drops or yields: %', orphan;
    END IF;
END;
$$;
