-- 0221_holding_a_line_is_the_win
--
-- Three corrections to 0219 and 0220, all of them found by opening a tide and
-- reading the numbers back.
--
-- ONE. THE WIN CONDITION WAS UNREACHABLE ON A SMALL TURNOUT. A tide is sized
-- when it opens, before anybody has swung, so it has to guess from who was
-- about that day - eleven actives produced 572 beasts. If two of the eleven
-- turn up, 572 in two hours is not a fight, it is a foregone loss, and the
-- thing I set out to avoid is exactly what I built.
--
-- So the win is HOLDING THE LINE, not emptying the sea. Survive to the end
-- with fewer than `line_holds` beasts past you and the region is saved. The
-- beast count is no longer a requirement; it is an early finish - clear it and
-- the King rises before the clock does. Two people hold a smaller board
-- because fewer spawn at once, and holding is what they are asked to do.
--
-- Running out of time now means you held. It used to mean you lost.
--
-- TWO. THE KING IS NOT A DUNGEON RUN. 0219 hung a `king_run_id` on the tide
-- and 0220's header said the finale would reuse `dungeon_runs`. Reading
-- `dungeon_begin` again: it charges every raider a key and a purse of stones,
-- wants a leader, and takes invitations by name. All three are wrong for a
-- public event anybody may walk into - nobody should pay a key to defend their
-- own region. The King is a horde encounter with a crown on it, struck the
-- same way everything else in the channel is struck. The column goes rather
-- than sitting there pointing at nothing.
--
-- THREE. `horde_verdict` decided a stale answer was possible. It is computed,
-- not stored, and it now reads the clock the same way everything else does.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The King is one of the beasts
-- ---------------------------------------------------------------------------

ALTER TABLE horde_encounters DROP CONSTRAINT horde_encounters_kind_check;
ALTER TABLE horde_encounters ADD CONSTRAINT horde_encounters_kind_check
    CHECK (kind IN ('normal', 'elite', 'king'));

-- The board reads the column, so it is rebuilt below rather than cascaded
-- away: a CASCADE here would drop the view silently and the next migration to
-- reference it would fail somewhere unrelated.
DROP VIEW horde_board;
DROP INDEX beast_hordes_king_idx;
ALTER TABLE beast_hordes DROP COLUMN king_run_id;

INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_hp_per_hand', 9000,
     'The King''s health per hand on the line, times the tide''s rank. It is '
     'meant to need the room, not to need a week.'),
    ('horde_king_minutes', 25,
     'How long the King stands before it walks into the region. Longer than a '
     'beast by far - it is the last thing anybody has to organise around.'),
    ('horde_chest_one', 2000,
     'Contribution for the first chest. Reachable by somebody who turned up '
     'and swung a few times.'),
    ('horde_chest_two', 12000,
     'Contribution for the second chest.'),
    ('horde_chest_three', 40000,
     'Contribution for the third. A serious afternoon on the line.'),
    ('horde_blessing_hours', 4,
     'How long a saved region is luckier for.'),
    ('horde_scourge_hours', 6,
     'How long an overrun region suffers. Longer than the blessing on '
     'purpose: losing should be felt.');


-- ---------------------------------------------------------------------------
-- Where the tide stands
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_verdict(p_horde_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        WHEN h.status IN ('won', 'lost') THEN h.status

        -- The only failure: enough of them got past.
        WHEN h.beasts_lost >= h.line_holds THEN 'lost'

        -- Cleared the sea early, so the thing behind it comes out.
        WHEN h.beasts_slain >= h.beasts_total
             AND NOT EXISTS (SELECT 1 FROM horde_encounters e
                             WHERE e.horde_id = h.horde_id
                               AND e.kind = 'king' AND e.status = 'slain')
            THEN 'king'

        -- The King came out and went down. That is the best ending there is.
        WHEN EXISTS (SELECT 1 FROM horde_encounters e
                     WHERE e.horde_id = h.horde_id
                       AND e.kind = 'king' AND e.status = 'slain')
            THEN 'won'

        -- Time up with the line unbroken. You held; that was the job.
        WHEN h.ends_at <= now() THEN 'won'

        ELSE 'fighting'
    END
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_verdict(BIGINT) IS
    'Where the tide stands, computed rather than stored. Holding the line to the end is a win; only beasts getting past is a loss.';


-- ---------------------------------------------------------------------------
-- The King
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_king_rise(p_horde_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide  RECORD;
    who   BIGINT;
    pool  BIGINT;
    made  BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Only once, and only when the sea behind it is empty.
    IF EXISTS (SELECT 1 FROM horde_encounters e
               WHERE e.horde_id = p_horde_id AND e.kind = 'king') THEN
        RETURN NULL;
    END IF;
    IF horde_verdict(p_horde_id) <> 'king' THEN
        RETURN NULL;
    END IF;

    -- The biggest thing that lives there, or the biggest thing there is.
    SELECT cs.species_id INTO who
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = tide.region_code AND cs.kind IN ('beast', 'elite')
    ORDER BY cs.rank DESC, cs.base_hp DESC, random()
    LIMIT 1;

    IF who IS NULL THEN
        RETURN NULL;
    END IF;

    pool := GREATEST(1000,
        round(game_config_value('horde_king_hp_per_hand')
              * horde_hands(p_horde_id) * GREATEST(1, tide.rank)))::bigint;

    INSERT INTO horde_encounters
        (horde_id, species_id, kind, hp, max_hp, expires_at)
    VALUES (p_horde_id, who, 'king', pool, pool,
            now() + make_interval(
                mins => game_config_value('horde_king_minutes')::integer))
    RETURNING horde_encounters.encounter_id INTO made;

    UPDATE beast_hordes SET status = 'king' WHERE horde_id = p_horde_id;

    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- Closing it, and what the region carries afterwards
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_settle(p_horde_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    tide RECORD;
    call TEXT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF tide.status IN ('won', 'lost') THEN
        RETURN tide.status;
    END IF;

    PERFORM horde_sweep(p_horde_id);
    call := horde_verdict(p_horde_id);

    IF call NOT IN ('won', 'lost') THEN
        RETURN call;
    END IF;

    -- Whatever is still standing walks off either way; the event is over.
    UPDATE horde_encounters e
    SET status = 'escaped', settled_at = now()
    WHERE e.horde_id = p_horde_id AND e.status = 'alive';

    UPDATE beast_hordes h
    SET status = call, ended_at = now()
    WHERE h.horde_id = p_horde_id;

    IF call = 'won' THEN
        INSERT INTO region_effects (region_code, kind, magnitude, reason, until)
        VALUES
            (tide.region_code, 'gathering_yield', 0.10, 'the tide was held',
             now() + make_interval(hours => game_config_value('horde_blessing_hours')::integer)),
            (tide.region_code, 'material_find', 0.10, 'the tide was held',
             now() + make_interval(hours => game_config_value('horde_blessing_hours')::integer));
    ELSE
        INSERT INTO region_effects (region_code, kind, magnitude, reason, until)
        VALUES
            (tide.region_code, 'gathering_yield', -0.15, 'the region is overrun',
             now() + make_interval(hours => game_config_value('horde_scourge_hours')::integer)),
            (tide.region_code, 'ambush_chance', 0.30, 'the region is overrun',
             now() + make_interval(hours => game_config_value('horde_scourge_hours')::integer));
    END IF;

    RETURN call;
END;
$$;


-- ---------------------------------------------------------------------------
-- Reading it back
-- ---------------------------------------------------------------------------

CREATE VIEW horde_board AS
SELECT h.horde_id, h.region_code, r.name AS region_name, r.emoji AS region_emoji,
       h.rank, h.status, h.beasts_total, h.beasts_slain, h.beasts_lost,
       h.line_holds, h.channel_id, h.board_id,
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


DO $$
DECLARE
    tide BIGINT;
    who  BIGINT;
    n    INTEGER;
    call TEXT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to defend anything; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        tide := horde_open('northern', 3::smallint, NULL);

        -- A fresh tide is being fought, not already decided.
        IF horde_verdict(tide) <> 'fighting' THEN
            RAISE EXCEPTION 'a tide was over before it began: %', horde_verdict(tide);
        END IF;

        -- Running out of time with the line intact is a WIN. This is the whole
        -- correction, and it is the one worth asking the database about.
        UPDATE beast_hordes SET ends_at = now() - interval '1 minute'
        WHERE horde_id = tide;
        IF horde_verdict(tide) <> 'won' THEN
            RAISE EXCEPTION 'holding the line to the end was scored as %',
                horde_verdict(tide);
        END IF;

        call := horde_settle(tide);
        IF call <> 'won' THEN
            RAISE EXCEPTION 'settling a held line gave %', call;
        END IF;

        SELECT count(*) INTO n FROM region_effects
        WHERE region_code = 'northern' AND magnitude > 0 AND until > now();
        IF n = 0 THEN
            RAISE EXCEPTION 'a saved region carries nothing';
        END IF;

        -- And a broken line is a loss, whatever the clock says.
        tide := horde_open('southern', 3::smallint, NULL);
        UPDATE beast_hordes SET beasts_lost = line_holds WHERE horde_id = tide;
        IF horde_verdict(tide) <> 'lost' THEN
            RAISE EXCEPTION 'a broken line was scored as %', horde_verdict(tide);
        END IF;

        call := horde_settle(tide);
        IF call <> 'lost' THEN
            RAISE EXCEPTION 'settling a broken line gave %', call;
        END IF;

        SELECT count(*) INTO n FROM region_effects
        WHERE region_code = 'southern' AND magnitude < 0 AND until > now();
        IF n = 0 THEN
            RAISE EXCEPTION 'an overrun region carries nothing';
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
