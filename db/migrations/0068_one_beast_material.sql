-- 0068_one_beast_material
--
-- "1 beast materials on the anvil".
--
-- Every other craft's `skill_buys` line starts at two or three, so none of
-- them has ever had to say "1" and the plural has never been wrong before.
-- Blacksmithing starts at one.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION skill_buys(p_skill TEXT, p_level SMALLINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE p_skill
        WHEN 'gu_refining' THEN
            gu_refine_aux_slots(p_level) || ' auxiliary materials on the bench'
        WHEN 'alchemy' THEN
            alchemy_herb_slots(p_level) || ' herbs in the cauldron'
        WHEN 'refinement' THEN
            refinement_max_pages(p_level) || ' pages in one refinement'
        WHEN 'mining' THEN
            'veins down to tier ' || mining_tier_cap(p_level)
        WHEN 'blacksmithing' THEN
            'tier ' || smith_tier_cap(p_level) || ' pieces, '
            || smith_part_slots(p_level)
            || CASE WHEN smith_part_slots(p_level) = 1
                    THEN ' beast material' ELSE ' beast materials' END
            || ' on the anvil'
    END;
$$;
