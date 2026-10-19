-- 0251_a_world_boss_is_fought_in_bursts
--
-- A world boss had one limit on it: 125 strikes each, spendable as fast as
-- anybody could press. So the fight is not an event the server turns up to,
-- it is a race won by whoever opened Discord first - and it is over before
-- most of the roster knows it started.
--
-- FIVE, THEN A WAIT. A cultivator gets a burst and then has to stand off while
-- it comes back, which spreads one boss across an evening and across the
-- people who are actually around. The 125 total stays as the ceiling on how
-- much of one beast a single person may claim; this is about the pace.
--
-- The clock starts on the LAST strike of a burst rather than the first, so
-- somebody who takes their five slowly is not punished for it - the wait is
-- the same length however they spend the burst.
--
-- This does not fix the other thing. A sustain build out-heals a world boss
-- outright: Life Steal returns more than the capped bite lands, so the boss
-- cannot kill anybody however long it stands. Slowing the swings makes that
-- take longer rather than making it a fight, and the fix for it is a cap on
-- what one exchange may heal - a separate decision, deliberately not smuggled
-- in here.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE boss_strikes
    ADD COLUMN burst_used SMALLINT    NOT NULL DEFAULT 0 CHECK (burst_used >= 0),
    ADD COLUMN resumes_at TIMESTAMPTZ;

COMMENT ON COLUMN boss_strikes.burst_used IS
    'Strikes taken since the last wait. Reset when the cooldown runs out, which is what makes a burst a burst rather than a budget.';
COMMENT ON COLUMN boss_strikes.resumes_at IS
    'When this cultivator may swing again. Set on the last strike of a burst, so taking the burst slowly costs nothing extra.';


INSERT INTO game_config (key, value, description) VALUES
    ('boss_strike_burst', 5,
     'Strikes a cultivator may land on a world beast before standing off. The '
     'thing that turns the fight from a race into an event.'),
    ('boss_strike_cooldown_minutes', 7,
     'How long the stand-off lasts. Long enough that a boss lives across an '
     'evening and short enough that somebody checking in is not shut out.');


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'strike_boss';

    old := '    SELECT COALESCE(bs.strikes, 0) INTO spent
    FROM (SELECT 1) _ LEFT JOIN boss_strikes bs
      ON bs.encounter_id = live.encounter_id AND bs.player_id = p_player_id;

    IF spent >= allowed THEN
        RAISE EXCEPTION ''you have spent all % of your strikes on this one'', allowed
            USING ERRCODE = ''check_violation'';
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer counts strikes the old way';
    END IF;

    src := replace(src, old,
'    SELECT COALESCE(bs.strikes, 0), COALESCE(bs.burst_used, 0), bs.resumes_at
    INTO spent, in_burst, waits_till
    FROM (SELECT 1) _ LEFT JOIN boss_strikes bs
      ON bs.encounter_id = live.encounter_id AND bs.player_id = p_player_id;

    IF spent >= allowed THEN
        RAISE EXCEPTION ''you have spent all % of your strikes on this one'', allowed
            USING ERRCODE = ''check_violation'';
    END IF;

    -- The stand-off. A burst is five swings and then a wait, so one beast
    -- lasts an evening and the people who turn up later still find it there.
    IF waits_till IS NOT NULL AND waits_till > now() THEN
        RAISE EXCEPTION ''you are standing off - % before you can swing again'',
            CASE WHEN waits_till - now() < interval ''1 minute''
                 THEN ceil(EXTRACT(EPOCH FROM (waits_till - now())))::int
                      || '' seconds''
                 ELSE ceil(EXTRACT(EPOCH FROM (waits_till - now())) / 60)::int
                      || '' minutes'' END
            USING ERRCODE = ''check_violation'';
    END IF;

    -- The wait is over, so the burst begins again.
    IF waits_till IS NOT NULL THEN
        in_burst := 0;
        waits_till := NULL;
    END IF;

    in_burst := in_burst + 1;
    IF in_burst >= game_config_value(''boss_strike_burst'')::integer THEN
        waits_till := now() + make_interval(
            mins => game_config_value(''boss_strike_cooldown_minutes'')::integer);
    END IF;');

    -- The ledger records where the burst stands.
    old := '    ON CONFLICT ON CONSTRAINT boss_strikes_pkey DO UPDATE SET
        strikes     = boss_strikes.strikes + 1,
        damage      = boss_strikes.damage + EXCLUDED.damage,
        taken       = boss_strikes.taken + EXCLUDED.taken,
        last_struck = now()';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer writes its ledger the old way';
    END IF;

    src := replace(src, old,
'    ON CONFLICT ON CONSTRAINT boss_strikes_pkey DO UPDATE SET
        strikes     = boss_strikes.strikes + 1,
        damage      = boss_strikes.damage + EXCLUDED.damage,
        taken       = boss_strikes.taken + EXCLUDED.taken,
        burst_used  = EXCLUDED.burst_used,
        resumes_at  = EXCLUDED.resumes_at,
        last_struck = now()');

    old := '    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage, taken)
    VALUES (live.encounter_id, p_player_id, 1, swung.dealt, back)';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer opens its ledger the old way';
    END IF;

    src := replace(src, old,
'    INSERT INTO boss_strikes
        (encounter_id, player_id, strikes, damage, taken, burst_used, resumes_at)
    VALUES (live.encounter_id, p_player_id, 1, swung.dealt, back,
            in_burst, waits_till)');

    old := '    mine      BIGINT;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'strike_boss no longer declares its tally';
    END IF;
    src := replace(src, old,
'    mine      BIGINT;
    in_burst  INTEGER := 0;
    waits_till TIMESTAMPTZ;');

    EXECUTE src;
END;
$$;


-- What a screen needs to say when somebody is standing off.
CREATE FUNCTION boss_strike_ready_at(p_player_id BIGINT)
RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE
AS $$
    SELECT bs.resumes_at
    FROM boss_strikes bs
    JOIN boss_encounters e ON e.encounter_id = bs.encounter_id
    WHERE bs.player_id = p_player_id AND e.status = 'open'
      AND bs.resumes_at > now()
    ORDER BY bs.resumes_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION boss_strike_ready_at(BIGINT) IS
    'When this cultivator may swing at the standing beast again, or NULL if they may now. So no screen has to work out a burst for itself.';


DO $$
DECLARE
    who   BIGINT;
    burst INTEGER := game_config_value('boss_strike_burst')::integer;
    made  BIGINT;
    n     INTEGER;
    said  TEXT;
    stood BOOLEAN := FALSE;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        UPDATE boss_encounters SET status = 'slain', ended_at = now()
        WHERE status = 'open';

        INSERT INTO boss_encounters
            (species_id, region_code, current_hp, max_hp, status, closes_at)
        SELECT cs.species_id, 'northern', 10000000000, 10000000000, 'open',
               now() + interval '2 hours'
        FROM creature_species cs WHERE cs.kind = 'world' LIMIT 1
        RETURNING encounter_id INTO made;

        UPDATE player_physique SET current_hp = max_hp WHERE player_id = who;
        DELETE FROM boss_strikes WHERE player_id = who;

        -- The burst goes through.
        FOR n IN 1..burst LOOP
            PERFORM strike_boss(who);
        END LOOP;

        -- And the next one does not.
        BEGIN
            PERFORM strike_boss(who);
            RAISE EXCEPTION 'a % strike burst had no wait after it', burst;
        EXCEPTION
            WHEN check_violation THEN
                GET STACKED DIAGNOSTICS said = MESSAGE_TEXT;
                IF said NOT LIKE '%standing off%' THEN
                    RAISE;
                END IF;
                stood := TRUE;
        END;

        IF NOT stood THEN
            RAISE EXCEPTION 'the stand-off never happened';
        END IF;

        -- A screen can say when.
        IF boss_strike_ready_at(who) IS NULL THEN
            RAISE EXCEPTION 'nothing can tell them when they may swing again';
        END IF;

        -- And when the wait is over, the burst begins again.
        UPDATE boss_strikes SET resumes_at = now() - interval '1 second'
        WHERE player_id = who AND encounter_id = made;

        PERFORM strike_boss(who);

        IF (SELECT bs.burst_used FROM boss_strikes bs
            WHERE bs.player_id = who AND bs.encounter_id = made) <> 1 THEN
            RAISE EXCEPTION 'the burst did not start over after the wait';
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
