-- 0122_a_road_runs_both_ways
--
-- `region_routes` stores each road once, as a canonical ordered pair - it has
-- carried `CHECK (origin < destination)` since 0016 and `travel_hours_between`
-- reads it with LEAST/GREATEST precisely because a road has no direction.
--
-- 0121's gazetteer listed roads with `WHERE origin = p_region`, which reads
-- half the table. The Western Desert sorts last of the five, so every one of
-- its four roads is stored with it as the DESTINATION, and its page claimed
-- it had none - a region you cannot leave, according to the only screen that
-- says which roads exist.
--
-- Caught by the test that asks whether every region has a page worth reading,
-- which is the job that test was written to do.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION region_index(p_region TEXT)
RETURNS TABLE (
    kind  TEXT,
    code  TEXT,
    name  TEXT,
    emoji TEXT,
    note  TEXT,
    share NUMERIC
)
LANGUAGE sql STABLE
AS $$
    SELECT f.kind, f.material_code, f.material_name, f.emoji,
           COALESCE(f.source_name, f.rarity), f.share
    FROM region_finds(p_region) f
    WHERE f.kind IN ('gather', 'mine')

    UNION ALL

    SELECT 'beast', cs.species_id::text, cs.name,
           CASE cs.kind
               WHEN 'boss'  THEN '👑'
               WHEN 'elite' THEN '💢'
               WHEN 'world' THEN '🌋'
               WHEN 'rogue' THEN '🗡'
               ELSE '🐾'
           END,
           'rank ' || cs.rank || CASE WHEN cs.kind <> 'beast'
                                      THEN ' ' || cs.kind ELSE '' END,
           round(100 * cr.weight / sum(cr.weight) OVER (), 1)
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = p_region

    UNION ALL

    SELECT 'gu', gt.code, gt.name, gt.emoji,
           'rank ' || gt.rank || ' ' || gt.rarity,
           round(100 * gd.weight / sum(gd.weight) OVER (), 1)
    FROM gu_region_drops gd
    JOIN gu_types gt ON gt.gu_type_id = gd.gu_type_id
    WHERE gd.region_code = p_region

    UNION ALL

    -- Both ends. The pair is stored once with the alphabetically earlier code
    -- as `origin`, so reading only that column hides every road belonging to
    -- whichever region sorts last.
    SELECT 'road', other.code, other.name, other.emoji,
           rr.travel_hours || 'h away', NULL::numeric
    FROM region_routes rr
    JOIN regions other
      ON other.code = CASE WHEN rr.origin = p_region
                           THEN rr.destination ELSE rr.origin END
    WHERE p_region IN (rr.origin, rr.destination)

    ORDER BY 1, 6 DESC NULLS LAST, 3;
$$;

COMMENT ON FUNCTION region_index(TEXT) IS
    'Everything a region holds: what grows, what is under it, what lives there, what Gu are found there, and every road it touches from either end.';
