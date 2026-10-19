-- 0413_a_chest_you_earned_does_not_expire_because_the_next_tide_came
--
-- `/horde` shows one tide: the live one if a tide is running, otherwise the
-- most recent. The claim button hangs off that tide and only that tide, and
-- `ClaimView` only draws it at all when the tide it was handed is finished.
-- Put together:
--
--   * while a tide is running there is NO claim button on the screen, so
--     anything owed from the last one cannot be reached; and
--   * once the next tide starts, the previous one is no longer what `/horde`
--     shows, so it can never be reached again.
--
-- A chest therefore had to be opened in the window between one tide ending
-- and the next beginning, and nothing anywhere said so. Twenty-one chests are
-- stranded behind this right now, across eight cultivators, the oldest on
-- horde 656 - and nine of them are King's chests, which are the ones you only
-- get for standing in front of the King.
--
-- The fix is not to make the board show an older tide; the board is for the
-- tide. It is that what you are OWED has nothing to do with what is on the
-- screen. `horde_owed` answers what is outstanding across every finished
-- tide, and `horde_claim_all` settles the lot in one opening.
--
-- WHY IT MERGES RATHER THAN LOOPING IN THE BOT. Eight tides is eight calls,
-- eight failure points and eight embeds, and a bot that dies on the fourth
-- has taken four chests and shown nothing. One function, one transaction: it
-- either all lands or none of it does, and the caller gets one pile to print.
--
-- `horde_chest_take` is untouched and still does the actual opening, so there
-- is one description of what a chest contains and this is not a second
-- opinion about it.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION horde_owed(p_player_id bigint)
RETURNS TABLE (horde_id bigint)
LANGUAGE sql
STABLE
AS $$
    -- Every finished tide this cultivator stood on and has not been paid for.
    -- Oldest first, so an opening reads in the order the tides came.
    SELECT c.horde_id
    FROM horde_contributions c
    JOIN beast_hordes h ON h.horde_id = c.horde_id
    WHERE c.player_id = p_player_id
      AND h.status IN ('won', 'lost')
      AND (horde_chests_earned(c.horde_id, p_player_id) > c.chest_taken
           OR horde_king_chest_due(c.horde_id, p_player_id))
    ORDER BY c.horde_id;
$$;

COMMENT ON FUNCTION horde_owed(bigint) IS
    'The finished tides a cultivator has unopened chests on. What you are owed is not a property of whichever tide the board happens to be showing.';


CREATE FUNCTION horde_claim_all(p_player_id bigint)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    one     JSONB;
    v_h     BIGINT;
    v_tides INTEGER := 0;
    v_chest INTEGER := 0;
    v_pages INTEGER := 0;
    v_stone BIGINT  := 0;
    v_king  BOOLEAN := FALSE;
    v_thru  INTEGER := 0;
    v_parts TEXT[]  := '{}';
    v_herbs TEXT[]  := '{}';
    v_eggs  TEXT[]  := '{}';
    v_gu    TEXT[]  := '{}';
BEGIN
    FOR v_h IN SELECT o.horde_id FROM horde_owed(p_player_id) o LOOP
        -- The same opening a single claim performs. Nothing about what a
        -- chest holds is decided here.
        one := horde_chest_take(v_h, p_player_id);

        v_tides := v_tides + 1;
        v_chest := v_chest + COALESCE((one ->> 'chests')::integer, 0);
        v_pages := v_pages + COALESCE((one ->> 'pages')::integer, 0);
        v_stone := v_stone + COALESCE((one ->> 'stones')::bigint, 0);
        v_king  := v_king OR COALESCE((one ->> 'king')::boolean, FALSE);
        v_thru  := GREATEST(v_thru, COALESCE((one ->> 'through')::integer, 0));

        v_parts := v_parts || ARRAY(SELECT jsonb_array_elements_text(one -> 'parts'));
        v_herbs := v_herbs || ARRAY(SELECT jsonb_array_elements_text(one -> 'herbs'));
        v_eggs  := v_eggs  || ARRAY(SELECT jsonb_array_elements_text(one -> 'eggs'));
        v_gu    := v_gu    || ARRAY(SELECT jsonb_array_elements_text(one -> 'gu'));
    END LOOP;

    IF v_tides = 0 THEN
        RAISE EXCEPTION 'you have opened everything you earned'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN jsonb_build_object(
        'chests',  v_chest,
        'tides',   v_tides,
        'through', v_thru,
        'king',    v_king,
        'stones',  v_stone,
        'pages',   v_pages,
        'parts',   to_jsonb(v_parts),
        'herbs',   to_jsonb(v_herbs),
        'eggs',    to_jsonb(v_eggs),
        'gu',      to_jsonb(v_gu));
END;
$$;

COMMENT ON FUNCTION horde_claim_all(bigint) IS
    'Opens every chest a cultivator is owed, across every finished tide, in one transaction. Raises the same sentence a single claim does when there is nothing outstanding.';


-- ---------------------------------------------------------------------------
-- Nothing earned is stranded behind the tide that came after it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_owed  INTEGER;
    v_got   JSONB;
    v_left  INTEGER;
    r       RECORD;
BEGIN
    -- How much is stranded right now, which is the reason for the migration.
    SELECT count(*) INTO v_owed
    FROM horde_contributions c
    JOIN beast_hordes h ON h.horde_id = c.horde_id
    WHERE h.status IN ('won', 'lost')
      AND (horde_chests_earned(c.horde_id, c.player_id) > c.chest_taken
           OR horde_king_chest_due(c.horde_id, c.player_id));

    RAISE NOTICE '% unopened chests are waiting across the finished tides', v_owed;

    -- `horde_owed` must find them, one row per tide, for the right person.
    FOR r IN
        SELECT p.discord_name, count(*) AS tides
        FROM players p
        JOIN LATERAL horde_owed(p.player_id) o ON TRUE
        WHERE p.deleted_at IS NULL
        GROUP BY 1 ORDER BY 2 DESC, 1
    LOOP
        RAISE NOTICE '  % is owed % tide(s)', rpad(r.discord_name, 16), r.tides;
    END LOOP;

    -- And a real claim settles every one of them, on a subtransaction that is
    -- thrown away. Somebody owed more than one tide, or the test is not a test.
    BEGIN
        SELECT p.player_id INTO v_who
        FROM players p
        JOIN LATERAL horde_owed(p.player_id) o ON TRUE
        WHERE p.deleted_at IS NULL
        GROUP BY p.player_id HAVING count(*) > 1
        ORDER BY count(*) DESC LIMIT 1;

        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';        -- nobody to try it on
        END IF;

        v_got := horde_claim_all(v_who);

        IF COALESCE((v_got ->> 'tides')::integer, 0) < 2 THEN
            RAISE EXCEPTION 'a claim across several tides settled only %',
                v_got ->> 'tides';
        END IF;

        SELECT count(*) INTO v_left FROM horde_owed(v_who);
        IF v_left <> 0 THEN
            RAISE EXCEPTION 'still owed % tide(s) after claiming everything',
                v_left;
        END IF;

        RAISE NOTICE
            'one opening settled % tides, % chests, % spirit stones',
            v_got ->> 'tides', v_got ->> 'chests', v_got ->> 'stones';
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
