-- 0217_a_room_deep_enough_holds_a_nest
--
-- 0216 built eggs and nothing drops them, which is the one state a collectible
-- must never be in: the whole argument for shipping eggs ahead of pets is that
-- players can be collecting NOW, and an egg nothing produces is not something
-- anybody can collect.
--
-- The Beast Horde is where they will mostly come from. That is not built yet,
-- and waiting for it would waste the head start the eggs exist to give.
--
-- So a cleared dungeon leaves a nest, at the same shape as everything else in
-- that room: a roll that difficulty leans on, and a tier taken from the room
-- rather than from what laid it. The rank 6 room leaves tier 6 eggs of
-- whatever lives nearby, which is the whole point of the tier being where you
-- found it.
--
-- NO REGION, ON PURPOSE. A dungeon is not in a region - `dungeons` carries a
-- realm rank and a boss and nothing else - so the egg is rolled from every
-- beast rather than from a region's own pool, and `found_in` stays null. When
-- the Horde drops them it will pass its region and the same function will
-- narrow to what actually lives there.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_egg_chance', 0.22,
     'Chance of a beast egg per raider on a clear, before difficulty. Between '
     'the pill and the Gu: rarer than a pill, commoner than a worm.');


DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_spoils_for';

    -- Between the pill and the Gu, which is where it sits in value too.
    old := '    ceiling := game_config_value(''gu_max_droppable_rank'')::smallint;';
    new := '    -- ---- a nest ----------------------------------------------------------
    -- The tier is the room, not the beast. 48 of the 52 huntable creatures
    -- are rank 1 or 2, so an egg graded by what laid it would always be a
    -- tier 1 and the depth of the room would buy nothing.
    IF random() < LEAST(0.95, game_config_value(''dungeon_egg_chance'') * lean) THEN
        made := roll_beast_egg(p_player_id, p_rank, NULL);
        IF made IS NOT NULL THEN
            got := got || jsonb_build_object(''egg'',
                (SELECT s.name FROM player_egg_shelf s WHERE s.egg_id = made));
        END IF;
    END IF;

    ceiling := game_config_value(''gu_max_droppable_rank'')::smallint;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_spoils_for no longer reads the Gu ceiling the old way';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    who  BIGINT;
    got  JSONB;
    r    SMALLINT;
    hits INTEGER := 0;
    n    INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to clear a room; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- Every room lays one eventually, and the tier is the room's.
        FOR r IN 1..9 LOOP
            FOR i IN 1..25 LOOP
                got := dungeon_spoils_for(who, r::smallint, 11.0);
                IF got ? 'egg' THEN
                    hits := hits + 1;
                END IF;
            END LOOP;

            SELECT count(*) INTO n FROM player_beast_eggs e
            WHERE e.owner_id = who AND e.tier <> r;
            IF n > 0 THEN
                RAISE EXCEPTION 'the rank % room laid % eggs of another tier', r, n;
            END IF;

            DELETE FROM player_beast_eggs WHERE owner_id = who;
        END LOOP;

        IF hits = 0 THEN
            RAISE EXCEPTION 'two hundred and twenty five clears laid no eggs at all';
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
