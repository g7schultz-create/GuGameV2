-- 0207_nobody_pays_a_key_to_watch
--
-- A raider with no attack technique can do nothing in a dungeon. The round
-- resolver handles it honestly - "has no attack to make" - but honest is not
-- the same as acceptable: they paid a key and a purse of stones to stand in a
-- room, and spoils are split by damage dealt, so their share is exactly zero.
-- They would be worse off than if they had stayed outside, and the boss's
-- health pool would be 60% larger for their trouble.
--
-- Two live cultivators are in that state right now - m_i_y_u_k_i. and
-- night.moth_ both hold zero learned techniques - so this is not hypothetical.
--
-- So the door refuses them, by name, and says what to do about it. 0192 filled
-- ranks 2 to 5 of every Path, so there is something to learn at every realm;
-- the fix is one `/learn` away and the message says so.
--
-- Checked for the WHOLE PARTY before anything is spent. `dungeon_begin` takes
-- keys in a loop, and finding out at raider four that raider five cannot fight
-- would leave three people paid up for a run that does not start.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_begin';

    old := '    SELECT count(*) INTO party FROM dungeon_raiders WHERE run_id = p_run_id;';
    new := '    SELECT count(*) INTO party FROM dungeon_raiders WHERE run_id = p_run_id;

    -- Before a single key is taken. Somebody who cannot swing would pay to
    -- watch, earn nothing - spoils go by damage dealt - and make the boss
    -- bigger for everyone else.
    SELECT string_agg(p.discord_name, '', '' ORDER BY p.discord_name) INTO unarmed
    FROM dungeon_raiders x
    JOIN players p ON p.player_id = x.player_id
    WHERE x.run_id = p_run_id
      AND dungeon_default_move(x.player_id) IS NULL;

    IF unarmed IS NOT NULL THEN
        RAISE EXCEPTION
            ''% cannot attack, and spoils are split by damage - learn a technique with /learn first'',
            unarmed
            USING ERRCODE = ''check_violation'';
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_begin no longer counts the party the old way';
    END IF;
    src := replace(src, old, new);

    -- The new local.
    old := '    party INTEGER;';
    new := '    party INTEGER;
    unarmed TEXT;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_begin no longer declares the party count';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    mute BIGINT;
    able BIGINT;
    run  BIGINT;
    keys BIGINT;
BEGIN
    SELECT p.player_id INTO mute FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NULL
    LIMIT 1;

    SELECT p.player_id INTO able FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;

    IF mute IS NULL OR able IS NULL THEN
        RAISE NOTICE 'no pair to probe with; tests carry it';
        RETURN;
    END IF;

    BEGIN
        PERFORM grant_material(able, 'dungeon_key', 3);
        PERFORM grant_material(able, 'spirit_stone', 9000000);
        PERFORM grant_material(mute, 'dungeon_key', 3);
        PERFORM grant_material(mute, 'spirit_stone', 9000000);
        PERFORM grant_jade(able, 50, 'probe');
        PERFORM grant_jade(mute, 50, 'probe');

        SELECT COALESCE(pm.quantity, 0) INTO keys FROM player_materials pm
        WHERE pm.player_id = able AND pm.material_code = 'dungeon_key';

        run := dungeon_open(able, 1::smallint, 'normal');
        PERFORM dungeon_invite(run, able, mute);
        PERFORM dungeon_join(run, mute);

        BEGIN
            PERFORM dungeon_begin(run, able);
            RAISE EXCEPTION 'the door let an unarmed raider in';
        EXCEPTION
            WHEN check_violation THEN
                NULL;   -- refused, which is the point
        END;

        -- And it refused before taking anybody's key.
        IF (SELECT COALESCE(pm.quantity, 0) FROM player_materials pm
            WHERE pm.player_id = able AND pm.material_code = 'dungeon_key')
           <> keys THEN
            RAISE EXCEPTION 'a key was spent on a run that was refused';
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
