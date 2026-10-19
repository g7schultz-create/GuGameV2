-- 0481_a_cache_worth_finding_twice_over
--
-- 0479 set a cache of jade at 4.13 a roll and called it "deliberately on the
-- low side of a dial I expect to be turned". It is turned.
--
-- THE ARGUMENT, AND IT IS RIGHT: a jade cache is behind TWO rolls, not one.
-- You have to find the tile - one cache on thirty dark squares with sixteen
-- actions to spend - and then roll well on it. A world beast is behind one
-- roll and a fight, and the ledger says what it pays:
--
--     784 hours, 30 cultivators
--     dungeon_spoils   437 grants   19,417 jade   44.4 each
--     world_beast     1052 grants   18,104 jade   17.2 each
--     daily            281 grants    4,292 jade   15.3 each
--
-- A thing you had to find AND roll for, paying a quarter of what a world
-- beast pays for turning up, is not a cache. It is a consolation.
--
-- SO THE BANDS MOVE, to about 22 a roll:
--
--     1-40    8-14      a few coins somebody dropped
--     41-70   15-25     a working purse
--     71-90   26-40     somebody's savings
--     91-98   41-70     a merchant's strongbox
--     99      100       a tribute that never arrived
--     100     200       the whole seam
--
-- That puts a FOUND cache above a world beast kill, which is the right order
-- given it took two rolls to get there, and a hundred now pays two hundred -
-- a number worth shouting about, which is what the die was for.
--
-- WHAT IT MEANS PER HOUR, stated so it can be argued with: roughly 22 a cache,
-- found maybe half the time a delve is walked, so about 10 an hour to somebody
-- delving every hour and routing toward it. The whole server currently mints
-- about 79 jade an hour from every source combined, so a dozen cultivators
-- delving hourly would roughly double that. That is the figure to watch, and
-- `delve_jade_rolls` is still one UPDATE away if it reads too generous in a
-- week.
--
-- Forward-only. Do not edit once applied.


UPDATE delve_jade_rolls SET jade_min =  8, jade_max =  14,
    said = 'A few coins somebody dropped.'                     WHERE low =   1;
UPDATE delve_jade_rolls SET jade_min = 15, jade_max =  25,
    said = 'A working purse, and nobody left to want it.'      WHERE low =  51;
UPDATE delve_jade_rolls SET jade_min = 26, jade_max =  40,
    said = 'Somebody''s savings. They never came back for it.' WHERE low =  81;
UPDATE delve_jade_rolls SET jade_min = 41, jade_max =  70,
    said = 'A merchant''s strongbox, still locked.'            WHERE low =  96;
UPDATE delve_jade_rolls SET jade_min = 50, jade_max =  50,
    said = 'The whole seam. You will not see this again.'      WHERE low = 100;

-- The bands themselves move too: the old ones bunched four fifths of the
-- rolls into the bottom two, which is where a die stops being interesting.
UPDATE delve_jade_rolls SET high = 40 WHERE low = 1;
UPDATE delve_jade_rolls SET low = 41, high = 70 WHERE low = 51;
UPDATE delve_jade_rolls SET low = 71, high = 90 WHERE low = 81;
UPDATE delve_jade_rolls SET low = 91, high = 98 WHERE low = 96;

-- And a hundred is worth being a hundred.
INSERT INTO delve_jade_rolls (low, high, jade_min, jade_max, said) VALUES
    (99, 99, 100, 100, 'A tribute that never reached whoever it was for.')
ON CONFLICT (low) DO UPDATE
SET high = EXCLUDED.high, jade_min = EXCLUDED.jade_min,
    jade_max = EXCLUDED.jade_max, said = EXCLUDED.said;

UPDATE delve_jade_rolls
SET jade_min = 200, jade_max = 200,
    said = 'The whole seam. You will not see this again.'
WHERE low = 100;


-- ---------------------------------------------------------------------------
-- A found cache beats a world beast, and the die still covers every face
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_gap   INTEGER;
    v_avg   NUMERIC;
    v_beast NUMERIC;
    r       RECORD;
BEGIN
    -- Every face still lands on exactly one band. Moving band edges by hand
    -- is precisely how a hole gets left in the middle of a die.
    SELECT count(*) INTO v_gap
    FROM generate_series(1, 100) f
    WHERE (SELECT count(*) FROM delve_jade_rolls r2
           WHERE f BETWEEN r2.low AND r2.high) <> 1;
    IF v_gap > 0 THEN
        RAISE EXCEPTION
            '% faces of the die land on no band, or on two', v_gap;
    END IF;

    -- And they still climb.
    IF EXISTS (
        SELECT 1 FROM delve_jade_rolls a JOIN delve_jade_rolls b ON b.low > a.low
        WHERE b.jade_max < a.jade_max
    ) THEN
        RAISE EXCEPTION 'a higher roll pays less than a lower one';
    END IF;

    SELECT sum((r2.high - r2.low + 1) * (r2.jade_min + r2.jade_max) / 2.0) / 100
    INTO v_avg FROM delve_jade_rolls r2;

    -- What a world beast actually pays, read off the ledger rather than
    -- remembered, so this comparison ages with the game.
    SELECT COALESCE(avg(j.delta), 0) INTO v_beast
    FROM jade_ledger j WHERE j.reason = 'world_beast';

    RAISE NOTICE
        'a cache averages % against a world beast''s % - and takes two rolls',
        round(v_avg, 2), round(v_beast, 1);

    FOR r IN SELECT * FROM delve_jade_rolls ORDER BY low LOOP
        RAISE NOTICE '  % to %   % to % jade',
            lpad(r.low::text, 3), lpad(r.high::text, 3),
            lpad(r.jade_min::text, 3), lpad(r.jade_max::text, 3);
    END LOOP;

    IF v_beast > 0 AND v_avg <= v_beast THEN
        RAISE EXCEPTION
            'a cache still pays % against a world beast''s %, behind two rolls',
            round(v_avg, 2), round(v_beast, 1);
    END IF;

    -- And it has not become the only thing worth doing either. A dungeon run
    -- is the richest jade in the game and should stay that way.
    IF v_avg > 60 THEN
        RAISE EXCEPTION
            'a cache averages %, which is more than a dungeon run', round(v_avg, 2);
    END IF;
END;
$probe$;
