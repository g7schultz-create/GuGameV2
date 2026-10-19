-- 0346_recipes_that_do_not_fight_themselves
--
-- 0343 gave the hundred and fifty-one Black Heaven Gu a recipe apiece by
-- walking round the ingredient lists in step - Gu number n takes herb n mod
-- 40 and beast part n mod 6. It satisfied 'every Gu can be refined' and broke
-- two older rules that are about whether a recipe is any GOOD.
--
--   A RECIPE MUST NOT FIGHT ITSELF. Refining starts at 50 harmony and adds
--   the affinity of each ingredient to the Gu's Path, and a pair the Path
--   rejects puts the floor under the failure threshold - so the attempt
--   cannot succeed and eats the materials. Hundred Men Gu floored at 17
--   against a threshold of 25. 0038 shipped exactly one of these and this
--   rule has guarded the table ever since; a round robin put dozens back.
--
--   AND ITS BEAST HALF MUST BE REACHABLE. 'Whatever a recipe costs, something
--   within a few ranks of it has to drop the ingredient.' Forty-six of them
--   asked a rank 5 or 6 Gu for a part that only falls off a rank 8 or 9
--   beast, which is 0038's 270-bones-off-a-leviathan all over again.
--
-- So the recipes are CHOSEN rather than dealt: for each Gu, the Black Heaven
-- herb its Path likes best, and the best-liked beast part among those
-- something within two ranks actually drops. Picking by affinity is what the
-- first rule is asking for, and filtering by dropper rank is the second.
--
-- A COMMON CULTIVATION HERB. `a_cultivation_herb_grows_in_every_region` wants
-- one in every region, and its reason is worth quoting: the five Paths that
-- brew cultivation held 10.1 of gatherable weight against physique's 186,
-- 'with not one common among them. Cultivation is the bar every cultivator is
-- trying to move, and it was the rarest thing to gather in the game.'
--
-- None of the forty is common - a heaven does not do common - so this adds a
-- forty-first, and it is the one thing here that is not on the list I was
-- given. It is a star-Path moss of no value whatsoever, and it exists so that
-- an immortal standing in Black Heaven can brew the one kind of pill every
-- cultivator wants without walking back to the mortal world for the moss.
--
-- Forward-only. Do not edit once applied.


-- The forty-first, and the humblest thing in the heaven.
INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
VALUES ('starless_moss', 'Starless Moss', 'gathering', 'common', 'star', '🌾',
        'Grows where starlight fell and did not stay. Worth nothing, and in '
        'every cauldron in Black Heaven.');

UPDATE materials SET tier = 1 WHERE code = 'starless_moss';

INSERT INTO region_materials (region_code, material_code, weight)
VALUES ('black_heaven', 'starless_moss', 7.0);


-- An index on the foreign key 0344 added. Every FK column in this schema
-- carries one; a bare one turns a delete of the referenced row into a scan.
CREATE INDEX creature_species_signature_gu_idx
    ON creature_species (signature_gu_type_id)
    WHERE signature_gu_type_id IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Chosen, not dealt
-- ---------------------------------------------------------------------------

DELETE FROM gu_recipes r
USING gu_types g
WHERE g.gu_type_id = r.gu_type_id
  AND g.description = 'Found only in Black Heaven.';

INSERT INTO gu_recipes (gu_type_id, base_material, secondary_material)
SELECT g.gu_type_id, herb.code, part.code
FROM gu_types g
-- The herb of this place its Path likes most.
CROSS JOIN LATERAL (
    SELECT m.code
    FROM region_materials rm
    JOIN materials m ON m.code = rm.material_code
    WHERE rm.region_code = 'black_heaven'
    ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
    LIMIT 1
) AS herb
-- And the best-liked beast part something within two ranks of it drops.
CROSS JOIN LATERAL (
    SELECT m.code
    FROM materials m
    WHERE m.category = 'beast'
      AND EXISTS (
          SELECT 1 FROM creature_drops d
          JOIN creature_species s ON s.species_id = d.species_id
          WHERE d.material_code = m.code AND s.rank <= g.rank + 2
      )
    ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
    LIMIT 1
) AS part
WHERE g.description = 'Found only in Black Heaven.';


-- ---------------------------------------------------------------------------
-- Every recipe can succeed, and every ingredient can be got
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    threshold NUMERIC := game_config_value('gu_refine_failure_threshold');
    worst     RECORD;
    bad       TEXT;
BEGIN
    SELECT c.gu_code,
           50 + material_affinity(c.base_material, c.path_code)
              + material_affinity(c.secondary_material, c.path_code) AS floor
    INTO worst
    FROM gu_recipe_costs c ORDER BY floor LIMIT 1;

    IF worst.floor < threshold + 15 THEN
        RAISE EXCEPTION '% floors at %, and an empty bench would destroy it',
            worst.gu_code, worst.floor;
    END IF;

    SELECT string_agg(t.gu_code, ', ') INTO bad
    FROM (
        SELECT c.gu_code FROM gu_recipe_costs c
        JOIN creature_drops d ON d.material_code = c.secondary_material
        JOIN creature_species s ON s.species_id = d.species_id
        GROUP BY c.gu_code, c.rank
        HAVING min(s.rank) > c.rank + 2
    ) t;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are gated behind something unreachable: %',
            left(bad, 200);
    END IF;

    -- And the common cultivation herb is actually there.
    IF NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = 'black_heaven'
          AND ppk.kind = 'cultivation' AND m.rarity = 'common'
    ) THEN
        RAISE EXCEPTION 'Black Heaven still grows no common cultivation herb';
    END IF;

    RAISE NOTICE
        'the worst recipe in the game floors at % against a threshold of %',
        worst.floor, threshold;
END;
$probe$;
