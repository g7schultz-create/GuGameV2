-- 0145_a_beast_that_takes_a_while
--
-- The first world beast died in twenty strikes. Four cultivators turned up,
-- spent their allowance, and it was over before most of the server knew it had
-- arrived - which is not what a world beast is for.
--
-- THE ALLOWANCE IS THE LEVER, NOT THE POOL ALONE. `boss_strikes_each` is per
-- ENCOUNTER, so the pool can never exceed what the roster's whole allowance
-- can deal or the beast is simply unkillable. Raising HP without raising
-- strikes would produce a wall, which is the same mistake as the Leviathan's
-- five million.
--
--     5 strikes each  x 10 cultivators = 50 blows available
--     pool 4,980 at effort 0.55        = dead on blow 20
--
-- So both move together: twenty-five strikes each against sixty per cent of
-- what that can deal.
--
--     25 strikes each x 10 cultivators = 250 blows available
--     pool 27,165 at effort 0.60       = dead somewhere past blow 120
--
-- WHY THAT ACTUALLY TAKES TIME. The bite cap from 0141 means about five blows
-- empties a cultivator, and `/rest` closes 15-55% every five minutes. Nobody
-- can spend twenty-five strikes in one sitting - they spend five, rest, come
-- back. The fight becomes an afternoon the server drifts in and out of, which
-- is the shape group content wants and the reason the cap and the allowance
-- had to stop being the same number.
--
-- The window widens to forty-eight hours to match, and the rest between beasts
-- with it, so one is standing rather more often than not.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 25,
    description = 'Strikes one cultivator gets at one world beast. Well past what their health allows in a sitting - the bite cap means five blows and a rest, so this is a day''s worth rather than a minute''s.'
WHERE key = 'boss_strikes_each';

UPDATE game_config SET value = 0.60,
    description = 'What fraction of the roster''s full allowance the beast is worth. Below 1 so a turnout that is not everybody can still bring it down.'
WHERE key = 'boss_effort';

UPDATE game_config SET value = 48,
    description = 'How long a world beast stands. Long enough to rest and come back several times.'
WHERE key = 'boss_hours';

UPDATE game_config SET value = 8,
    description = 'Quiet between one beast leaving and the next arriving.'
WHERE key = 'boss_rest_hours';

UPDATE game_config SET value = 20000,
    description = 'Smallest a world beast can be however thin the server is.'
WHERE key = 'boss_hp_floor';


-- The two numbers have to stay in step. A pool the roster's whole allowance
-- cannot deal is a beast nobody can kill; a pool a quarter of it can deal is
-- the twenty-strike afternoon this migration exists to end.
DO $$
DECLARE
    pool    BIGINT := boss_hp_pool();
    roster  NUMERIC;
    blows   NUMERIC;
    ceiling NUMERIC;
BEGIN
    SELECT COALESCE(sum(best.power), 0) INTO roster
    FROM players p
    JOIN LATERAL (
        SELECT max(t.base_power) AS power
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = p.player_id AND t.base_power > 0
    ) best ON best.power IS NOT NULL
    WHERE p.deleted_at IS NULL
      AND p.last_seen_at >= now() - interval '7 days';

    IF roster = 0 THEN
        RAISE NOTICE 'no active strikers; the pool falls back to its floor';
        RETURN;
    END IF;

    ceiling := roster * game_config_value('boss_strikes_each');
    blows   := pool / (roster / (SELECT count(*) FROM players p
                                 WHERE p.deleted_at IS NULL
                                   AND p.last_seen_at >= now() - interval '7 days'));

    IF pool >= ceiling THEN
        RAISE EXCEPTION
            'the pool is % and the roster can only ever deal %; nobody could kill it',
            pool, ceiling;
    END IF;

    -- And it must not fall over in an afternoon either. Forty blows is the
    -- floor of "a while" - well past the twenty it used to take.
    IF blows < 40 THEN
        RAISE EXCEPTION
            'the beast falls in about % blows, which is still an afternoon',
            round(blows);
    END IF;

    RAISE NOTICE 'world beast: % HP, about % blows, ceiling %',
        pool, round(blows), ceiling;
END;
$$;
