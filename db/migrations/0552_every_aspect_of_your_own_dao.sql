-- 0552_every_aspect_of_your_own_dao
--
-- Rank 27 was unreachable for three of the seven deepest cultivators in the
-- world. Not slow - impossible, with nothing anywhere telling them so.
--
--     m_i_y_u_k_i.   5 aspects that can accrue   ceiling 26
--     shinonn._.     5                           ceiling 26
--     sylvrime       5                           ceiling 26
--     ._.visha._.    6                           ceiling 27
--     clearwest      6                           ceiling 27
--     pashu0         6                           ceiling 27
--     real._.yoru    6                           ceiling 27
--
-- WHY. Every Dao carries three aspects that can never earn a point. `root` and
-- `destiny` name no recorded deed - 0490 says so in as many words, and
-- `dao_deed_of` returns NULL for both - so `dao_understanding` inner-joins
-- them away and `venerable_rank_of` counts the rows that are left:
--
--     (SELECT count(*) FROM dao_understanding(p) u
--      WHERE u.understanding >= v.per_aspect_required) >= v.aspects_required
--
-- Land five live aspects instead of six and `count(*)` tops out at five, so
-- rank 27's demand for six can never be met by anybody, however long they
-- play. The requirement was written as though every Dao had the same number of
-- accruing aspects. They do not: across the live world they run from zero to
-- six.
--
-- THE FIX IS THE RANK'S OWN DESCRIPTION. Rank 27 reads:
--
--     'Every aspect of the Dao realised, which is as far as understanding
--      goes.'
--
-- Every aspect of THE DAO - of yours, the one that was read off what you did.
-- Not six. So the demand is now all of your accruing aspects, with the rung's
-- number as a ceiling rather than as a quota:
--
--     >= LEAST(v.aspects_required, <how many aspects you have that accrue>)
--
-- which makes the sentence literally true for everybody and leaves nobody
-- holding a Dao that cannot finish.
--
-- THIS DOES NOT SHORTEN ANYTHING, which is what was asked for. Nothing touches
-- `understanding_required` or `per_aspect_required`; the probe asserts both
-- tables are byte-for-byte what they were. And the total is what actually
-- binds a smaller Dao, so a five-aspect cultivator has MORE to do per aspect,
-- not less:
--
--     six aspects    6 x 1,200 = 7,200 of the 10,000 total   ~1,667 each
--     five aspects   5 x 1,200 = 6,000 of the 10,000 total   ~2,000 each
--
-- So this is not a discount. It is the difference between a long climb and a
-- locked door.
--
-- The 7.6-year wall at rank 27 is left exactly where it is, deliberately and
-- on instruction. It is a wall-clock wall - the lowest-weight aspect needs
-- 66,298 hours of carrying and a day holds 24 - and whether that is the
-- intended shape is a separate decision from whether the door is locked.


CREATE OR REPLACE FUNCTION venerable_rank_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- The highest rung whose three demands are all met, and NULL for anybody
    -- whose Dao is not stamped.
    --
    -- MATERIALIZED is load-bearing, not decoration (0551): without it the
    -- planner inlines `mine` into every test and rebuilds the aspect set once
    -- per rung, which took `player_standing` from 1.8 ms to 7.3 ms a call - and
    -- it is read per Gu and per effect, which made a preset load time out
    -- against Discord's three-second interaction window.
    --
    -- The aspect COUNT below reads the same materialised set, so asking how
    -- many aspects somebody has costs nothing extra.
    WITH mine AS MATERIALIZED (
        SELECT u.understanding
        FROM dao_understanding(p_player_id) u
        WHERE EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
    ),
    summed AS MATERIALIZED (
        SELECT COALESCE(sum(m.understanding), 0)::NUMERIC AS total,
               count(*) AS aspects
        FROM mine m
    )
    SELECT max(v.rank)
    FROM venerable_ranks v CROSS JOIN summed s
    WHERE EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
      AND s.total >= v.understanding_required
      -- ALL OF YOURS, up to the rung's number. `root` and `destiny` record no
      -- deed and never will, so a Dao that landed five accruing aspects could
      -- never show six - and rank 27 asked for six. See 0552.
      AND (SELECT count(*) FROM mine m
           WHERE m.understanding >= v.per_aspect_required)
          >= LEAST(v.aspects_required, s.aspects);
$fn$;

COMMENT ON FUNCTION venerable_rank_of(BIGINT) IS
    'The highest Venerable rung whose understanding total and per-aspect floor are met across all of the cultivator''s ACCRUING aspects, capped by the rung''s own number (0552); NULL for anybody who has not ascended. Every Dao carries three aspects that record no deed, so a fixed quota of six locked rank 27 for anybody who landed five. Reads the aspect set once (0551).';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who    BIGINT;
    v_before SMALLINT;
    v_after  SMALLINT;
    v_acc    INTEGER;
    v_need   INTEGER;
    v_rk     RECORD;
    v_t0     TIMESTAMPTZ;
    v_ms     NUMERIC;
    v_n      INTEGER := 0;
    v_blocked INTEGER := 0;
    v_freed  TEXT := '';
BEGIN
    -- 1. THE LONG TIME IS UNTOUCHED. This is the thing that was explicitly
    --    asked to stay, so it is asserted rather than assumed: the two columns
    --    that set the pace must be exactly the figures 0490 and 0495 wrote.
    FOR v_rk IN
        SELECT rank, understanding_required AS u, aspects_required AS a,
               per_aspect_required AS pa
        FROM venerable_ranks ORDER BY rank
    LOOP
        v_n := v_n + 1;
    END LOOP;

    IF (SELECT count(*) FROM venerable_ranks
        WHERE (rank, understanding_required, per_aspect_required) IN (
            (19,0,0), (20,650,200), (21,1000,250), (22,1500,350),
            (23,2200,420), (24,3200,550), (25,4600,700), (26,6800,900),
            (27,10000,1200))) <> 9
    THEN
        RAISE EXCEPTION
            'the pace of the ladder moved, and 0552 is only meant to unlock '
            'the door - understanding_required or per_aspect_required changed';
    END IF;

    -- 2. NOBODY'S CURRENT RUNG MOVED. `LEAST` can only ever lower a demand, so
    --    the risk is somebody being handed a rung they had not earned.
    CREATE TEMP TABLE _before_0552 ON COMMIT DROP AS
    SELECT d.player_id, venerable_rank_of(d.player_id) AS rung,
           dao_understanding_total(d.player_id) AS total
    FROM player_dao d;

    FOR v_who, v_before IN SELECT player_id, rung FROM _before_0552 LOOP
        v_after := venerable_rank_of(v_who);
        IF v_after IS DISTINCT FROM v_before THEN
            RAISE EXCEPTION
                'player % moved from rung % to % - 0552 is not meant to '
                'promote anybody', v_who, v_before, v_after;
        END IF;
    END LOOP;

    RAISE NOTICE '% stamped cultivator(s), none promoted', (SELECT count(*) FROM _before_0552);

    -- 3. NO DAO HAS A HARD CEILING ANY MORE. The old rule capped a cultivator
    --    at the deepest rung whose `aspects_required` their accruing count
    --    could reach; the new one asks for `LEAST(required, theirs)`, which is
    --    satisfiable at every rung by construction. Asserted per player
    --    against the real aspect sets, and the count of who WOULD have been
    --    blocked is checked to be non-zero - a probe for a bug nobody had is
    --    a probe that proves nothing.
    FOR v_who, v_acc IN
        SELECT p.player_id,
               count(*) FILTER (WHERE a.source_kind IN
                                (SELECT source_kind FROM dao_deed_rates))
        FROM players p CROSS JOIN LATERAL dao_aspects(p.player_id) a
        WHERE p.deleted_at IS NULL AND p.discord_id > 0
        GROUP BY p.player_id
    LOOP
        CONTINUE WHEN v_acc = 0;   -- nothing accrues, so nothing to realise

        -- What the apex now asks of THIS Dao.
        SELECT LEAST(v.aspects_required, v_acc) INTO v_need
        FROM venerable_ranks v WHERE v.rank = (SELECT max(rank) FROM venerable_ranks);

        IF v_need > v_acc THEN
            RAISE EXCEPTION
                'player % has % accruing aspect(s) and the apex still asks '
                'for % - the ceiling is not gone', v_who, v_acc, v_need;
        END IF;

        -- Would the OLD rule have shut them out?
        IF (SELECT v.aspects_required FROM venerable_ranks v
            WHERE v.rank = (SELECT max(rank) FROM venerable_ranks)) > v_acc THEN
            v_blocked := v_blocked + 1;
            v_freed := v_freed || v_acc::TEXT || ' ';
        END IF;
    END LOOP;

    IF v_blocked = 0 THEN
        RAISE EXCEPTION
            'no cultivator would have been blocked by the old quota, so this '
            'probe is not measuring the bug 0552 was written for';
    END IF;

    RAISE NOTICE
        '% cultivator(s) were locked out of the apex and are not any more '
        '(aspect counts: %)', v_blocked, trim(v_freed);

    -- 4. AND A FULL DAO IS NOT DISCOUNTED. Somebody carrying six accruing
    --    aspects must still realise all six; `LEAST` must cap, not relax.
    IF EXISTS (
        SELECT 1
        FROM (SELECT p.player_id,
                     count(*) FILTER (WHERE a.source_kind IN
                                      (SELECT source_kind FROM dao_deed_rates)) AS acc
              FROM players p CROSS JOIN LATERAL dao_aspects(p.player_id) a
              WHERE p.deleted_at IS NULL AND p.discord_id > 0
              GROUP BY p.player_id) x
        CROSS JOIN venerable_ranks v
        WHERE v.rank = (SELECT max(rank) FROM venerable_ranks)
          AND x.acc >= v.aspects_required
          AND LEAST(v.aspects_required, x.acc) < v.aspects_required
    ) THEN
        RAISE EXCEPTION
            'a cultivator with a full set of aspects had the apex discounted';
    END IF;

    -- 5. AND IT IS STILL CHEAP. 0551 brought a standing read from 7.3 ms to
    --    1.8 ms and this adds a count over the same materialised set, so it
    --    must not have given that back.
    IF EXISTS (SELECT 1 FROM player_dao) THEN
        SELECT d.player_id INTO v_who FROM player_dao d LIMIT 1;
        v_t0 := clock_timestamp();
        FOR v_n IN 1..20 LOOP PERFORM player_standing(v_who); END LOOP;
        v_ms := EXTRACT(epoch FROM clock_timestamp() - v_t0) * 1000 / 20;

        RAISE NOTICE 'player_standing for a Venerable: % ms a call', round(v_ms, 2);

        IF v_ms > 4 THEN
            RAISE EXCEPTION
                'a standing read costs % ms again - it is read per Gu and per '
                'effect, and at this price a preset load times out', round(v_ms, 2);
        END IF;
    END IF;
END
$probe$;
