-- 0223_a_tide_remembers_where_it_was_fought
--
-- 0219 gave `beast_hordes` two Discord columns and the cog reads neither.
--
-- `channel_id` is written when a tide opens and then ignored: the cog asks
-- `config.horde_channel_id()` every time instead. That is the same failure
-- this project keeps finding - a column that is filled in and never read - and
-- here it has a consequence. Change HORDE_CHANNEL_ID during a live tide and
-- the beasts already standing in the old channel become unreachable, because
-- the loop starts editing messages in a channel they are not in. A tide should
-- be fought where it started.
--
-- So the column stays and the cog reads it, with the config as the fallback
-- for a tide opened before this migration.
--
-- `board_id` was for a pinned scoreboard message that gets edited in place. It
-- is a good idea and it is not built, and an unbuilt idea is better as a note
-- than as a column that every SELECT carries and nothing sets. It goes.
--
-- Forward-only. Do not edit once applied.


DROP VIEW horde_board;
ALTER TABLE beast_hordes DROP COLUMN board_id;

CREATE VIEW horde_board AS
SELECT h.horde_id, h.region_code, r.name AS region_name, r.emoji AS region_emoji,
       h.rank, h.status, h.beasts_total, h.beasts_slain, h.beasts_lost,
       h.line_holds, h.channel_id,
       h.opened_at, h.ends_at, h.ended_at,
       GREATEST(0, h.beasts_total - h.beasts_slain) AS beasts_left,
       GREATEST(0, h.line_holds - h.beasts_lost)    AS line_left,
       horde_verdict(h.horde_id) AS standing,
       horde_hands(h.horde_id)   AS hands,
       (SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = h.horde_id AND e.status = 'alive') AS loose,
       (SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = h.horde_id AND e.kind = 'king' AND e.status = 'alive')
           AS king_up,
       (SELECT count(*) FROM horde_contributions c
        WHERE c.horde_id = h.horde_id) AS defenders
FROM beast_hordes h
JOIN regions r ON r.code = h.region_code;

COMMENT ON COLUMN beast_hordes.channel_id IS
    'Where this tide is being fought. Read by the loop, so moving HORDE_CHANNEL_ID mid-tide does not strand the beasts already standing.';


DO $$
DECLARE
    n INTEGER;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
    WHERE table_name = 'beast_hordes' AND column_name = 'board_id';
    IF n > 0 THEN
        RAISE EXCEPTION 'board_id is still there';
    END IF;

    SELECT count(*) INTO n FROM information_schema.columns
    WHERE table_name = 'horde_board' AND column_name = 'channel_id';
    IF n <> 1 THEN
        RAISE EXCEPTION 'the board cannot say where a tide is being fought';
    END IF;
END;
$$;
