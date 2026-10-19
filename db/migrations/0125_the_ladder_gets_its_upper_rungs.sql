-- 0125_the_ladder_gets_its_upper_rungs
--
-- The whole answer to "how do I get a stronger technique" is `/learn`, and
-- `/learn` gates on realm rank. So the reward for crossing a great realm is
-- whatever sits on the next rung - and above rank 3 the rungs were empty:
--
--     rank 1  14        rank 5   0
--     rank 2   2        rank 6   1
--     rank 3   2        rank 7   0
--     rank 4   1        rank 8   0
--                       rank 9   0
--
-- Twenty techniques in the game and fourteen of them rank 1. A cultivator
-- reaching Nascent Soul was crossing a door into a room with one thing in it.
--
-- Twenty-four more, four to a rank, ranks 4 through 9.
--
-- POWER. Anchored on the two that already existed rather than invented:
-- Blazing Heaven Sword is 1,600 at rank 4 and Blood Blade is 10,000 at rank 6,
-- which is 2.5x a rank. Every centre below is that same step continued -
-- 4,000, 25,000, 62,500, 156,250 - so the new content sits on the curve the
-- old content already drew rather than beside it.
--
-- CATEGORY. Every one of these is 'attack', and that is a deliberate
-- restraint rather than a lack of imagination. Combat never reads
-- `techniques.category` and never reads `techniques.effects`; a 'defense'
-- technique with 0 base power spends a turn doing arithmetic on zero. Rooted
-- Stance and Mind's Eye have been that since 0010. Writing eight more of them
-- would be writing eight more screens that lie. When a turn can be spent on
-- something other than damage, that migration can add the moves that do it.
--
-- TYPING. Thirty of the thirty-four Paths now appear on a technique, against
-- fourteen before, and twenty of these twenty-four are dual-Path - a mechanic
-- that has existed since 0004 and had exactly one user. Dual typing is how a
-- cultivator answers a resistance: Frozen Soul Lance is 60% Ice, so a beast
-- that shrugs off cold still takes the other 40%. The four Paths still with no
-- technique are Luck, Refinement, Painting and Food, which are not fought with.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    -- ---- rank 4, around 1,600 ------------------------------------------
    ('frozen_soul_lance', 'Frozen Soul Lance', 4, 'attack', 1550, 0.2000, 0.9500, 2,
     'Ice driven through the place a soul is anchored. The body it leaves behind is unmarked and considerably colder than the room.'),

    ('hundred_anvil_hammer', 'Hundred Anvil Hammer', 4, 'attack', 1750, 0.2400, 0.9000, 3,
     'A hundred strikes folded into one, the way a hundred foldings are folded into a blade. Slow to raise. Not survivable to be under.'),

    ('severing_wind_pass', 'Severing Wind Pass', 4, 'attack', 1500, 0.1800, 1.0000, 1,
     'The wind goes through the gap between two things. Afterwards there are two things where there had been one.'),

    ('grave_root_seizure', 'Grave Root Seizure', 4, 'attack', 1600, 0.2100, 0.9500, 2,
     'Wood does not grow toward light here. It grows toward the warm thing, and it grows fast.'),

    -- ---- rank 5, around 4,000 ------------------------------------------
    ('nine_veins_venom_surge', 'Nine Veins Venom Surge', 5, 'attack', 3800, 0.2200, 0.9500, 2,
     'Nine poisons, each harmless, each the antidote to the one before it. Administered in the wrong order on purpose.'),

    ('earthshear_pillar', 'Earthshear Pillar', 5, 'attack', 4200, 0.2600, 0.9000, 3,
     'A column of bedrock arrives from below at the speed a fist arrives from the side.'),

    ('moths_lantern_flame', 'Moth''s Lantern Flame', 5, 'attack', 3900, 0.2400, 0.9500, 2,
     'A small, patient, beckoning light. Everything with a soul goes to it. Nothing with a soul comes back.'),

    ('drowning_mirror', 'Drowning Mirror', 5, 'attack', 4000, 0.2500, 0.9000, 2,
     'The water shows you standing safely on the bank. You are welcome to keep believing that.'),

    -- ---- rank 6, around 10,000 -----------------------------------------
    ('heavenly_thunder_edict', 'Heavenly Thunder Edict', 6, 'attack', 10500, 0.3000, 0.9000, 4,
     'Not a bolt called down but a sentence read out. The lightning is only how the sentence is delivered.'),

    ('white_bone_procession', 'White Bone Procession', 6, 'attack', 9500, 0.2800, 0.9500, 3,
     'Everything the cultivator has killed walks out in front of them, in order, oldest first.'),

    ('thousand_league_sword_intent', 'Thousand League Sword Intent', 6, 'attack', 10000, 0.3000, 0.9500, 3,
     'The sword stays sheathed. The intent has already gone a thousand leagues and come back, and the sheath was never the point.'),

    ('void_tide_reversal', 'Void Tide Reversal', 6, 'attack', 9800, 0.3200, 0.9000, 4,
     'The distance between the strike and the struck is folded, struck through, and unfolded. The wound was there before the blow.'),

    -- ---- rank 7, around 25,000 -----------------------------------------
    ('star_furnace_collapse', 'Star Furnace Collapse', 7, 'attack', 26000, 0.3200, 0.9000, 4,
     'A star is a furnace holding itself up. Stop it holding itself up.'),

    ('stolen_years', 'Stolen Years', 7, 'attack', 24000, 0.3500, 0.9500, 4,
     'Time taken off one life and put on another. The thief ages backward for as long as it lasts, which is the part that makes it a Path and not a trick.'),

    ('shadow_of_the_hundred_gu', 'Shadow of the Hundred Gu', 7, 'attack', 25000, 0.3000, 0.9500, 3,
     'The shadow is not cast by the cultivator. It is cast by what the cultivator keeps, and it does not always wait to be sent.'),

    ('unbroken_dream_siege', 'Unbroken Dream Siege', 7, 'attack', 23500, 0.3300, 0.9000, 4,
     'A siege conducted entirely in sleep, over years, against a wall the defender does not know they are standing on.'),

    -- ---- rank 8, around 62,500 -----------------------------------------
    ('formation_of_the_falling_sky', 'Formation of the Falling Sky', 8, 'attack', 64000, 0.3500, 0.9000, 5,
     'Nine hundred flags set over eleven years. When the last one goes in the ground the sky is already coming down; the flags were only the appointment.'),

    ('hollow_light_execution', 'Hollow Light Execution', 8, 'attack', 61000, 0.3400, 0.9500, 4,
     'Light with the space taken out of it. It does not travel to the target so much as stop pretending it was ever anywhere else.'),

    ('river_of_transformation', 'River of Transformation', 8, 'attack', 62500, 0.3600, 0.9500, 4,
     'Everything the river touches becomes river. It has been widening for a very long time.'),

    ('red_lotus_rebirth_strike', 'Red Lotus Rebirth Strike', 8, 'attack', 63500, 0.4000, 0.9000, 5,
     'The cultivator burns their own blood to ash and blooms out of it. Whatever was standing in front of them does not get the second half.'),

    -- ---- rank 9, around 156,250 ----------------------------------------
    ('rule_of_the_last_word', 'Rule of the Last Word', 9, 'attack', 156000, 0.4000, 0.9500, 6,
     'Not force. A ruling. The world is informed of how the exchange concluded and the world, having no standing to appeal, complies.'),

    ('eternal_night_descends', 'Eternal Night Descends', 9, 'attack', 158000, 0.4200, 0.9000, 6,
     'Every shadow that has ever been cast arrives at once, having taken the shortest route, which is through the intervening centuries.'),

    ('heavens_will_undone', 'Heaven''s Will Undone', 9, 'attack', 154000, 0.4500, 0.9500, 6,
     'Heaven wants a thing. A cultivator who has come this far wants otherwise. One of the two is going to be disappointed and it has stopped being obvious which.'),

    ('primordial_qi_devourment', 'Primordial Qi Devourment', 9, 'attack', 160000, 0.4500, 0.9000, 7,
     'Not a strike at a body. A strike at the qi holding the body in the habit of being one.');


-- ---------------------------------------------------------------------------
-- Typing
-- ---------------------------------------------------------------------------
-- Weights total exactly 1 per technique, checked at COMMIT by the deferred
-- constraint trigger from 0004 - which is what lets a 0.60/0.40 pair go in one
-- row at a time without the first row failing on a total of 0.60.

INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('frozen_soul_lance',            'ice',            0.6000),
    ('frozen_soul_lance',            'soul',           0.4000),
    ('hundred_anvil_hammer',         'metal',          1.0000),
    ('severing_wind_pass',           'wind',           0.7000),
    ('severing_wind_pass',           'sword',          0.3000),
    ('grave_root_seizure',           'wood',           0.7000),
    ('grave_root_seizure',           'blood',          0.3000),

    ('nine_veins_venom_surge',       'poison',         1.0000),
    ('earthshear_pillar',            'earth',          0.6000),
    ('earthshear_pillar',            'strength',       0.4000),
    ('moths_lantern_flame',          'fire',           0.7000),
    ('moths_lantern_flame',          'soul',           0.3000),
    ('drowning_mirror',              'water',          0.5000),
    ('drowning_mirror',              'illusion',       0.5000),

    ('heavenly_thunder_edict',       'lightning',      0.7000),
    ('heavenly_thunder_edict',       'heaven',         0.3000),
    ('white_bone_procession',        'bone',           0.6000),
    ('white_bone_procession',        'soul',           0.4000),
    ('thousand_league_sword_intent', 'sword',          1.0000),
    ('void_tide_reversal',           'space',          0.6000),
    ('void_tide_reversal',           'water',          0.4000),

    ('star_furnace_collapse',        'star',           0.6000),
    ('star_furnace_collapse',        'fire',           0.4000),
    ('stolen_years',                 'time',           0.5000),
    ('stolen_years',                 'theft',          0.5000),
    ('shadow_of_the_hundred_gu',     'shadow',         0.6000),
    ('shadow_of_the_hundred_gu',     'enslavement',    0.4000),
    ('unbroken_dream_siege',         'dream',          0.7000),
    ('unbroken_dream_siege',         'soul',           0.3000),

    ('formation_of_the_falling_sky', 'formation',      0.6000),
    ('formation_of_the_falling_sky', 'heaven',         0.4000),
    ('hollow_light_execution',       'light',          0.6000),
    ('hollow_light_execution',       'space',          0.4000),
    ('river_of_transformation',      'transformation', 0.7000),
    ('river_of_transformation',      'water',          0.3000),
    ('red_lotus_rebirth_strike',     'blood',          0.5000),
    ('red_lotus_rebirth_strike',     'fire',           0.5000),

    ('rule_of_the_last_word',        'rule',           1.0000),
    ('eternal_night_descends',       'shadow',         0.5000),
    ('eternal_night_descends',       'time',           0.5000),
    ('heavens_will_undone',          'heaven',         0.6000),
    ('heavens_will_undone',          'human',          0.4000),
    ('primordial_qi_devourment',     'qi',             0.5000),
    ('primordial_qi_devourment',     'enslavement',    0.5000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- ---------------------------------------------------------------------------
-- The ladder has to have every rung, and it has to climb
-- ---------------------------------------------------------------------------
-- A typo in a power figure above would be invisible - the game would simply
-- have a rank 8 technique weaker than a rank 5 one and nobody would find out
-- until somebody bought it.

DO $$
DECLARE
    thin  SMALLINT;
    wrong INTEGER;
BEGIN
    SELECT r.rank INTO thin
    FROM generate_series(1, 9) AS r (rank)
    WHERE (SELECT count(*) FROM techniques t
           WHERE t.created_by IS NULL AND t.rank = r.rank) < 2
    ORDER BY r.rank
    LIMIT 1;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'rank % has fewer than two techniques on it', thin;
    END IF;

    -- Every rank's weakest attack must beat the rank below it outright, or
    -- crossing a realm can hand you a downgrade.
    SELECT count(*) INTO wrong
    FROM (
        SELECT t.rank, min(t.base_power) AS lo, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) a
    JOIN (
        SELECT t.rank, min(t.base_power) AS lo, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) b ON b.rank = a.rank + 1
    WHERE b.lo <= a.hi;

    IF wrong > 0 THEN
        RAISE EXCEPTION 'the power ladder overlaps at % rank boundary(s)', wrong;
    END IF;
END;
$$;
