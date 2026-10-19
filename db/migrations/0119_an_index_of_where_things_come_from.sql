-- 0119_an_index_of_where_things_come_from
--
-- A recipe says "12 Tide Stone" and the game has never once said where a Tide
-- Stone is. The information exists - `region_materials`, `region_veins` and
-- `creature_drops` between them account for every material in the world - but
-- it has only ever been readable by whoever wrote the migration.
--
-- The alternative to an index is a player gathering in six regions to find out
-- which one has the thing, which is not exploration, it is a survey.
--
-- BOTH DIRECTIONS. "Where do I get this" and "what is here" are the same table
-- read from two ends, and a player asks the first when they have a recipe and
-- the second when they have an afternoon.
--
-- WEIGHTS BECOME SHARES. A weight of 8 means nothing on its own; 8 out of a
-- region's 63 is "about one in eight of what you pull up". The arithmetic is
-- done here so that no screen has to know a weight is relative to its region's
-- total, which is the sort of thing two screens would do differently.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION material_sources(p_code TEXT)
RETURNS TABLE (
    kind        TEXT,
    region_code TEXT,
    region_name TEXT,
    source_name TEXT,
    share       NUMERIC,
    detail      TEXT
)
LANGUAGE sql STABLE
AS $$
    -- Gathered: a share of that region's gathering table.
    SELECT 'gather', rm.region_code, r.name, NULL::text,
           round(100 * rm.weight / sum(rm.weight) OVER (PARTITION BY rm.region_code), 1),
           'one in ' || round(sum(rm.weight) OVER (PARTITION BY rm.region_code)
                              / rm.weight)::text || ' of what you gather'
    FROM region_materials rm
    JOIN regions r ON r.code = rm.region_code
    WHERE rm.material_code = p_code

    UNION ALL

    -- Mined: the same, against the region's veins.
    SELECT 'mine', rv.region_code, r.name, NULL::text,
           round(100 * rv.weight / sum(rv.weight) OVER (PARTITION BY rv.region_code), 1),
           'tier ' || o.tier || ' vein'
    FROM region_veins rv
    JOIN regions r ON r.code = rv.region_code
    JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.material_code = p_code

    UNION ALL

    -- Stripped off something: the chance is the drop's own, not a share.
    SELECT 'hunt', cr.region_code, r.name, cs.name,
           round(100 * cd.chance, 1),
           CASE WHEN cd.min_quantity = cd.max_quantity
                THEN cd.min_quantity::text || ' each time'
                ELSE cd.min_quantity::text || '-' || cd.max_quantity::text || ' each time'
           END
    FROM creature_drops cd
    JOIN creature_species cs ON cs.species_id = cd.species_id
    JOIN creature_regions cr ON cr.species_id = cd.species_id
    JOIN regions r ON r.code = cr.region_code
    WHERE cd.material_code = p_code

    ORDER BY 1, 5 DESC, 3;
$$;

COMMENT ON FUNCTION material_sources(TEXT) IS
    'Every way a material enters the world, with weights already turned into shares. The answer to "where do I get this".';


CREATE FUNCTION region_finds(p_region TEXT)
RETURNS TABLE (
    kind        TEXT,
    material_code TEXT,
    material_name TEXT,
    emoji       TEXT,
    rarity      TEXT,
    source_name TEXT,
    share       NUMERIC
)
LANGUAGE sql STABLE
AS $$
    SELECT 'gather', rm.material_code, material_name(rm.material_code),
           m.emoji, m.rarity, NULL::text,
           round(100 * rm.weight / sum(rm.weight) OVER (), 1)
    FROM region_materials rm
    JOIN materials m ON m.code = rm.material_code
    WHERE rm.region_code = p_region

    UNION ALL

    SELECT 'mine', rv.material_code, material_name(rv.material_code),
           m.emoji, m.rarity, 'tier ' || o.tier,
           round(100 * rv.weight / sum(rv.weight) OVER (), 1)
    FROM region_veins rv
    JOIN materials m ON m.code = rv.material_code
    JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = p_region

    UNION ALL

    SELECT DISTINCT 'hunt', cd.material_code, material_name(cd.material_code),
           m.emoji, m.rarity, cs.name,
           round(100 * cd.chance, 1)
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    JOIN creature_drops cd ON cd.species_id = cr.species_id
    JOIN materials m ON m.code = cd.material_code
    WHERE cr.region_code = p_region

    ORDER BY 1, 7 DESC, 3;
$$;

COMMENT ON FUNCTION region_finds(TEXT) IS
    'Everything a region yields, by how it is got. The answer to "what is here".';
