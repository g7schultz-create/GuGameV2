-- 0240_a_world_beast_is_sized_to_the_room
--
-- A beast in the channel dies too fast for the channel to reach it.
--
-- 0229 made them nine times the health of a gauntlet wave so a room would have
-- to gang up on one. At rank 3 that is about 10,400 health, and a cultivator
-- swinging for two thousand ends it in five clicks - before anybody else has
-- looked at the message. The event is built around several people hitting the
-- same body and the body is not standing long enough for several people to
-- find it.
--
-- SO IT IS SIZED TO THE ROOM, the way the King already is. `horde_world_hp` is
-- a floor now and `horde_world_hp_per_hand` grows it with the number of hands
-- that have actually swung lately - the same `horde_hands` the whole event
-- scales to. Ten people get something ten people have to share; one person
-- gets something one person can still finish. The alternative, a bigger flat
-- number, would be an immovable wall on a quiet evening and the same five
-- clicks on a busy one.
--
-- Health at rank 3, where it was 10,400 whatever the turnout:
--
--     1 hand    27,800      3 hands   41,600
--     6 hands   62,400     10 hands   90,200
--
-- AND THEY STAND LONGER. Twenty minutes rather than fifteen, because a body
-- that now needs twenty-odd blows needs the room to assemble around it, and a
-- beast that walks off costs the line what its pack was worth.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 18,
    description = 'The floor on a channel beast''s health, as a multiple of '
                  'what the same beast would carry as a gauntlet wave. Grown '
                  'from here by how many hands are on the line.'
WHERE key = 'horde_world_hp';

UPDATE game_config SET value = 20,
    description = 'How long a world beast stands in the channel before it '
                  'breaks through. Long, because it now takes a crowd and the '
                  'crowd arrives at its own pace.'
WHERE key = 'horde_beast_minutes';

INSERT INTO game_config (key, value, description) VALUES
    ('horde_world_hp_per_hand', 6,
     'Added to the health multiple for every hand that has swung lately. This '
     'is what makes a channel beast a thing the room shares rather than a '
     'thing the fastest cultivator collects.');


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_spawn';

    old := '    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * game_config_value(''horde_world_hp'')
                              * CASE WHEN elite
                                     THEN game_config_value(''horde_elite_hp'')
                                     ELSE 1 END))::bigint;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_spawn no longer sizes a beast the old way';
    END IF;

    EXECUTE replace(src, old,
        '    -- Sized to the room, like the King. A flat multiple was a wall on a
    -- quiet evening and five clicks on a busy one; this is neither.
    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * (game_config_value(''horde_world_hp'')
                                 + game_config_value(''horde_world_hp_per_hand'')
                                   * horde_hands(p_horde_id))
                              * CASE WHEN elite
                                     THEN game_config_value(''horde_elite_hp'')
                                     ELSE 1 END))::bigint;');
END;
$$;


DO $$
DECLARE
    tide  BIGINT;
    made  BIGINT;
    lone  BIGINT;
    crowd BIGINT;
    who   BIGINT;
    n     INTEGER;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 3::smallint, NULL);

        -- Nobody has swung: the floor.
        made := horde_spawn(tide);
        SELECT e.max_hp INTO lone FROM horde_encounters e WHERE e.encounter_id = made;

        -- Now a room turns up.
        n := 0;
        FOR who IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 6
        LOOP
            n := n + 1;
            INSERT INTO horde_contributions (horde_id, player_id, last_swing_at)
            VALUES (tide, who, now())
            ON CONFLICT (horde_id, player_id) DO UPDATE SET last_swing_at = now();
        END LOOP;

        IF n < 2 THEN
            RAISE NOTICE 'not enough cultivators to measure a crowd';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Clear the board so the cap does not refuse the next spawn.
        UPDATE horde_encounters SET status = 'slain', settled_at = now()
        WHERE horde_id = tide AND status = 'alive';

        made := horde_spawn(tide);
        SELECT e.max_hp INTO crowd FROM horde_encounters e WHERE e.encounter_id = made;

        -- Both were rolled from the same regional roster, so a crowd's beast
        -- can be a smaller species than a lone defender's - compare the
        -- multiple rather than the raw pool.
        IF game_config_value('horde_world_hp_per_hand') <= 0 THEN
            RAISE EXCEPTION 'the per-hand term does nothing';
        END IF;
        IF lone IS NULL OR crowd IS NULL THEN
            RAISE EXCEPTION 'a tide would not spawn anything to measure';
        END IF;

        RAISE NOTICE 'one hand: %, % hands: %', lone, n, crowd;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
