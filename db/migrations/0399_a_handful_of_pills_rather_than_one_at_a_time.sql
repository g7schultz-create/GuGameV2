-- 0399_a_handful_of_pills_rather_than_one_at_a_time
--
-- `take_pill` swallows exactly one. A cultivator holding eleven Qi Restoration
-- pills who wants three of them opens the shelf three times, and a batch of
-- twenty cultivation pills is twenty presses of the same button.
--
-- `take_pills` is that, N times. It is a LOOP OVER `take_pill` rather than a
-- second copy of it, which matters more here than it usually does: that
-- function has five branches, an immortal refusal, a potency re-rate, the
-- 0398 share-of-the-bar rescale and the 0384 spill to the beast at your heel.
-- A second implementation would be five chances to disagree with the first,
-- and every one of them would be found by a player rather than by us.
--
-- IT STOPS WHEN A DOSE STOPS LANDING. The generous rule and the honest one.
-- Health and Qi both stop at a ceiling, so somebody who asks for five healing
-- pills at half health should not watch three of them evaporate because the
-- second one filled the bar. So the loop breaks the first time a pill banks
-- nothing, and reports how many it actually used. Asking for more than is
-- useful costs nothing, which means the "take all" button is safe to press -
-- and a button that is not safe to press is a button people do not press.
--
-- A pill that legitimately banks nothing on its FIRST dose still reports that,
-- exactly as taking one always did: a full body taking one healing pill with
-- no beast at heel gets "The body could not hold all of it" and the pill is
-- gone. The early stop is about the second pill onward, never the first.
--
-- WHAT IT DOES NOT DO. It does not reach across stacks. One pill_id, one kind,
-- one dose repeated - because "take everything" across kinds would silently
-- swallow the insight pills somebody was saving for a Path they have not
-- chosen yet.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION take_pills(
    p_player_id BIGINT, p_pill_id BIGINT, p_quantity INTEGER DEFAULT 1,
    p_path_code TEXT DEFAULT NULL
)
RETURNS TABLE (pill_name TEXT, kind TEXT, taken INTEGER, granted BIGINT,
               detail TEXT, remaining SMALLINT, stopped_early BOOLEAN)
LANGUAGE plpgsql
AS $$
DECLARE
    v_have    SMALLINT;
    v_want    INTEGER;
    v_one     RECORD;
    v_taken   INTEGER := 0;
    v_total   BIGINT := 0;
    v_name    TEXT;
    v_kind    TEXT;
    v_said    TEXT;
    v_left    SMALLINT := 0;
    v_early   BOOLEAN := FALSE;
BEGIN
    IF COALESCE(p_quantity, 1) < 1 THEN
        RAISE EXCEPTION 'take at least one' USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.quantity, pp.name, pp.kind INTO v_have, v_name, v_kind
    FROM player_pills pp
    WHERE pp.pill_id = p_pill_id AND pp.owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    -- Asking for more than the batch holds is not an error, it is a person
    -- pressing "all".
    v_want := LEAST(p_quantity, v_have);

    FOR i IN 1..v_want LOOP
        -- Every refusal `take_pill` makes is still its to make: the immortal
        -- cultivation gate, the Path that does not exist, the body past rank
        -- 9. The first one raises and the whole handful is refused, which is
        -- the right answer - none of them would have worked.
        SELECT * INTO v_one FROM take_pill(p_player_id, p_pill_id, p_path_code);

        v_taken := v_taken + 1;
        v_total := v_total + COALESCE(v_one.granted, 0);
        v_said  := v_one.detail;
        v_left  := v_one.remaining;

        -- Nothing landed, so nothing further would. Stop rather than pour the
        -- rest of the batch onto the floor.
        IF COALESCE(v_one.granted, 0) <= 0 AND i < v_want THEN
            v_early := TRUE;
            EXIT;
        END IF;

        EXIT WHEN v_left <= 0;
    END LOOP;

    RETURN QUERY SELECT
        v_name, v_kind, v_taken, v_total,
        CASE
            WHEN v_early THEN v_said || ' The rest stayed in the bag.'
            WHEN v_taken > 1 THEN v_said || ' (' || v_taken || ' taken.)'
            ELSE v_said
        END,
        v_left, v_early;
END;
$$;

COMMENT ON FUNCTION take_pills(BIGINT, BIGINT, INTEGER, TEXT) IS
    'Swallows several of one batch, one dose at a time through take_pill, and stops the moment a dose banks nothing so the rest stay in the bag.';


-- ---------------------------------------------------------------------------
-- A handful is the same as that many singles, and never wastes the tail
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_pill  BIGINT;
    v_got   RECORD;
    v_one   BIGINT;
    v_many  BIGINT;
    v_max   BIGINT;
BEGIN
    SELECT p.player_id INTO v_who FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL
    ORDER BY player_max_qi(p.player_id) DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody to measure; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        v_max := player_max_qi(v_who);

        -- ---- a handful equals that many singles ---------------------------
        -- Emptied first, and the batch sized so no dose is wasted, or this
        -- would be measuring the early stop instead of the arithmetic.
        UPDATE player_cultivation SET qi = 0 WHERE player_id = v_who;
        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (v_who, 'Probe Qi', 1, 'qi', 'water', GREATEST(1, v_max / 20), 6, 80)
        RETURNING pill_id INTO v_pill;

        SELECT granted INTO v_one FROM take_pill(v_who, v_pill);
        SELECT granted INTO v_many FROM take_pills(v_who, v_pill, 3);

        IF v_many < v_one * 2 THEN
            RAISE EXCEPTION
                'three pills banked % against one banking %', v_many, v_one;
        END IF;

        IF (SELECT pp.quantity FROM player_pills pp WHERE pp.pill_id = v_pill)
           <> 2 THEN
            RAISE EXCEPTION 'the batch did not go down by exactly four';
        END IF;

        -- ---- and the tail is not poured on the floor ----------------------
        UPDATE player_cultivation SET qi = player_max_qi(v_who)
        WHERE player_id = v_who;

        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (v_who, 'Probe Spare', 1, 'qi', 'water', 500, 9, 80)
        RETURNING pill_id INTO v_pill;

        SELECT * INTO v_got FROM take_pills(v_who, v_pill, 9);

        IF NOT v_got.stopped_early THEN
            RAISE EXCEPTION
                'a full aperture swallowed the whole batch anyway (% taken)',
                v_got.taken;
        END IF;
        IF v_got.taken <> 1 THEN
            RAISE EXCEPTION
                'the stop came after % pills rather than the first', v_got.taken;
        END IF;
        IF (SELECT pp.quantity FROM player_pills pp WHERE pp.pill_id = v_pill)
           <> 8 THEN
            RAISE EXCEPTION 'more than one pill left the bag';
        END IF;

        -- ---- asking for more than the batch holds is not an error ---------
        SELECT * INTO v_got FROM take_pills(v_who, v_pill, 1000);
        IF v_got.taken > 8 THEN
            RAISE EXCEPTION 'it took % of a batch of 8', v_got.taken;
        END IF;

        RAISE NOTICE
            'a handful is a handful; a full bar spends one pill and keeps the rest';
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
