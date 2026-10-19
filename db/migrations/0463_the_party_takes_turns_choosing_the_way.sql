-- 0463_the_party_takes_turns_choosing_the_way
--
-- The leader has been the only one who moves. Everybody else watches four
-- greyed-out arrows for the length of a map, which makes a Peer Trial a thing
-- one person plays while two people wait to pick a technique.
--
-- SO THE RIGHT TO STEP GOES ROUND. Each move passes it to the next peer, and
-- on a dark map that matters: the person steering is the person who finds the
-- warden, and next time it will be somebody else.
--
-- IT IS COMPUTED, NOT STORED. The map keeps a turn counter and the mover is
-- the Nth peer still standing. Storing a mover_id would need mending every
-- time somebody is knocked down or leaves the party mid-map; a counter over a
-- live list cannot go stale, because there is nothing in it to go stale.
--
-- THE DOWNED DO NOT STEER. A cultivator at zero is out of the fight, and
-- handing them the map so the party can watch a corpse take a turn is the kind
-- of correctness nobody wants. If everybody is down the map is over anyway, and
-- the fallback returns the first peer rather than nothing so a wipe still
-- resolves through the ordinary path.
--
-- THE LEADER STILL GOES FIRST, because somebody has to, and the leader is the
-- one who gathered the party and walked it in.
--
-- A REFUSED MOVE DOES NOT PASS THE TURN. Walking into the edge of the map
-- costs no step - 0455 - and must not cost you your go either, or the way to
-- grief a party would be to bounce off a wall.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE trial_maps
    ADD COLUMN turn_no INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN trial_maps.turn_no IS
    'How many steps the party has taken, which is what decides whose turn it is to choose the way. See trial_map_mover.';


CREATE OR REPLACE FUNCTION trial_map_mover(p_map_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    -- The Nth peer still standing, counting from the leader. Recomputed every
    -- time rather than remembered, so somebody going down or leaving simply
    -- drops out of the rotation instead of stranding it.
    WITH able AS (
        SELECT m.player_id,
               row_number() OVER (
                   ORDER BY (m.player_id = p.leader_id) DESC, m.player_id
               ) - 1 AS seat,
               count(*) OVER () AS seats
        FROM trial_maps mp
        JOIN trial_parties p ON p.party_id = mp.party_id
        JOIN trial_party_members m ON m.party_id = mp.party_id
        JOIN trial_map_bodies b
          ON b.map_id = mp.map_id AND b.player_id = m.player_id
        WHERE mp.map_id = p_map_id AND b.current_hp > 0
    )
    SELECT COALESCE(
        (SELECT a.player_id FROM able a
         WHERE a.seat = (SELECT mp.turn_no FROM trial_maps mp
                         WHERE mp.map_id = p_map_id) % a.seats),
        -- Nobody standing. The map is about to end; let it end the usual way
        -- rather than refusing every move until somebody notices.
        (SELECT m.player_id FROM trial_maps mp
         JOIN trial_parties p ON p.party_id = mp.party_id
         JOIN trial_party_members m ON m.party_id = mp.party_id
         WHERE mp.map_id = p_map_id
         ORDER BY (m.player_id = p.leader_id) DESC, m.player_id LIMIT 1));
$fn$;

COMMENT ON FUNCTION trial_map_mover(bigint) IS
    'Whose turn it is to choose the way. The right to step goes round the party so a Trial is not one person playing while the others wait.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_map_move' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'trial_map_move is missing';
    END IF;

    -- ---- it is no longer the leader's map alone -------------------------
    anchor := concat(
'    IF (SELECT p.leader_id FROM trial_parties p WHERE p.party_id = mp.party_id)', chr(10),
'       <> p_player_id THEN', chr(10),
'        RAISE EXCEPTION ''the one leading chooses the way''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_map_move no longer guards the way it did';
    END IF;

    body := replace(body, anchor, concat(
'    -- 0463: the right to step goes round the party.', chr(10),
'    IF trial_map_mover(v_map) <> p_player_id THEN', chr(10),
'        RAISE EXCEPTION ''it is %''''s turn to choose the way'',', chr(10),
'            (SELECT pl.discord_name FROM players pl', chr(10),
'             WHERE pl.player_id = trial_map_mover(v_map))', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;'));

    -- ---- and a step passes it on ----------------------------------------
    anchor := concat(
'    UPDATE trial_maps m', chr(10),
'    SET at_x = v_nx, at_y = v_ny, steps_left = GREATEST(0, m.steps_left - 1)', chr(10),
'    WHERE m.map_id = v_map;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_map_move no longer takes its step where it did';
    END IF;

    -- Below the edge-of-map return, so a refused move keeps both the step and
    -- the turn. That ordering is the whole correctness of this patch.
    EXECUTE replace(body, anchor, concat(
'    UPDATE trial_maps m', chr(10),
'    SET at_x = v_nx, at_y = v_ny, steps_left = GREATEST(0, m.steps_left - 1),', chr(10),
'        turn_no = m.turn_no + 1', chr(10),
'    WHERE m.map_id = v_map;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- It goes round, it skips the fallen, and a wall does not cost you your go
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_map   BIGINT;
    v_who   BIGINT;
    v_first BIGINT;
    v_seen  BIGINT[] := ARRAY[]::bigint[];
    v_size  INTEGER;
    mv      RECORD;
    r       RECORD;
    i       INTEGER;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_lead IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;
        PERFORM trial_party_seal(v_lead);

        SELECT count(*) INTO v_size FROM trial_party_members m
        WHERE m.party_id = v_party;
        IF v_size < 2 THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_map := trial_map_open(v_lead);

        -- The leader opens the walking.
        IF trial_map_mover(v_map) <> v_lead THEN
            RAISE EXCEPTION 'the leader does not get the first step';
        END IF;

        -- Nobody else may take it.
        BEGIN
            PERFORM trial_map_move(
                (SELECT m.player_id FROM trial_party_members m
                 WHERE m.party_id = v_party AND m.player_id <> v_lead LIMIT 1),
                'up');
            RAISE EXCEPTION 'somebody moved out of turn';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- Walking into the edge must cost neither a step nor a turn.
        v_first := trial_map_mover(v_map);
        SELECT * INTO mv FROM trial_map_move(v_lead, 'down');
        IF mv.moved THEN
            RAISE EXCEPTION 'the party walked off the bottom of the map';
        END IF;
        IF trial_map_mover(v_map) <> v_first THEN
            RAISE EXCEPTION 'bouncing off a wall passed the turn along';
        END IF;

        -- And then it really does go round. Open ground all the way so no
        -- fight interrupts the rotation being counted.
        UPDATE trial_map_tiles t SET kind = 'way' WHERE t.map_id = v_map;

        FOR i IN 1..v_size LOOP
            v_who := trial_map_mover(v_map);
            v_seen := v_seen || v_who;
            PERFORM trial_map_move(v_who,
                CASE WHEN i % 2 = 1 THEN 'up' ELSE 'down' END);
        END LOOP;

        IF array_length(ARRAY(SELECT DISTINCT unnest(v_seen)), 1) <> v_size THEN
            RAISE EXCEPTION
                'in % steps the map was steered by % different peers',
                v_size, array_length(ARRAY(SELECT DISTINCT unnest(v_seen)), 1);
        END IF;
        IF trial_map_mover(v_map) <> v_first THEN
            RAISE EXCEPTION 'after a full round the turn did not come back';
        END IF;

        RAISE NOTICE 'the way went round all % peers and came back', v_size;

        -- A peer who is down is skipped rather than handed the map.
        UPDATE trial_map_bodies b SET current_hp = 0
        WHERE b.map_id = v_map AND b.player_id = v_first;

        IF trial_map_mover(v_map) = v_first THEN
            RAISE EXCEPTION 'a cultivator at zero was given the next step';
        END IF;

        -- And with everybody down it still answers, so a wipe resolves.
        UPDATE trial_map_bodies b SET current_hp = 0 WHERE b.map_id = v_map;
        IF trial_map_mover(v_map) IS NULL THEN
            RAISE EXCEPTION 'a fallen party has nobody to move at all';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
