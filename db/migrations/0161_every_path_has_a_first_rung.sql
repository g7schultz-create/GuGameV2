-- 0161_every_path_has_a_first_rung
--
-- An audit of all 34 Paths for the lowest rank at which each is reachable.
-- Seventeen of them had no attack a cultivator could actually buy:
--
--   nothing anywhere      Wisdom, Luck, Refinement, Painting, Food
--   nothing below rank 4  Time 4, Space 5, Heaven 6, Star 7, Dream 7,
--                         Enslavement 7, Light 8, Transformation 8,
--                         Formation 8, Rule 9, Qi 9, Human 9
--
-- 0125 checked coverage by asking whether a Path appeared on the roster at
-- all. Space appears - at rank 5, four realms above anybody alive. The whole
-- roster is rank 2, so pashu0 holds 1,476 Space insight and 3,297 Enslavement
-- insight with nothing addressed to either, and Wisdom has four roots and
-- three physiques feeding a Path whose only technique deals no damage.
--
-- A root granting attainment in a Path nothing is written in is a bonus that
-- reads well and does nothing, which is the failure this codebase keeps
-- punishing. So: one sole-Path attack at rank 1 for each of the seventeen -
-- `technique_required_tier(1)` is 0, so a first rung is gated on realm rank
-- and 25 stones and on nothing else - and eight dual-Path moves at ranks 2
-- and 3 so the newly-opened Paths climb rather than stopping at one move.
--
-- Same 2.5x-a-rank curve and the same rule as 0125 and 0127: every one is
-- 'attack', because combat still reads neither `category` nor `effects`.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    -- ---- rank 1: one Path each, nothing borrowed ------------------------
    ('fault_line_read', 'Fault Line Read', 1, 'attack', 118, 0.0600, 1.0000, 0,
     'Every stance has one joint holding the rest of it up. Finding it is the technique; the strike afterwards is a formality.'),

    ('half_step_seam', 'Half-Step Seam', 1, 'attack', 124, 0.0900, 0.9500, 0,
     'The distance between you was correct a moment ago. It is not crossed. It is simply no longer there.'),

    ('stolen_instant', 'Stolen Instant', 1, 'attack', 121, 0.0900, 1.0000, 1,
     'One heartbeat lifted out of the middle of the exchange. They finish a movement they never began.'),

    ('ill_fortune_nudge', 'Ill-Fortune Nudge', 1, 'attack', 138, 0.0800, 0.8000, 0,
     'Nothing is thrown. The ground merely turns out to have been uneven, the grip loose, the timing early.'),

    ('slag_drawing_touch', 'Slag-Drawing Touch', 1, 'attack', 126, 0.1000, 0.9500, 1,
     'What comes out is called impurity. The body it comes out of does not agree that it was spare.'),

    ('three_stone_array', 'Three-Stone Array', 1, 'attack', 120, 0.1000, 1.0000, 1,
     'Three pebbles set down before the fight, which turn the ground between them into a room with one door.'),

    ('yoke_thread', 'Yoke Thread', 1, 'attack', 116, 0.0800, 0.9500, 0,
     'A thread thin enough to be worth ignoring, tied to a limb that will be asked for later.'),

    ('borrowed_claw', 'Borrowed Claw', 1, 'attack', 128, 0.1100, 0.9000, 1,
     'It is a hand again by the time anybody thinks to look at it.'),

    ('crowd_borrowed_fist', 'Crowd-Borrowed Fist', 1, 'attack', 130, 0.1000, 0.9500, 0,
     'Ten thousand people have thrown this punch before. It arrives with all of them standing behind it.'),

    ('fate_tap', 'Fate Tap', 1, 'attack', 113, 0.0700, 1.0000, 0,
     'A small correction to what was going to happen anyway, applied where nobody thought to watch.'),

    ('raw_qi_lance', 'Raw Qi Lance', 1, 'attack', 134, 0.1400, 0.9000, 1,
     'No refinement, no shape and no cleverness. Qi drawn to a point and pushed through.'),

    ('waking_nail', 'Waking Nail', 1, 'attack', 117, 0.0900, 0.9500, 0,
     'Driven in while they are awake, so that it is already waiting the next time they are not.'),

    ('ink_wash_cut', 'Ink Wash Cut', 1, 'attack', 122, 0.1000, 0.9500, 1,
     'One stroke laid across the figure. Where the ink runs, the figure runs with it.'),

    ('bitter_mouthful', 'Bitter Mouthful', 1, 'attack', 112, 0.0700, 1.0000, 0,
     'Fed, not struck. Whatever goes down manages the rest of it without further help.'),

    ('one_word_halt', 'One Word: Halt', 1, 'attack', 125, 0.1100, 0.9000, 1,
     'Not a command and not persuasion. A statement about what is now permitted.'),

    ('noon_glare', 'Noon Glare', 1, 'attack', 131, 0.1000, 0.9000, 0,
     'Light with nothing hidden inside it and nowhere at all to stand out of it.'),

    ('falling_speck', 'Falling Speck', 1, 'attack', 119, 0.0900, 0.9500, 1,
     'Something very far off, arriving on a schedule that was set long before this fight was.'),

    -- ---- rank 2, around 300 ---------------------------------------------
    ('tide_locked_moment', 'Tide-Locked Moment', 2, 'attack', 285, 0.1200, 0.9500, 1,
     'The wave is held at its highest point for precisely as long as it needs to be held there.'),

    ('lantern_array_snap', 'Lantern Array Snap', 2, 'attack', 310, 0.1300, 0.9000, 2,
     'Nine lanterns lit in order, and the tenth position in the array is where the opponent is standing.'),

    ('sleepwalker_step', 'Sleepwalker Step', 2, 'attack', 275, 0.1100, 1.0000, 1,
     'They step aside from something that is not there, into something that is.'),

    ('hollow_pace', 'Hollow Pace', 2, 'attack', 325, 0.1300, 0.9000, 2,
     'Ground is walked that was never laid, and the last stride comes down somewhere inconvenient.'),

    -- ---- rank 3, around 660 ---------------------------------------------
    ('gilded_word_binding', 'Gilded Word Binding', 3, 'attack', 610, 0.1500, 1.0000, 1,
     'The law is written out along a band, and the band is made the size of a throat.'),

    ('starfall_ember', 'Starfall Ember', 3, 'attack', 655, 0.1600, 0.9500, 2,
     'It has been falling since a long time before either of you was named.'),

    ('skinchanger_lunge', 'Skinchanger Lunge', 3, 'attack', 680, 0.1700, 0.9000, 2,
     'Three shapes between the beginning of the movement and the end of it, and the last one has the reach.'),

    ('many_hands_reckoning', 'Many Hands Reckoning', 3, 'attack', 695, 0.1700, 0.9500, 2,
     'One person is only ever one person. Everything here follows from that piece of arithmetic.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('fault_line_read',      'wisdom',         1.0000),
    ('half_step_seam',       'space',          1.0000),
    ('stolen_instant',       'time',           1.0000),
    ('ill_fortune_nudge',    'luck',           1.0000),
    ('slag_drawing_touch',   'refinement',     1.0000),
    ('three_stone_array',    'formation',      1.0000),
    ('yoke_thread',          'enslavement',    1.0000),
    ('borrowed_claw',        'transformation', 1.0000),
    ('crowd_borrowed_fist',  'human',          1.0000),
    ('fate_tap',             'heaven',         1.0000),
    ('raw_qi_lance',         'qi',             1.0000),
    ('waking_nail',          'dream',          1.0000),
    ('ink_wash_cut',         'painting',       1.0000),
    ('bitter_mouthful',      'food',           1.0000),
    ('one_word_halt',        'rule',           1.0000),
    ('noon_glare',           'light',          1.0000),
    ('falling_speck',        'star',           1.0000),

    -- The newly-opened Path leads in every pairing, so the tier gate at ranks
    -- 2 and 3 falls on it: you take its rank 1 move, earn attainment on it,
    -- and that attainment is what admits you to the rung above.
    ('tide_locked_moment',   'time',           0.6000),
    ('tide_locked_moment',   'water',          0.4000),
    ('lantern_array_snap',   'formation',      0.6000),
    ('lantern_array_snap',   'fire',           0.4000),
    ('sleepwalker_step',     'dream',          0.6000),
    ('sleepwalker_step',     'illusion',       0.4000),
    ('hollow_pace',          'space',          0.7000),
    ('hollow_pace',          'wind',           0.3000),

    ('gilded_word_binding',  'rule',           0.6000),
    ('gilded_word_binding',  'metal',          0.4000),
    ('starfall_ember',       'star',           0.6000),
    ('starfall_ember',       'fire',           0.4000),
    ('skinchanger_lunge',    'transformation', 0.7000),
    ('skinchanger_lunge',    'strength',       0.3000),
    ('many_hands_reckoning', 'human',          0.6000),
    ('many_hands_reckoning', 'enslavement',    0.4000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- The check this migration exists for, stated as the invariant rather than as
-- a count of rows added: no Path may be written into the game and then be
-- unreachable by everyone who plays it.

DO $$
DECLARE
    stranded TEXT;
    wrong    INTEGER;
    loose    TEXT;
    tier_one SMALLINT;
BEGIN
    SELECT string_agg(p.name, ', ' ORDER BY p.sort_order) INTO stranded
    FROM paths p
    WHERE NOT EXISTS (
        SELECT 1 FROM technique_paths tp
        JOIN techniques t ON t.technique_id = tp.technique_id
        WHERE tp.path_code = p.code
          AND t.created_by IS NULL
          AND t.category = 'attack'
          AND t.rank <= 3
    );

    IF stranded IS NOT NULL THEN
        RAISE EXCEPTION 'no low-rank attack on: %', stranded;
    END IF;

    -- A first rung nobody can reach is not a first rung. Rank 1 must be free
    -- of any attainment gate, which is what makes seventeen new Paths open
    -- the moment this lands rather than after some other grind.
    tier_one := technique_required_tier(1::smallint);
    IF tier_one <> 0 THEN
        RAISE EXCEPTION 'rank 1 now demands tier %, so the fill is gated', tier_one;
    END IF;

    -- Weights that do not sum to one silently rescale a technique's damage,
    -- and a typo in the second figure of a pair is invisible without this.
    SELECT string_agg(t.code, ', ' ORDER BY t.code) INTO loose
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
    GROUP BY t.technique_id, t.code
    HAVING sum(tp.weight) <> 1.0000;

    IF loose IS NOT NULL THEN
        RAISE EXCEPTION 'path weights do not sum to one on: %', loose;
    END IF;

    -- The ladder check 0125 and 0127 both ran, because it is the one that
    -- catches a mistyped power figure.
    SELECT count(*) INTO wrong
    FROM (
        SELECT t.rank, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) a
    JOIN (
        SELECT t.rank, min(t.base_power) AS lo
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


-- A row that parses is not a row a screen will show. `technique_shelf` is the
-- single authority for what /learn offers, so the fill is only real if the
-- shelf hands these back as buyable - which is asked of a live cultivator
-- here, and of a fixture in the test suite for the case where there is none.

DO $$
DECLARE
    who    BIGINT;
    missed TEXT;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 1
    ORDER BY pc.player_id
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no cultivator to probe the shelf with; tests carry it';
        RETURN;
    END IF;

    -- The seventeen sole-Path moves only. The shelf gates on the DOMINANT
    -- Path of a technique, so a Path that is only ever somebody's junior
    -- partner - Soul under Shadow, Illusion under Dream - is reachable
    -- without being what the gate is measured against. That is a separate
    -- question from this one, and asking it here would make the probe fail
    -- for a reason this migration is not about.
    SELECT string_agg(s.name, ', ' ORDER BY s.name) INTO missed
    FROM technique_shelf(who) s
    WHERE s.code IN (
        'fault_line_read', 'half_step_seam', 'stolen_instant',
        'ill_fortune_nudge', 'slag_drawing_touch', 'three_stone_array',
        'yoke_thread', 'borrowed_claw', 'crowd_borrowed_fist', 'fate_tap',
        'raw_qi_lance', 'waking_nail', 'ink_wash_cut', 'bitter_mouthful',
        'one_word_halt', 'noon_glare', 'falling_speck'
    )
    AND NOT (s.realm_ok AND s.tier_ok);

    IF missed IS NOT NULL THEN
        RAISE EXCEPTION
            'the shelf still bars player % from: %', who, missed;
    END IF;

    IF (SELECT count(*) FROM technique_shelf(who) s
        WHERE s.tech_rank = 1 AND s.category = 'attack') <> 31 THEN
        RAISE EXCEPTION 'rank 1 came back with the wrong number of attacks';
    END IF;
END;
$$;
