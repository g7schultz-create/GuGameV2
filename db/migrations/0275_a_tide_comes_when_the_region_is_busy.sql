-- 0275_a_tide_comes_when_the_region_is_busy
--
-- `/dev horde` says it plainly: "Hordes are meant to arrive on their own.
-- Nothing schedules them yet, so this is how one starts." Every tide this
-- server has seen was typed by hand, which means they arrive when an owner is
-- awake rather than when a room is busy.
--
-- So a tide comes on its own, and how soon depends on how many people are
-- about. Same shape as `boss_open_if_due`, which the world beast has used
-- since 0153: a rest after the last one, then a roll on every tick.
--
--     chance per tick = horde_spawn_chance_per_hand x people about
--
-- capped, so a crowd does not summon one instantly, and floored on numbers,
-- so a tide never arrives for one person to face alone. With five about that
-- is a tide something like half an hour after the rest ends; with two, an
-- hour and a half. Quiet servers get quieter tides, which is the point.
--
-- WHO COUNTS AS ABOUT is the interesting half. `last_seen_at` was touched only
-- by commands, so a channel could be busy talking and read as empty. The bot
-- watches every message for its "I hunt" prefix already, so 0275's companion
-- change touches that column for anybody who speaks - throttled by the WHERE
-- clause, so it is one write per person per horde_watch_minutes and not one
-- per message.
--
-- The region is drawn from where those people are standing, so the tide comes
-- for somewhere that matters rather than an empty corner of the map. Random
-- among them, so it is never quite predictable.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_rest_hours', 3,
     'Quiet time after a tide ends before another may come. The floor on how '
     'often the event can happen, whoever is about.'),
    ('horde_watch_minutes', 15,
     'How recently somebody must have spoken or acted to count as being about '
     'for a tide. Talking counts: a busy channel is exactly the room a tide '
     'should arrive in.'),
    ('horde_spawn_floor', 2,
     'Nobody gets a tide to themselves. Below this many about, none comes - a '
     'sea sized for one person is not an event, it is a chore.'),
    ('horde_spawn_chance_per_hand', 0.002,
     'Chance per tick, per person about, that the tide breaks. Small because '
     'the tick is twenty seconds: five people make it about even odds inside '
     'half an hour.'),
    ('horde_spawn_chance_cap', 0.02,
     'The most likely a tide may be on any one tick, however busy. A crowd '
     'brings one sooner, not instantly.');


CREATE FUNCTION horde_watchers()
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    -- Anybody who has spoken or acted lately. Not `horde_hands`, which counts
    -- who has swung AT a tide - there is no tide yet to swing at.
    SELECT count(*)::integer
    FROM players p
    JOIN player_character pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND pc.confirmed_at IS NOT NULL
      AND p.last_seen_at > now() - make_interval(
              mins => game_config_value('horde_watch_minutes')::integer);
$$;

COMMENT ON FUNCTION horde_watchers() IS
    'How many cultivators are about right now, counting anyone who has spoken as well as anyone who has acted.';


CREATE FUNCTION horde_next_at()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
    -- NULL while one is running: "when is the next" has no answer until this
    -- one is done, and a timestamp there would be a guess about when.
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM beast_hordes
                     WHERE status IN ('fighting', 'king'))
            THEN NULL
        ELSE COALESCE(max(h.ended_at), 'epoch'::timestamptz)
             + make_interval(hours => game_config_value('horde_rest_hours')::integer)
    END
    FROM beast_hordes h;
$$;

COMMENT ON FUNCTION horde_next_at() IS
    'The earliest another tide may break, or NULL while one is already running. A time, not a promise - what happens after it is a roll.';


CREATE FUNCTION horde_open_if_due(p_channel BIGINT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live    BIGINT;
    due_at  TIMESTAMPTZ;
    watch   INTEGER;
    odds    NUMERIC;
    region  TEXT;
BEGIN
    SELECT horde_id INTO live FROM beast_hordes
    WHERE status IN ('fighting', 'king') LIMIT 1;

    IF live IS NOT NULL THEN
        RETURN NULL;
    END IF;

    due_at := horde_next_at();
    IF due_at IS NULL OR due_at > now() THEN
        RETURN NULL;
    END IF;

    watch := horde_watchers();
    IF watch < game_config_value('horde_spawn_floor') THEN
        RETURN NULL;
    END IF;

    odds := LEAST(game_config_value('horde_spawn_chance_cap'),
                  game_config_value('horde_spawn_chance_per_hand') * watch);

    IF random() >= odds THEN
        RETURN NULL;
    END IF;

    -- Where those people are standing. A tide that breaks over an empty
    -- corner of the map is a tide nobody goes to.
    SELECT pl.region_code INTO region
    FROM player_location pl
    JOIN players p ON p.player_id = pl.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND p.last_seen_at > now() - make_interval(
              mins => game_config_value('horde_watch_minutes')::integer)
    GROUP BY pl.region_code
    ORDER BY random() * count(*) DESC
    LIMIT 1;

    IF region IS NULL THEN
        SELECT code INTO region FROM regions ORDER BY random() LIMIT 1;
    END IF;

    RETURN horde_open(region, NULL, p_channel);
END;
$$;

COMMENT ON FUNCTION horde_open_if_due(BIGINT) IS
    'Rolls for a tide, and opens one if it comes up. Refuses while one runs, inside the rest period, or when too few are about to face it.';


-- ---------------------------------------------------------------------------
-- It refuses for the reasons it is supposed to refuse for
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    made BIGINT;
BEGIN
    BEGIN
        -- ---- while one runs -------------------------------------------------
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');

        made := horde_open('northern', 2::smallint, NULL);

        IF horde_next_at() IS NOT NULL THEN
            RAISE EXCEPTION 'a running tide still promised a next one';
        END IF;
        IF horde_open_if_due(NULL) IS NOT NULL THEN
            RAISE EXCEPTION 'a second tide opened on top of a live one';
        END IF;

        -- ---- inside the rest ------------------------------------------------
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE horde_id = made;

        IF horde_next_at() <= now() THEN
            RAISE EXCEPTION 'a tide that just ended is already due again';
        END IF;
        IF horde_open_if_due(NULL) IS NOT NULL THEN
            RAISE EXCEPTION 'a tide broke inside its own rest';
        END IF;

        -- ---- past the rest, but the room is empty ---------------------------
        UPDATE beast_hordes
        SET ended_at = now() - make_interval(
                hours => game_config_value('horde_rest_hours')::integer + 1)
        WHERE horde_id = made;

        UPDATE players SET last_seen_at = now() - interval '1 day'
        WHERE discord_id <> 0;

        IF horde_watchers() >= game_config_value('horde_spawn_floor') THEN
            RAISE EXCEPTION 'the probe could not empty the room';
        END IF;
        IF horde_open_if_due(NULL) IS NOT NULL THEN
            RAISE EXCEPTION 'a tide came for nobody';
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
-- And it does come, given a busy room and enough tries
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    made  BIGINT;
    tries INTEGER := 0;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won',
            ended_at = now() - make_interval(
                hours => game_config_value('horde_rest_hours')::integer + 1)
        WHERE status IN ('fighting', 'king') OR ended_at IS NULL;

        UPDATE beast_hordes
        SET ended_at = now() - make_interval(
                hours => game_config_value('horde_rest_hours')::integer + 1)
        WHERE ended_at > now() - make_interval(
                hours => game_config_value('horde_rest_hours')::integer + 1);

        -- A room that is unmistakably busy.
        UPDATE players SET last_seen_at = now() WHERE discord_id <> 0;

        IF horde_watchers() < game_config_value('horde_spawn_floor') THEN
            RAISE NOTICE 'not enough cultivators exist to prove this; tests carry it';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- The odds are per tick and small on purpose, so this rolls until it
        -- lands rather than asserting on one throw.
        WHILE made IS NULL AND tries < 20000 LOOP
            made  := horde_open_if_due(NULL);
            tries := tries + 1;
        END LOOP;

        IF made IS NULL THEN
            RAISE EXCEPTION
                'twenty thousand ticks of a busy room and no tide ever broke';
        END IF;

        RAISE NOTICE 'a tide broke after % ticks', tries;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
