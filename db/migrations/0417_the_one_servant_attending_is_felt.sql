-- 0417_the_one_servant_attending_is_felt
--
-- Last of four. 0414 wrote the roster, 0415 let people own and raise them,
-- 0416 sent them to work. None of it has yet done a thing to the cultivator
-- holding the contract, because `player_stat` has never heard of a servant.
--
-- It sums seven sources - Gu, equipment, physique, root, dwelling, manual,
-- destiny - and clamps the total at the effect's ceiling. A servant becomes
-- the eighth. That is the whole change: an eighth term in one addition, and a
-- function to produce it.
--
-- ONE AT A TIME, which is not enforced here because it cannot be broken here.
-- `player_servant_attending` is keyed on the player, so there is exactly one
-- attending servant per cultivator by construction rather than by a rule
-- somebody has to remember. A flag on `player_servants` would have needed a
-- partial unique index and a guard in every writer; a table with the player as
-- its primary key needs neither.
--
-- THE CEILING IS ALREADY THERE and is why this is safe to add. `player_stat`
-- clamps at `gu_effects.cap` over every source at once, so a Venerable does
-- not stack past what the game already allows any other route to reach. A
-- five-star Fang Yuan is six per cent of cultivation speed raised to twelve,
-- against a ceiling of three hundred that a Gu, a manual, a helm and a
-- physique are already paying into.
--
-- STRENGTH TAKES THE OTHER COLUMN. `servant_bonuses.is_flat` marks it, and
-- this is where that matters: Sinew is points, so a Strength servant adds
-- `flat_bonus` and not `pct_bonus`. Reading the wrong column would have given
-- Hei Lou Lan six hundredths of a point of Sinew and called it plus six per
-- cent.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION servant_stat(p_player_id bigint, p_effect text)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- At most one row: `player_servant_attending` is keyed on the player.
    SELECT COALESCE(sum(
        CASE WHEN b.is_flat   THEN t.flat_bonus::numeric
             WHEN b.is_strike THEN t.strike_bonus
             ELSE t.pct_bonus
        END * servant_star_scale(ps.stars)
    ), 0)
    FROM player_servant_attending a
    JOIN player_servants ps ON ps.player_servant_id = a.player_servant_id
    JOIN servants s         ON s.servant_code = ps.servant_code
    JOIN servant_tiers t    ON t.tier = s.tier
    JOIN servant_bonuses b  ON b.kind = s.bonus_kind
    WHERE a.player_id = p_player_id
      AND b.effect_code = p_effect;
$$;

COMMENT ON FUNCTION servant_stat(bigint, text) IS
    'What the servant currently attending is worth to one effect. Strength reads the flat column because Sinew is points; everything else reads its share.';


CREATE FUNCTION servant_attend(p_player_id bigint, p_player_servant_id bigint)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_name TEXT;
BEGIN
    SELECT s.name INTO v_name
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO player_servant_attending (player_id, player_servant_id)
    VALUES (p_player_id, p_player_servant_id)
    ON CONFLICT (player_id) DO UPDATE
        SET player_servant_id = EXCLUDED.player_servant_id;

    RETURN v_name || ' attends you.';
END;
$$;


CREATE FUNCTION servant_dismiss(p_player_id bigint)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER;
BEGIN
    DELETE FROM player_servant_attending WHERE player_id = p_player_id;
    GET DIAGNOSTICS gone = ROW_COUNT;
    RETURN gone > 0;
END;
$$;


-- ---------------------------------------------------------------------------
-- The eighth source
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'player_stat' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'player_stat is missing';
    END IF;

    anchor := '        + destiny_stat(p_player_id, p_effect)';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'player_stat no longer sums its sources where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        + destiny_stat(p_player_id, p_effect)', chr(10),
'        -- The one servant attending, since 0417. Inside the same LEAST as', chr(10),
'        -- every other source, so a Venerable cannot push past a ceiling the', chr(10),
'        -- rest of the game already shares.', chr(10),
'        + servant_stat(p_player_id, p_effect)'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A servant is felt, one at a time, and never past the ceiling
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_a     BIGINT;
    v_b     BIGINT;
    v_was   NUMERIC;
    v_now   NUMERIC;
    v_code  TEXT;
    v_eff   TEXT;
    r       RECORD;
BEGIN
    -- `player_stat` must actually read it, or every servant is a card with
    -- nothing behind it.
    IF (SELECT prosrc FROM pg_proc
        WHERE proname = 'player_stat'
          AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%servant_stat(p_player_id, p_effect)%' THEN
        RAISE EXCEPTION 'player_stat still cannot feel a servant';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        -- A known quantity rather than whatever the wheel felt like: a
        -- Venerable of a known bonus, so the assertion below is exact.
        SELECT s.servant_code, b.effect_code INTO v_code, v_eff
        FROM servants s
        JOIN servant_bonuses b ON b.kind = s.bonus_kind
        WHERE s.tier = 7 AND NOT b.is_flat AND NOT b.is_strike
        ORDER BY s.servant_code LIMIT 1;

        v_was := player_stat(v_who, v_eff);

        INSERT INTO player_servants (player_id, servant_code, realm_id)
        VALUES (v_who, v_code, (SELECT min(realm_id) FROM realms))
        RETURNING player_servant_id INTO v_a;

        -- Held but not attending: felt by nobody.
        IF player_stat(v_who, v_eff) <> v_was THEN
            RAISE EXCEPTION 'a servant nobody called was felt anyway';
        END IF;

        PERFORM servant_attend(v_who, v_a);
        v_now := player_stat(v_who, v_eff);
        IF v_now <= v_was THEN
            RAISE EXCEPTION
                'the attending servant changed % from % to %', v_eff, v_was, v_now;
        END IF;

        -- A second one called replaces the first rather than joining it.
        INSERT INTO player_servants (player_id, servant_code, realm_id)
        VALUES (v_who, v_code, (SELECT min(realm_id) FROM realms))
        RETURNING player_servant_id INTO v_b;
        PERFORM servant_attend(v_who, v_b);

        IF (SELECT count(*) FROM player_servant_attending
            WHERE player_id = v_who) <> 1 THEN
            RAISE EXCEPTION 'two servants are attending at once';
        END IF;
        IF player_stat(v_who, v_eff) <> v_now THEN
            RAISE EXCEPTION 'swapping servants stacked them instead';
        END IF;

        PERFORM servant_dismiss(v_who);
        IF player_stat(v_who, v_eff) <> v_was THEN
            RAISE EXCEPTION 'a dismissed servant is still being felt';
        END IF;

        RAISE NOTICE 'one Venerable moved % from % to %', v_eff, v_was, v_now;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT b.name AS bonus, ef.name AS feeds, ef.cap,
               CASE WHEN b.is_flat THEN t.flat_bonus::numeric
                    WHEN b.is_strike THEN t.strike_bonus
                    ELSE t.pct_bonus END
               * servant_star_scale(5::smallint) AS five_star_t7
        FROM servant_bonuses b
        JOIN gu_effects ef ON ef.code = b.effect_code
        CROSS JOIN servant_tiers t
        WHERE t.tier = 7
        ORDER BY b.name
    LOOP
        RAISE NOTICE '% feeds % (ceiling %) - a five-star Venerable gives %',
            rpad(r.bonus, 14), rpad(r.feeds, 20), r.cap, r.five_star_t7;
    END LOOP;
END;
$probe$;
