-- 0273_the_stand_off_says_minutes_not_minutess
--
-- 0272 wrote the King's stand-off refusal as
--
--     RAISE EXCEPTION 'you are standing off - %s before you can swing ...'
--
-- In plpgsql the placeholder is `%`, not `%s`. The argument already reads
-- '6 minutes', so the trailing s is literal and every player who hits the cap
-- is told they are standing off for '6 minutess'.
--
-- It is one character and it is on the one message this whole feature exists
-- to show, so it does not get to wait for the next time something else in
-- horde_strike needs changing.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_strike';

    old := 'you are standing off - %s before you can swing at the King again';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the stand-off no longer says what 0272 made it say';
    END IF;

    src := replace(src, old,
                   'you are standing off - % before you can swing at the King again');

    EXECUTE src;
END;
$$;


DO $$
BEGIN
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'horde_strike')
       LIKE '%standing off - %s before%' THEN
        RAISE EXCEPTION 'the stand-off still has a stray s in it';
    END IF;

    IF (SELECT prosrc FROM pg_proc WHERE proname = 'horde_strike')
       NOT LIKE '%standing off%' THEN
        RAISE EXCEPTION 'the stand-off message is gone entirely';
    END IF;
END;
$$;
