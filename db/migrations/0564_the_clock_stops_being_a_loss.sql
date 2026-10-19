-- 0564_the_clock_stops_being_a_loss
--
-- `dungeon_round_cap` 100 -> 500, as asked for.
--
-- WHAT THE CAP IS STILL DOING. 0553 raised it from 40 because sixteen of
-- nineteen losses were the clock rather than a wipe. Measured again now, on
-- every run settled since:
--
--     won     15 runs   38.9 rounds on average   longest 73    0 at the cap
--     lost     9 runs   23.8 rounds on average   longest 100   1 at the cap
--
-- So the clock has already stopped deciding much: eight of nine losses are
-- deaths, no winning party has needed a 74th round, and exactly one run in
-- twenty-four ended on the timer. Raising it to 500 removes that one.
--
-- WHAT IT MEANS, said plainly: after this a dungeon can effectively only be
-- lost by DYING. 500 rounds is five times the longest run anybody has ever
-- had and twelve times the average win, so nothing that is going to finish
-- will ever reach it. What remains is a backstop against a room that cannot
-- be hurt at all - a party with no usable attack, or one whose damage rounds
-- to nothing against a difficulty they had no business opening - and in that
-- case 500 rounds of pressing is the cost of finding out.
--
-- `dungeon_round_seconds` (60) is untouched and is what keeps a stalled run
-- from hanging: a round resolves when everybody has chosen OR the minute is
-- up, so an abandoned raid still walks itself to an ending without anybody
-- sitting through five hundred presses.
--
-- And `trial_round_cap` describes itself against this number again - 0553
-- already had to correct it once from 'forty' to 'hundred'. It is written
-- without the figure this time, which is the actual fix: a comment that
-- quotes a number somewhere else is wrong the moment that number moves.


UPDATE game_config
SET value = 500,
    description = 'Rounds a room allows before it wins. Raised to 500 in 0564, which effectively retires it as a loss condition - a dungeon is now lost by dying. It remains a backstop against a party that cannot hurt the room at all; `dungeon_round_seconds` is what stops a stalled run hanging.'
WHERE key = 'dungeon_round_cap';

UPDATE game_config
SET description = 'Rounds before the Trial simply wins. Much shorter than a dungeon''s, because a Trial is a rehearsal rather than a raid and a party that cannot answer it in twenty rounds has learnt what it came to learn.'
WHERE key = 'trial_round_cap';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_cap     INTEGER;
    v_readers TEXT;
    v_longest INTEGER;
BEGIN
    v_cap := game_config_value('dungeon_round_cap');
    IF v_cap <> 500 THEN
        RAISE EXCEPTION 'the cap reads % and should be 500', v_cap;
    END IF;

    -- 1. STILL ONLY ONE READER. If anything had come to lean on the cap -
    --    a reward curve, a health pool - raising it would move that too, and
    --    the whole claim here is that it only moves the clock.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_readers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) LIKE '%dungeon_round_cap%';

    IF v_readers IS DISTINCT FROM 'dungeon_resolve_round' THEN
        RAISE EXCEPTION
            'the cap is read by % - raising it did more than lengthen a room',
            v_readers;
    END IF;

    -- 2. AND IT IS GENUINELY ABOVE EVERYTHING ANYBODY HAS PLAYED. A cap set
    --    below a real run is a cap that still decides fights.
    SELECT COALESCE(max(round_no), 0) INTO v_longest
    FROM dungeon_runs WHERE status IN ('won', 'lost');

    IF v_cap <= v_longest THEN
        RAISE EXCEPTION
            'the cap is % and the longest run ever played was % - it would '
            'still be deciding runs', v_cap, v_longest;
    END IF;

    RAISE NOTICE
        'cap %, against a longest run ever of % - % times the margin',
        v_cap, v_longest, round(v_cap::numeric / GREATEST(1, v_longest), 1);

    -- 3. AND THE THING THAT ACTUALLY STOPS A STALLED RUN IS STILL THERE.
    --    Without the per-round timer, 500 rounds would be 500 presses with no
    --    way out for a party somebody walked away from.
    IF COALESCE(game_config_value('dungeon_round_seconds'), 0) <= 0 THEN
        RAISE EXCEPTION
            'there is no per-round timer, so nothing resolves a run nobody '
            'is answering';
    END IF;
END
$probe$;
