-- 0472_a_stance_that_does_not_swing_has_no_swing_to_read
--
-- `delve_act` throws on any round where nothing was thrown:
--
--     record "swung" is not assigned yet
--
-- The swing is guarded, correctly - a stance with no damage in it, or a
-- cultivator with no technique to throw, must not call `player_swing` - and
-- then the return reads `swung.healed` unconditionally. So `Search the lair`,
-- the one stance that deals nothing on purpose, could never be used at all,
-- and neither could any stance for somebody with nothing to throw.
--
-- A plpgsql RECORD is not NULL until it has been assigned; it is unreadable,
-- and COALESCE around it does not help because the error is raised reaching
-- for the field rather than by the value being null. The fix is an ordinary
-- variable that starts at zero, set from the swing when there is one.
--
-- Found by `test_searching_the_lair_deals_nothing_and_costs_full`, which is
-- the test for the stance that could not run.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_act is missing';
    END IF;

    -- ---- somewhere to keep it --------------------------------------------
    anchor := '    v_taken BIGINT := 0;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer declares what it takes';
    END IF;
    body := replace(body, anchor, concat(
anchor, chr(10),
'    v_heal  BIGINT := 0;    -- 0472: a round with no swing in it still returns'));

    -- ---- set it where the swing happens ----------------------------------
    anchor := concat(
'        IF swung.healed > 0 THEN', chr(10),
'            v_hp := LEAST(v_max, v_hp + swung.healed);', chr(10),
'        END IF;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer heals where it did';
    END IF;
    body := replace(body, anchor, concat(
'        v_heal := GREATEST(0, COALESCE(swung.healed, 0));', chr(10),
'        IF v_heal > 0 THEN', chr(10),
'            v_hp := LEAST(v_max, v_hp + v_heal);', chr(10),
'        END IF;'));

    -- ---- and read it rather than the record ------------------------------
    anchor := '        v_dealt, v_taken, COALESCE(swung.healed, 0),';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer returns what it healed';
    END IF;

    EXECUTE replace(body, anchor, '        v_dealt, v_taken, v_heal,');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every stance can actually be used
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p   BIGINT;
    v_id  BIGINT;
    at    RECORD;
    f     RECORD;
    r     RECORD;
    st    RECORD;
BEGIN
    -- The RETURN no longer reaches for the record. Reading it inside the
    -- block that assigns it is fine and is where the remaining mention is,
    -- so this names the return line rather than the field.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_act'
        AND pronamespace = 'public'::regnamespace)
       LIKE '%v_dealt, v_taken, COALESCE(swung%' THEN
        RAISE EXCEPTION 'the return still reads a record that may be unassigned';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);
        SELECT r2.at_x, r2.at_y INTO at FROM delve_runs r2 WHERE r2.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'beast', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;
        PERFORM delve_step(v_p, 'up');

        SELECT * INTO f FROM delve_fights x
        WHERE x.delve_id = v_id AND x.status = 'fighting';

        -- Every stance in the table, on the safe move so none of them ends
        -- the fight before the rest have been tried.
        FOR st IN SELECT code FROM delve_stances ORDER BY code LOOP
            UPDATE delve_fights x SET coming = 'circle', hp = x.max_hp
            WHERE x.fight_id = f.fight_id;
            UPDATE player_physique pp SET current_hp = pp.max_hp
            WHERE pp.player_id = v_p;

            SELECT * INTO r FROM delve_act(v_p, st.code, NULL);
            IF r.fight_id IS NULL THEN
                RAISE EXCEPTION 'the stance % returned nothing', st.code;
            END IF;
            RAISE NOTICE '  % : dealt %, took %, healed %',
                rpad(st.code, 7), r.dealt, r.taken, r.healed;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
