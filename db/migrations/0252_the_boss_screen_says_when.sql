-- 0252_the_boss_screen_says_when
--
-- 0251 gave a world beast a stand-off and left the screen unable to mention
-- it. `boss_state` resolves everything /boss draws so no screen has to work
-- anything out for itself, and it does not carry the one number a cultivator
-- who has just spent their burst actually needs.
--
-- A Strike button that stops working with no reason on it is a bug from where
-- the player is standing, whatever the database thinks.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'boss_state';

    old := ' strikes_left integer, my_share numeric, rewarded boolean, slayer text)';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'boss_state no longer returns what it used to';
    END IF;
    src := replace(src, old,
        ' strikes_left integer, my_share numeric, rewarded boolean, slayer text,'
        || ' ready_in numeric)');

    old := '        slayer.discord_name
    FROM boss_encounters e';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'boss_state no longer selects its slayer the old way';
    END IF;
    src := replace(src, old,
'        slayer.discord_name,
        -- Seconds until this cultivator may swing again, or NULL if they may
        -- now. The screen shows a stand-off on the button itself.
        CASE WHEN mine.resumes_at > now()
             THEN EXTRACT(EPOCH FROM (mine.resumes_at - now()))
        END
    FROM boss_encounters e');

    DROP FUNCTION boss_state(BIGINT);
    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who  BIGINT;
    made BIGINT;
    n    INTEGER;
    left_s NUMERIC;
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

        -- Before the burst is spent, there is nothing to wait for.
        SELECT b.ready_in INTO left_s FROM boss_state(who) b;
        IF left_s IS NOT NULL THEN
            RAISE EXCEPTION 'a fresh cultivator is already standing off';
        END IF;

        FOR n IN 1..game_config_value('boss_strike_burst')::integer LOOP
            PERFORM strike_boss(who);
        END LOOP;

        SELECT b.ready_in INTO left_s FROM boss_state(who) b;
        IF left_s IS NULL OR left_s <= 0 THEN
            RAISE EXCEPTION 'the screen cannot say when they may swing again';
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
