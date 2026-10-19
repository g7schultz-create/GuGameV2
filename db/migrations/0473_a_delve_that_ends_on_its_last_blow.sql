-- 0473_a_delve_that_ends_on_its_last_blow
--
-- A real run, found while clearing somebody's cooldown:
--
--     delve 69 | clearwest | walking | actions_left 0 | deepest 5
--
-- Nought actions and still open. That state should not exist: a delve ends
-- the moment the strength runs out.
--
-- HOW IT IS REACHED. `delve_step` ends a spent delve, but only
--
--     IF d.status = 'walking' AND d.actions_left <= 0
--
-- and the step that spends your last action on a beast tile leaves the run
-- `fighting`, so the check is skipped - correctly, because you are now in a
-- fight and the fight has to resolve. `delve_act` then puts the run back to
-- `walking` when the thing dies and never looks at what is left of you.
--
-- So: walk onto a beast with your last action, kill it, and the delve sits
-- there forever. Nothing can be done with it, and because a cultivator may
-- only have one open at a time, nothing can be done with delving either until
-- somebody notices.
--
-- `delve_flee` already got this right, which is the tell - two ways out of a
-- fight and only one of them remembered that the walk might be over.
--
-- THE CHECK GOES WHERE THE STATUS CHANGES rather than being repeated at the
-- top of `delve_step`. A delve is spent the moment it is spent; finding out
-- about it on the next action would mean the screen shows a map with no moves
-- left on it and invites you to press an arrow.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_act is missing';
    END IF;

    anchor := concat(
'        UPDATE delve_runs r SET status = ''walking'' WHERE r.delve_id = v_delve;', chr(10),
'        PERFORM effect_clear(''delve'', v_delve);');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer returns you to the walk where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        UPDATE delve_runs r SET status = ''walking'' WHERE r.delve_id = v_delve;', chr(10),
'        PERFORM effect_clear(''delve'', v_delve);', chr(10),
'', chr(10),
'        -- 0473: and if that was the last of your strength, the delve is', chr(10),
'        -- over. `delve_step` cannot catch this - the step that began the', chr(10),
'        -- fight left the run `fighting`, so its own check was skipped.', chr(10),
'        IF (SELECT r2.actions_left FROM delve_runs r2', chr(10),
'            WHERE r2.delve_id = v_delve) <= 0 THEN', chr(10),
'            PERFORM delve_end(v_delve, ''spent'');', chr(10),
'        END IF;'));
END;
$patch$;


-- Any run already stranded in that state is closed out. There is one today.
UPDATE delve_runs
SET status = 'done',
    outcome = COALESCE(outcome, 'spent'),
    ended_at = COALESCE(ended_at, now())
WHERE status = 'walking' AND actions_left <= 0;


-- ---------------------------------------------------------------------------
-- No delve is left open with nothing left to spend on it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p    BIGINT;
    v_id   BIGINT;
    at     RECORD;
    f      RECORD;
    r      RECORD;
    v_left INTEGER;
BEGIN
    -- Nothing in the ground is stranded now.
    IF EXISTS (SELECT 1 FROM delve_runs
               WHERE status <> 'done' AND actions_left <= 0) THEN
        RAISE EXCEPTION 'a delve is still open with no strength left in it';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);

        -- The exact shape: the last action is spent walking onto a beast.
        SELECT dr.at_x, dr.at_y INTO at FROM delve_runs dr WHERE dr.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'beast', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;
        UPDATE delve_runs dr SET actions_left = 1 WHERE dr.delve_id = v_id;

        PERFORM delve_step(v_p, 'up');

        SELECT * INTO f FROM delve_runs dr WHERE dr.delve_id = v_id;
        IF f.status <> 'fighting' THEN
            RAISE EXCEPTION 'the last action did not start the fight it stepped into';
        END IF;
        IF f.actions_left <> 0 THEN
            RAISE EXCEPTION 'the step did not spend the last action';
        END IF;

        -- Settle it in one blow and see whether the delve closes behind it.
        UPDATE delve_fights x SET hp = 1
        WHERE x.delve_id = v_id AND x.status = 'fighting';
        UPDATE player_physique pp SET current_hp = pp.max_hp
        WHERE pp.player_id = v_p;

        SELECT * INTO r FROM delve_act(v_p, 'strike', NULL);
        IF r.outcome <> 'slain' THEN
            RAISE EXCEPTION 'the probe could not fell a beast on one point';
        END IF;

        SELECT * INTO f FROM delve_runs dr WHERE dr.delve_id = v_id;
        IF f.status <> 'done' THEN
            RAISE EXCEPTION
                'the delve is % with % actions left after the last blow',
                f.status, f.actions_left;
        END IF;

        RAISE NOTICE
            'the last action bought a kill, and the delve closed as %', f.outcome;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- And walking away from a fight still closes a spent delve, which is the
    -- half that was already right.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_flee'
        AND pronamespace = 'public'::regnamespace) NOT LIKE '%delve_end%' THEN
        RAISE EXCEPTION 'backing away no longer ends a spent delve';
    END IF;
END;
$probe$;
