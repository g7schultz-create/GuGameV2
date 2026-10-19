-- 0350_a_tide_breaks_where_everyone_can_reach_it
--
-- `horde_open_if_due` chooses where a tide breaks by looking at where people
-- are standing - 'a tide that breaks over an empty corner of the map is a
-- tide nobody goes to'. Since 0337 and 0348 two of the places people can be
-- standing are behind a rank 10 door.
--
-- A tide in a heaven is the same fault the comment is about, turned inside
-- out. The horde is the one event the whole server is meant to turn up to:
-- it is sized against everybody present, it pays chests by contribution, and
-- 0327 went to some trouble to make sure somebody swinging for 122,079 could
-- still earn one beside somebody swinging for 188 million. Opening it
-- somewhere all of them are locked out of would hand the entire event - sea,
-- chests, King and all - to the four cultivators who can walk through the
-- door, and leave everybody else looking at an announcement for a place they
-- cannot reach.
--
-- So the automatic tide picks an OPEN region. `horde_open` still takes any
-- region it is given, so `/dev horde black_heaven` remains available for
-- deliberately running one up there - it is the unattended choice that has to
-- be the safe one.
--
-- An immortal standing in a heaven when the tide breaks is in exactly the
-- position of a cultivator standing in the Northern Plains when it breaks
-- over the Southern Border: twelve hours away, and welcome when they arrive.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    SELECT pl.region_code INTO region', chr(10),
'    FROM player_location pl', chr(10),
'    JOIN players p ON p.player_id = pl.player_id', chr(10),
'    WHERE p.deleted_at IS NULL AND p.discord_id <> 0', chr(10),
'      AND p.last_seen_at > now() - make_interval(', chr(10),
'              mins => game_config_value(''horde_watch_minutes'')::integer)', chr(10),
'    GROUP BY pl.region_code', chr(10),
'    ORDER BY random() * count(*) DESC', chr(10),
'    LIMIT 1;');

    swap := concat(
'    SELECT pl.region_code INTO region', chr(10),
'    FROM player_location pl', chr(10),
'    JOIN players p ON p.player_id = pl.player_id', chr(10),
'    JOIN regions r ON r.code = pl.region_code', chr(10),
'    WHERE p.deleted_at IS NULL AND p.discord_id <> 0', chr(10),
'      AND p.last_seen_at > now() - make_interval(', chr(10),
'              mins => game_config_value(''horde_watch_minutes'')::integer)', chr(10),
'      -- Somewhere the whole server can reach. A tide behind a rank 10 door', chr(10),
'      -- is an event four people are invited to, and the chest ladder was', chr(10),
'      -- built so that the other fourteen could earn one.', chr(10),
'      AND r.min_rank = 1', chr(10),
'    GROUP BY pl.region_code', chr(10),
'    ORDER BY random() * count(*) DESC', chr(10),
'    LIMIT 1;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_open_if_due';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_open_if_due no longer chooses its region where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Where a tide can break on its own, and where it still can be sent
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    body TEXT;
    made BIGINT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_open_if_due';
    IF body NOT LIKE '%r.min_rank = 1%' THEN
        RAISE EXCEPTION 'the automatic tide can still break in a heaven';
    END IF;

    -- ...and a deliberate one still can. Stood back down immediately; this is
    -- a check that the door is not bolted from both sides.
    UPDATE beast_hordes SET status = 'won', ended_at = now()
    WHERE status IN ('fighting', 'king');

    made := horde_open('black_heaven', 5::smallint, NULL);
    IF made IS NULL THEN
        RAISE EXCEPTION 'a tide cannot be sent to a heaven on purpose either';
    END IF;
    DELETE FROM beast_hordes WHERE horde_id = made;

    RAISE NOTICE 'tides break in the open world and can still be sent anywhere';
END;
$probe$;
