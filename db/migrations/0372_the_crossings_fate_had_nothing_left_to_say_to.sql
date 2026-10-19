-- 0372_the_crossings_fate_had_nothing_left_to_say_to
--
-- 0370 deepened the well. This pours for the people who reached it dry.
--
-- `destiny_offer` is called once, by `breakthrough`, at the moment of
-- crossing - and when it finds nothing left to offer it returns NULL and
-- writes no row. There is no second attempt, because until now there was never
-- a reason for one: the pool could not empty. pashu0 crossed into Purple
-- Mulberry against an empty pool and that crossing is simply gone.
--
-- 0257 had this same shape when fate arrived after people had already climbed,
-- and its answer works here unchanged: walk every door already behind every
-- cultivator and ask again. `destiny_offer` hands back the existing offer
-- where there is one and rolls a fresh three only where there is not, so this
-- is safe to run over everybody and cannot disturb a fate already written or
-- a board already sitting in front of somebody.
--
-- Every door from 2 up, not just the immortal ones: a mortal who ran into the
-- same wall for any other reason gets the same second look.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    who    RECORD;
    step   INTEGER;
    made   TEXT[];
    opened INTEGER := 0;
    people INTEGER := 0;
BEGIN
    FOR who IN
        SELECT pc.player_id, r.rank
        FROM player_cultivation pc
        JOIN players p ON p.player_id = pc.player_id
        JOIN realms r  ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND r.rank > 1
        ORDER BY pc.player_id
    LOOP
        people := people + 1;

        FOR step IN 2..who.rank LOOP
            IF NOT EXISTS (
                SELECT 1 FROM player_destinies pd
                WHERE pd.player_id = who.player_id AND pd.rank = step
            ) THEN
                made := destiny_offer(who.player_id, step::smallint);
                IF made IS NOT NULL THEN
                    opened := opened + 1;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'opened % missed crossings across % cultivators', opened, people;
END;
$$;


-- ---------------------------------------------------------------------------
-- Nobody is owed a crossing any more, and nobody was offered one twice
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad   TEXT;
    dupes TEXT;
BEGIN
    -- The assertion the suite makes, made here so the migration proves its
    -- own fix rather than waiting for a test run.
    SELECT string_agg(p.discord_name || ' (rank ' || r.rank || ', has '
                      || (SELECT count(*) FROM player_destinies pd
                          WHERE pd.player_id = pc.player_id) || ')', ', ')
    INTO bad
    FROM player_cultivation pc
    JOIN players p ON p.player_id = pc.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE p.deleted_at IS NULL AND r.rank > 1
      AND (SELECT count(*) FROM player_destinies pd
           WHERE pd.player_id = pc.player_id) < r.rank - 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'still owed crossings: %', bad;
    END IF;

    -- And the well did not pour the same fate into two cups. `destiny_stat`
    -- sums what it finds, so a fate offered twice is a fate worth double.
    SELECT string_agg(t.player_id || ':' || t.code, ', ') INTO dupes
    FROM (
        SELECT pd.player_id, d.code
        FROM player_destinies pd
        CROSS JOIN LATERAL unnest(pd.offered) AS d(code)
        GROUP BY pd.player_id, d.code
        HAVING count(*) > 1
    ) t;
    IF dupes IS NOT NULL THEN
        RAISE EXCEPTION 'these fates were offered twice to one person: %', dupes;
    END IF;

    RAISE NOTICE 'every crossing behind every cultivator now has its three';
END;
$probe$;
