-- 0268_nobody_is_left_standing_on_a_line_that_went_home
--
-- visha has been unable to use /fight horde for twenty-three hours. grafv for
-- ten. The screen they are looking at is real and the buttons do nothing.
--
--     gauntlet 198  visha    wave 18  fighting   tide 886  won 23.4h ago
--     gauntlet 719  grafv    wave 34  fighting   tide 3387 won  9.9h ago
--     gauntlet 747  pashu0   wave  1  fighting   tide 3504 won  1.2h ago
--
-- `horde_settle` ends a tide by walking every beast still standing off the
-- field. It says nothing about the people. A run therefore stays 'fighting'
-- forever, and `horde_gauntlet_open` refuses its owner a new one with 'you are
-- already on the line' - a line that went home yesterday.
--
-- There WAS a self-heal: `horde_gauntlet_swing` notices a dead tide, closes
-- the run and says 'the tide has broken off'. It only fires if the player
-- still has a working button, and a Discord view does not survive a restart or
-- its own timeout. So the one escape hatch is behind the door it is meant to
-- open.
--
-- Two changes, because either one alone leaves a hole:
--
--   * `horde_settle` walks the line off with the beasts. That is the fix.
--   * `horde_gauntlet_open` closes a run whose tide is over rather than
--     refusing on it. That is the guarantee - any future gap that strands a
--     run costs a player one press, not their access to the event.
--
-- Contribution is not touched. It is recorded per swing in
-- horde_contributions as it happens, so a stranded run has already been paid
-- for everything it did.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_settle';

    old := '    UPDATE horde_encounters e
    SET status = ''escaped'', settled_at = now()
    WHERE e.horde_id = p_horde_id AND e.status = ''alive'';';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_settle no longer walks its beasts off';
    END IF;

    src := replace(src, old, old || '

    -- And everybody still on the line. A run left ''fighting'' locks its owner
    -- out of /fight horde entirely, because opening one refuses anybody who
    -- already has a live run - so forgetting the people here read to them as
    -- the command being broken.
    UPDATE horde_gauntlets g
    SET status = ''cleared'', ended_at = now()
    WHERE g.horde_id = p_horde_id AND g.status = ''fighting'';');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_gauntlet_open';

    old := '    IF EXISTS (SELECT 1 FROM horde_gauntlets g
               WHERE g.player_id = p_player_id AND g.status = ''fighting'') THEN
        RAISE EXCEPTION ''you are already on the line''
            USING ERRCODE = ''check_violation'';
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_open no longer guards the one live run';
    END IF;

    src := replace(src, old,
'    -- A run whose tide is over is not a run you are standing in. Closing it
    -- here rather than refusing on it means a strand costs one press instead
    -- of the whole event, whatever left it behind.
    UPDATE horde_gauntlets g
    SET status = ''cleared'', ended_at = now()
    WHERE g.player_id = p_player_id AND g.status = ''fighting''
      AND NOT EXISTS (SELECT 1 FROM beast_hordes h
                      WHERE h.horde_id = g.horde_id
                        AND h.status IN (''fighting'', ''king''));

' || old);

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- The three who are standing there now
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    freed INTEGER;
BEGIN
    UPDATE horde_gauntlets g
    SET status = 'cleared', ended_at = now()
    WHERE g.status = 'fighting'
      AND NOT EXISTS (SELECT 1 FROM beast_hordes h
                      WHERE h.horde_id = g.horde_id
                        AND h.status IN ('fighting', 'king'));

    GET DIAGNOSTICS freed = ROW_COUNT;
    RAISE NOTICE 'sent % stranded runs home', freed;

    IF EXISTS (
        SELECT 1 FROM horde_gauntlets g
        WHERE g.status = 'fighting'
          AND NOT EXISTS (SELECT 1 FROM beast_hordes h
                          WHERE h.horde_id = g.horde_id
                            AND h.status IN ('fighting', 'king'))
    ) THEN
        RAISE EXCEPTION 'somebody is still on a line that went home';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A tide that ends takes the line with it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    tide  BIGINT;
    run   BIGINT;
    still TEXT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can walk it; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        tide := horde_open('northern', NULL, NULL);
        run  := horde_gauntlet_open(who);

        IF (SELECT g.status FROM horde_gauntlets g WHERE g.gauntlet_id = run)
           <> 'fighting' THEN
            RAISE EXCEPTION 'the run did not start';
        END IF;

        -- End it under them, the way a tide ends. By the clock rather than by
        -- emptying the sea: draining it returns 'king', which is the finale
        -- starting rather than the event being over, and `horde_settle`
        -- rightly does nothing yet.
        UPDATE beast_hordes SET ends_at = now() - interval '1 minute'
        WHERE horde_id = tide;

        IF horde_settle(tide) <> 'won' THEN
            RAISE EXCEPTION 'the probe did not manage to end its own tide';
        END IF;

        SELECT g.status INTO still FROM horde_gauntlets g WHERE g.gauntlet_id = run;
        IF still = 'fighting' THEN
            RAISE EXCEPTION 'the tide ended and left somebody on the line';
        END IF;

        -- And the line being over does not bar them from the next one.
        IF EXISTS (SELECT 1 FROM horde_gauntlets g
                   WHERE g.player_id = who AND g.status = 'fighting') THEN
            RAISE EXCEPTION 'a closed run still counts as being on the line';
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
