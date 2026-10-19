-- 0459_the_three_answers_reach_every_realm
--
-- A Peer Trial is answered with a pull, a hardening or a mend. Across every
-- live cultivator in the game, two can harden, one can mend, and nobody at all
-- can pull - so the most expensive threat in the table, the one that takes 55
-- per cent off the weakest raider, has never once been covered.
--
-- THAT IS NOT BECAUSE THE TECHNIQUES ARE LOCKED. They are on everybody's
-- shelf and they are affordable. It is because of WHERE THEY SIT:
--
--     harden   basic techniques at ranks 1 3 4 5 6 7 8 9
--     mend     basic techniques at ranks     3 4 5   7 8 9
--     pull     basic techniques at ranks         5   7 8 9
--
-- A rank N technique asks for tier N-1 in its path. So the earliest pull in
-- the game wants Master attainment, and a party below realm 5 cannot answer
-- `fixes_on_one` by any route whatsoever. The Trial was built around a choice
-- that most of its players are structurally unable to make.
--
-- AND THE PATHS COMPOUND IT. Every seeded pull lives in illusion, shadow,
-- bone, soul, earth or enslavement. A cultivator walking fire or sword or
-- lightning has no pull at any rank, at any price, ever.
--
-- SO: NINE TECHNIQUES, filling every hole, in the paths cultivators actually
-- walk. Counting live players per path: lightning 12, heaven 10, sword 10,
-- wisdom 9, blood 8, human 7, metal 7, time 7, qi 6, ice 5.
--
--     pull     human 1, sword 2, metal 3, lightning 4, heaven 6
--     mend     qi 1, human 2, time 6
--     harden   ice 2
--
-- Rank 1 asks for tier 0 - Uninitiated - which is no attainment at all. From
-- here every cultivator in the game can buy a pull and a mend for 25 spirit
-- stones, and the remaining ranks give each answer a rung on every realm.
--
-- OWNING ONE IS NOT THE COST, AND THAT IS DELIBERATE. The price of answering
-- a threat is the round you spend doing it instead of hitting the thing, and
-- 0454 sized the creature off what the party puts out when it is ATTACKING. So
-- every supporting round lengthens the fight and buys one more roll on the
-- threat table. The equilibrium is tempo, not spirit stones, which is why
-- these are cheap on purpose rather than cheap by oversight.
--
-- MAGNITUDES CLIMB WITH RANK because a dungeon reads them even though a Trial
-- does not: `dungeon_resolve_round` picks its target with
-- `-ln(random()) / (1 + taunt)`, so a rank 1 pull really does hold less
-- attention than a rank 6 one. The Trial asks only whether an answer was
-- applied, so the low rungs answer a threat fully - what they do not do is
-- make you the one it hits in a dungeon.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy,
     cooldown_turns, grade, effects, description)
VALUES
    -- ---- pull: somebody has to be the one it looks at ----------------------
    ('step_into_the_gap', 'Step Into the Gap', 1, 'utility', 0, 0.0400, 1.0000,
     1, 'basic',
     '{"apply": [{"code": "taunt", "turns": 2, "magnitude": 0.35}]}',
     'No art to it. You put yourself where the thing is already looking and you do not move, and for as long as that holds it is thinking about you instead of about whoever is behind you.'),

    ('bared_edge', 'Bared Edge', 2, 'utility', 0, 0.0600, 1.0000,
     1, 'basic',
     '{"apply": [{"code": "taunt", "turns": 2, "magnitude": 0.45}]}',
     'A blade drawn slowly enough to be watched. Anything that fights for a living knows what an edge means and cannot entirely ignore one being shown to it.'),

    ('the_struck_bell', 'The Struck Bell', 3, 'utility', 0, 0.0900, 1.0000,
     0, 'basic',
     '{"apply": [{"code": "taunt", "turns": 3, "magnitude": 0.55}]}',
     'Metal rung hard enough to be felt in the teeth. It is not a threat and it is not a wound; it is simply the loudest thing in the room, and attention goes where the noise is.'),

    ('first_to_draw_the_sky', 'First to Draw the Sky', 4, 'utility', 0, 0.1200,
     1.0000, 0, 'basic',
     '{"apply": [{"code": "taunt", "turns": 3, "magnitude": 0.65}]}',
     'Lightning answers whoever reaches for it first, and so does everything watching. The cultivator who calls the sky down on themselves is, for those few breaths, the only person present.'),

    ('heaven_marks_the_standing', 'Heaven Marks the Standing One', 6, 'utility',
     0, 0.2200, 1.0000, 0, 'basic',
     '{"apply": [{"code": "taunt", "turns": 3, "magnitude": 0.75}]}',
     'Heaven keeps a short list of who is still upright and makes no secret of it. To be written onto that list is to be the thing every hostile eye in the vicinity finds first.'),

    -- ---- mend: the fight goes long and somebody has to pay for it ----------
    ('even_breath', 'Even Breath', 1, 'support', 0, 0.0500, 1.0000,
     0, 'basic',
     '{"apply": [{"code": "regen", "turns": 2, "magnitude": 0.03}]}',
     'The first thing any master teaches and the first thing anyone forgets when they are frightened. Qi moves the way breath moves, and a body breathing properly closes its own small hurts.'),

    ('hands_that_knit', 'Hands That Knit', 2, 'support', 0, 0.0800, 1.0000,
     0, 'basic',
     '{"apply": [{"code": "regen", "turns": 3, "target": "party", "magnitude": 0.04}]}',
     'Ordinary field work - pressure, a binding, a hand held where the bleeding is. It is the least mystical thing a cultivator can do for another and it is why anybody survives the early realms at all.'),

    ('a_moment_returned', 'A Moment Returned', 6, 'support', 0, 0.2500, 1.0000,
     0, 'basic',
     '{"apply": [{"code": "regen", "turns": 3, "target": "party", "magnitude": 0.08}]}',
     'Not a healing. The wound is given back the moment immediately before it, over and over, and a thing that keeps being handed its own past has a hard time finishing what it started.'),

    -- ---- harden: the one rung the ladder was missing ----------------------
    ('rime_guard', 'Rime Guard', 2, 'defense', 0, 0.0600, 1.0000,
     1, 'basic',
     '{"apply": [{"code": "defence_up", "turns": 2, "magnitude": 0.12}]}',
     'Frost drawn over the skin in a single breath. It cracks the moment it is struck, which is the point - what breaks first is the ice and not the cultivator under it.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, 1
FROM (VALUES
    ('step_into_the_gap',         'human'),
    ('bared_edge',                'sword'),
    ('the_struck_bell',           'metal'),
    ('first_to_draw_the_sky',     'lightning'),
    ('heaven_marks_the_standing', 'heaven'),
    ('even_breath',               'qi'),
    ('hands_that_knit',           'human'),
    ('a_moment_returned',         'time'),
    ('rime_guard',                'ice')
) AS v (code, path_code)
JOIN techniques t ON t.code = v.code;


-- ---------------------------------------------------------------------------
-- Every answer has a rung on every realm, and somebody can reach it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_rank    INTEGER;
    v_answer  TEXT;
    v_have    INTEGER;
    v_before  INTEGER;
    v_after   INTEGER;
    r         RECORD;
BEGIN
    -- The hole this migration exists to fill: no rank 1 to 9 may be without a
    -- basic technique for any of the three answers.
    FOR v_rank IN 1..9 LOOP
        FOREACH v_answer IN ARRAY ARRAY['pull', 'mend', 'harden'] LOOP
            SELECT count(DISTINCT t.technique_id) INTO v_have
            FROM techniques t
            CROSS JOIN LATERAL jsonb_array_elements(
                COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
            WHERE t.created_by IS NULL
              AND t.grade = 'basic'
              AND t.rank <= v_rank
              AND e ->> 'code' = ANY (CASE v_answer
                  WHEN 'pull'   THEN ARRAY['taunt']
                  WHEN 'mend'   THEN ARRAY['regen']
                  WHEN 'harden' THEN ARRAY['defence_up', 'block_up'] END);

            IF v_have = 0 THEN
                RAISE EXCEPTION
                    'a cultivator of realm % still cannot learn a %',
                    v_rank, v_answer;
            END IF;
        END LOOP;
    END LOOP;

    -- And the lowest rung of each really is free of attainment, which is what
    -- makes it reachable by somebody who has not specialised at all.
    FOR r IN
        SELECT t.code, t.name, t.rank FROM techniques t
        WHERE t.code IN ('step_into_the_gap', 'even_breath')
    LOOP
        IF r.rank <> 1 THEN
            RAISE EXCEPTION '% is rank % and was meant to be the free rung',
                r.code, r.rank;
        END IF;
    END LOOP;

    -- Measured against the live roster rather than asserted: how many
    -- cultivators could walk into a Trial able to pull, before and after.
    SELECT count(DISTINCT p.player_id) INTO v_after
    FROM players p
    CROSS JOIN LATERAL technique_shelf(p.player_id) s
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE((SELECT t.effects -> 'apply' FROM techniques t
                  WHERE t.technique_id = s.technique_id), '[]'::jsonb)) e
    WHERE p.deleted_at IS NULL AND s.ready AND e ->> 'code' = 'taunt';

    IF v_after < 10 THEN
        RAISE EXCEPTION
            'only % cultivators can reach a pull, which is barely a change',
            v_after;
    END IF;

    RAISE NOTICE '% cultivators can now learn a pull; it was 3', v_after;

    FOR r IN
        SELECT CASE WHEN e ->> 'code' = 'taunt' THEN 'pull'
                    WHEN e ->> 'code' = 'regen' THEN 'mend'
                    ELSE 'harden' END AS answer,
               count(DISTINCT p.player_id) AS who
        FROM players p
        CROSS JOIN LATERAL technique_shelf(p.player_id) s
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE((SELECT t.effects -> 'apply' FROM techniques t
                      WHERE t.technique_id = s.technique_id), '[]'::jsonb)) e
        WHERE p.deleted_at IS NULL AND s.ready
          AND e ->> 'code' IN ('taunt', 'regen', 'defence_up', 'block_up')
        GROUP BY 1 ORDER BY 1
    LOOP
        RAISE NOTICE '  % : % cultivators could learn one now', r.answer, r.who;
    END LOOP;

    -- Nothing seeded here may be a second copy of an existing code, and every
    -- one of them must have landed on a path.
    IF EXISTS (
        SELECT 1 FROM techniques t
        WHERE t.code IN ('step_into_the_gap', 'bared_edge', 'the_struck_bell',
                         'first_to_draw_the_sky', 'heaven_marks_the_standing',
                         'even_breath', 'hands_that_knit', 'a_moment_returned',
                         'rime_guard')
          AND NOT EXISTS (SELECT 1 FROM technique_paths tp
                          WHERE tp.technique_id = t.technique_id)
    ) THEN
        RAISE EXCEPTION 'one of the new techniques walks no path at all';
    END IF;
END;
$probe$;
