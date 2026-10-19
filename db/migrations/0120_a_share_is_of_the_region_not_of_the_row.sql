-- 0120_a_share_is_of_the_region_not_of_the_row
--
-- `material_sources` computed a material's share of its region with
--
--     sum(weight) OVER (PARTITION BY region_code)
--
-- and a window function sums the QUERY'S rows, not the table's. The query has
-- already filtered to one material, so the partition contained exactly one
-- row and every material in the world reported a 100% share and "one in 1 of
-- what you gather".
--
-- Confidently wrong, which is the worst kind of wrong for an index: a player
-- reading it would go to the Eastern Sea expecting Tide Stone every time.
--
-- The region's total has to be looked up against the whole table, so it is a
-- correlated subquery rather than a window. `region_finds` was never affected
-- - it selects a whole region, so its partition really does hold every row.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION material_sources(p_code TEXT)
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
    SELECT 'gather', rm.region_code, r.name, NULL::text,
           round(100 * rm.weight / whole.total, 1),
           'about one in ' || GREATEST(1, round(whole.total / rm.weight))::text
           || ' of what you gather there'
    FROM region_materials rm
    JOIN regions r ON r.code = rm.region_code
    CROSS JOIN LATERAL (
        SELECT sum(all_rm.weight) AS total FROM region_materials all_rm
        WHERE all_rm.region_code = rm.region_code
    ) whole
    WHERE rm.material_code = p_code

    UNION ALL

    SELECT 'mine', rv.region_code, r.name, NULL::text,
           round(100 * rv.weight / whole.total, 1),
           'tier ' || o.tier || ' vein, about one in '
           || GREATEST(1, round(whole.total / rv.weight))::text || ' you strike'
    FROM region_veins rv
    JOIN regions r ON r.code = rv.region_code
    JOIN ores o ON o.material_code = rv.material_code
    CROSS JOIN LATERAL (
        SELECT sum(all_rv.weight) AS total FROM region_veins all_rv
        WHERE all_rv.region_code = rv.region_code
    ) whole
    WHERE rv.material_code = p_code

    UNION ALL

    -- A drop chance is already absolute, so there is nothing to divide by.
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
    'Every way a material enters the world. Gathering and mining shares are of the whole region''s table; a drop chance is its own.';
