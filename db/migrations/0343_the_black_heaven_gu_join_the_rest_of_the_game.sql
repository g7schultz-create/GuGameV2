-- 0343_the_black_heaven_gu_join_the_rest_of_the_game
--
-- 0341 put a hundred and fifty-one Gu in the catalogue and three rules said
-- they were not properly in the GAME yet. All three were right.
--
-- EVERY GU CAN BE REFINED. `test_every_gu_can_be_refined` - 'Refinement is
-- the intended main source. A Gu with no recipe is a Gu nobody can plan for.'
-- And `test_every_rarity_has_a_price` catches the same hole from the other
-- side, because `gu_recipe_costs` INNER JOINs the recipe, so a Gu without one
-- does not become expensive, it disappears off /refine while still existing.
-- A hundred and fifty-one Gu that can be found and never made is exactly the
-- state that rule was written after.
--
-- The recipes are built out of this place: a Black Heaven herb for the base
-- and one of the deep-country legendaries for the beast half, which is what
-- the schema asks for - `check_recipe_ingredients` wants a gathering material
-- and then a beast one, in that order.
--
-- NO SINGLE GU FINISHES AN EFFECT ON ITS OWN. Thirty-five of the generated
-- magnitudes came out above three fifths of their effect's cap, worst at
-- 0.2495 against a 0.4000 lifesteal ceiling. The rule's reason is the whole
-- reason caps exist: 'One worm that reaches a ceiling by itself makes the
-- other slots decoration.' My generator read its magnitudes off the live
-- AVERAGES at each rank and never checked them against the ceilings those
-- averages sit under - so the rank 8 end of several effects sailed past.
--
-- They are clamped rather than re-rolled. Three fifths is the rule, so the
-- clamp lands at 0.58 of the cap and leaves the ones already under it alone;
-- re-rolling would move a hundred and fifty-one rows to fix thirty-five and
-- make the two migrations disagree about what the others are worth.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A recipe apiece, made of the place they come from
-- ---------------------------------------------------------------------------

INSERT INTO gu_recipes (gu_type_id, base_material, secondary_material)
SELECT g.gu_type_id, h.code, b.code
FROM (
    SELECT gu_type_id, row_number() OVER (ORDER BY code) - 1 AS n
    FROM gu_types WHERE description = 'Found only in Black Heaven.'
) g
JOIN (
    SELECT code, row_number() OVER (ORDER BY code) - 1 AS n,
           count(*) OVER () AS of_them
    FROM materials
    WHERE code IN (SELECT material_code FROM region_materials
                   WHERE region_code = 'black_heaven')
) h ON h.n = g.n % h.of_them
JOIN (
    SELECT code, row_number() OVER (ORDER BY code) - 1 AS n,
           count(*) OVER () AS of_them
    FROM materials
    WHERE code IN ('void_fang', 'immortal_soul_ember', 'sovereign_fang',
                   'primordial_blood', 'abyssal_core', 'dragon_whale_heart')
) b ON b.n = g.n % b.of_them;


-- ---------------------------------------------------------------------------
-- And none of them eats a whole ceiling
-- ---------------------------------------------------------------------------

UPDATE gu_type_effects e
SET magnitude = round(0.58 * f.cap, 4)
FROM gu_effects f, gu_types g
WHERE f.code = e.effect_code
  AND g.gu_type_id = e.gu_type_id
  AND g.description = 'Found only in Black Heaven.'
  AND e.magnitude > 0.6 * f.cap;


-- ---------------------------------------------------------------------------
-- Findable, makeable, and none of them a build on its own
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_types g
    WHERE NOT EXISTS (SELECT 1 FROM gu_recipes r WHERE r.gu_type_id = g.gu_type_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cannot be refined: %', left(bad, 200);
    END IF;

    -- The same hole from the /refine side.
    SELECT count(*) INTO n FROM gu_recipe_costs;
    IF n <> (SELECT count(*) FROM gu_types) THEN
        RAISE EXCEPTION '% Gu have a price and % exist', n,
            (SELECT count(*) FROM gu_types);
    END IF;

    SELECT string_agg(g.code || '/' || e.effect_code, ', ') INTO bad
    FROM gu_type_effects e
    JOIN gu_types g ON g.gu_type_id = e.gu_type_id
    JOIN gu_effects f ON f.code = e.effect_code
    WHERE e.magnitude > 0.6 * f.cap;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still eat a ceiling: %', left(bad, 200);
    END IF;

    -- A recipe of this place: the base grows here.
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_types g JOIN gu_recipes r ON r.gu_type_id = g.gu_type_id
    WHERE g.description = 'Found only in Black Heaven.'
      AND r.base_material NOT IN (SELECT material_code FROM region_materials
                                  WHERE region_code = 'black_heaven');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are refined out of somewhere else: %', left(bad, 200);
    END IF;

    RAISE NOTICE 'every Gu in the game can be made, and none of them is a build';
END;
$probe$;
