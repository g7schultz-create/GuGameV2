-- 0294_a_king_stands_for_thirty_minutes
--
-- Twenty minutes was chosen as a cadence before anybody asked what it cost,
-- and the answer is that it costs nothing. A full measure of the roster is
-- 96ms. A tick that finds nothing due is 7ms. At twenty minutes that is seven
-- seconds of database time a day; at five it is twenty-eight. Neither number
-- is a reason to do anything.
--
-- What twenty minutes actually costs is convergence, and that is a real cost:
--
--     cadence   time to adapt   rechecks a King gets
--       20 min       2.7 h              1
--       10 min       1.3 h              3
--        5 min       0.7 h              6
--
-- A step may move a beast by `boss_resize_step`, so adapting from a beast
-- built for the whole week to one built for the four people here takes about
-- eight steps whatever the cadence. Multiply by twenty minutes and a world
-- beast spends the better part of three hours being unkillable by the room
-- that is actually in front of it - which is the exact complaint this was
-- built to answer, just shorter.
--
-- And the King is worse than slow, it is excluded. It stands for
-- `horde_king_minutes` - thirty - so at a twenty minute cadence it is
-- measured once in its life and then walks into the region. A feature that
-- fires once per King is not a feature.
--
-- Five minutes: a beast adapts inside forty minutes, a King is measured six
-- times while it stands, and the whole thing costs half a minute of database
-- time a day. There is no thrash to fear at that rate either, because the
-- target only moves when somebody crosses the forty-five minute presence
-- boundary, not on every tick.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 5,
    description =
        'How often a standing beast is measured against the room again. Five '
        'rather than twenty because a King only stands for thirty minutes, so '
        'a slower cadence measures it once and never again - and because a '
        'step is capped, so the cadence is what decides how long a beast '
        'spends being the wrong size.'
WHERE key = 'boss_resize_minutes';


-- ---------------------------------------------------------------------------
-- A King is measured more than once while it stands
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    cadence NUMERIC := game_config_value('boss_resize_minutes');
    stands  NUMERIC := game_config_value('horde_king_minutes');
    step    NUMERIC := game_config_value('boss_resize_step');
    looks   NUMERIC;
    adapts  NUMERIC;
BEGIN
    looks := floor(stands / cadence);

    IF looks < 3 THEN
        RAISE EXCEPTION
            'a King stands % minutes and would be measured % time(s) at a % minute cadence',
            stands, looks, cadence;
    END IF;

    -- Eight steps is the distance from a beast built for everybody who
    -- appeared this week to one built for a quiet room, measured against this
    -- server's actual spread.
    adapts := 8 * cadence;

    IF adapts > game_config_value('boss_hours') * 60 THEN
        RAISE EXCEPTION
            'a beast would need % minutes to adapt and only stands % minutes',
            adapts, game_config_value('boss_hours') * 60;
    END IF;

    RAISE NOTICE
        'a King is measured % times while it stands; a beast adapts in % minutes',
        looks, adapts;

    -- The step still has to be a step. A cadence this short with an uncapped
    -- step would be the lurching the cap exists to prevent.
    IF step >= 1 THEN
        RAISE EXCEPTION 'a recheck may move a beast to anything at all';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- And the cost of asking that often is still nothing
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    started TIMESTAMPTZ;
    took    NUMERIC;
    sp      BIGINT;
BEGIN
    SELECT species_id INTO sp FROM creature_species WHERE kind = 'world' LIMIT 1;
    IF sp IS NULL THEN
        RAISE NOTICE 'no world beast in the book; the tests carry this';
        RETURN;
    END IF;

    started := clock_timestamp();
    PERFORM boss_hp_pool(sp);
    took := EXTRACT(EPOCH FROM (clock_timestamp() - started)) * 1000;

    -- Generous: this is a guard against the measure quietly becoming
    -- expensive later, not a benchmark. At a five minute cadence even a
    -- second per measure would be five minutes of database time a day.
    IF took > 2000 THEN
        RAISE EXCEPTION
            'measuring the roster now takes %ms; the cadence assumes it is cheap',
            round(took);
    END IF;

    RAISE NOTICE 'measuring the roster takes %ms', round(took);
END;
$$;
