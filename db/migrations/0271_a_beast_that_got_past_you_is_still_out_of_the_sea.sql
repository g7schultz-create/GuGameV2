-- 0271_a_beast_that_got_past_you_is_still_out_of_the_sea
--
-- The King rises when `beasts_slain >= beasts_total`, and a beast that times
-- out in the channel is marked escaped: its worth is added to `beasts_lost`
-- and never to `beasts_slain`. So an escape puts its share of the sea BACK in
-- the pool to be sent again, and the finale waits on it.
--
-- One at a time that is a delay. At the tail of a tide it is a stall: the sea
-- is down to its last few, /fight horde already refuses because
-- `horde_sea_left` counts what is standing in the channel, and the only thing
-- between the room and the King is catching one boar before a twenty-minute
-- timer. Miss it and the count goes backwards.
--
-- A beast that got past you is out of the sea. It is in the region now, it has
-- already been counted against `line_holds` - which is what an escape is
-- supposed to cost - and making the room kill it a second time is charging
-- twice for one mistake. So the sea is worked through when everything in it
-- has been either killed or let past:
--
--     the sea is done when  beasts_slain + beasts_lost >= beasts_total
--
-- Four readers have to agree on that or they pull against each other: the
-- verdict that raises the King, the sea the gauntlet draws from, the spawner
-- that decides whether to send another, and the board that tells the room how
-- many are left.
--
-- What does NOT change is what an escape costs. `beasts_lost >= line_holds` is
-- still the only way to lose a tide, and every escape still counts fully
-- toward it. This makes an escape stop DELAYING the finale; it does not make
-- it free.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION horde_sea_left(p_horde_id BIGINT)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    -- Killed, let past, or standing in the channel right now - all three are
    -- out of the pool. Only what is left has yet to be sent.
    SELECT GREATEST(0, h.beasts_total - h.beasts_slain - h.beasts_lost
        - COALESCE((SELECT sum(e.worth)::integer FROM horde_encounters e
                    WHERE e.horde_id = h.horde_id AND e.status = 'alive'), 0))
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_sea_left(BIGINT) IS
    'What the tide has left to send. A beast that got past the line is out of the sea, not back in it - it is counted against line_holds instead.';


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    -- ---- the King rises on the whole sea, not only the slain half ---------
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_verdict';

    old := '        WHEN h.beasts_slain >= h.beasts_total THEN ''king''';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_verdict no longer raises the King on a drained sea';
    END IF;
    src := replace(src, old,
'        WHEN h.beasts_slain + h.beasts_lost >= h.beasts_total THEN ''king''');
    EXECUTE src;

    -- ---- and the spawner stops when it is drained -------------------------
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_spawn';

    old := '    IF tide.beasts_slain + packed >= tide.beasts_total THEN';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_spawn no longer guards against overdrawing the sea';
    END IF;
    src := replace(src, old,
'    IF tide.beasts_slain + tide.beasts_lost + packed >= tide.beasts_total THEN');

    old := '                  GREATEST(1, tide.beasts_total - tide.beasts_slain - packed))::smallint;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_spawn no longer clamps a pack to what is left';
    END IF;
    src := replace(src, old,
'                  GREATEST(1, tide.beasts_total - tide.beasts_slain
                              - tide.beasts_lost - packed))::smallint;');

    EXECUTE src;
END;
$$;


-- The room is told the same number the King is waiting on.
CREATE OR REPLACE VIEW horde_board AS
SELECT h.horde_id,
       h.region_code,
       r.name AS region_name,
       r.emoji AS region_emoji,
       h.rank,
       h.status,
       h.beasts_total,
       h.beasts_slain,
       h.beasts_lost,
       h.line_holds,
       h.channel_id,
       h.board_id,
       h.opened_at,
       h.ends_at,
       h.ended_at,
       GREATEST(0, h.beasts_total - h.beasts_slain - h.beasts_lost) AS beasts_left,
       GREATEST(0, h.line_holds - h.beasts_lost) AS line_left,
       EXTRACT(epoch FROM h.ends_at - now()) AS seconds_left,
       horde_verdict(h.horde_id) AS standing,
       horde_hands(h.horde_id) AS hands,
       (SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = h.horde_id AND e.status = 'alive') AS loose,
       (SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = h.horde_id AND e.kind = 'king' AND e.status = 'alive') AS king_up,
       (SELECT count(*) FROM horde_contributions c
        WHERE c.horde_id = h.horde_id) AS defenders
FROM beast_hordes h
JOIN regions r ON r.code = h.region_code;


-- ---------------------------------------------------------------------------
-- An escape at the tail no longer holds the finale
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide  BIGINT;
    beast BIGINT;
    call  TEXT;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');

        tide := horde_open('northern', 2::smallint, NULL);

        -- Everything but one beast's worth is already dealt with.
        UPDATE beast_hordes SET beasts_slain = beasts_total - 12
        WHERE horde_id = tide;

        INSERT INTO horde_encounters
            (horde_id, species_id, kind, hp, max_hp, worth, expires_at)
        VALUES (tide,
                (SELECT species_id FROM creature_species WHERE kind = 'beast' LIMIT 1),
                'normal', 100, 100, 12, now() - interval '1 second')
        RETURNING encounter_id INTO beast;

        IF horde_verdict(tide) <> 'fighting' THEN
            RAISE EXCEPTION 'the tide was already decided before the beast fled';
        END IF;

        -- It times out rather than being caught.
        PERFORM horde_sweep(tide);

        IF (SELECT status FROM horde_encounters WHERE encounter_id = beast)
           <> 'escaped' THEN
            RAISE EXCEPTION 'the probe did not manage to let its beast past';
        END IF;

        call := horde_verdict(tide);
        IF call <> 'king' THEN
            RAISE EXCEPTION
                'one escape at the tail still leaves the tide at %', call;
        END IF;

        -- The sea is done, so nothing more is sent.
        IF horde_sea_left(tide) <> 0 THEN
            RAISE EXCEPTION 'the sea still has % in it', horde_sea_left(tide);
        END IF;
        IF horde_spawn(tide) IS NOT NULL THEN
            RAISE EXCEPTION 'a drained tide sent another beast';
        END IF;

        -- And it still cost the line what it always cost.
        IF (SELECT beasts_lost FROM beast_hordes WHERE horde_id = tide) <> 12 THEN
            RAISE EXCEPTION 'the escape stopped counting against the line';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- ---------------------------------------------------------------------------
-- Losing the line is still the only way to lose
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide BIGINT;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');

        tide := horde_open('northern', 2::smallint, NULL);

        -- Enough got past to break the line, before the sea is worked through.
        UPDATE beast_hordes
        SET beasts_lost = line_holds, beasts_slain = 0
        WHERE horde_id = tide;

        IF horde_verdict(tide) <> 'lost' THEN
            RAISE EXCEPTION
                'a broken line reads as %, not lost', horde_verdict(tide);
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
