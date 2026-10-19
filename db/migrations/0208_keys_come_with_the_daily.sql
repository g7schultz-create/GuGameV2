-- 0208_keys_come_with_the_daily
--
-- 0204 gave the key its own twelve-hour clock. That was one more thing to
-- remember on a screen already full of them, and it paid on a schedule nobody
-- else in the game runs on - /daily is 22 hours precisely so the time does not
-- creep later, and a 12-hour key drifts across it every day.
--
-- So the key comes with the daily instead. Two of them, which is a party of
-- two every day or one run of five every third day, and the streak already
-- rewards coming back.
--
-- The clock is removed, not merely unused: `cooldown_status` reads every
-- `%_cooldown_minutes` in `game_config`, so leaving the config behind would
-- leave a timer in /cooldowns for something that no longer ticks. The
-- `cooldown_display` row goes with it.
--
-- `claim_daily` gains a column, so it is DROPped and recreated rather than
-- replaced - a return type cannot be changed in place.
--
-- Nobody loses a key they already hold.
--
-- Forward-only. Do not edit once applied.


DELETE FROM cooldown_display WHERE action = 'dungeon_key';
DELETE FROM game_config WHERE key = 'dungeon_key_cooldown_minutes';
DELETE FROM game_config WHERE key = 'dungeon_key_per_claim';

INSERT INTO game_config (key, value, description) VALUES
    ('daily_dungeon_keys', 2,
     'Dungeon keys handed over by /daily. Two is a party of two every day, or '
     'one full party of five every third day - and keys trade, so a group can '
     'pool them.');


DROP FUNCTION claim_daily(BIGINT);

CREATE FUNCTION claim_daily(p_player_id BIGINT)
RETURNS TABLE (
    claimed  BOOLEAN,
    jade     BIGINT,
    keys     BIGINT,
    streak   INTEGER,
    longest  INTEGER,
    kept     BOOLEAN,
    next_at  TIMESTAMPTZ,
    held     BIGINT,
    keys_held BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it      player_daily%ROWTYPE;
    wait    INTERVAL := make_interval(hours => game_config_value('daily_cooldown_hours')::int);
    grace   INTERVAL := make_interval(hours => game_config_value('daily_streak_grace_hours')::int);
    run     INTEGER;
    carried BOOLEAN;
    paid    BIGINT;
    cut     BIGINT := game_config_value('daily_dungeon_keys')::bigint;
BEGIN
    SELECT * INTO it FROM player_daily WHERE player_id = p_player_id FOR UPDATE;

    IF FOUND AND it.last_claimed_at + wait > now() THEN
        RETURN QUERY SELECT FALSE, 0::bigint, 0::bigint, it.streak,
                            it.longest_streak, TRUE,
                            it.last_claimed_at + wait, jade_held(p_player_id),
                            COALESCE((SELECT pm.quantity FROM player_materials pm
                                      WHERE pm.player_id = p_player_id
                                        AND pm.material_code = 'dungeon_key'),
                                     0);
        RETURN;
    END IF;

    -- A run continues if the last claim was recent enough; otherwise it starts
    -- again at one. `kept` is what the screen needs to say which happened.
    carried := FOUND AND it.last_claimed_at IS NOT NULL
               AND it.last_claimed_at + grace > now();
    run := CASE WHEN carried THEN it.streak + 1 ELSE 1 END;

    paid := daily_jade_for_streak(run);

    INSERT INTO player_daily
        (player_id, streak, longest_streak, claims, last_claimed_at)
    VALUES (p_player_id, run, run, 1, now())
    ON CONFLICT (player_id) DO UPDATE
        SET streak          = run,
            longest_streak  = GREATEST(player_daily.longest_streak, run),
            claims          = player_daily.claims + 1,
            last_claimed_at = now();

    PERFORM grant_jade(p_player_id, paid, 'daily');

    IF cut > 0 THEN
        PERFORM grant_material(p_player_id, 'dungeon_key', cut);
    END IF;

    RETURN QUERY
    SELECT TRUE, paid, cut, d.streak, d.longest_streak, carried,
           now() + wait, jade_held(p_player_id),
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = 'dungeon_key'), 0)
    FROM player_daily d WHERE d.player_id = p_player_id;
END;
$$;


DO $$
DECLARE
    who    BIGINT;
    before BIGINT;
    got    RECORD;
BEGIN
    -- The key must no longer have a clock of its own, or /cooldowns keeps
    -- promising something that never arrives.
    IF EXISTS (SELECT 1 FROM game_config
               WHERE key = 'dungeon_key_cooldown_minutes') THEN
        RAISE EXCEPTION 'the key still has its own timer';
    END IF;
    IF EXISTS (SELECT 1 FROM cooldown_display WHERE action = 'dungeon_key') THEN
        RAISE EXCEPTION 'the key is still listed among the clocks';
    END IF;

    -- Claimed for real, on somebody whose daily is due, inside a
    -- subtransaction that is thrown away.
    SELECT p.player_id INTO who
    FROM players p
    LEFT JOIN player_daily d ON d.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND (d.last_claimed_at IS NULL
           OR d.last_claimed_at + make_interval(
                  hours => game_config_value('daily_cooldown_hours')::int) <= now())
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody is due a daily; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT COALESCE(pm.quantity, 0) INTO before FROM player_materials pm
        WHERE pm.player_id = who AND pm.material_code = 'dungeon_key';
        before := COALESCE(before, 0);

        SELECT * INTO got FROM claim_daily(who);

        IF NOT got.claimed THEN
            RAISE EXCEPTION 'the daily refused somebody it was due to';
        END IF;

        IF got.keys <> game_config_value('daily_dungeon_keys') THEN
            RAISE EXCEPTION 'the daily handed over % keys rather than %',
                got.keys, game_config_value('daily_dungeon_keys');
        END IF;

        IF (SELECT COALESCE(pm.quantity, 0) FROM player_materials pm
            WHERE pm.player_id = who AND pm.material_code = 'dungeon_key')
           <> before + got.keys THEN
            RAISE EXCEPTION 'the keys were reported but not handed over';
        END IF;

        -- And the jade half still works, which is the part that already did.
        IF got.jade <= 0 THEN
            RAISE EXCEPTION 'the daily stopped paying jade';
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
