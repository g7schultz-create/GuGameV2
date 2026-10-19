-- 0523_the_first_rung_is_granted_by_the_sky
--
-- 0521 floored `venerable_rank_of` at the first rung once a Dao is stamped,
-- because a cultivator who had just crossed the tribulation held zero
-- understanding, met no rung, read NULL and stood at 18 to the rest of the
-- game - they would have ascended into nothing.
--
-- THE FLOOR WAS IN THE WRONG PLACE. Four standing tests said so, and they are
-- right:
--
--     test_the_rung_reads_its_demands_from_the_table
--     "Tuning the ladder is an UPDATE, so the reader must not hard-code any
--      of it."
--
-- A GREATEST against min(rank) inside the reader is exactly that hard-coding:
-- it makes the first rung free in a way no row in `venerable_ranks` says, so
-- the table and the function disagree about what V1 costs. The table says 400
-- understanding across 2 aspects; the function hands it out for nothing.
--
-- So the grant moves into the table. V1 asks for nothing, which is TRUE -
-- it is paid for with the Sovereign Calamity - and `venerable_rank_of` goes
-- back to the plain max() that reads its demands from the row.
--
-- AND THE LADDER ABOVE IT DOES NOT MOVE. The eight rungs after V1 keep the
-- thresholds 0495 tuned - 650, 1000, 1500, 2200, 3200, 4600, 6800, 10000 - so
-- the top of the realm is still 10,000 understanding away. Only the 400 rung
-- goes, because the sky now stands where it stood. The first climb is 0 to
-- 650 rather than 400 to 650, which is a LONGER first bar than before, and
-- the whole reason the nine rungs exist is that the last realm "was passed too
-- fast".
--
-- Forward-only. Do not edit once applied.


-- Three constraints said every rung costs understanding:
--
--     understanding_required > 0
--     aspects_required      >= 1
--     per_aspect_required    > 0
--
-- which was right when every rung did. They are replaced by ONE constraint
-- that says what the rule actually is - every rung ABOVE THE FIRST costs
-- understanding, and the first costs a tribulation - rather than three that
-- have to be read together and still do not say it.
ALTER TABLE venerable_ranks
    DROP CONSTRAINT venerable_ranks_understanding_required_check,
    DROP CONSTRAINT venerable_ranks_aspects_required_check,
    DROP CONSTRAINT venerable_ranks_per_aspect_required_check,
    ADD CONSTRAINT venerable_ranks_demands_are_not_negative
        CHECK (understanding_required >= 0 AND aspects_required >= 0
               AND per_aspect_required >= 0),
    ADD CONSTRAINT venerable_ranks_only_the_first_is_granted
        CHECK (venerable_tier = 1
               OR (understanding_required > 0 AND aspects_required >= 1
                   AND per_aspect_required > 0));


-- The sky is the price of the first rung.
UPDATE venerable_ranks
SET understanding_required = 0,
    aspects_required       = 0,
    per_aspect_required    = 0,
    description = 'Granted by the Sovereign Calamity itself. Nothing is asked '
                  || 'of your understanding here - you have not had time to '
                  || 'understand anything. What was asked, you survived.'
WHERE venerable_tier = 1;


CREATE OR REPLACE FUNCTION venerable_rank_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- The highest rung whose three demands are all met, and NULL for anybody
    -- whose Dao is not stamped.
    --
    -- Back to the plain max() 0490 wrote. 0521 wrapped this in a GREATEST
    -- against min(rank) to keep a freshly-ascended cultivator off the floor,
    -- which worked and was in the wrong place: it made the first rung free in
    -- a way no row in `venerable_ranks` said, so the table and the reader
    -- disagreed about what V1 costs. The first rung asks for nothing now, and
    -- it says so in its own row.
    SELECT max(v.rank)
    FROM venerable_ranks v
    WHERE EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id)
      AND dao_understanding_total(p_player_id) >= v.understanding_required
      AND (SELECT count(*) FROM dao_understanding(p_player_id) u
           WHERE u.understanding >= v.per_aspect_required) >= v.aspects_required;
$fn$;


-- ---------------------------------------------------------------------------
-- The ladder still climbs, and the crossing still lands on V1
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid  BIGINT;
    v_path TEXT;
    v_bad  TEXT;
    v_n    INTEGER;
BEGIN
    -- Exactly one rung is free, and it is the first.
    SELECT string_agg('V' || venerable_tier, ', ') INTO v_bad
    FROM venerable_ranks
    WHERE understanding_required = 0 AND venerable_tier <> 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs are free and should not be: %', v_bad;
    END IF;
    IF (SELECT understanding_required FROM venerable_ranks WHERE venerable_tier = 1)
       <> 0 THEN
        RAISE EXCEPTION 'the first rung still has a price the sky already paid';
    END IF;

    -- And the eight above it are untouched, so the realm is no shorter.
    IF (SELECT max(understanding_required) FROM venerable_ranks) <> 10000 THEN
        RAISE EXCEPTION
            'the top of the ladder moved to %',
            (SELECT max(understanding_required) FROM venerable_ranks);
    END IF;
    SELECT count(*) INTO v_n
    FROM venerable_ranks a JOIN venerable_ranks b ON b.rank = a.rank + 1
    WHERE b.understanding_required <= a.understanding_required
       OR b.aspects_required < a.aspects_required;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% rungs do not ask more than the one below', v_n;
    END IF;

    -- The reader hard-codes nothing: the first rung is free because its ROW
    -- says so, which a probe proves by putting a price back on it.
    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-996, 'rung-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());

        PERFORM venerable_ascend(v_pid);

        IF venerable_rank_of(v_pid) <> 19 THEN
            RAISE EXCEPTION
                'a crossing landed on rung % rather than the first',
                venerable_rank_of(v_pid);
        END IF;
        IF player_standing(v_pid) <> 19 THEN
            RAISE EXCEPTION
                'a Venerable stands at % to the game', player_standing(v_pid);
        END IF;
        IF dao_understanding_total(v_pid) <> 0 THEN
            RAISE EXCEPTION
                'the point of this probe is a cultivator with no understanding, and they have %',
                dao_understanding_total(v_pid);
        END IF;

        -- Put a price back on the first rung: the reader must follow the row.
        UPDATE venerable_ranks SET understanding_required = 1
        WHERE venerable_tier = 1;
        IF venerable_rank_of(v_pid) IS NOT NULL THEN
            RAISE EXCEPTION
                'the reader kept granting the first rung after the table charged for it - the floor is still hard-coded';
        END IF;

        -- And the bar starts empty rather than part-filled.
        UPDATE venerable_ranks SET understanding_required = 0
        WHERE venerable_tier = 1;
        IF (SELECT p.next_tier FROM venerable_progress(v_pid) p) <> 2 THEN
            RAISE EXCEPTION
                'a fresh Venerable is pointed at rung % rather than the second',
                (SELECT p.next_tier FROM venerable_progress(v_pid) p);
        END IF;
        IF (SELECT p.fraction FROM venerable_progress(v_pid) p) <> 0 THEN
            RAISE EXCEPTION
                'a fresh Venerable''s bar is already % percent full',
                (SELECT round(p.fraction * 100) FROM venerable_progress(v_pid) p);
        END IF;
        IF (SELECT p.required - p.floor_at FROM venerable_progress(v_pid) p) <> 650 THEN
            RAISE EXCEPTION
                'the first climb is % understanding rather than 650',
                (SELECT p.required - p.floor_at FROM venerable_progress(v_pid) p);
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody alive is stamped, so nobody's rung moved today.
    SELECT count(*) INTO v_n
    FROM players p WHERE p.deleted_at IS NULL
      AND venerable_rank_of(p.player_id) IS NOT NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators hold a Venerable rung already', v_n;
    END IF;

    RAISE NOTICE
        'the first rung is paid for with the sky; the eight above it still cost % understanding',
        (SELECT max(understanding_required) FROM venerable_ranks);
END;
$probe$;
