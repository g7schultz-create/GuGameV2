-- 0573_a_delve_ends_when_the_strength_does
--
-- sylvrime is standing in the Heavenly Court in a delve that cannot be played
-- and cannot be finished: status `fighting`, `actions_left` 0. It has been
-- that way since 07:52 this morning.
--
-- `delve_act` ends a combat round in one of three branches, and only two of
-- them look at whether the cultivator has any strength left:
--
--     f.hp <= 0     the beast is down   -> 0473 added the check here
--     v_hp <= 0     you are down        -> ends the delve outright
--     ELSE          the fight goes on   -> NOTHING
--
-- So spending the last action on a round that fells neither of you leaves the
-- run open at zero. `delve_step` cannot save it either, for the reason 0473
-- already wrote down beside its own fix: 'the step that began the fight left
-- the run `fighting`, so its own check was skipped.'
--
-- 0473 found this, fixed the branch in front of it, and did not look at the
-- one below. The test that caught it has been asserting the state of the live
-- table all along - `test_no_delve_is_left_open_with_nothing_to_spend` - and
-- it went red the moment a real player landed in it.
--
-- The third branch gets the same ending, and it is the honest one: you ran out
-- of strength in the middle of a fight, so the delve is 'spent' exactly as it
-- would be if you had run out between them.
--
-- And sylvrime's run is closed, because a migration that fixes the cause and
-- leaves the person stuck has not finished the job.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    ELSE
        v_next := delve_draw_move();
        UPDATE delve_fights x
        SET round_no = x.round_no + 1, coming = v_next
        WHERE x.fight_id = f.fight_id;
        PERFORM effect_tick(''delve'', v_delve);
    END IF;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'delve_act does not carry the fight on where it did';
    END IF;

    patched := replace(src, anchor,
'    ELSE
        v_next := delve_draw_move();
        UPDATE delve_fights x
        SET round_no = x.round_no + 1, coming = v_next
        WHERE x.fight_id = f.fight_id;
        PERFORM effect_tick(''delve'', v_delve);

        -- AND HERE TOO (0573). 0473 put this check on the branch above - the
        -- beast going down - and left this one, where the fight simply carries
        -- on. Spending the last action on a round that fells nobody left the
        -- run `fighting` at zero actions: unplayable, unfinishable, and a real
        -- cultivator was standing in one.
        IF (SELECT r2.actions_left FROM delve_runs r2
            WHERE r2.delve_id = v_delve) <= 0 THEN
            -- The RUN ends ''spent''; the FIGHT is ''fled''. `delve_fights`
            -- admits slain, fled or died and nothing else - walking away
            -- because there is no strength left is still walking away.
            UPDATE delve_fights x
            SET status = ''done'', outcome = ''fled'', ended_at = now(),
                coming = NULL
            WHERE x.fight_id = f.fight_id;
            PERFORM delve_end(v_delve, ''spent'');
            PERFORM effect_clear(''delve'', v_delve);
        END IF;
    END IF;');

    IF patched = src THEN
        RAISE EXCEPTION 'the delve_act patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- And let the people who are already stuck out
-- ---------------------------------------------------------------------------

DO $free$
DECLARE
    r RECORD;
    n INTEGER := 0;
BEGIN
    FOR r IN
        SELECT d.delve_id, d.player_id FROM delve_runs d
        WHERE d.status <> 'done' AND d.actions_left <= 0
    LOOP
        -- 'fled' rather than 'spent': that is the fight's own vocabulary.
        UPDATE delve_fights x
        SET status = 'done', outcome = 'fled', ended_at = now(), coming = NULL
        WHERE x.delve_id = r.delve_id AND x.status <> 'done';

        PERFORM delve_end(r.delve_id, 'spent');
        PERFORM effect_clear('delve', r.delve_id);
        n := n + 1;
    END LOOP;

    IF n > 0 THEN
        RAISE NOTICE '% stranded delve(s) closed as spent', n;
    END IF;
END
$free$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n   INTEGER;
    v_src TEXT;
BEGIN
    -- 1. NOBODY IS STRANDED ANY MORE. The same assertion the suite makes of
    --    the live table, made here so the migration cannot claim a fix it did
    --    not deliver.
    SELECT count(*) INTO v_n FROM delve_runs
    WHERE status <> 'done' AND actions_left <= 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% delve(s) are still open with nothing to spend', v_n;
    END IF;

    -- 2. AND ALL THREE BRANCHES NOW LOOK. Counted rather than eyeballed: the
    --    whole fault was one branch of three being left out, and a count is
    --    what would have caught that.
    SELECT pg_get_functiondef(oid) INTO v_src FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;

    v_n := (length(v_src)
            - length(replace(v_src, 'r2.actions_left FROM delve_runs r2', '')))
           / length('r2.actions_left FROM delve_runs r2');

    IF v_n < 2 THEN
        RAISE EXCEPTION
            'delve_act checks the remaining strength % time(s); the branch '
            'where the fight carries on needs one of its own', v_n;
    END IF;

    -- The `died` branch ends the run unconditionally and needs no check, so
    -- two is the right number rather than three.
    RAISE NOTICE
        'delve_act now checks for spent strength in % place(s)', v_n;
END
$probe$;
