-- 0495_nine_venerable_ranks_and_a_bar_that_fills_slowly
--
-- 0490 built understanding and four rungs. Two things are wrong with it, and
-- the user named both: there should be NINE Venerable ranks, and there should
-- be a bar that fills, because a ladder with no visible movement between
-- rungs does not feel like progress.
--
-- AND THE PACING WAS WRONG BY MORE THAN AN ORDER OF MAGNITUDE. Measured
-- against how fast the existing ladder was actually climbed:
--
--     six cultivators reached rank 18, the ceiling, in 29 to 33 days
--     one reached rank 17 peak in 16 days
--
-- That is about 1.7 days a rank for eighteen ranks, which is the "last realm
-- was passed too fast" this is meant to answer. Then the rates: a dedicated
-- cultivator's measured deed counters move at roughly
--
--     body     132 levels/day  -> 13.2 understanding/day at weight 1.0
--     craft    103 levels/day  ->  4.1 at a typical craft weight of 0.4
--     gu        24 hours/day   ->  0.7 at a typical weight of 0.3
--
-- about 18 a day from the three I can measure. Against a first rung of 100,
-- rank 19 would have fallen in under a week - and that is before casting,
-- which at 0490's rate of one point per two casts would have dwarfed
-- everything else. A couple of hundred swings a day is 100 understanding, six
-- times the other three axes combined.
--
-- SO THE PATH RATE GOES FROM 2 TO 20. Not to punish casting but to put it on
-- the same footing as the rest: ~200 casts a day becomes ~10 understanding,
-- which sits alongside body's 13 instead of swamping it. Four axes each
-- worth something is the mechanic; one axis worth everything is not.
--
-- That gives a dedicated cultivator about 28 a day, and the nine rungs are
-- priced off it:
--
--     V1    400     ~14 days        V6   3,200   ~114 days
--     V2    650     ~23 days        V7   4,600   ~164 days
--     V3  1,000     ~36 days        V8   6,800   ~243 days
--     V4  1,500     ~54 days        V9  10,000   ~357 days
--     V5  2,200     ~79 days
--
-- A year of dedicated play to the top of the Venerable ladder against a month
-- for the eighteen ranks below it. The first rung still arrives in a fortnight
-- so the realm does not open onto a wall.
--
-- SIX IS THE MOST ASPECTS THAT CAN EVER FEED. A Dao holds up to nine aspects,
-- but only four KINDS record a deed - at most three Paths, one body, one
-- craft and one worm. So `aspects_required` cannot exceed 6 or the rung is
-- unreachable by construction, and it climbs 2,2,3,3,4,4,5,5,6 to land
-- exactly on the ceiling at V9. Asserted below, because getting that wrong
-- would ship a top rung nobody could ever hold.
--
-- These are still all table rows. Nobody has stood at rank 19, the cast rate
-- is the one number I could not measure, and the whole point of putting them
-- in `dao_deed_rates` and `venerable_ranks` was that the first guess would be
-- wrong.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Casting joins the other three rather than replacing them
-- ---------------------------------------------------------------------------

UPDATE dao_deed_rates SET units_per_point = 20.000 WHERE source_kind = 'path';


-- ---------------------------------------------------------------------------
-- Nine rungs, named and numbered
-- ---------------------------------------------------------------------------

ALTER TABLE venerable_ranks
    ADD COLUMN venerable_tier SMALLINT;

UPDATE venerable_ranks SET venerable_tier = rank - 18;

-- The ladder is Venerable Rank 1 through 9. `rank` stays the game-wide rank
-- so it sits above the eighteen below it; `venerable_tier` is what a
-- cultivator is told.
ALTER TABLE venerable_ranks
    ALTER COLUMN venerable_tier SET NOT NULL,
    ADD CONSTRAINT venerable_ranks_tier_follows_rank CHECK (venerable_tier = rank - 18),
    ADD CONSTRAINT venerable_ranks_tier_in_range CHECK (venerable_tier BETWEEN 1 AND 9);

COMMENT ON COLUMN venerable_ranks.venerable_tier IS
    'Venerable Rank 1 to 9, which is what the cultivator is shown. Always rank - 18.';


-- The four that 0490 seeded, repriced.
UPDATE venerable_ranks SET understanding_required = 400,  aspects_required = 2, per_aspect_required = 120  WHERE rank = 19;
UPDATE venerable_ranks SET understanding_required = 650,  aspects_required = 2, per_aspect_required = 200  WHERE rank = 20;
UPDATE venerable_ranks SET understanding_required = 1000, aspects_required = 3, per_aspect_required = 250  WHERE rank = 21;
UPDATE venerable_ranks SET understanding_required = 1500, aspects_required = 3, per_aspect_required = 350  WHERE rank = 22;

INSERT INTO venerable_ranks
    (rank, venerable_tier, name, understanding_required, aspects_required, per_aspect_required, description)
VALUES
    (23, 5, 'Myriad-Dao Venerable',  2200, 4,  420,
     'Holds four strands of the Dao at once and lets none of them slip.'),
    (24, 6, 'Sovereign Venerable',   3200, 4,  550,
     'What the Dao asks and what they want have stopped differing.'),
    (25, 7, 'Eternal Venerable',     4600, 5,  700,
     'Five strands realised. Little of the Dao is still opaque to them.'),
    (26, 8, 'Limitless Venerable',   6800, 5,  900,
     'The Dao no longer has edges they have not walked to.'),
    (27, 9, 'Venerable of the Unbroken Dao', 10000, 6, 1200,
     'Every aspect of the Dao realised, which is as far as understanding goes.');


-- ---------------------------------------------------------------------------
-- The bar
-- ---------------------------------------------------------------------------

CREATE FUNCTION venerable_progress(p_player_id BIGINT)
RETURNS TABLE (
    held_rank        SMALLINT,
    held_tier        SMALLINT,
    held_name        TEXT,
    next_rank        SMALLINT,
    next_tier        SMALLINT,
    next_name        TEXT,
    understanding    NUMERIC,
    floor_at         NUMERIC,
    required         NUMERIC,
    fraction         NUMERIC,
    aspects_realised INTEGER,
    aspects_needed   SMALLINT,
    per_aspect       NUMERIC
)
LANGUAGE sql STABLE AS $fn$
WITH me AS (
    SELECT dao_understanding_total(p_player_id) AS total,
           venerable_rank_of(p_player_id) AS held
    WHERE EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id)
),
held AS (
    SELECT v.* FROM venerable_ranks v, me WHERE v.rank = me.held
),
nxt AS (
    SELECT v.* FROM venerable_ranks v, me
    WHERE me.held IS NULL OR v.rank > me.held
    ORDER BY v.rank
    LIMIT 1
)
SELECT h.rank, h.venerable_tier, h.name,
       n.rank, n.venerable_tier, n.name,
       me.total,
       -- The bar fills from the rung you hold, not from zero: at V3 the bar
       -- should look nearly empty again rather than nearly full.
       COALESCE(h.understanding_required, 0),
       n.understanding_required,
       CASE
           WHEN n.rank IS NULL THEN 1.000
           WHEN n.understanding_required <= COALESCE(h.understanding_required, 0) THEN 1.000
           ELSE round(LEAST(1.0, GREATEST(0.0,
               (me.total - COALESCE(h.understanding_required, 0))
               / (n.understanding_required - COALESCE(h.understanding_required, 0))
           )), 3)
       END,
       (SELECT count(*)::INTEGER FROM dao_understanding(p_player_id) u
        WHERE u.understanding >= COALESCE(n.per_aspect_required, 0)),
       n.aspects_required,
       n.per_aspect_required
FROM me
LEFT JOIN held h ON TRUE
LEFT JOIN nxt  n ON TRUE;
$fn$;

COMMENT ON FUNCTION venerable_progress(BIGINT) IS
    'One row describing where a cultivator stands on the Venerable ladder, including the fraction for a progress bar. The bar fills from the rung held rather than from zero, so each rung starts the bar over.';


-- ---------------------------------------------------------------------------
-- Nine reachable rungs, paced against what was measured
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_max_feed INTEGER;
    v_bad      TEXT;
    v_rate     NUMERIC;
    v_days     NUMERIC;
    v_pid      BIGINT;
    v_frac     NUMERIC;
    r          RECORD;
BEGIN
    -- Nine rungs, numbered 1 to 9, starting where the fruits stop.
    IF (SELECT count(*) FROM venerable_ranks) <> 9 THEN
        RAISE EXCEPTION 'the ladder has % rungs rather than nine',
            (SELECT count(*) FROM venerable_ranks);
    END IF;
    IF (SELECT min(venerable_tier) FROM venerable_ranks) <> 1
       OR (SELECT max(venerable_tier) FROM venerable_ranks) <> 9 THEN
        RAISE EXCEPTION 'the Venerable tiers do not run 1 to 9';
    END IF;
    IF (SELECT min(rank) FROM venerable_ranks) <> 19 THEN
        RAISE EXCEPTION 'the ladder does not begin above the fruits';
    END IF;

    -- THE ONE THAT WOULD HAVE SHIPPED AN UNREACHABLE TOP RUNG. A Dao holds up
    -- to nine aspects but only four KINDS record a deed, so at most three
    -- Paths plus a body plus a craft plus a worm can ever feed.
    v_max_feed := 3 + 1 + 1 + 1;
    SELECT string_agg('V' || venerable_tier || ' wants ' || aspects_required, ', ')
    INTO v_bad FROM venerable_ranks WHERE aspects_required > v_max_feed;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a rung asks for more aspects than can ever feed (max %): %',
            v_max_feed, v_bad;
    END IF;

    -- And each rung's own demands have to be consistent with each other:
    -- asking for six aspects at 1,200 each is 7,200, so a total below that
    -- would be the aspects doing all the work.
    SELECT string_agg('V' || venerable_tier, ', ') INTO v_bad
    FROM venerable_ranks
    WHERE aspects_required * per_aspect_required > understanding_required;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs ask more per aspect than in total: %', v_bad;
    END IF;

    -- Still climbing on all three demands.
    IF EXISTS (SELECT 1 FROM venerable_ranks a JOIN venerable_ranks b ON b.rank = a.rank + 1
               WHERE b.understanding_required <= a.understanding_required
                  OR b.aspects_required < a.aspects_required
                  OR b.per_aspect_required <= a.per_aspect_required) THEN
        RAISE EXCEPTION 'a Venerable rung is no harder than the one below it';
    END IF;

    -- PACED SLOWER THAN WHAT WAS PASSED TOO FAST. 18 ranks went in ~30 days,
    -- which is 1.7 days a rank. At the measured ~28 understanding a day the
    -- first rung must take considerably longer than that, and the ninth must
    -- take months.
    v_rate := 28;
    SELECT understanding_required / v_rate INTO v_days
    FROM venerable_ranks WHERE venerable_tier = 1;
    IF v_days < 7 THEN
        RAISE EXCEPTION
            'the first Venerable rung falls in % days, which is the old pace', v_days;
    END IF;

    SELECT understanding_required / v_rate INTO v_days
    FROM venerable_ranks WHERE venerable_tier = 9;
    IF v_days < 180 THEN
        RAISE EXCEPTION 'the whole ladder goes in % days', v_days;
    END IF;

    -- Casting no longer swamps the other three axes. 200 casts a day against
    -- body's measured 132 levels a day.
    IF 200 / (SELECT units_per_point FROM dao_deed_rates WHERE source_kind = 'path')
       > 2 * (132 / (SELECT units_per_point FROM dao_deed_rates WHERE source_kind = 'body'))
    THEN
        RAISE EXCEPTION 'casting is still worth more than twice the body axis';
    END IF;

    -- The bar. Walked up a real cultivator rather than asserted on arithmetic.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-996, 'bar-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        VALUES (v_pid, (SELECT min(realm_id) FROM realms), 0);
        INSERT INTO player_physique (player_id, physique_id, body_path, body_level)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques), 'buddhist', 10);
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, 'sword', 90000, 5);
        -- Two feeding aspects, because V1 asks for two realised. A probe with
        -- one body and nothing else cannot reach the first rung however much
        -- it tempers, which is how this probe failed first time round.
        INSERT INTO player_professions (player_id, profession, level)
        VALUES (v_pid, 'mining', 10);

        -- No Dao stamped: no row at all rather than a row full of nulls.
        IF EXISTS (SELECT 1 FROM venerable_progress(v_pid)) THEN
            RAISE EXCEPTION 'an unstamped cultivator has a place on the ladder';
        END IF;

        PERFORM dao_stamp(v_pid);

        SELECT fraction INTO v_frac FROM venerable_progress(v_pid);
        IF v_frac <> 0 THEN
            RAISE EXCEPTION 'a freshly stamped Dao starts the bar at %', v_frac;
        END IF;

        -- Half of the first rung's 400 is 200 understanding; at weight 1.0 on
        -- the body axis and 10 levels a point that is 2,000 body levels.
        UPDATE player_physique SET body_level = 2010 WHERE player_id = v_pid;
        SELECT fraction INTO v_frac FROM venerable_progress(v_pid);
        IF v_frac < 0.4 OR v_frac > 0.6 THEN
            RAISE EXCEPTION 'halfway up the first rung the bar reads %', v_frac;
        END IF;

        -- The bar restarts at each rung rather than creeping to full once.
        -- 300 from the body and 120 from the craft is 420 against V1's 400,
        -- with both aspects past the 120 it wants on each.
        UPDATE player_physique SET body_level = 3010 WHERE player_id = v_pid;
        UPDATE player_professions SET level = 1210 WHERE player_id = v_pid;
        SELECT fraction, held_tier INTO v_frac, v_max_feed
        FROM venerable_progress(v_pid);
        IF v_max_feed IS NULL THEN
            RAISE EXCEPTION 'four hundred understanding across two aspects reached no rung';
        END IF;
        IF v_frac > 0.5 THEN
            RAISE EXCEPTION
                'on reaching a rung the bar did not restart - it reads %', v_frac;
        END IF;

        -- Never out of bounds, at any amount.
        UPDATE player_physique SET body_level = 30000 WHERE player_id = v_pid;
        FOR r IN SELECT * FROM venerable_progress(v_pid) LOOP
            IF r.fraction < 0 OR r.fraction > 1 THEN
                RAISE EXCEPTION 'the bar reads % outside 0 to 1', r.fraction;
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'nine rungs, V1 at % days and V9 at % days of dedicated play',
        round((SELECT understanding_required FROM venerable_ranks WHERE venerable_tier=1) / v_rate),
        round((SELECT understanding_required FROM venerable_ranks WHERE venerable_tier=9) / v_rate);
END;
$probe$;
