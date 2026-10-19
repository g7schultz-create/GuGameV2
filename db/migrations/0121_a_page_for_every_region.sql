-- 0121_a_page_for_every_region
--
-- 0119 answered "where does this come from" and gave the other direction a
-- start: what a region yields, in materials. It stopped there, and it
-- truncated - so the browse half showed the top ten of three lists and never
-- mentioned the four other things a region actually has.
--
-- A gazetteer entry is the complete thing:
--
--     what grows there          region_materials
--     what is under it          region_veins
--     what lives there          creature_regions
--     what Gu are found there   gu_region_drops   <- never shown anywhere
--     how dangerous it is       regions.danger_level  <- never shown anywhere
--     what it is next to        region_routes
--
-- Two of those six have been sitting in the schema unread since they were
-- written. `gu_region_drops` decides where a Gu is found and no screen in the
-- game has ever said so, which means the only way to learn it was to kill
-- things somewhere until one appeared.
--
-- WHY NOT WIDEN `region_finds`. Because its columns are called
-- `material_code` and `rarity`, and a beast is not a material with a rarity.
-- Widening it would have meant putting a species id in a column named for
-- something else - the kind of thing that reads fine on the day and is a trap
-- a year later. `region_index` has neutral names and calls `region_finds` for
-- its material half, so the share arithmetic still lives in exactly one place.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION region_index(p_region TEXT)
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
    -- What grows and what is under it, from the one function that knows how
    -- a weight becomes a share.
    SELECT f.kind, f.material_code, f.material_name, f.emoji,
           COALESCE(f.source_name, f.rarity), f.share
    FROM region_finds(p_region) f
    WHERE f.kind IN ('gather', 'mine')

    UNION ALL

    -- What lives there. Ranked, because a rank is what tells you whether to
    -- walk in.
    -- `creature_species` carries a kind rather than an emoji, and the kind is
    -- the more useful thing to show: a boss and a beast are not the same
    -- encounter however similar their names look.
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

    -- What Gu are found there. Written in 0036 and read by nothing until now.
    SELECT 'gu', gt.code, gt.name, gt.emoji,
           'rank ' || gt.rank || ' ' || gt.rarity,
           round(100 * gd.weight / sum(gd.weight) OVER (), 1)
    FROM gu_region_drops gd
    JOIN gu_types gt ON gt.gu_type_id = gd.gu_type_id
    WHERE gd.region_code = p_region

    UNION ALL

    -- What it is next to, and how far.
    SELECT 'road', rr.destination, r.name, r.emoji,
           rr.travel_hours || 'h away', NULL::numeric
    FROM region_routes rr
    JOIN regions r ON r.code = rr.destination
    WHERE rr.origin = p_region

    ORDER BY 1, 6 DESC NULLS LAST, 3;
$$;

COMMENT ON FUNCTION region_index(TEXT) IS
    'Everything a region holds: what grows, what is under it, what lives there, what Gu are found there, and what it is next to. The material half defers to region_finds so shares are computed once.';
