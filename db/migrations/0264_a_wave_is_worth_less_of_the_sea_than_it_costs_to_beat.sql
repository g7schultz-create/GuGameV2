-- 0264_a_wave_is_worth_less_of_the_sea_than_it_costs_to_beat
--
-- Tides are allotted two hours and end in three minutes. The last six:
--
--     3504  580 beasts   3.2 min      3096  512 beasts   9.7 min
--     3387  580 beasts  44.7 min      2707  512 beasts   4.1 min
--      886  580 beasts   4.5 min       656  580 beasts   5.9 min
--
-- The cause is one number. A gauntlet wave charges the sea
-- `horde_gauntlet_worth(wave)` = 0.35 x 1.18^(wave-1), so the cost of a wave
-- compounds at eighteen per cent forever:
--
--     wave 20 costs   10        wave 33 costs   65
--     wave 26 costs   22        wave 40 costs  223
--
-- A run to wave 33 charges 461 beasts. The sea was 580. In tide 3504 miyuki
-- walked the line once, ate four fifths of the tide by herself, and pashu0 got
-- one wave in before the whole thing was over. A sea sized at 40 beasts per
-- hand is handing every player 58 beasts and letting one of them spend 461.
--
-- The mistake is that ONE dial was doing two jobs. `horde_gauntlet_step` is
-- the difficulty curve - it scales each wave's health, and it is why a run
-- ends on its own without a wave limit - and it was also being read as how
-- much of the sea a wave represents. Those are not the same question. A wave
-- SHOULD get much harder as it goes, and eighteen per cent compounding is
-- what makes a run end around wave 33 instead of running forever. What it
-- should not do is decide that the thirty-third wave is sixty-five beasts.
--
-- So the worth gets its own step. Difficulty stays exactly where it is; only
-- the accounting changes:
--
--     wave 20 costs 1 (was  10)      wave 33 costs 2 (was  65)
--     wave 26 costs 1 (was  22)      wave 40 costs 3 (was 223)
--
-- and a run to wave 33 now charges 41 rather than 461. That is a hair over
-- one hand's share of 58, which is the number the sea was built from: a tide
-- is sized per person, so one person's complete run should cost about one
-- person's share. Tide 3504 would have taken ten such runs to drain instead
-- of one and a quarter.
--
-- The King still rises, which is the thing a bigger sea would have broken:
-- draining is what brings him out, and ten runs is a long event, not an
-- impossible one.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_gauntlet_worth_step', 1.06,
     'How much more of the sea each wave represents than the one before it. '
     'Separate from horde_gauntlet_step, which is difficulty: a wave should '
     'get much harder as it goes without also deciding it is sixty-five '
     'beasts. Set so a full run costs about one hand''s share of a tide.');

UPDATE game_config
SET description =
    'How much harder each wave is than the one before - health and the bite '
    'both. Compounding, so a run ends on its own without a wave limit. This '
    'is difficulty ONLY; what a wave takes out of the sea is '
    'horde_gauntlet_worth_step.'
WHERE key = 'horde_gauntlet_step';


CREATE OR REPLACE FUNCTION horde_gauntlet_worth(p_wave INTEGER)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, round(
        game_config_value('horde_gauntlet_start')
        * power(game_config_value('horde_gauntlet_worth_step'),
                GREATEST(0, p_wave - 1))))::smallint;
$$;

COMMENT ON FUNCTION horde_gauntlet_worth(INTEGER) IS
    'How many beasts one gauntlet wave takes out of the sea. Grows on its own step, not the difficulty one - a wave that is sixty-five times harder than the first is not sixty-five beasts.';


-- ---------------------------------------------------------------------------
-- A run costs about what a hand is given
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    share  NUMERIC;
    run    INTEGER;
    worst  INTEGER;
    deep   INTEGER := 40;
BEGIN
    -- What the sea hands one player, at the shallowest band - the tightest
    -- case, because the sea grows with the band and the worth does not.
    share := game_config_value('horde_beasts_per_hand') * (1 + 1 * 0.15);

    SELECT sum(horde_gauntlet_worth(i)), max(horde_gauntlet_worth(i))
    INTO run, worst
    FROM generate_series(1, deep) i;

    IF run > share * 2 THEN
        RAISE EXCEPTION
            'a full run costs % against a share of %', run, round(share);
    END IF;

    -- No single wave may be a meaningful bite out of the tide. This is the
    -- shape of the old bug rather than its size: 223 against a share of 46.
    IF worst > share / 4 THEN
        RAISE EXCEPTION
            'the deepest wave alone costs % against a share of %',
            worst, round(share);
    END IF;

    -- And the sea must still be drainable, or the King never comes out.
    IF run < 10 THEN
        RAISE EXCEPTION
            'a full run costs only % - the sea will not empty in an evening', run;
    END IF;

    RAISE NOTICE 'full run %, dearest wave %, one hand is given %',
        run, worst, round(share);
END;
$$;


-- ---------------------------------------------------------------------------
-- Against the tides that actually happened
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    tide    RECORD;
    now_it  INTEGER;
    biggest NUMERIC := 0;
BEGIN
    -- Every real gauntlet run this server has seen, recharged at the new rate
    -- and measured against the sea it was actually drawing from.
    FOR tide IN
        SELECT g.gauntlet_id, g.wave, h.beasts_total,
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

    -- The deepest run this server has ever seen went to wave 34 and took 543
    -- of 580. Nobody should be able to take a third of a tide alone.
    IF biggest > 0.34 THEN
        RAISE EXCEPTION
            'the deepest real run still takes % pct of its tide',
            round(biggest * 100);
    END IF;

    RAISE NOTICE 'the deepest run on the books now takes % pct of its tide',
        round(biggest * 100);
END;
$$;
