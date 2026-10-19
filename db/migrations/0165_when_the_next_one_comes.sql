-- 0165_when_the_next_one_comes
--
-- /cooldowns and /boss both say "nothing standing" and stop there, which is
-- the half of the answer nobody was asking for. The other half exists and is
-- computable: `boss_open_if_due` will not open one until the world has rested
-- `boss_rest_hours` since the last beast ended, so there is an exact moment
-- the next one becomes due.
--
-- That rule was written inline inside `boss_open_if_due` and nowhere else, so
-- a screen wanting to report it had to restate it - and a restated rule is
-- one that drifts the first time the rest period changes. It comes out into a
-- function that both the opener and the screens read.
--
-- Nothing here changes when a beast arrives. It only makes the moment
-- sayable.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION boss_next_spawn_at()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $$
    -- NULL while one is standing: "when is the next" has no answer until the
    -- current one is done, and a timestamp there would be a guess about when
    -- somebody finishes it.
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM boss_encounters WHERE status = 'open')
            THEN NULL
        -- No beast has ever stood, so one is overdue rather than pending.
        ELSE COALESCE(max(e.ended_at), 'epoch'::timestamptz)
             + make_interval(hours => game_config_value('boss_rest_hours')::int)
    END
    FROM boss_encounters e;
$$;


-- The opener now reads the same rule rather than carrying its own copy.
CREATE OR REPLACE FUNCTION boss_open_if_due()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live   BIGINT;
    lapsed BIGINT;
    due_at TIMESTAMPTZ;
    chosen BIGINT;
    made   BIGINT;
    pool   BIGINT;
BEGIN
    -- A beast that stood out its welcome leaves - and is settled on the way
    -- out, so an escape pays what it owes without anybody pressing anything.
    FOR lapsed IN
        SELECT encounter_id FROM boss_encounters
        WHERE status = 'open' AND closes_at <= now()
    LOOP
        UPDATE boss_encounters
        SET status = 'escaped', ended_at = now()
        WHERE encounter_id = lapsed;
        PERFORM settle_boss(lapsed);
    END LOOP;

    SELECT encounter_id INTO live
    FROM boss_encounters WHERE status = 'open';

    IF live IS NOT NULL THEN
        RETURN live;
    END IF;

    due_at := boss_next_spawn_at();
    IF due_at IS NULL OR due_at > now() THEN
        RETURN NULL;
    END IF;

    SELECT cs.species_id INTO chosen
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
    ORDER BY random()
    LIMIT 1;

    IF chosen IS NULL THEN
        RETURN NULL;
    END IF;

    -- Sized against the beast that was actually rolled.
    pool := boss_hp_pool(chosen);

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, closes_at)
    SELECT chosen,
           COALESCE((SELECT cr.region_code FROM creature_regions cr
                     WHERE cr.species_id = chosen ORDER BY random() LIMIT 1),
                    (SELECT r.code FROM regions r ORDER BY r.code LIMIT 1)),
           pool, pool,
           now() + make_interval(hours => game_config_value('boss_hours')::int)
    ON CONFLICT DO NOTHING
    RETURNING encounter_id INTO made;

    IF made IS NULL THEN
        SELECT encounter_id INTO made
        FROM boss_encounters WHERE status = 'open';
    END IF;

    RETURN made;
END;
$$;


-- The function has to agree with the rule it was lifted out of, or the screen
-- counts down to a moment the opener disagrees with - which reads as a bot
-- that is simply not doing what it said.

DO $$
DECLARE
    said  TIMESTAMPTZ;
    ought TIMESTAMPTZ;
    standing BOOLEAN;
BEGIN
    standing := EXISTS (SELECT 1 FROM boss_encounters WHERE status = 'open');
    said := boss_next_spawn_at();

    IF standing THEN
        IF said IS NOT NULL THEN
            RAISE EXCEPTION 'a beast is standing and the clock still answered';
        END IF;
        -- And the opener must hand back the standing one rather than a NULL.
        IF boss_open_if_due() IS NULL THEN
            RAISE EXCEPTION 'the opener lost the beast that is standing';
        END IF;
        RETURN;
    END IF;

    SELECT COALESCE(max(ended_at), 'epoch'::timestamptz)
           + make_interval(hours => game_config_value('boss_rest_hours')::int)
    INTO ought
    FROM boss_encounters;

    IF said IS DISTINCT FROM ought THEN
        RAISE EXCEPTION 'the clock says % and the rule says %', said, ought;
    END IF;
END;
$$;
