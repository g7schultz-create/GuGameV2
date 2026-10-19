-- 0272_the_king_is_fought_in_bursts_and_is_worth_standing_off_for
--
-- Tide 3873's King rose with 637,653 health and was dead inside one twenty
-- second tick. miyuki hit it for 2,292,229 - three and a half times over - and
-- nobody else in a room of seven got to touch the finale.
--
-- Two things were wrong and they are the same two the world beast already
-- solved in 0251.
--
-- IT IS TOO SMALL. The King is counted in beasts of its own region, which is
-- right, but eight of them stopped being a lot. The room deals about 3.8M a
-- beast at the top and 2.6M behind that, so eight average beasts is under a
-- single cultivator's opening exchange. `horde_king_beasts` goes 8 -> 1000,
-- putting it near 80M against a room that lands roughly 33M in a full burst
-- round - three rounds to fell, inside the thirty minutes it stands. It still
-- scales with the room on its own, because `horde_world_scale` already counts
-- hands.
--
-- ANYONE MAY EMPTY THEMSELVES INTO IT AT ONCE. A world beast takes five
-- strikes from a cultivator and then makes them stand off for seven minutes,
-- and that is what turns a race into an event. The King had no such rule, so
-- the fastest cultivator collected it. It has one now, on its own dials -
-- the King stands for thirty minutes rather than an evening, so its stand-off
-- is its own number to tune.
--
-- Bookkeeping goes on `horde_contributions`, which is already the per-player
-- row for a tide, rather than a new table - the same way `king_damage` and
-- `king_chest_taken` live there.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1000,
    description =
        'The King''s health, counted in what the region''s average beast '
        'carries at this tide''s scale. Counted rather than set, so it stays '
        'a fixed multiple of the sea it comes after however the sea is tuned. '
        'Sized against what a room lands in one burst round, not against one '
        'cultivator''s opening blow.'
WHERE key = 'horde_king_beasts';

INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_burst', 5,
     'Strikes a cultivator may land on the King before standing off. Five, '
     'the same as a world beast - the thing that turns the finale from a race '
     'into something the whole room is at.'),
    ('horde_king_cooldown_minutes', 7,
     'How long the stand-off against the King lasts. Its own dial rather than '
     'the world beast''s: the King stands for horde_king_minutes and not an '
     'evening, so the two have to be tuned against each other.');


ALTER TABLE horde_contributions
    ADD COLUMN king_burst_used INTEGER NOT NULL DEFAULT 0
        CHECK (king_burst_used >= 0),
    ADD COLUMN king_resumes_at TIMESTAMPTZ;

COMMENT ON COLUMN horde_contributions.king_burst_used IS
    'Strikes landed on the King since this cultivator last stood off.';
COMMENT ON COLUMN horde_contributions.king_resumes_at IS
    'When they may swing at the King again. NULL while they are still inside a burst.';


CREATE FUNCTION horde_king_ready_at(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
    SELECT c.king_resumes_at
    FROM horde_contributions c
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id
      AND c.king_resumes_at > now();
$$;

COMMENT ON FUNCTION horde_king_ready_at(BIGINT, BIGINT) IS
    'When this cultivator may swing at the King again, or NULL if they may now. The screen reads this so a stand-off is visible before it is refused.';


-- ---------------------------------------------------------------------------
-- The stand-off, inside the strike
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_strike';

    -- ---- a place to hold the burst ---------------------------------------
    old := '    drain  BIGINT := 0;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer declares what it drains';
    END IF;
    src := replace(src, old, old || '
    burst  INTEGER := 0;
    waits  TIMESTAMPTZ;');

    -- ---- refuse a swing that is inside one --------------------------------
    old := '    move := dungeon_default_move(p_player_id);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer picks a move';
    END IF;

    src := replace(src, old,
'    -- The King is fought in bursts. Five swings and then a stand-off, the
    -- same rule a world beast has had since 0251 - without it the finale goes
    -- to whoever types fastest and the rest of the room watches.
    IF met.kind = ''king'' THEN
        SELECT COALESCE(c.king_burst_used, 0), c.king_resumes_at
        INTO burst, waits
        FROM horde_contributions c
        WHERE c.horde_id = met.horde_id AND c.player_id = p_player_id;

        -- Somebody whose first swing of the whole tide is at the King has no
        -- contribution row yet, and SELECT INTO leaves the target NULL rather
        -- than untouched. Without this their burst counts as NULL and the
        -- column refuses it.
        burst := COALESCE(burst, 0);

        IF waits IS NOT NULL AND waits > now() THEN
            RAISE EXCEPTION ''you are standing off - %s before you can swing at the King again'',
                CASE WHEN waits - now() < interval ''1 minute''
                     THEN ceil(EXTRACT(EPOCH FROM (waits - now())))::int || '' seconds''
                     ELSE ceil(EXTRACT(EPOCH FROM (waits - now())) / 60)::int || '' minutes''
                END
                USING ERRCODE = ''check_violation'';
        END IF;

        -- The wait is over, so the burst begins again.
        IF waits IS NOT NULL THEN
            burst := 0;
        END IF;
    END IF;

' || old);

    -- ---- and count it after the blow lands --------------------------------
    old := '    IF met.kind = ''king'' THEN
        UPDATE horde_contributions c
        SET king_damage = c.king_damage + hurt
        WHERE c.horde_id = met.horde_id AND c.player_id = p_player_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer records what the King was dealt';
    END IF;

    src := replace(src, old,
'    IF met.kind = ''king'' THEN
        burst := burst + 1;

        UPDATE horde_contributions c
        SET king_damage     = c.king_damage + hurt,
            king_burst_used = burst,
            -- Spent the burst: stand off. Under it, the wait is cleared so a
            -- cultivator who waited once is not held by the old timestamp.
            king_resumes_at = CASE
                WHEN burst >= game_config_value(''horde_king_burst'')
                THEN now() + make_interval(
                        mins => game_config_value(''horde_king_cooldown_minutes'')::integer)
                ELSE NULL
            END
        WHERE c.horde_id = met.horde_id AND c.player_id = p_player_id;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- A King worth the room turning up for
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide  BIGINT;
    king  BIGINT;
    pool  BIGINT;
    room  BIGINT;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');

        tide := horde_open('northern', 3::smallint, NULL);
        UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = tide;

        king := horde_king_rise(tide);
        IF king IS NULL THEN
            RAISE EXCEPTION 'the King did not rise on a drained sea';
        END IF;

        SELECT max_hp INTO pool FROM horde_encounters WHERE encounter_id = king;

        -- One burst from the strongest cultivator on the server, measured off
        -- tide 3873: miyuki dealt 3,840,944 a beast, five of which is what a
        -- burst now allows. The King is sized against a ROOM, but this is the
        -- number that has to be cleared for it not to die to one person again.
        room := 3840944 * game_config_value('horde_king_burst')::bigint;

        IF pool <= room THEN
            RAISE EXCEPTION
                'the King holds % and one cultivator lands % in a burst',
                pool, room;
        END IF;

        -- And a lone strong cultivator must still be able to fell it inside
        -- the time it stands, or the finale is unwinnable when few turn up.
        IF pool > room * (floor(game_config_value('horde_king_minutes')
                                / game_config_value('horde_king_cooldown_minutes')) + 1) THEN
            RAISE EXCEPTION
                'the King holds % - more than can be dealt in the % minutes it stands',
                pool, game_config_value('horde_king_minutes');
        END IF;

        RAISE NOTICE 'the King holds %, about % bursts from one cultivator',
            pool, round(pool::numeric / room, 1);

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
-- Five swings and then a stand-off
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide  BIGINT;
    king  BIGINT;
    who   BIGINT;
    cap   INTEGER := game_config_value('horde_king_burst')::integer;
    n     INTEGER;
    stood BOOLEAN := FALSE;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');

        tide := horde_open('northern', 2::smallint, NULL);
        UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = tide;
        king := horde_king_rise(tide);

        -- Big enough that the burst runs out before its health does.
        UPDATE horde_encounters SET hp = 999999999999, max_hp = 999999999999
        WHERE encounter_id = king;

        FOR n IN 1..(cap + 1) LOOP
            BEGIN
                -- The encounter first, then the swinger. Getting that round
                -- the wrong way asks the King to hit a player id and reads
                -- back as 'there is nothing there'.
                PERFORM horde_strike(king, who);
            EXCEPTION
                WHEN SQLSTATE '23514' THEN
                    -- Only a stand-off counts. Any other refusal here is a
                    -- broken probe wearing the right error code.
                    IF SQLERRM NOT LIKE '%standing off%' THEN
                        RAISE EXCEPTION
                            'swing % was refused for another reason: %', n, SQLERRM;
                    END IF;
                    IF n <= cap THEN
                        RAISE EXCEPTION
                            'the stand-off began after % swings, not %', n - 1, cap;
                    END IF;
                    stood := TRUE;
            END;
        END LOOP;

        IF NOT stood THEN
            RAISE EXCEPTION
                'a cultivator landed % swings on the King with no stand-off', cap + 1;
        END IF;

        IF (SELECT c.king_burst_used FROM horde_contributions c
            WHERE c.horde_id = tide AND c.player_id = who) <> cap THEN
            RAISE EXCEPTION 'the burst was not counted to its cap';
        END IF;

        IF horde_king_ready_at(tide, who) IS NULL THEN
            RAISE EXCEPTION 'the screen cannot see the stand-off it is in';
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
