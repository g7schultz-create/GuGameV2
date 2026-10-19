-- 0512_a_boss_hoard_is_a_second_table_on_purpose
--
-- 0510 gave the Warden of Longevity Heaven an exclusive drop by putting it in
-- `creature_drops` and relying on nothing else dropping it. The standing test
-- rejected that, and its docstring explains why better than I could:
--
--     "It paid out of `creature_drops` - the same table a hunt rolls - so
--      bringing down a rank 9 leviathan yielded three rare beast materials
--      worth two or three Spirit Stones each. `boss_drops` is a second table
--      so that a hunt can never roll these, WHATEVER ELSE CHANGES."
--
-- Exclusivity by a second table rather than by nobody else happening to have
-- the row. My version was exclusive only until somebody added a second
-- creature with the same drop, which is precisely the failure the split was
-- built to make impossible. So the crown fragment moves to `boss_drops`.
--
-- Forward-only. Do not edit once applied.

DELETE FROM creature_drops
WHERE material_code = 'longevity_crown_fragment';

INSERT INTO boss_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, 'longevity_crown_fragment', 1.00, 1, 2
FROM creature_species cs WHERE cs.code = 'longevity_heaven_warden'
ON CONFLICT DO NOTHING;


DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    -- Every world beast and boss holds something out of the hoard that no
    -- hunt can reach, which is the rule the split exists for.
    SELECT string_agg(cs.name, ', ') INTO v_bad
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
      AND NOT EXISTS (
          SELECT 1 FROM boss_drops bd
          WHERE bd.species_id = cs.species_id
            AND NOT EXISTS (
                SELECT 1 FROM creature_drops cd
                WHERE cd.species_id = bd.species_id
                  AND cd.material_code = bd.material_code));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these hold nothing a hunt could not also yield: %', v_bad;
    END IF;

    -- And the crown is out of the hunt table entirely rather than in both.
    IF EXISTS (SELECT 1 FROM creature_drops
               WHERE material_code = 'longevity_crown_fragment') THEN
        RAISE EXCEPTION 'the crown is still rollable by a hunt';
    END IF;

    RAISE NOTICE 'the Warden holds its crown out of the hoard, not the hunt';
END;
$probe$;
