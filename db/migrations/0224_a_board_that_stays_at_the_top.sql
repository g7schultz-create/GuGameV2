-- 0224_a_board_that_stays_at_the_top
--
-- 0223 dropped `board_id` on the grounds that an unbuilt idea is better as a
-- note than as a column nothing sets. The idea is being built, so the column
-- comes back. That is the sequence working rather than a mistake: a column
-- arrives when the thing that reads it does, and in between it is not there
-- pretending.
--
-- The board is one message in the horde channel, posted when the first beast
-- is, edited every tick and never re-sent. That last part is the whole design:
-- a channel filling with beast messages needs one fixed thing in it that
-- always says where the line is, and a scoreboard that posted itself every
-- twenty seconds would be the noisiest thing in the room.
--
-- WHO IS WINNING IS NOT WHO GETS PAID. `horde_roll` already ranks defenders
-- and the chests are thresholds - the ranking pays nobody. The board shows it
-- because a defence with nobody keeping score is a chore, and it shows the
-- chest each person has EARNED beside it so the ranking is never mistaken for
-- the reward.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE beast_hordes ADD COLUMN board_id BIGINT;

COMMENT ON COLUMN beast_hordes.board_id IS
    'The one message in the channel that is edited rather than re-sent. Null until the first tick posts it; read every tick after that.';


DROP VIEW horde_board;

CREATE VIEW horde_board AS
SELECT h.horde_id, h.region_code, r.name AS region_name, r.emoji AS region_emoji,
       h.rank, h.status, h.beasts_total, h.beasts_slain, h.beasts_lost,
       h.line_holds, h.channel_id, h.board_id,
       h.opened_at, h.ends_at, h.ended_at,
       GREATEST(0, h.beasts_total - h.beasts_slain) AS beasts_left,
       GREATEST(0, h.line_holds - h.beasts_lost)    AS line_left,
       EXTRACT(EPOCH FROM (h.ends_at - now()))      AS seconds_left,
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


-- The top of the roll, with what each of them has earned beside it - so the
-- ranking is never mistaken for the reward.
CREATE FUNCTION horde_leaders(p_horde_id BIGINT, p_top INTEGER DEFAULT 5)
RETURNS TABLE (
    standing      BIGINT,
    player_id     BIGINT,
    discord_name  TEXT,
    contribution  BIGINT,
    beasts_slain  INTEGER,
    elites_slain  INTEGER,
    chests_earned SMALLINT
)
LANGUAGE sql STABLE
AS $$
    SELECT r.standing, r.player_id, r.discord_name, r.contribution,
           r.beasts_slain, r.elites_slain, r.chests_earned
    FROM horde_roll r
    WHERE r.horde_id = p_horde_id
    ORDER BY r.standing, r.discord_name
    LIMIT GREATEST(1, p_top);
$$;


DO $$
DECLARE
    tide BIGINT;
    who  BIGINT;
    n    INTEGER;
BEGIN
    SELECT count(*) INTO n FROM information_schema.columns
    WHERE table_name = 'horde_board' AND column_name = 'board_id';
    IF n <> 1 THEN
        RAISE EXCEPTION 'the board cannot remember its own message';
    END IF;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to rank; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        tide := horde_open('northern', 2::smallint, 1);

        -- An empty roll is a board with nothing on it, not an error.
        SELECT count(*) INTO n FROM horde_leaders(tide, 5);
        IF n <> 0 THEN
            RAISE EXCEPTION 'a tide nobody has fought has % leaders', n;
        END IF;

        INSERT INTO horde_contributions (horde_id, player_id, damage_dealt)
        VALUES (tide, who, game_config_value('horde_chest_two')::bigint);

        SELECT count(*) INTO n FROM horde_leaders(tide, 5);
        IF n <> 1 THEN
            RAISE EXCEPTION 'one defender produced % rows', n;
        END IF;

        IF (SELECT l.chests_earned FROM horde_leaders(tide, 5) l LIMIT 1) < 2 THEN
            RAISE EXCEPTION 'the board would show the wrong chest count';
        END IF;

        IF (SELECT l.standing FROM horde_leaders(tide, 5) l LIMIT 1) <> 1 THEN
            RAISE EXCEPTION 'the only defender is not first';
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
