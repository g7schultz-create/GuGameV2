-- 0171_the_world_rests_an_hour
--
-- `boss_rest_hours` has been 8 since 0139, chosen when a beast was expected
-- to stand for its full 48 hours. It does not any more: 0164 resized the pool
-- from delivered damage instead of raw `base_power`, and the first beast sized
-- that way went from 24,178 to nothing in under a day.
--
-- Eight hours of empty world after every kill is most of a session with the
-- group content switched off. One hour keeps a gap - somebody has to notice
-- and look, and the announcement still lands on an empty channel rather than
-- on top of the last one - without turning a fast kill into a punishment.
--
-- Nothing else moves. `boss_next_spawn_at` reads the config, `boss_open_if_due`
-- reads that function, and both were made to do so in 0165 precisely so this
-- would be one row.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1,
    description = 'Hours the world waits after a beast ends before another '
                  'may come. One, because a kill is a fast afternoon now '
                  'rather than a two-day siege.'
WHERE key = 'boss_rest_hours';


DO $$
DECLARE
    said  NUMERIC;
    due   TIMESTAMPTZ;
    ended TIMESTAMPTZ;
BEGIN
    said := game_config_value('boss_rest_hours');
    IF said <> 1 THEN
        RAISE EXCEPTION 'the rest is % hours, not one', said;
    END IF;

    -- The clock has to have moved with it, or 0165's whole point is lost and
    -- two places are deciding when a beast comes again.
    IF NOT EXISTS (SELECT 1 FROM boss_encounters WHERE status = 'open') THEN
        SELECT max(ended_at) INTO ended FROM boss_encounters;
        due := boss_next_spawn_at();

        IF ended IS NOT NULL AND due IS DISTINCT FROM ended + interval '1 hour' THEN
            RAISE EXCEPTION
                'the spawn clock says % and an hour after the last is %',
                due, ended + interval '1 hour';
        END IF;
    END IF;
END;
$$;
