-- 0357_fifteen_more_worms_that_give_you_an_arm
--
-- Sinew had fifteen worms against Body's forty-one and Hide's fifty-two,
-- because the might theme in 0355 matched a narrow slice of a list dominated
-- by weapon and element names. Fifteen options across every Path in the game
-- is not a build, it is a coincidence. Fifteen more, ranks 2 to 9.
--
-- WRITTEN RATHER THAN CONVERTED. 0355 moved existing worms onto Sinew and
-- kept their value exactly; these are new, so they are built to the house
-- rules instead: size equals rank, rarity follows rank, two effects apiece,
-- and no magnitude past three fifths of its ceiling. The second effect varies
-- deliberately - braced, damage reduction, cornered strength, and on three of
-- them a second BODY stat - so that thirty Sinew worms are not one worm
-- printed thirty times, which was the complaint that started all this.
--
-- The arm they give climbs 3, 4, 5, 6 ... 17 against a ceiling of 30, so two
-- of the best reach it and the small ones are a step rather than a solution.
--
-- THE RANK 9 ONE CANNOT CURRENTLY BE OBTAINED, and that is worth stating
-- plainly rather than leaving to be discovered. The bench stops at
-- `gu_max_refinable_rank` = 6. Mortal regions stop at
-- `gu_max_droppable_rank` = 5 and the heavens at
-- `gu_max_immortal_droppable_rank` = 8. So the only rank 9 worms anybody can
-- reach are the two 0351 hung on the heaven bosses, and both of those are
-- spoken for.
--
-- Venerable Strength Gu is built anyway, because it was asked for and because
-- a catalogue entry waiting for a source is exactly how Soul Demon King Gu
-- sat until Black Heaven arrived. It has a recipe and a full effect set and
-- will work the moment something hands it over - a third boss, a raised
-- refining ceiling, or a signature on an Immemorial beast.
--
-- Forward-only. Do not edit once applied.


INSERT INTO gu_types (code, name, path_code, rank, rarity, category, size, emoji, description) VALUES
    ('wild_ox_strength_gu', 'Wild Ox Strength Gu', 'strength', 2, 'uncommon', 'support', 2, '🐛',
     'The arm remembers being an ox. The rest of you does not.'),
    ('iron_arm_gu', 'Iron Arm Gu', 'metal', 2, 'uncommon', 'support', 2, '🐛',
     'Heavier to lift and heavier to be hit by.'),
    ('stone_sinew_gu', 'Stone Sinew Gu', 'earth', 3, 'rare', 'support', 3, '🐛',
     'Tendons that grind rather than stretch.'),
    ('bear_might_gu', 'Bear Might Gu', 'blood', 3, 'rare', 'support', 3, '🐛',
     'Winter strength: slow to wake and difficult to stop.'),
    ('tiger_force_gu', 'Tiger Force Gu', 'strength', 4, 'epic', 'support', 4, '🐛',
     'All of it in the first movement, and the first movement is enough.'),
    ('bronze_muscle_gu', 'Bronze Muscle Gu', 'metal', 4, 'epic', 'support', 4, '🐛',
     'Cast rather than grown. It does not tire because it was never alive.'),
    ('titan_thew_gu', 'Titan Thew Gu', 'earth', 5, 'legendary', 'support', 5, '🐛',
     'Something very large was buried here and some of it is in your arm now.'),
    ('war_ox_gu', 'War Ox Gu', 'strength', 5, 'legendary', 'support', 5, '🐛',
     'Bred for the plough and then for something else.'),
    ('mountain_lifting_gu', 'Mountain Lifting Gu', 'earth', 6, 'mythic', 'support', 6, '🐛',
     'The mountain still weighs what it weighed. You do not.'),
    ('iron_bull_gu', 'Iron Bull Gu', 'metal', 6, 'mythic', 'support', 6, '🐛',
     'It charges whether or not the cultivator carrying it agreed to.'),
    ('giant_sinew_gu', 'Giant Sinew Gu', 'strength', 7, 'divine', 'support', 7, '🐛',
     'Strung from something the histories only mention being afraid of.'),
    ('primordial_arm_gu', 'Primordial Arm Gu', 'bone', 7, 'divine', 'support', 7, '🐛',
     'An arm from before arms were this shape. It works better.'),
    ('heaven_lifting_gu', 'Heaven Lifting Gu', 'heaven', 8, 'unique', 'support', 8, '🐛',
     'The Heavenly Court discourages the practice, which is the recommendation.'),
    ('titan_heart_gu', 'Titan Heart Gu', 'blood', 8, 'unique', 'support', 8, '🐛',
     'It pushes blood the way a river pushes a boat.'),
    ('venerable_strength_gu', 'Venerable Strength Gu', 'strength', 9, 'extreme', 'support', 9, '🐛',
     'The arm a Venerable would recognise as an arm.');


INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT g.gu_type_id, v.effect_code, v.magnitude
FROM (VALUES
    ('wild_ox_strength_gu',   'base_strength',     3.0), ('wild_ox_strength_gu',   'braced',           0.08),
    ('iron_arm_gu',           'base_strength',     4.0), ('iron_arm_gu',           'max_hp',           0.10),
    ('stone_sinew_gu',        'base_strength',     5.0), ('stone_sinew_gu',        'damage_reduction', 0.10),
    ('bear_might_gu',         'base_strength',     6.0), ('bear_might_gu',         'wounded_power',    0.12),
    ('tiger_force_gu',        'base_strength',     7.0), ('tiger_force_gu',        'braced',           0.14),
    ('bronze_muscle_gu',      'base_strength',     8.0), ('bronze_muscle_gu',      'base_hp',          8.0),
    ('titan_thew_gu',         'base_strength',     9.0), ('titan_thew_gu',         'max_hp',           0.20),
    ('war_ox_gu',             'base_strength',    10.0), ('war_ox_gu',             'damage_reduction', 0.18),
    ('mountain_lifting_gu',   'base_strength',    11.0), ('mountain_lifting_gu',   'wounded_power',    0.26),
    ('iron_bull_gu',          'base_strength',    12.0), ('iron_bull_gu',          'braced',           0.20),
    ('giant_sinew_gu',        'base_strength',    13.0), ('giant_sinew_gu',        'base_hp',         14.0),
    ('primordial_arm_gu',     'base_strength',    14.0), ('primordial_arm_gu',     'max_hp',           0.32),
    ('heaven_lifting_gu',     'base_strength',    15.0), ('heaven_lifting_gu',     'damage_reduction', 0.34),
    ('titan_heart_gu',        'base_strength',    16.0), ('titan_heart_gu',        'braced',           0.26),
    ('venerable_strength_gu', 'base_strength',    17.0), ('venerable_strength_gu', 'base_hp',         20.0)
) AS v (code, effect_code, magnitude)
JOIN gu_types g ON g.code = v.code;


-- Chosen the way 0346 chooses: the herb this Path likes best, and the best
-- beast part something within two ranks of it actually drops.
INSERT INTO gu_recipes (gu_type_id, base_material, secondary_material)
SELECT g.gu_type_id, herb.code, part.code
FROM gu_types g
CROSS JOIN LATERAL (
    SELECT m.code FROM materials m
    WHERE m.category = 'gathering'
      AND EXISTS (SELECT 1 FROM region_materials rm WHERE rm.material_code = m.code)
    ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
    LIMIT 1
) AS herb
CROSS JOIN LATERAL (
    SELECT m.code FROM materials m
    WHERE m.category = 'beast'
      AND EXISTS (SELECT 1 FROM creature_drops d
                  JOIN creature_species s ON s.species_id = d.species_id
                  WHERE d.material_code = m.code AND s.rank <= g.rank + 2)
    ORDER BY material_affinity(m.code, g.path_code) DESC, m.code
    LIMIT 1
) AS part
WHERE g.code IN (
    'wild_ox_strength_gu','iron_arm_gu','stone_sinew_gu','bear_might_gu',
    'tiger_force_gu','bronze_muscle_gu','titan_thew_gu','war_ox_gu',
    'mountain_lifting_gu','iron_bull_gu','giant_sinew_gu','primordial_arm_gu',
    'heaven_lifting_gu','titan_heart_gu','venerable_strength_gu');


-- Ranks 2 to 5 in the mortal world, 6 to 8 in the heavens, at the weight a
-- flat worm of that rank already carries there. Rank 9 goes nowhere, because
-- there is nowhere for it to go.
INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
SELECT v.region, g.gu_type_id, v.weight
FROM (VALUES
    ('wild_ox_strength_gu', 'central',      6.74), ('iron_arm_gu',        'northern',    6.74),
    ('stone_sinew_gu',      'eastern',      3.23), ('bear_might_gu',      'southern',    3.23),
    ('tiger_force_gu',      'western',      1.40), ('bronze_muscle_gu',   'central',     1.40),
    ('titan_thew_gu',       'northern',     1.87), ('war_ox_gu',          'eastern',     1.87),
    ('mountain_lifting_gu', 'black_heaven', 9.00), ('iron_bull_gu',       'white_heaven', 9.00),
    ('giant_sinew_gu',      'black_heaven', 4.50), ('primordial_arm_gu',  'white_heaven', 4.50),
    ('heaven_lifting_gu',   'black_heaven', 1.50), ('titan_heart_gu',     'white_heaven', 1.50)
) AS v (code, region, weight)
JOIN gu_types g ON g.code = v.code;


-- ---------------------------------------------------------------------------
-- Thirty worms, a reachable ceiling, and one that is waiting for a door
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n      INTEGER;
    bad    TEXT;
    lo     NUMERIC;
    hi     NUMERIC;
    ceiling NUMERIC := (SELECT cap FROM gu_effects WHERE code = 'base_strength');
BEGIN
    SELECT count(*), min(magnitude), max(magnitude) INTO n, lo, hi
    FROM gu_type_effects WHERE effect_code = 'base_strength';
    IF n < 30 THEN
        RAISE EXCEPTION 'only % worms give Sinew', n;
    END IF;

    -- None of them is a build on its own, the rule every effect is held to.
    IF hi > 0.6 * ceiling THEN
        RAISE EXCEPTION 'the best Sinew worm gives % against a ceiling of %', hi, ceiling;
    END IF;

    -- Two of the best reach the ceiling; the smallest is a step and not a
    -- solution. Both halves matter - a range where everything reaches it is
    -- one worm printed thirty times.
    IF ceil(ceiling / hi) > 2 OR ceil(ceiling / lo) < 6 THEN
        RAISE EXCEPTION
            'the Sinew range is wrong: % to % against a ceiling of %', lo, hi, ceiling;
    END IF;

    -- Every new worm can be made, and every one below rank 9 can be found.
    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_types g
    WHERE g.code IN ('wild_ox_strength_gu','iron_arm_gu','stone_sinew_gu',
                     'bear_might_gu','tiger_force_gu','bronze_muscle_gu',
                     'titan_thew_gu','war_ox_gu','mountain_lifting_gu',
                     'iron_bull_gu','giant_sinew_gu','primordial_arm_gu',
                     'heaven_lifting_gu','titan_heart_gu','venerable_strength_gu')
      AND NOT EXISTS (SELECT 1 FROM gu_recipes r WHERE r.gu_type_id = g.gu_type_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cannot be refined: %', bad;
    END IF;

    SELECT string_agg(g.code, ', ') INTO bad
    FROM gu_types g
    WHERE g.rank <= 8
      AND g.code IN ('wild_ox_strength_gu','iron_arm_gu','stone_sinew_gu',
                     'bear_might_gu','tiger_force_gu','bronze_muscle_gu',
                     'titan_thew_gu','war_ox_gu','mountain_lifting_gu',
                     'iron_bull_gu','giant_sinew_gu','primordial_arm_gu',
                     'heaven_lifting_gu','titan_heart_gu')
      AND NOT EXISTS (SELECT 1 FROM gu_region_drops d WHERE d.gu_type_id = g.gu_type_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are found nowhere: %', bad;
    END IF;

    -- And the rank 9 one really is the only orphan, so the note above is
    -- accurate rather than hopeful.
    IF EXISTS (SELECT 1 FROM gu_region_drops d
               JOIN gu_types g ON g.gu_type_id = d.gu_type_id
               WHERE g.code = 'venerable_strength_gu') THEN
        RAISE EXCEPTION 'the rank 9 worm was given a home after all';
    END IF;

    SELECT count(DISTINCT g.path_code) INTO n
    FROM gu_type_effects ef JOIN gu_types g ON g.gu_type_id = ef.gu_type_id
    WHERE ef.effect_code = 'base_strength';

    RAISE NOTICE
        'Sinew now has % worms from % to % across % Paths',
        (SELECT count(*) FROM gu_type_effects WHERE effect_code = 'base_strength'),
        lo, hi, n;
END;
$probe$;
