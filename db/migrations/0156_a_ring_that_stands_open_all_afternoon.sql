-- 0156_a_ring_that_stands_open_all_afternoon
--
-- Thirty minutes was too short for a server this size. Three cultivators have
-- to be looking at the same half hour for a tournament to run at all, and on a
-- roster of eleven who play at different times of day that is mostly nobody.
--
-- Three hours. Nothing else has to move: `join_tournament` refuses once
-- `closes_at` has passed and `run_tournament` picks up whatever is past it, so
-- the window is the only thing this number controls.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 180,
    description = 'How long the entry list stands open, in minutes. Three hours, because three cultivators have to overlap for a ring to run and they do not all play at the same time of day.'
WHERE key = 'tournament_signup_minutes';


-- A ring already standing keeps the window it opened with, which would leave
-- one thirty-minute list behind at the moment of the change. Widen it too, so
-- nobody is caught by a deadline the config no longer describes.
UPDATE tournaments
SET closes_at = opened_at + interval '180 minutes'
WHERE status = 'signup';


DO $$
DECLARE
    mins NUMERIC := game_config_value('tournament_signup_minutes');
BEGIN
    IF mins <> 180 THEN
        RAISE EXCEPTION 'the entry list stands for % minutes, not 180', mins;
    END IF;

    -- The window has to be shorter than the rest of the game's patience for
    -- it: a list open longer than a day would never resolve on a look.
    IF mins > 24 * 60 THEN
        RAISE EXCEPTION 'an entry list open for % minutes will never close', mins;
    END IF;

    IF EXISTS (
        SELECT 1 FROM tournaments
        WHERE status = 'signup' AND closes_at < opened_at + interval '180 minutes'
    ) THEN
        RAISE EXCEPTION 'a standing ring kept its old, shorter window';
    END IF;
END;
$$;
