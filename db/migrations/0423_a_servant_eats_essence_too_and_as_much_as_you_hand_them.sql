-- 0423_a_servant_eats_essence_too_and_as_much_as_you_hand_them
--
-- 0416's own header says a servant is fed "cultivation pills, insight pills,
-- and past the immortal door, essence". Two of those three were true.
-- `servant_feed` refuses anything that is not a pill:
--
--     IF pill.kind NOT IN ('cultivation', 'insight') THEN
--         RAISE EXCEPTION 'a servant grows on Cultivation and Insight pills...'
--
-- So the essence half was a sentence in a comment. This is it built.
--
-- WHAT A MOUTHFUL IS WORTH, and it is the shape 0409 already chose for beasts
-- rather than a third dialect: the essence of the servant's OWN rank is the
-- reference, and everything else is worth its `unit_value` against that. A
-- servant at Blood Cherry is fed Blood Cherry and gets
-- `servant_essence_share` of their stage; handed Dewberry instead they get
-- 1/81st of that, because that is the ratio the essence ladder itself sets.
-- Below the immortal door there is no essence of their rank, so the
-- shallowest stands in as the reference and any essence is generous there.
--
-- That is what makes essence the LATER food without a gate saying so. Pills
-- are a flat eleven per cent of a stage at every realm (0422), so they never
-- stop working; essence simply overtakes them once you hold the deep kind,
-- and wastes itself if you feed the wrong one. A rule the ladder enforces on
-- its own beats a rule somebody has to remember to check.
--
-- AND AS MANY AS YOU LIKE. `servant_feed` has taken a quantity since 0416 and
-- the screen has always passed 1. The quantity is now asked for, on both
-- foods. Feeding twelve pills is twelve times one pill - no bulk discount and
-- no bulk penalty - because the alternative is a screen where the arithmetic
-- is not the arithmetic.
--
-- THE CLIMB IS EXTRACTED. `servant_feed` grew realms in an inline loop, and a
-- second feeding function would have meant a second copy of it - the exact
-- thing 0422 refused to do with the pill formula, one migration ago. It is
-- now `servant_climb`, called by both. The patch below lifts the old loop out
-- by its two ends rather than retyping the fifteen lines between them, which
-- is also why there is no indentation to miscount.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_essence_share', 0.10,
     'What one mouthful of the essence matching a servant''s OWN rank is worth, as a share of the stage they are crossing. Ten a realm. Other essences are worth their unit_value against that, so feeding the wrong depth is wasteful rather than forbidden.');


-- ---------------------------------------------------------------------------
-- Climbing, said once
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_climb(p_player_servant_id bigint, p_ceiling smallint)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    nextr RECORD;
    here  BIGINT;
    grew  BOOLEAN := FALSE;
BEGIN
    LOOP
        SELECT ps.realm_id INTO here FROM player_servants ps
        WHERE ps.player_servant_id = p_player_servant_id;

        SELECT r.realm_id, r.rank INTO nextr
        FROM realms r WHERE r.realm_id = here + 1;

        EXIT WHEN nextr.realm_id IS NULL;                  -- end of the ladder
        EXIT WHEN nextr.rank > COALESCE(p_ceiling, 1);     -- past their master
        EXIT WHEN (SELECT ps.cultivation FROM player_servants ps
                   WHERE ps.player_servant_id = p_player_servant_id)
                  < servant_realm_cost(nextr.realm_id);    -- not paid for

        UPDATE player_servants ps SET realm_id = nextr.realm_id
        WHERE ps.player_servant_id = p_player_servant_id;
        grew := TRUE;
    END LOOP;

    RETURN grew;
END;
$$;

COMMENT ON FUNCTION servant_climb(bigint, smallint) IS
    'Raises a servant through as many realms as their cultivation has paid for, stopping at their owner''s own rank. One copy, called by every food.';


-- ---------------------------------------------------------------------------
-- What a mouthful is worth to a servant
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_essence_worth(p_player_servant_id bigint, p_code text,
                                      p_quantity bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, round(
        servant_stage_gap(p_player_servant_id)
        * game_config_value('servant_essence_share')
        * GREATEST(0, p_quantity)
        * (SELECT ie.unit_value FROM immortal_essences ie
           WHERE ie.material_code = p_code)::numeric
        / GREATEST(1, COALESCE(
            -- The essence of their own rank is the reference.
            (SELECT ie2.unit_value FROM immortal_essences ie2
             WHERE ie2.rank = (SELECT r.rank FROM player_servants ps
                               JOIN realms r ON r.realm_id = ps.realm_id
                               WHERE ps.player_servant_id = p_player_servant_id)),
            -- Below the immortal door there is none, so the shallowest does.
            (SELECT min(ie3.unit_value) FROM immortal_essences ie3)))
    ))::bigint;
$$;

COMMENT ON FUNCTION servant_essence_worth(bigint, text, bigint) IS
    'What essence is worth to a servant: a share of their stage, measured against the essence of their OWN rank. Feeding the wrong depth is wasteful rather than refused, which is what makes essence the later food without a gate.';


-- ---------------------------------------------------------------------------
-- Feeding it
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_feed_essence(p_player_id bigint, p_player_servant_id bigint,
                                     p_code text, p_quantity integer DEFAULT 1)
RETURNS TABLE (
    servant_name TEXT,
    fed          TEXT,
    gained       BIGINT,
    cultivation  BIGINT,
    realm_name   TEXT,
    rose         BOOLEAN,
    wants        BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it      RECORD;
    v_ess   RECORD;
    worth   BIGINT;
    ceiling SMALLINT;
    grew    BOOLEAN;
BEGIN
    SELECT ps.*, s.name INTO it
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id
    FOR UPDATE OF ps;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT ie.material_code, m.name INTO v_ess
    FROM immortal_essences ie
    JOIN materials m ON m.code = ie.material_code
    WHERE ie.material_code = p_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not immortal essence'
            USING ERRCODE = 'check_violation';
    END IF;

    IF COALESCE(p_quantity, 0) < 1 THEN
        RAISE EXCEPTION 'feed them something' USING ERRCODE = 'check_violation';
    END IF;

    SELECT r.rank INTO ceiling FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id WHERE pc.player_id = p_player_id;

    IF (SELECT r.rank FROM realms r WHERE r.realm_id = it.realm_id)
       >= COALESCE(ceiling, 1)
       AND COALESCE((SELECT r.rank FROM realms r
                     WHERE r.realm_id = it.realm_id + 1), 99)
           > COALESCE(ceiling, 1) THEN
        RAISE EXCEPTION
            '% cannot be raised past the realm you stand in yourself', it.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- `spend_material` refuses rather than going negative, so an unaffordable
    -- mouthful stops here rather than half way through one.
    PERFORM spend_material(p_player_id, p_code, p_quantity::bigint);

    worth := servant_essence_worth(p_player_servant_id, p_code,
                                   p_quantity::bigint);

    UPDATE player_servants ps
    SET cultivation = ps.cultivation + worth
    WHERE ps.player_servant_id = p_player_servant_id;

    grew := servant_climb(p_player_servant_id, ceiling);

    RETURN QUERY
    SELECT it.name, v_ess.name, worth, ps.cultivation, r.name, grew,
           COALESCE(servant_realm_cost(ps.realm_id + 1), 0)
    FROM player_servants ps
    JOIN realms r ON r.realm_id = ps.realm_id
    WHERE ps.player_servant_id = p_player_servant_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- And the pill route climbs by the same rule
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body  TEXT;
    head  TEXT := '    -- As many realms as that paid for, stopping at the owner''s own.';
    tail  TEXT := '    END LOOP;';
    v_a   INTEGER;
    v_b   INTEGER;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_feed' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_feed is missing';
    END IF;

    -- Lifted out by its two ends. The fifteen lines between them are never
    -- retyped, so there is no indentation here to count wrongly - which is
    -- how two patches in this codebase have already had to be done twice.
    v_a := position(head in body);
    v_b := position(tail in body);

    IF v_a = 0 THEN
        RAISE EXCEPTION 'servant_feed no longer opens its climb where it did';
    END IF;
    IF v_b = 0 OR v_b < v_a THEN
        RAISE EXCEPTION 'servant_feed no longer closes its climb where it did';
    END IF;
    IF (length(body) - length(replace(body, tail, ''))) / length(tail) <> 1 THEN
        RAISE EXCEPTION 'servant_feed has more than one loop to lift';
    END IF;

    EXECUTE substr(body, 1, v_a - 1)
         || '    -- As many realms as that paid for. Extracted to `servant_climb`'
         || chr(10)
         || '    -- in 0423 so that pills and essence raise a servant by one rule'
         || chr(10)
         || '    -- rather than by two copies of it.'
         || chr(10)
         || '    grew := servant_climb(p_player_servant_id, ceiling);'
         || substr(body, v_b + length(tail));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Essence feeds a servant, and the deep kind is the one worth feeding
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_id   BIGINT;
    v_gap  BIGINT;
    v_low  BIGINT;
    v_high BIGINT;
    v_rose BOOLEAN;
    r      RECORD;
BEGIN
    IF (SELECT prosrc FROM pg_proc
        WHERE proname = 'servant_feed'
          AND pronamespace = 'public'::regnamespace) NOT LIKE '%servant_climb%' THEN
        RAISE EXCEPTION 'the pill route still keeps its own copy of the climb';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        INSERT INTO player_servants (player_id, servant_code, realm_id)
        SELECT v_who, s.servant_code, (SELECT min(realm_id) FROM realms)
        FROM servants s ORDER BY s.servant_code LIMIT 1
        RETURNING player_servant_id INTO v_id;

        v_gap  := servant_stage_gap(v_id);
        v_low  := servant_essence_worth(v_id, 'dewberry_essence', 1);
        v_high := servant_essence_worth(v_id, 'yellow_apricot_essence', 1);

        -- The deeper mouthful is worth more, which is the whole ladder.
        IF v_high <= v_low THEN
            RAISE EXCEPTION
                'a Yellow Apricot mouthful (%) is not worth more than a Dewberry one (%)',
                v_high, v_low;
        END IF;

        -- And one of their own rank is a share of a stage, not several.
        IF v_low > v_gap THEN
            RAISE EXCEPTION
                'one mouthful is % of a % stage', v_low, v_gap;
        END IF;

        -- Quantity is honoured, and a handful is never worse than the same
        -- number one at a time. Not EQUAL: the quantity is inside the formula
        -- so a bulk feeding rounds once rather than ten times, which at the
        -- shallow end is 84 against ten roundings of 8.4. Better by a hair,
        -- never worse, and the alternative is charging for rounding error.
        IF servant_essence_worth(v_id, 'dewberry_essence', 10) < v_low * 10 THEN
            RAISE EXCEPTION
                'ten at once (%) is worth less than ten one at a time (%)',
                servant_essence_worth(v_id, 'dewberry_essence', 10), v_low * 10;
        END IF;

        PERFORM grant_material(v_who, 'dewberry_essence', 50);
        SELECT rose INTO v_rose
        FROM servant_feed_essence(v_who, v_id, 'dewberry_essence', 20);

        IF (SELECT cultivation FROM player_servants
            WHERE player_servant_id = v_id) = 0 THEN
            RAISE EXCEPTION 'twenty mouthfuls fed a servant nothing';
        END IF;

        -- And a thing that is not essence is refused.
        BEGIN
            PERFORM servant_feed_essence(v_who, v_id, 'iron_ore', 1);
            RAISE EXCEPTION 'a servant swallowed iron ore';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE NOTICE
            'a new servant crossing % gets % from a Dewberry mouthful and % from a Yellow Apricot one',
            v_gap, v_low, v_high;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT ie.rank, m.name, ie.unit_value FROM immortal_essences ie
        JOIN materials m ON m.code = ie.material_code
        ORDER BY ie.rank LIMIT 3
    LOOP
        RAISE NOTICE 'rank % is fed % (worth %)',
            r.rank, rpad(r.name, 28), r.unit_value;
    END LOOP;
END;
$probe$;
