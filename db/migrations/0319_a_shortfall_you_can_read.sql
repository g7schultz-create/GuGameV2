-- 0319_a_shortfall_you_can_read
--
-- `pseudo_immortal_shortfall` from 0317 returns the truth in an unreadable
-- shape. Its clauses each began with a space and were concatenated, so the
-- anvil said:
--
--     still wants:a Blacksmith of 85 3 more kind(s) of tier 8 metal 3 of
--     each tier 8 metal (fewest is 0).
--
-- Three requirements run together as one sentence with no separators, and
-- the reader has to guess where each ends. The fix is to collect clauses in
-- an array and join them, which is what should have been written first.
--
-- Two other things go with it:
--
--   THE LEVEL IS READ, NOT TYPED. 0317 wrote 'a Blacksmith of 85' as a
--   literal in the message while the actual gate lives in profession_steps.
--   Those are two copies of one number, and a migration that moved the rung
--   would leave the anvil confidently quoting the old one.
--
--   AN EMPTY ARRAY IS NOT AN EMPTY SHORTFALL. array_to_string over no
--   clauses gives '', and '' IS NOT NULL - so a fully stocked anvil would
--   have read as short and `forge` would have capped every piece at 7
--   forever. NULLIF is doing real work here, not tidying.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION pseudo_immortal_shortfall(
    p_ores TEXT[], p_ore_qtys INTEGER[],
    p_parts TEXT[], p_part_qtys INTEGER[],
    p_level SMALLINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    kinds   INTEGER;
    fewest  INTEGER;
    fodder  NUMERIC;
    gate    INTEGER;
    want_k  INTEGER := game_config_value('pseudo_immortal_kinds')::integer;
    want_e  INTEGER := game_config_value('pseudo_immortal_each')::integer;
    want_f  NUMERIC := game_config_value('pseudo_immortal_fodder');
    short   TEXT[] := ARRAY[]::text[];
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

    -- The level the ladder actually asks for. One copy of the number.
    SELECT max(level_required) INTO gate
    FROM profession_steps WHERE ladder = 'forge_tier';

    IF smith_tier_cap(p_level) < 8 THEN
        short := short || ('a Blacksmith of ' || gate);
    END IF;

    IF kinds < want_k THEN
        short := short || ((want_k - kinds) || ' more kind'
                 || CASE WHEN want_k - kinds = 1 THEN '' ELSE 's' END
                 || ' of tier 8 metal');
    END IF;

    -- Only worth saying once some tier 8 metal is on the anvil. With none at
    -- all the line above has already said it, and 'you have 0 of one' about
    -- metal you do not have is a second way of saying nothing.
    IF kinds > 0 AND fewest < want_e THEN
        short := short || (want_e || ' of each tier 8 metal (you have '
                 || fewest || ' of one)');
    END IF;

    IF fodder < want_f THEN
        short := short || (round(want_f - fodder)
                 || ' more potency of other material');
    END IF;

    RETURN NULLIF(array_to_string(short, ', '), '');
END;
$fn$;


-- ---------------------------------------------------------------------------
-- It reads as a list, it quotes the real gate, and enough is still enough
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    said TEXT;
    gate INTEGER := (SELECT max(level_required) FROM profession_steps
                     WHERE ladder = 'forge_tier');
BEGIN
    -- A bare anvil: no metal, no smith, no fodder. Three clauses, two commas.
    said := pseudo_immortal_shortfall(
        ARRAY[]::text[], ARRAY[]::integer[],
        ARRAY[]::text[], ARRAY[]::integer[], 1::smallint);
    IF said IS NULL THEN
        RAISE EXCEPTION 'an empty anvil was not short of anything';
    END IF;
    IF (length(said) - length(replace(said, ', ', ''))) / 2 <> 2 THEN
        RAISE EXCEPTION 'three requirements did not come back as a list: %', said;
    END IF;
    IF said NOT LIKE '%a Blacksmith of ' || gate || '%' THEN
        RAISE EXCEPTION 'the message does not quote the ladder: %', said;
    END IF;
    RAISE NOTICE 'a bare anvil reads: %', said;

    -- With metal but not enough of it, the count is named rather than the
    -- absence.
    said := pseudo_immortal_shortfall(
        ARRAY['glacier_heart_adamant','sun_core_adamant','leviathan_spine_ore'],
        ARRAY[3, 3, 1],
        ARRAY['beast_blood'], ARRAY[700], 85::smallint);
    IF said IS NULL OR said NOT LIKE '%you have 1 of one%' THEN
        RAISE EXCEPTION 'the thin seam was not named: %', said;
    END IF;
    RAISE NOTICE 'a thin seam reads: %', said;

    -- And the full anvil still comes back NULL, not the empty string that
    -- would have capped every piece in the game at tier 7.
    said := pseudo_immortal_shortfall(
        ARRAY['glacier_heart_adamant','sun_core_adamant','leviathan_spine_ore'],
        ARRAY[3, 3, 3],
        ARRAY['beast_blood','bone_fragment'], ARRAY[350, 350],
        85::smallint);
    IF said IS NOT NULL THEN
        RAISE EXCEPTION 'a full anvil was still short: %', said;
    END IF;
    RAISE NOTICE 'a full anvil is short of nothing, and says so with NULL';
END;
$$;
