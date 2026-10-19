-- 0249_the_roster_climbs_by_its_own_kind
--
-- 0248 rescaled the roster with a broken divisor and the ladder came out at
-- 2.38x, 3.80x and 7.01x instead of four.
--
-- The anchor was the rank 1 mean of `beast` and `elite`, and the divisor was
-- the mean of EVERY kind at that rank. Those are different populations: a rank
-- 1 dungeon boss carries 864 against a beast's 288, and each rank holds a
-- different mix of beasts, elites, rogues and dungeon bosses. So every rank was
-- scaled by the wrong number, including rank 1, which is why the anchor itself
-- moved from 312 to 299.
--
-- The technique pass in the same migration was correct - it filtered the same
-- way on both sides - and came out at exactly 4.00x a rank. This is the same
-- fix applied to the roster.
--
-- EACH KIND CLIMBS ITS OWN LADDER. A dungeon boss is about three times the
-- beast of its rank and should stay that way, so every kind is anchored on its
-- own lowest rank rather than on the beasts. `world` and `boss` exist at one
-- rank each and have no ladder to climb; they are left exactly as they are.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    step  NUMERIC := power(game_config_value('stat_step_per_rank'), 2);
    k     RECORD;
    r     RECORD;
    hp0   NUMERIC;
    at0   NUMERIC;
    df0   NUMERIC;
    low   SMALLINT;
    moved INTEGER := 0;
BEGIN
    FOR k IN
        SELECT cs.kind, count(DISTINCT cs.rank) AS ranks
        FROM creature_species cs GROUP BY cs.kind
    LOOP
        -- A kind standing at a single rank has no ladder to be wrong about.
        CONTINUE WHEN k.ranks < 2;

        SELECT min(cs.rank) INTO low
        FROM creature_species cs WHERE cs.kind = k.kind;

        SELECT avg(cs.base_hp), avg(cs.base_attack), avg(cs.base_defense)
        INTO hp0, at0, df0
        FROM creature_species cs
        WHERE cs.kind = k.kind AND cs.rank = low;

        FOR r IN
            SELECT cs.rank,
                   avg(cs.base_hp) AS hp,
                   avg(cs.base_attack) AS atk,
                   avg(cs.base_defense) AS def
            FROM creature_species cs
            WHERE cs.kind = k.kind
            GROUP BY cs.rank
        LOOP
            -- Same population on both sides of the ratio, which is the whole
            -- of what went wrong last time.
            UPDATE creature_species cs
            SET base_hp = GREATEST(1, round(cs.base_hp
                    * (hp0 * power(step, r.rank - low)) / GREATEST(r.hp, 1))),
                base_attack = GREATEST(1, round(cs.base_attack
                    * (at0 * power(step, r.rank - low)) / GREATEST(r.atk, 1))),
                base_defense = GREATEST(0, round(cs.base_defense
                    * (df0 * power(step, r.rank - low)) / GREATEST(r.def, 1)))
            WHERE cs.kind = k.kind AND cs.rank = r.rank;

            moved := moved + 1;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'restacked % kind/rank groups', moved;
END;
$$;


DO $$
DECLARE
    k    RECORD;
    got  NUMERIC;
BEGIN
    -- Every kind that spans more than one rank now climbs by four, measured
    -- between adjacent ranks it actually occupies.
    FOR k IN
        SELECT cs.kind, cs.rank, avg(cs.base_hp) AS hp,
               lag(avg(cs.base_hp)) OVER (PARTITION BY cs.kind ORDER BY cs.rank) AS prev,
               lag(cs.rank) OVER (PARTITION BY cs.kind ORDER BY cs.rank) AS prev_rank
        FROM creature_species cs
        GROUP BY cs.kind, cs.rank
    LOOP
        CONTINUE WHEN k.prev IS NULL;

        got := k.hp / k.prev / power(4, k.rank - k.prev_rank);

        IF abs(got - 1) > 0.02 THEN
            RAISE EXCEPTION
                'a % climbs %x from rank % to %, not four a rank',
                k.kind, round(k.hp / k.prev, 2), k.prev_rank, k.rank;
        END IF;
    END LOOP;

    -- And nothing came out of it with no health.
    IF EXISTS (SELECT 1 FROM creature_species WHERE base_hp < 1) THEN
        RAISE EXCEPTION 'a species was left with no health at all';
    END IF;
END;
$$;
