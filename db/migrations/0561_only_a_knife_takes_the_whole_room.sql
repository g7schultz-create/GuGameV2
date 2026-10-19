-- 0561_only_a_knife_takes_the_whole_room
--
-- 0543 gave the pot to the last cultivator standing, whoever put the others
-- down:
--
--     'It does not matter who put the others down - the room, a companion,
--      or the round cap.'
--
--     share := CASE
--         WHEN upright = 0 THEN 0
--         WHEN upright = 1 THEN CASE WHEN one.player_id = alone THEN 1 ELSE 0 END
--         ELSE one.damage_dealt::numeric / total
--     END;
--
-- That is right for a betrayal and wrong for everything else. A party that
-- fought honestly, lost three of its four to the room, and finished the fight
-- anyway was treated exactly as though the survivor had knifed them - the
-- three who died doing most of the damage got nothing, and the one who
-- happened to outlive them took the lot.
--
-- Losing people to the boss is the normal shape of a hard room. It should not
-- quietly become a robbery.
--
-- SO THE RULE NOW ASKS WHY. Taking everything is what a BETRAYAL buys, and
-- `dungeon_raiders.betrayals` has counted them since 0541:
--
--     sole survivor, and they turned on somebody      they take it all
--     sole survivor, and they did not                 shared by damage dealt
--     more than one upright                           shared by damage dealt
--     nobody upright                                  nothing, as before
--
-- A raider who went down still shares, which is the point: they are paid for
-- the damage they did before they fell. The knife is the only thing that cuts
-- anybody out, which is what makes it a knife rather than a tactic.
--
-- And a betrayer who is NOT the last one standing shares like anybody else.
-- Turning on a companion is not itself a claim on the room; surviving alone
-- after turning on them is.
--
-- Nothing else moves. The stake refund still goes back whole to whoever paid
-- it, nobody-upright still earns nothing, and the items still follow the pot.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'            share := CASE
                WHEN upright = 0 THEN 0
                WHEN upright = 1 THEN
                     CASE WHEN one.player_id = alone THEN 1 ELSE 0 END
                ELSE one.damage_dealt::numeric / total
            END;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_pay_out' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_pay_out does not share the pot the way 0543 left it';
    END IF;

    patched := replace(src, anchor,
'            -- WHO WALKED OUT, AND WHY THE OTHERS DID NOT. 0543 handed the
            -- whole pot to the last one standing however the others fell,
            -- which treated a party wiped by the room exactly like a party
            -- knifed by a companion. Losing people to the boss is the normal
            -- shape of a hard room; it is not a robbery.
            --
            -- Taking everything is what a betrayal buys. `betrayals` has
            -- counted them per raider since 0541, so the rule can simply ask.
            -- A raider who went down still shares - they are paid for the
            -- damage they did before they fell.
            share := CASE
                WHEN upright = 0 THEN 0
                WHEN upright = 1 AND alone_betrayed THEN
                     CASE WHEN one.player_id = alone THEN 1 ELSE 0 END
                ELSE one.damage_dealt::numeric / total
            END;');

    -- The flag the CASE now reads, worked out once beside `upright` and
    -- `alone` rather than per raider inside the loop.
    patched := replace(patched,
'    upright INTEGER;   -- 0543. How many walked out.
    alone   BIGINT;    -- and who, if it was only one.',
'    upright INTEGER;   -- 0543. How many walked out.
    alone   BIGINT;    -- and who, if it was only one.
    alone_betrayed BOOLEAN;  -- 0561. And whether they earned the room alone.');

    patched := replace(patched,
'    INTO upright, alone
    FROM dungeon_raiders x WHERE x.run_id = p_run_id;',
'    INTO upright, alone
    FROM dungeon_raiders x WHERE x.run_id = p_run_id;

    -- Whether the one who walked out is the reason the others did not. Read
    -- once, before anybody is paid, for the same reason `upright` is: the
    -- answer decides how everybody is paid.
    alone_betrayed := COALESCE((
        SELECT x.betrayals > 0 FROM dungeon_raiders x
        WHERE x.run_id = p_run_id AND x.player_id = alone
    ), FALSE);');

    IF patched = src THEN
        RAISE EXCEPTION 'the dungeon_pay_out patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    src TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_pay_out' AND pronamespace = 'public'::regnamespace;

    -- 1. THE RULE READS THE KNIFE. Without this term the whole change is a
    --    comment: `upright = 1` would still take everything on its own.
    IF position('upright = 1 AND alone_betrayed' IN src) = 0 THEN
        RAISE EXCEPTION
            'the sole-survivor branch does not ask whether they betrayed anybody';
    END IF;

    -- 2. AND IT IS ANSWERED FROM THE COUNTER, not from anything the loop
    --    could have changed by paying somebody.
    IF position('x.betrayals > 0' IN src) = 0 THEN
        RAISE EXCEPTION 'alone_betrayed is not read off the betrayal counter';
    END IF;

    -- 3. NOBODY UPRIGHT STILL EARNS NOTHING. 0543's floor-of-corpses case is
    --    a real state - a simultaneous round can fell the last foe and the
    --    last raider together - and it must not have been loosened.
    IF position('WHEN upright = 0 THEN 0' IN src) = 0 THEN
        RAISE EXCEPTION 'a wiped party can now be paid';
    END IF;
END
$probe$;


-- ---------------------------------------------------------------------------
-- Played out, rather than read
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_run   BIGINT;
    v_a     BIGINT;
    v_b     BIGINT;
    v_dg    SMALLINT;
    v_paid  BIGINT;
    v_other BIGINT;
BEGIN
    BEGIN
        SELECT dungeon_id INTO v_dg FROM dungeons ORDER BY realm_rank LIMIT 1;

        INSERT INTO players (discord_id, discord_name)
        VALUES (-3301, 'loot-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-3302, 'loot-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (SELECT realm_id, cultivation_required FROM realms
                            WHERE rank = 4 ORDER BY realm_id DESC LIMIT 1) r;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp,
                                     defense, strength)
        SELECT x.who, (SELECT min(physique_id) FROM physiques),
               50000, 50000, 300, 900
        FROM (VALUES (v_a), (v_b)) AS x(who);

        -- `dungeon_begin` refuses a party that cannot attack, and says so.
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT x.who, (SELECT technique_id FROM techniques
                       WHERE created_by IS NULL AND category = 'attack'
                         AND rank = 1 ORDER BY base_power DESC LIMIT 1)
        FROM (VALUES (v_a), (v_b)) AS x(who);

        PERFORM grant_material(v_a, 'dungeon_key', 5);
        PERFORM grant_material(v_b, 'dungeon_key', 5);
        PERFORM grant_material(v_a, 'spirit_stone', 99999999);
        PERFORM grant_material(v_b, 'spirit_stone', 99999999);
        PERFORM grant_jade(v_a, 200, 'probe');
        PERFORM grant_jade(v_b, 200, 'probe');

        -- A run where one of them is down and the survivor knifed NOBODY.
        v_run := dungeon_open(v_a, v_dg, 'normal');
        PERFORM dungeon_invite(v_run, v_a, v_b);
        PERFORM dungeon_join(v_run, v_b);
        PERFORM dungeon_begin(v_run, v_a);

        -- Both dealt damage; the room put one of them down.
        UPDATE dungeon_raiders SET damage_dealt = 1000 WHERE run_id = v_run;
        UPDATE dungeon_raiders SET current_hp = 0
        WHERE run_id = v_run AND player_id = v_b;
        UPDATE dungeon_runs SET status = 'won', boss_hp = 0 WHERE run_id = v_run;

        PERFORM dungeon_pay_out(v_run);

        SELECT (spoils->>'stones')::bigint INTO v_paid
        FROM dungeon_raiders WHERE run_id = v_run AND player_id = v_a;
        SELECT (spoils->>'stones')::bigint INTO v_other
        FROM dungeon_raiders WHERE run_id = v_run AND player_id = v_b;

        IF COALESCE(v_other, 0) = 0 THEN
            RAISE EXCEPTION
                'a raider who went down to the ROOM was paid nothing while a '
                'companion who knifed nobody took the lot';
        END IF;

        RAISE NOTICE
            'an honest clear with one down: survivor %, the fallen %',
            v_paid, v_other;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
    END;
END
$probe$;
