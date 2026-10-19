-- 0265_the_worth_needs_its_own_first_wave_too
--
-- 0264 gave the gauntlet's appetite its own step and left it reading the
-- difficulty's START. That dial sets how much health wave one carries, and it
-- is 0.35 because a first wave is meant to be a warm-up nobody loses to. Read
-- as an appetite it says a first wave is a third of a beast, and against the
-- gentler step the floor of one swallowed the whole early curve:
--
--     wave 1 costs 1, wave 17 costs 1, wave 25 costs 1
--
-- which the test suite caught on the invariant 0229 wrote down - a deep wave
-- has to cost the sea more than the first one does. Twenty-five flat waves
-- and then growth is not a curve, it is a cliff with a ramp after it.
--
-- The separation was half done. The worth gets its own first wave as well as
-- its own step: one beast, because that is what a wave of the tide IS, and it
-- climbs from there.
--
--     wave  1 costs 1        wave 26 costs 2
--     wave 17 costs 2        wave 40 costs 4
--
-- A full run costs 84 against the 58 the sea hands each hand - within the
-- bargain 0264 set, and still twenty times less than the 1,462 that was
-- ending tides in three minutes. Tide 3504 would take about seven full runs
-- to drain rather than one and a quarter.
--
-- Difficulty is untouched for the third time: `horde_gauntlet_start` and
-- `horde_gauntlet_step` still say exactly what a wave costs to beat. Neither
-- of them says anything about the sea any more.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_gauntlet_worth_start', 0.9,
     'What the first gauntlet wave takes out of the sea, in beasts. One, '
     'because a wave of the tide is a beast of the tide. Separate from '
     'horde_gauntlet_start, which is how much health wave one carries.');

UPDATE game_config
SET value = 1.04,
    description =
        'How much more of the sea each wave represents than the one before '
        'it. Separate from horde_gauntlet_step, which is difficulty: a wave '
        'should get much harder as it goes without also deciding it is '
        'sixty-five beasts. Set so a full run costs about one hand''s share '
        'of a tide, and so the middle of a run already costs more than its '
        'first wave.'
WHERE key = 'horde_gauntlet_worth_step';

UPDATE game_config
SET description =
    'The first wave, as a fraction of what one beast of this tide would '
    'carry. Wave one is meant to be a warm-up nobody loses to. This is '
    'HEALTH only; what a wave takes out of the sea is '
    'horde_gauntlet_worth_start.'
WHERE key = 'horde_gauntlet_start';


CREATE OR REPLACE FUNCTION horde_gauntlet_worth(p_wave INTEGER)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, round(
        game_config_value('horde_gauntlet_worth_start')
        * power(game_config_value('horde_gauntlet_worth_step'),
                GREATEST(0, p_wave - 1))))::smallint;
$$;


-- ---------------------------------------------------------------------------
-- The curve 0229 asked for, and the budget 0264 set
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    share NUMERIC;
    run   INTEGER;
    worst INTEGER;
BEGIN
    share := game_config_value('horde_beasts_per_hand') * (1 + 1 * 0.15);

    SELECT sum(horde_gauntlet_worth(i)), max(horde_gauntlet_worth(i))
    INTO run, worst
    FROM generate_series(1, 40) i;

    -- 0229: a first wave is one beast, and a deep one is more than that.
    IF horde_gauntlet_worth(1) <> 1 THEN
        RAISE EXCEPTION 'a first wave costs %, not one',
            horde_gauntlet_worth(1);
    END IF;

    IF horde_gauntlet_worth(17) <= horde_gauntlet_worth(1) THEN
        RAISE EXCEPTION
            'the middle of a run still costs what its first wave did';
    END IF;

    -- The early curve must not be flat for most of a run. This is the shape
    -- 0264 accidentally produced: twenty-five waves at one beast each.
    IF horde_gauntlet_worth(13) <= horde_gauntlet_worth(1)
       AND horde_gauntlet_worth(17) <= horde_gauntlet_worth(13) THEN
        RAISE EXCEPTION 'the first half of a run is a flat line';
    END IF;

    -- 0264: a run costs about what a hand is given, and no wave is a bite.
    IF run > share * 2 THEN
        RAISE EXCEPTION 'a full run costs % against a share of %',
            run, round(share);
    END IF;

    IF worst > share / 4 THEN
        RAISE EXCEPTION 'the deepest wave alone costs % against a share of %',
            worst, round(share);
    END IF;

    IF run < 10 THEN
        RAISE EXCEPTION 'a full run costs only %; the sea will not empty', run;
    END IF;

    RAISE NOTICE 'full run %, dearest wave %, one hand is given %',
        run, worst, round(share);
END;
$$;


-- ---------------------------------------------------------------------------
-- And the runs that actually happened
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide    RECORD;
    biggest NUMERIC := 0;
BEGIN
    FOR tide IN
        SELECT g.wave, h.beasts_total,
               (SELECT sum(horde_gauntlet_worth(i))
                FROM generate_series(1, GREATEST(g.wave, 1)) i) AS costs_now
        FROM horde_gauntlets g
        JOIN beast_hordes h ON h.horde_id = g.horde_id
        WHERE g.wave > 0
    LOOP
        biggest := GREATEST(biggest, tide.costs_now::numeric / tide.beasts_total);
    END LOOP;

    IF biggest = 0 THEN
        RAISE NOTICE 'no runs on the books; the tests carry this';
        RETURN;
    END IF;

    IF biggest > 0.34 THEN
        RAISE EXCEPTION 'the deepest real run still takes % pct of its tide',
            round(biggest * 100);
    END IF;

    RAISE NOTICE 'the deepest run on the books now takes % pct of its tide',
        round(biggest * 100);
END;
$$;
