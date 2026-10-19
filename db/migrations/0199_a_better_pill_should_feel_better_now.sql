-- 0199_a_better_pill_should_feel_better_now
--
-- `grant_boost` banked an hours-weighted AVERAGE, and one row per kind held
-- it. So a good pill dissolved into whatever was already there:
--
--     m_i_y_u_k_i. held  978 hours at  +80%
--     swallowed          153 hours at +240%
--     came out with    1,131 hours at +101%
--
-- She paid a grade 7 pill for twenty-one percentage points. Take another and
-- it is worse: the bigger the stockpile, the less any new pill can move it.
-- The reward for saving pills was that pills stopped working.
--
-- The averaging was mine, in 0194, and I defended it there - hours bought at
-- the old rate should not be retroactively upgraded. That part is still true.
-- What was wrong is the other half: hours bought at the NEW rate should not be
-- retroactively DOWNGRADED either, and an average does both.
--
-- So boosts are stacks now, one row per rate, and the strongest is spent
-- first. Swallow a +240% pill and the next 153 settled hours run at 240%; the
-- +80% hours wait their turn underneath. Nothing is averaged, nothing is lost,
-- and the pill you just took is the pill you feel.
--
--     player_boosts PK  (player_id, kind)  ->  (player_id, kind, magnitude)
--
-- The settle already multiplies `boost * hours` into an hours-equivalent, so
-- several stacks compose without touching its arithmetic: the extra is just
-- the sum of magnitude x hours over the stacks it drank from.
--
-- Nobody's banked hours change. The four rows alive keep every hour they
-- have, at the rate they were averaged to - that average is now simply the
-- first stack rather than the only one.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE player_boosts DROP CONSTRAINT player_boosts_pkey;
ALTER TABLE player_boosts ADD PRIMARY KEY (player_id, kind, magnitude);


-- Accumulate a stack rather than blend one. Same signature, same return - the
-- total hours banked for the kind, which is what `take_pill` tells the player.
CREATE OR REPLACE FUNCTION grant_boost(
    p_player_id BIGINT, p_kind TEXT, p_magnitude NUMERIC, p_hours NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    total NUMERIC;
BEGIN
    INSERT INTO player_boosts (player_id, kind, magnitude, hours_left)
    VALUES (p_player_id, p_kind, p_magnitude, p_hours)
    ON CONFLICT (player_id, kind, magnitude) DO UPDATE SET
        hours_left = player_boosts.hours_left + EXCLUDED.hours_left;

    SELECT sum(b.hours_left) INTO total FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = p_kind;

    RETURN total;
END;
$$;


-- Drink the strongest stack first, up to `p_hours`, and say what it was
-- worth. `extra_hours` is the sum of magnitude x hours over the stacks it
-- touched - exactly the quantity the settle already adds to `paid`.
CREATE FUNCTION spend_boost(p_player_id BIGINT, p_kind TEXT, p_hours NUMERIC)
RETURNS TABLE (hours_used NUMERIC, extra_hours NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    stack RECORD;
    left_ NUMERIC := GREATEST(0, COALESCE(p_hours, 0));
    took  NUMERIC;
BEGIN
    hours_used := 0;
    extra_hours := 0;

    FOR stack IN
        SELECT b.magnitude, b.hours_left
        FROM player_boosts b
        WHERE b.player_id = p_player_id AND b.kind = p_kind
        ORDER BY b.magnitude DESC
        FOR UPDATE
    LOOP
        EXIT WHEN left_ <= 0;

        took        := LEAST(left_, stack.hours_left);
        left_       := left_ - took;
        hours_used  := hours_used + took;
        extra_hours := extra_hours + stack.magnitude * took;

        -- `hours_left > 0` is a CHECK and the right one: a stack with nothing
        -- in it is not a state worth keeping. So an emptied one goes rather
        -- than being written to zero.
        IF took >= stack.hours_left THEN
            DELETE FROM player_boosts b
            WHERE b.player_id = p_player_id AND b.kind = p_kind
              AND b.magnitude = stack.magnitude;
        ELSE
            UPDATE player_boosts b
            SET hours_left = b.hours_left - took
            WHERE b.player_id = p_player_id AND b.kind = p_kind
              AND b.magnitude = stack.magnitude;
        END IF;
    END LOOP;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION spend_boost(BIGINT, TEXT, NUMERIC) IS
    'Consume boost hours strongest first and report the hours-equivalent they '
    'were worth. The only place boost hours are spent.';


-- What a screen should show: the rate in force right now, and everything
-- banked behind it.
CREATE VIEW player_boost_standing AS
SELECT b.player_id,
       b.kind,
       (SELECT s.magnitude FROM player_boosts s
        WHERE s.player_id = b.player_id AND s.kind = b.kind
        ORDER BY s.magnitude DESC LIMIT 1) AS magnitude,
       sum(b.hours_left) AS hours_left,
       (SELECT s.hours_left FROM player_boosts s
        WHERE s.player_id = b.player_id AND s.kind = b.kind
        ORDER BY s.magnitude DESC LIMIT 1) AS hours_at_this_rate,
       count(*)::integer AS stacks
FROM player_boosts b
GROUP BY b.player_id, b.kind;


DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'settle_passive_cultivation';

    -- 1. Read-then-decrement becomes drink-and-report.
    old := '    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO cult_boost, cult_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = ''cultivation_rate'';

    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO att_boost, att_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = ''attainment_rate'';

    cult_boost := COALESCE(cult_boost, 0);
    cult_hours := COALESCE(cult_hours, 0);
    att_boost  := COALESCE(att_boost, 0);
    att_hours  := COALESCE(att_hours, 0);';
    new := '    -- Strongest stack first, so the pill just swallowed is the pill
    -- being felt. `spend_boost` both consumes and reports, so there is one
    -- place that decides what an hour of boost was worth.
    SELECT s.hours_used, s.extra_hours INTO cult_hours, cult_boost
    FROM spend_boost(p_player_id, ''cultivation_rate'', paid) s;

    SELECT s.hours_used, s.extra_hours INTO att_hours, att_boost
    FROM spend_boost(p_player_id, ''attainment_rate'', paid) s;

    -- `cult_boost` now holds the hours-equivalent outright rather than a rate
    -- to multiply by hours, so the two uses below drop their multiplication.
    cult_boost := COALESCE(cult_boost, 0);
    cult_hours := COALESCE(cult_hours, 0);
    att_boost  := COALESCE(att_boost, 0);
    att_hours  := COALESCE(att_hours, 0);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the settle no longer reads boosts the old way';
    END IF;
    src := replace(src, old, new);

    -- 2. The two places that multiplied rate by hours.
    old := '(paid + cult_boost * cult_hours) * cultivation_per_hour(p_player_id)';
    new := '(paid + cult_boost) * cultivation_per_hour(p_player_id)';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the cultivation gain no longer uses the boost the old way';
    END IF;
    src := replace(src, old, new);

    old := '(paid + att_boost * att_hours)';
    new := '(paid + att_boost)';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the insight gain no longer uses the boost the old way';
    END IF;
    src := replace(src, old, new);

    -- 3. The hand-rolled decrement, now done inside spend_boost.
    old := '    DELETE FROM player_boosts b
    WHERE b.player_id = p_player_id
      AND ((b.kind = ''cultivation_rate'' AND b.hours_left <= cult_hours)
        OR (b.kind = ''attainment_rate''  AND b.hours_left <= att_hours));

    UPDATE player_boosts b SET hours_left = b.hours_left - cult_hours
    WHERE b.player_id = p_player_id AND b.kind = ''cultivation_rate'';
    UPDATE player_boosts b SET hours_left = b.hours_left - att_hours
    WHERE b.player_id = p_player_id AND b.kind = ''attainment_rate'';';
    new := '    -- The stacks were already drunk from above; nothing to sweep here.';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the settle no longer decrements boosts the old way';
    END IF;
    src := replace(src, old, new);

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    got   RECORD;
    top   NUMERIC;
BEGIN
    -- A strong pill on top of a big cheap pile must be felt AT ITS OWN RATE.
    -- This is the failure in one assertion: under the average, 153 hours at
    -- 240% on top of 978 at 80% came out at 101%.
    SELECT b.player_id INTO who FROM player_boosts b
    WHERE b.kind = 'cultivation_rate'
    ORDER BY b.hours_left DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds a boost; tests carry it';
        RETURN;
    END IF;

    BEGIN
        PERFORM grant_boost(who, 'cultivation_rate', 2.4000, 10);

        SELECT * INTO got FROM player_boost_standing s
        WHERE s.player_id = who AND s.kind = 'cultivation_rate';

        IF got.magnitude <> 2.4000 THEN
            RAISE EXCEPTION
                'a 240%% pill on a full bank still reads %%%',
                round(100 * got.magnitude);
        END IF;

        -- And the first hours settled must be paid at that rate.
        SELECT s.extra_hours INTO top
        FROM spend_boost(who, 'cultivation_rate', 10) s;

        IF top <> 24 THEN
            RAISE EXCEPTION
                'ten hours off the top stack was worth % rather than 24', top;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
