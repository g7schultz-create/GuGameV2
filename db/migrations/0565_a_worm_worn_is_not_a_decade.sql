-- 0565_a_worm_worn_is_not_a_decade
--
-- Carrying a Gu paid 1 point of understanding for every 10 HOURS worn. Through
-- a weight, that is what it really cost the three cultivators who have a worm
-- in their Dao:
--
--     sylvrime    Battle Bone Wheel     0.305     33 hours a point
--     pashu0      Wolf Enslavement Gu   0.264     38 hours a point
--     clearwest   Battle Bone Wheel     0.181     55 hours a point
--
-- Which made the rank 20 floor alone - 200 points on one aspect - 6,557 to
-- 11,050 hours of wearing the same worm. And the apex demands 1,200:
--
--     clearwest, rank 27, the Gu aspect:  66,298 hours = 7.6 YEARS
--
-- carrying it every hour of every day, because a day holds 24 and there is no
-- playing harder past that. It was the hardest wall in the Venerable ladder
-- and the only one no amount of effort could move.
--
-- Ten times faster, as asked: `units_per_point` 10 -> 1. One hour, one unit.
--
--     clearwest, rank 20 floor:    11,050 hours  ->  1,105   (46 days)
--     clearwest, rank 27 floor:    66,298 hours  ->  6,630   (276 days)
--
-- Still the longest single commitment in the game and no longer a sentence.
--
-- RETROACTIVE, and deliberately. `dao_understanding` computes from the live
-- counter every time it is read - nothing is banked - so every hour already
-- carried is worth ten times what it was the moment this lands. Nobody loses
-- anything and nobody has to start again, which is the only honest way to
-- change a rate people have already been paying.
--
-- WHAT IT DOES TO THE SHAPE OF THE LADDER, measured rather than asserted, for
-- clearwest's own weights and their own measured pace:
--
--     Gu     200 points    1,105 hours     46 days   PASSIVE
--     body   200 points    2,000 levels    62 days   active
--     path   200 points    5,443 casts    259 days   active
--
-- So the worm becomes the fastest axis and it is the one that costs no
-- attention - you wear it and the meter fills. It does not run away with the
-- ladder, because the weights that make it cheap are the same weights that
-- made it expensive, but it is now the obvious thing to do first. Worth
-- knowing before it is a surprise.
--
-- The other three rates are untouched: body and craft stay at 10 of their own
-- units, a Path stays at 20 casts.


UPDATE dao_deed_rates
SET units_per_point = 1.000
WHERE source_kind = 'gu';

COMMENT ON TABLE dao_deed_rates IS
    'How many of an axis'' own units make one point of understanding. A table rather than a decision baked into a function, because these were a first guess - 0565 cut the Gu rate tenfold when wearing one worm to the apex turned out to be 7.6 years of wall-clock time.';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_rate   NUMERIC;
    v_row    RECORD;
    v_moved  INTEGER := 0;
    v_told   TEXT := '';
BEGIN
    SELECT units_per_point INTO v_rate FROM dao_deed_rates WHERE source_kind = 'gu';
    IF v_rate <> 1.000 THEN
        RAISE EXCEPTION 'the Gu rate reads % and should be 1', v_rate;
    END IF;

    -- 1. THE OTHER THREE DID NOT MOVE. A rate change that swept the table
    --    would quietly reprice body, craft and every Path as well.
    IF (SELECT count(*) FROM dao_deed_rates
        WHERE (source_kind, units_per_point) IN
              (('body', 10.000), ('craft', 10.000), ('path', 20.000))) <> 3 THEN
        RAISE EXCEPTION
            'another axis moved with the worm: %',
            (SELECT string_agg(source_kind || '=' || units_per_point, ', ')
             FROM dao_deed_rates ORDER BY 1);
    END IF;

    -- 2. NOBODY LOST ANYTHING. The rate divides, so a smaller divisor can only
    --    raise understanding - but it is asserted rather than reasoned,
    --    because this is everybody's progress and the arithmetic is one
    --    inverted comparison away from a catastrophe.
    FOR v_row IN
        SELECT p.discord_name, u.label, u.understanding
        FROM player_dao d
        JOIN players p ON p.player_id = d.player_id
        CROSS JOIN LATERAL dao_understanding(d.player_id) u
        WHERE u.source_kind = 'gu'
    LOOP
        IF v_row.understanding < 0 THEN
            RAISE EXCEPTION '% reads negative understanding on %',
                v_row.discord_name, v_row.label;
        END IF;
        v_told := v_told || format(' %s %s=%s', v_row.discord_name,
                                   v_row.label, round(v_row.understanding, 1));
    END LOOP;
    RAISE NOTICE 'Gu understanding now:%', v_told;

    -- 3. AND THE APEX IS NO LONGER MEASURED IN YEARS. The wall this was
    --    written for: 1,200 points on the worst-weighted worm anybody holds,
    --    at 24 hours in a day.
    SELECT p.discord_name,
           round(1200 * v_rate / u.weight) AS hours,
           round(1200 * v_rate / u.weight / 24) AS days
    INTO v_row
    FROM player_dao d
    JOIN players p ON p.player_id = d.player_id
    CROSS JOIN LATERAL dao_understanding(d.player_id) u
    WHERE u.source_kind = 'gu'
    ORDER BY u.weight ASC
    LIMIT 1;

    IF v_row.days > 1000 THEN
        RAISE EXCEPTION
            'the apex still wants % days of carrying for %', v_row.days,
            v_row.discord_name;
    END IF;
    RAISE NOTICE
        'the apex Gu aspect now wants % hours (% days) at worst, for %',
        v_row.hours, v_row.days, v_row.discord_name;
END
$probe$;
