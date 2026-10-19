-- 0281_a_leader_may_close_the_door_they_opened
--
-- A party that gathers and then changes its mind has no way to say so. The
-- run sits in `forming` until `dungeon_forming_minutes` runs out and the
-- sweeper closes it - ten minutes during which none of them may open another,
-- because `my_run` finds this one and every screen refuses.
--
-- So the leader may close it. There is nothing to give back: `dungeon_begin`
-- is what takes the keys, the stones and the jade, and a forming run has not
-- reached it. That is also why this stops at the door.
--
-- A RUN THAT HAS BEGUN IS NOT CANCELLABLE, deliberately. Everybody in it has
-- paid a key by then, and a leader who could end it would be spending four
-- other people's keys on a whim. Nor is one needed: a fighting run resolves
-- on the round clock whether or not anybody speaks, so it cannot stall the
-- way a forming one can.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION dungeon_cancel(p_run_id BIGINT, p_player_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    run RECORD;
BEGIN
    SELECT * INTO run FROM dungeon_runs
    WHERE run_id = p_run_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such run' USING ERRCODE = 'check_violation';
    END IF;
    IF run.leader_id <> p_player_id THEN
        RAISE EXCEPTION 'only the one who opened the door may close it'
            USING ERRCODE = 'check_violation';
    END IF;
    IF run.status = 'fighting' THEN
        RAISE EXCEPTION
            'the party is already through the door - everybody has paid a key'
            USING ERRCODE = 'check_violation';
    END IF;
    IF run.status <> 'forming' THEN
        RAISE EXCEPTION 'that run is already over'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Nothing to hand back. `dungeon_begin` takes the keys and it has not run.
    UPDATE dungeon_runs SET status = 'abandoned', ended_at = now()
    WHERE run_id = p_run_id;
END;
$$;

COMMENT ON FUNCTION dungeon_cancel(BIGINT, BIGINT) IS
    'The leader closing a door nobody went through. Refuses once the party has begun, because by then everyone has paid a key and it would not be the leader''s to spend.';


-- ---------------------------------------------------------------------------
-- Who may, and when
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    leader BIGINT;
    other  BIGINT;
    run    BIGINT;
    room   SMALLINT;
BEGIN
    SELECT p.player_id INTO leader FROM players p
    JOIN player_character pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;

    SELECT p.player_id INTO other FROM players p
    JOIN player_character pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 AND p.player_id <> leader
    LIMIT 1;

    SELECT dungeon_id INTO room FROM dungeons ORDER BY realm_rank LIMIT 1;

    IF leader IS NULL OR other IS NULL OR room IS NULL THEN
        RAISE NOTICE 'not enough cultivators or rooms; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE dungeon_runs SET status = 'abandoned', ended_at = now()
        WHERE status IN ('forming', 'fighting');

        run := dungeon_open(leader, room, 'normal');

        -- Not somebody else's to close.
        BEGIN
            PERFORM dungeon_cancel(run, other);
            RAISE EXCEPTION 'a stranger closed the leader''s door';
        EXCEPTION
            WHEN SQLSTATE '23514' THEN NULL;
        END;

        PERFORM dungeon_cancel(run, leader);

        IF (SELECT status FROM dungeon_runs WHERE run_id = run) <> 'abandoned' THEN
            RAISE EXCEPTION 'the run is still open after being cancelled';
        END IF;

        -- And the leader is free to open another at once, which is the whole
        -- point of the button.
        run := dungeon_open(leader, room, 'normal');
        IF run IS NULL THEN
            RAISE EXCEPTION 'cancelling did not release the leader';
        END IF;

        -- Once through the door it is nobody's to call off.
        UPDATE dungeon_runs SET status = 'fighting' WHERE run_id = run;
        BEGIN
            PERFORM dungeon_cancel(run, leader);
            RAISE EXCEPTION 'a run that had begun was cancelled anyway';
        EXCEPTION
            WHEN SQLSTATE '23514' THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
