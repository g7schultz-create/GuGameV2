-- 0551_a_rung_read_once_not_ten_times
--
-- Clea could not use a preset. The reason turned out to be the only thing in
-- this update that got slower rather than wrong.
--
--     clearwest    16 Gu, ASCENDED      5,351 ms
--     clearwest    11 Gu, ASCENDED      5,121 ms
--     m_i_y_u_k_i. 41 Gu, not ascended    488 ms
--     pashu0       35 Gu, not ascended    272 ms
--     shinonn._.   34 Gu, not ascended    443 ms
--
-- Fewer Gu than anybody else and twelve times slower, and the only difference
-- is a `player_dao` row. Discord voids an interaction token three seconds
-- after it is created, so `load_preset` finishing in five guaranteed error
-- 10062 - the preset went on, the screen never changed, and the player was
-- told the interaction failed. The cog now defers; this is the cause.
--
-- WHY ASCENDING COSTS SO MUCH. `player_standing` is read per equipped Gu by
-- `enforce_gu_capacity`, and then per EFFECT by `gu_effect_cap` through the
-- body recompute - 27 effects times sixteen worms is some hundreds of reads in
-- one preset load. That was fine while the read was free:
--
--     player_standing     not ascended   0.25 ms      the EXISTS short-circuits
--     player_standing     ASCENDED       7.30 ms      28x
--
-- and the 28x is `venerable_rank_of` evaluating `dao_understanding` TEN TIMES
-- per call. Both of its tests are correlated against `venerable_ranks`:
--
--     AND dao_understanding_total(p_player_id) >= v.understanding_required
--     AND (SELECT count(*) FROM dao_understanding(p_player_id) u
--          WHERE u.understanding >= v.per_aspect_required) >= v.aspects_required
--
-- so the aspect set is rebuilt once per rung - nine times - and
-- `dao_understanding_total` is a tenth, each one walking `path_casts_of`,
-- `gu_carried_seconds`, `player_skills` and `player_physique`.
--
-- The EXISTS guard 0519 put on `player_standing` was supposed to make this
-- free. It only ever helped the people who had NOT crossed: for a Venerable it
-- passes and the full chain runs every time. The guard was measured against a
-- world where nobody had ascended, which is the same mistake as 0550's curve
-- being tuned only at the apex.
--
-- THE FIX IS WHEN, NOT WHAT. The aspect set is materialised once and both
-- tests read it. Nothing about which rung anybody holds changes, and the probe
-- below asserts that against a reference implementation rather than trusting
-- it - including at a non-zero understanding, which is reached by raising a
-- deed counter the body aspect actually reads.
--
-- Not cached. A rung is still computed from live deeds every time it is asked
-- for, because understanding accrues by the second and a cached rung would be
-- a second definition of how far somebody has got. One definition, read once.


CREATE OR REPLACE FUNCTION venerable_rank_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- The highest rung whose three demands are all met, and NULL for anybody
    -- whose Dao is not stamped.
    --
    -- MATERIALIZED is the whole point of this function's shape: without it the
    -- planner inlines `mine` into both tests and rebuilds the aspect set once
    -- per rung, which is the ten evaluations 0551 was written to stop. The
    -- hint is load-bearing, not decoration.
    WITH mine AS MATERIALIZED (
        SELECT u.understanding
        FROM dao_understanding(p_player_id) u
        -- The same EXISTS that guards `player_standing`, kept here so an
        -- unstamped cultivator does no work at all rather than building an
        -- empty set the long way.
        WHERE EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
    ),
    summed AS MATERIALIZED (
        -- Exactly `dao_understanding_total`: a sum over the same rows, which
        -- are already rounded to three places by `dao_understanding`. Summing
        -- the rounded values is what the old call did too, so the total is
        -- identical rather than merely close.
        SELECT COALESCE(sum(m.understanding), 0)::NUMERIC AS total FROM mine m
    )
    SELECT max(v.rank)
    FROM venerable_ranks v CROSS JOIN summed s
    WHERE EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
      AND s.total >= v.understanding_required
      AND (SELECT count(*) FROM mine m
           WHERE m.understanding >= v.per_aspect_required) >= v.aspects_required;
$fn$;

COMMENT ON FUNCTION venerable_rank_of(BIGINT) IS
    'The highest Venerable rung whose understanding, aspect count and per-aspect floor are all met; NULL for anybody who has not ascended. Reads the aspect set ONCE (0551) - it is called per Gu and per effect through `gu_effect_cap`, and rebuilding it per rung made a preset load twelve times slower for a Venerable than for anybody else.';


-- ---------------------------------------------------------------------------
-- The probe
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_mine  BIGINT;
    v_ref   SMALLINT;
    v_got   SMALLINT;
    v_bump  INTEGER;
    v_t0    TIMESTAMPTZ;
    v_fast  NUMERIC;
    v_n     INTEGER := 0;
    v_seen  TEXT := '';
BEGIN
    -- 1. NOBODY'S RUNG MOVED. Against a reference implementation written out
    --    the long way - the shape the function had before this migration - so
    --    this compares the new answer with the old RULE rather than with the
    --    new code's own opinion.
    FOR v_who IN SELECT d.player_id FROM player_dao d LOOP
        SELECT max(v.rank) INTO v_ref
        FROM venerable_ranks v
        WHERE dao_understanding_total(v_who) >= v.understanding_required
          AND (SELECT count(*) FROM dao_understanding(v_who) u
               WHERE u.understanding >= v.per_aspect_required)
              >= v.aspects_required;

        v_got := venerable_rank_of(v_who);
        IF v_got IS DISTINCT FROM v_ref THEN
            RAISE EXCEPTION
                'player % reads rung % and the rule says %', v_who, v_got, v_ref;
        END IF;
        v_n := v_n + 1;
    END LOOP;

    RAISE NOTICE '% stamped cultivator(s) read the same rung as before', v_n;

    -- 2. AND AT A NON-ZERO UNDERSTANDING TOO. Everybody stamped today sits at
    --    zero, so agreeing there says very little.
    --
    --    This uses a REAL Dao rather than a synthetic one. The first attempt
    --    built a probe cultivator from one Path attainment and raised
    --    `body_level`, and understanding did not budge: a Dao is read off what
    --    you HAVE, and that cultivator had no body aspect for the counter to
    --    feed. The non-vacuity guard below caught it, which is the only reason
    --    this is not a probe that passes while testing nothing.
    --
    --    `dao_deed_of('body', ...)` reads `player_physique.body_level`, so
    --    raising it above the stamped baseline moves that aspect for real, and
    --    across enough values to cross several per-aspect floors - which is
    --    precisely the inner count(*) this migration restructured.
    IF EXISTS (SELECT 1 FROM player_dao) THEN
        BEGIN
            SELECT a.player_id INTO v_mine
            FROM player_dao_aspects a
            WHERE a.source_kind = 'body'
            ORDER BY a.player_id LIMIT 1;

            IF v_mine IS NULL THEN
                RAISE NOTICE
                    'no stamped Dao carries a body aspect, so the non-zero '
                    'comparison is skipped rather than faked';
            ELSE
                FOREACH v_bump IN ARRAY ARRAY[1, 2000, 4000, 8000, 12000] LOOP
                    -- SMALLINT, so nothing above 32767: 90000 overflowed it and
                    -- took the whole migration down on the first run, which is
                    -- the probe doing its job on itself.
                    UPDATE player_physique SET body_level = v_bump
                    WHERE player_id = v_mine;

                    SELECT max(v.rank) INTO v_ref
                    FROM venerable_ranks v
                    WHERE dao_understanding_total(v_mine) >= v.understanding_required
                      AND (SELECT count(*) FROM dao_understanding(v_mine) u
                           WHERE u.understanding >= v.per_aspect_required)
                          >= v.aspects_required;

                    v_got := venerable_rank_of(v_mine);
                    IF v_got IS DISTINCT FROM v_ref THEN
                        RAISE EXCEPTION
                            'at body_level % the function says rung % and the '
                            'rule says %', v_bump, v_got, v_ref;
                    END IF;

                    v_seen := v_seen
                        || round(dao_understanding_total(v_mine), 1)::TEXT || ' ';
                END LOOP;

                -- The understanding MUST have moved, or the five passes above
                -- are one pass run five times and the agreement is worth
                -- nothing. This is the assertion that caught the synthetic
                -- cultivator reading 0.0 five times over.
                IF (SELECT count(DISTINCT w)
                    FROM unnest(string_to_array(trim(v_seen), ' ')) w) < 4 THEN
                    RAISE EXCEPTION
                        'the body bumps barely moved understanding (%) - this '
                        'compared the same state five times over', trim(v_seen);
                END IF;

                RAISE NOTICE
                    'the two agree across understandings: %', trim(v_seen);
            END IF;

            -- 3. AND AN UNSTAMPED CULTIVATOR STILL READS NULL, which three
            --    readers depend on since 0538: `player_standing` floors at 1,
            --    so a missing rung must stay missing rather than becoming one.
            INSERT INTO players (discord_id, discord_name)
            VALUES (-7777, 'rung-probe') RETURNING player_id INTO v_who;
            IF venerable_rank_of(v_who) IS NOT NULL THEN
                RAISE EXCEPTION 'an unstamped cultivator was handed a rung';
            END IF;

            RAISE EXCEPTION 'probe-ok';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
        END;
    ELSE
        RAISE NOTICE
            'nobody has ascended, so there is no live rung to compare - '
            'tests/test_venerable.py pins the rule instead';
    END IF;

    -- 4. AND IT IS ACTUALLY FASTER, for the one cultivator who has crossed.
    --    A behavioural assertion, because the point of the migration is the
    --    clock: 7.3 ms a call is what made a preset time out, and a rewrite
    --    that reads prettier without being quicker fixes nothing.
    IF EXISTS (SELECT 1 FROM player_dao) THEN
        SELECT d.player_id INTO v_who FROM player_dao d LIMIT 1;
        v_t0 := clock_timestamp();
        FOR v_bump IN 1..20 LOOP
            PERFORM player_standing(v_who);
        END LOOP;
        v_fast := EXTRACT(epoch FROM clock_timestamp() - v_t0) * 1000 / 20;

        RAISE NOTICE 'player_standing for a Venerable: % ms a call (was 7.3)',
                     round(v_fast, 2);

        IF v_fast > 4 THEN
            RAISE EXCEPTION
                'a standing read still costs % ms - it is read per Gu and per '
                'effect, so this has to be cheap', round(v_fast, 2);
        END IF;
    END IF;
END
$probe$;
