-- 0384_a_pill_the_body_cannot_hold_goes_to_the_beast
--
-- A healing pill swallowed at full health is spent, reports "The body could
-- not hold all of it", and does nothing whatsoever. Meanwhile the beast that
-- covered thirty per cent of every blow in the last dungeon is on the floor
-- with no way up but `rest`.
--
-- 0285 already settled the principle and then only applied it to resting:
--
--     "The beast first, and outside the full-body early return: a cultivator
--      at full health with a beast on the floor still came here to rest, and
--      sending them away with nothing is how the beast never gets up."
--
-- A pill is the same sentence. What the body cannot hold goes to the beast.
--
-- THE OVERFLOW, NOT JUST THE FULL CASE. Gated on "your health is full" this
-- would still throw away nine tenths of a pill taken at ninety per cent, and
-- the moment a player notices that they start topping up before drinking,
-- which is a chore rather than a decision. So the pill fills the body first
-- and the remainder goes to the beast - the full case is that rule with the
-- first half equal to zero, and there is no threshold anywhere to discover.
--
-- `pet_at_heel` and not `pet_standing`, for exactly the reason `rest` gives:
-- a beast on nought is the one that most needs a pill, and a heal that
-- refuses to reach the unconscious is not a heal.
--
-- `granted` KEEPS MEANING WHAT LANDED. 0045 and 0057 made this function
-- report what it banked rather than what it offered, and every screen reading
-- it is built on that. So the beast's share is added to `granted` and named in
-- `detail` - the same number, still honest, now counting both bodies. Nothing
-- in the bot changes.
--
-- A pill taken with no beast at heel behaves exactly as it did.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'take_pill';

    IF body IS NULL THEN
        RAISE EXCEPTION 'take_pill is missing';
    END IF;

    -- ---- somewhere to put the beast ---------------------------------------
    anchor := '    aimed  TEXT;';
    swap   := concat(
'    aimed  TEXT;', chr(10),
'    spilled BIGINT := 0;', chr(10),
'    beast   BIGINT;', chr(10),
'    beast_nm TEXT;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'take_pill no longer declares aimed exactly once';
    END IF;
    body := replace(body, anchor, swap);

    -- ---- and the healing branch itself ------------------------------------
    anchor := concat(
'        after := after - before;', chr(10),
'        said := CASE WHEN after < it.magnitude', chr(10),
'                     THEN ''The body could not hold all of it.''', chr(10),
'                     ELSE ''Health, at once.'' END;');

    swap := concat(
'        after := after - before;', chr(10),
'', chr(10),
'        -- What the body could not hold goes to the beast at your heel', chr(10),
'        -- rather than nowhere. `pet_at_heel` and not `pet_standing`, for', chr(10),
'        -- the reason `rest` gives: a beast on the floor is the one that', chr(10),
'        -- most needs this.', chr(10),
'        beast := pet_at_heel(p_player_id);', chr(10),
'        IF beast IS NOT NULL AND after < it.magnitude THEN', chr(10),
'            spilled := pet_mend(beast, (it.magnitude - after)::bigint);', chr(10),
'            IF spilled > 0 THEN', chr(10),
'                SELECT b.name INTO beast_nm FROM player_beasts b', chr(10),
'                WHERE b.beast_id = beast;', chr(10),
'            END IF;', chr(10),
'        END IF;', chr(10),
'', chr(10),
'        said := CASE', chr(10),
'            WHEN spilled > 0 AND after = 0', chr(10),
'                THEN ''You were whole, so '' || beast_nm || '' drank it.''', chr(10),
'            WHEN spilled > 0', chr(10),
'                THEN ''Health, at once - and what would not fit went to ''', chr(10),
'                     || beast_nm || ''.''', chr(10),
'            WHEN after < it.magnitude', chr(10),
'                THEN ''The body could not hold all of it.''', chr(10),
'            ELSE ''Health, at once.'' END;', chr(10),
'', chr(10),
'        -- Counted into what landed, because that is what `granted` has meant', chr(10),
'        -- since 0045 and every screen reading it was built on that.', chr(10),
'        after := after + spilled;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'take_pill''s healing branch is not the one this migration patches';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


COMMENT ON FUNCTION take_pill(BIGINT, BIGINT, TEXT) IS
    'Swallows one pill and reports what it actually banked. What a healing pill cannot fit in the body goes to the beast at your heel.';


-- ---------------------------------------------------------------------------
-- A whole body, a hurt beast, and a pill that reaches it
-- ---------------------------------------------------------------------------
--
-- Driven on somebody real and rolled back, because the thing worth checking is
-- that the branch runs against a live beast with a live cap over it - not that
-- the arithmetic I just typed agrees with itself.

DO $probe$
DECLARE
    who     BIGINT;
    beast   BIGINT;
    top     BIGINT;
    pill    BIGINT;
    took    RECORD;
    v_after BIGINT;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    JOIN player_physique pp ON pp.player_id = b.owner_id
    WHERE b.at_heel AND pet_max_hp(b.beast_id) > 100
    ORDER BY pet_max_hp(b.beast_id) DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        top := pet_max_hp(beast);

        -- Whole cultivator, beast on a tenth.
        UPDATE player_physique SET current_hp = max_hp WHERE player_id = who;
        UPDATE player_beasts SET hp = GREATEST(1, top / 10)
        WHERE beast_id = beast;

        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (who, 'Probe Pill', 3, 'healing', 'water',
                GREATEST(1, top / 4), 1, 80)
        RETURNING pill_id INTO pill;

        SELECT * INTO took FROM take_pill(who, pill);

        IF took.granted <= 0 THEN
            RAISE EXCEPTION
                'a whole body with a hurt beast still banked nothing';
        END IF;
        IF pet_hp(beast) <= GREATEST(1, top / 10) THEN
            RAISE EXCEPTION 'the beast is no better off for the pill';
        END IF;
        IF took.detail NOT LIKE '%drank it%' THEN
            RAISE EXCEPTION
                'the pill did not say where it went: %', took.detail;
        END IF;

        -- And with no beast at heel it is exactly the old behaviour: nothing
        -- banked, and the old sentence. This is the half that must not move.
        UPDATE player_beasts SET at_heel = FALSE WHERE beast_id = beast;
        UPDATE player_physique SET current_hp = max_hp WHERE player_id = who;

        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (who, 'Probe Pill', 3, 'healing', 'water', 500, 1, 80)
        RETURNING pill_id INTO pill;

        SELECT * INTO took FROM take_pill(who, pill);
        IF took.granted <> 0 THEN
            RAISE EXCEPTION
                'a full body with no beast banked % from a pill', took.granted;
        END IF;
        IF took.detail <> 'The body could not hold all of it.' THEN
            RAISE EXCEPTION 'the old sentence changed: %', took.detail;
        END IF;

        -- And a hurt body still fills first, with the beast taking only the
        -- remainder rather than a share of the whole.
        UPDATE player_beasts SET at_heel = TRUE, hp = GREATEST(1, top / 10)
        WHERE beast_id = beast;
        UPDATE player_physique SET current_hp = max_hp - 100
        WHERE player_id = who;

        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (who, 'Probe Pill', 3, 'healing', 'water', 400, 1, 80)
        RETURNING pill_id INTO pill;

        SELECT * INTO took FROM take_pill(who, pill);
        SELECT pp.current_hp INTO v_after FROM player_physique pp
        WHERE pp.player_id = who;
        IF v_after <> (SELECT pp2.max_hp FROM player_physique pp2
                       WHERE pp2.player_id = who) THEN
            RAISE EXCEPTION 'the body was not filled first';
        END IF;

        RAISE NOTICE
            'a pill reaching past a whole body mended % of the beast', took.granted;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
