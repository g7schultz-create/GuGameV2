-- 0279_put_back_the_swing_i_retyped
--
-- 0277 needed two new columns on `player_swing`, which cannot be added to a
-- RETURNS TABLE in place, so it dropped and recreated the function. It should
-- have lifted the existing body with `pg_get_functiondef` and patched it, the
-- way every other migration in this schema changes a function. Instead the
-- body was retyped, and three lines of it were retyped WRONG:
--
--     mom := mom * LEAST(p_turn, game_config_value('momentum_turn_cap'))
--     ... game_config_value('cornered_threshold') ...
--     wounded := player_stat(p_player_id, 'cornered')
--
-- None of those exist. There is no `momentum_turn_cap` and no
-- `cornered_threshold` in `game_config`, and the stat is `wounded_power`, not
-- `cornered`. `game_config_value` raises on an unknown key, so every swing in
-- every lane - hunt, dungeon, gauntlet, channel, boss - raised instead of
-- landing. Combat was down.
--
-- What 0225 actually wrote, restored verbatim:
--
--   * momentum is capped by the EFFECT's own cap out of `gu_effects`, not by
--     a config dial, and it multiplies `p_turn - 1` so the first turn of a
--     fight has none of it;
--   * a body counts as cornered at half health, written as
--     `p_player_hp * 2 <= p_player_max_hp` rather than through a threshold
--     dial;
--   * and the stat it reads is `wounded_power`.
--
-- The pet lines from 0277 and the share cap from 0278 are kept as they were.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'player_swing';

    old := '    mom := player_stat(p_player_id, ''momentum'');
    IF mom > 0 AND p_turn > 0 THEN
        mom := mom * LEAST(p_turn, game_config_value(''momentum_turn_cap''));
    ELSE
        mom := 0;
    END IF;

    IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL
       AND p_player_max_hp > 0
       AND p_player_hp::numeric / p_player_max_hp
           <= game_config_value(''cornered_threshold'') THEN
        wounded := player_stat(p_player_id, ''cornered'');
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing does not hold the retyped block';
    END IF;

    src := replace(src, old,
'    -- Momentum builds with the fight and a cornered body hits harder. Both
    -- join the external stack, which is a sum. A fight with no turn count -
    -- a horde beast, a dungeon round - simply has no momentum to build.
    mom := player_stat(p_player_id, ''momentum'');
    IF mom > 0 AND p_turn > 0 THEN
        mom := LEAST((SELECT ef.cap FROM gu_effects ef WHERE ef.code = ''momentum''),
                     mom * GREATEST(0, p_turn - 1));
    ELSE
        mom := 0;
    END IF;

    -- And a body that is not being tracked cannot be cornered.
    IF p_player_hp IS NOT NULL AND p_player_max_hp IS NOT NULL
       AND p_player_hp * 2 <= p_player_max_hp THEN
        wounded := player_stat(p_player_id, ''wounded_power'');
    END IF;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- Every lane swings again
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    move   BIGINT;
    target BIGINT;
    swung  RECORD;
BEGIN
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'player_swing')
       LIKE '%momentum_turn_cap%' THEN
        RAISE EXCEPTION 'the invented config key is still in there';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'player_swing')
       LIKE '%cornered_threshold%' THEN
        RAISE EXCEPTION 'the invented threshold is still in there';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'player_swing')
       NOT LIKE '%wounded_power%' THEN
        RAISE EXCEPTION 'the cornered stat is not the one that exists';
    END IF;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry this';
        RETURN;
    END IF;

    move := dungeon_default_move(who);
    SELECT cs.species_id INTO target
    FROM creature_species cs WHERE cs.kind = 'beast' ORDER BY cs.rank LIMIT 1;

    -- A tracked body, wounded, deep into a fight: the path that reads every
    -- one of the three lines that were wrong.
    SELECT * INTO swung FROM player_swing(
        who, move, target, 99999999::bigint, 0::bigint,
        50::bigint, 1000::bigint, 6);

    IF swung.dealt <= 0 THEN
        RAISE EXCEPTION 'a swing landed nothing';
    END IF;

    RAISE NOTICE 'a wounded swing on turn six deals %', swung.dealt;
END;
$$;
