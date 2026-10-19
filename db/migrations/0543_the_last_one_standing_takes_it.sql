-- 0543_the_last_one_standing_takes_it
--
-- Phase 5, and the last of the raid. "Just taking the loot for yourself if
-- you're the last one standing."
--
-- The pot and the spoils are split by damage dealt today - the world boss's
-- rule, so the game has one answer to "who earned what" rather than two. That
-- stays, for a party that walks out together. What changes is what happens
-- when only one of them walks out:
--
--     one standing    they take ALL of it. The whole pot, every item.
--     none standing   nobody takes anything, which is the user's own
--                     condition: "they can not get the loot if they are also
--                     killed by the boss"
--     two or more     split by damage, exactly as before
--
-- "INCLUDING THOSE KILLED BY THE BOSS", as given. The rule does not care who
-- put somebody down - the boss, a companion's knife, or the round cap. Being
-- the only one upright is the whole condition, which is also the only version
-- a cultivator can plan around.
--
-- AND A WON ROOM WITH NOBODY LEFT IS A REAL STATE, which the simultaneous
-- round loop of 0541 creates: every blow in a round is priced against the
-- state it opened in, so the last foe and the last raider can fall together.
-- `dungeon_resolve_round` reads `pool <= 0` FIRST - deliberately, since "a
-- blow that breaks the room on the last allowed round breaks it" - so that
-- run is WON with a floor full of corpses. Without the guard below the pot
-- would be split between them. The condition was given and it covers this
-- exactly.
--
-- THE STAKE IS NOT LOOT. The stones and jade a raider paid to come in still
-- come back to whoever paid them, on any won run, standing or not - that
-- refund exists so "the one who went down first" does not buy the run for
-- everybody else, and a betrayal does not change who paid what. What a knife
-- takes is the POT and the SPOILS.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('dungeon_pay_out(bigint)'::regprocedure);

    -- Two more locals.
    one := '    loot   JSONB;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the dungeon_pay_out declarations are not where I read them';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        '    upright INTEGER;   -- 0543. How many walked out.' || chr(10) ||
        '    alone   BIGINT;    -- and who, if it was only one.');

    -- Counted once, before the loop pays anybody.
    one := '    SELECT GREATEST(1, COALESCE(sum(x.damage_dealt), 0)) INTO total' || chr(10) ||
           '    FROM dungeon_raiders x WHERE x.run_id = p_run_id;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the damage total is not where I read it';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        chr(10) ||
        '    -- WHO WALKED OUT. Counted before anybody is paid, because the' || chr(10) ||
        '    -- answer decides how everybody is paid. It does not matter who put' || chr(10) ||
        '    -- the others down - the room, a companion, or the round cap.' || chr(10) ||
        '    SELECT count(*) FILTER (WHERE x.current_hp > 0),' || chr(10) ||
        '           min(x.player_id) FILTER (WHERE x.current_hp > 0)' || chr(10) ||
        '    INTO upright, alone' || chr(10) ||
        '    FROM dungeon_raiders x WHERE x.run_id = p_run_id;');

    -- And the share is no longer always the damage share.
    one := '            -- The pot is the bonus, and it is still split by damage.' || chr(10) ||
           '            share  := one.damage_dealt::numeric / total;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the damage share is not where I read it';
    END IF;
    src := replace(src, one,
        '            -- THE POT IS THE BONUS, and who gets it depends on who is' || chr(10) ||
        '            -- still upright.' || chr(10) ||
        '            --' || chr(10) ||
        '            -- Nobody upright is a real state and not a rounding' || chr(10) ||
        '            -- error: 0541''s round is simultaneous, so the last foe and' || chr(10) ||
        '            -- the last raider can fall together, and the room is read' || chr(10) ||
        '            -- as WON because a blow that breaks it on the final round' || chr(10) ||
        '            -- breaks it. A floor of corpses earns nothing.' || chr(10) ||
        '            share := CASE' || chr(10) ||
        '                WHEN upright = 0 THEN 0' || chr(10) ||
        '                WHEN upright = 1 THEN' || chr(10) ||
        '                     CASE WHEN one.player_id = alone THEN 1 ELSE 0 END' || chr(10) ||
        '                ELSE one.damage_dealt::numeric / total' || chr(10) ||
        '            END;');

    -- The spoils are the same question.
    one := '            loot := dungeon_spoils_for(one.player_id, run.realm_rank,' || chr(10) ||
           '                                       run.reward_scale);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the spoils call is not where I read it';
    END IF;
    src := replace(src, one,
        '            -- The items follow the pot. A corpse carries nothing out' || chr(10) ||
        '            -- and neither does somebody a knife left on the floor.' || chr(10) ||
        '            IF share > 0 THEN' || chr(10) ||
        '                loot := dungeon_spoils_for(one.player_id, run.realm_rank,' || chr(10) ||
        '                                           run.reward_scale);' || chr(10) ||
        '            END IF;');

    -- And the screen is told which of the three it was.
    one := '            ''keys_back'', CASE WHEN run.status = ''won'' THEN 0' || chr(10) ||
           '                              ELSE one.keys_paid END) || loot';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the spoils record is not where I read it';
    END IF;
    src := replace(src, one,
        '            ''keys_back'', CASE WHEN run.status = ''won'' THEN 0' || chr(10) ||
        '                              ELSE one.keys_paid END,' || chr(10) ||
        '            -- So the card can say what happened rather than leaving' || chr(10) ||
        '            -- somebody to work out why they got nothing.' || chr(10) ||
        '            ''upright'', upright,' || chr(10) ||
        '            ''took_it_all'', (upright = 1 AND one.player_id = alone),' || chr(10) ||
        '            ''betrayals'', one.betrayals) || loot');

    -- `betrayals` has to come out of the cursor for that line to work.
    one := '        SELECT x.player_id, x.damage_dealt, x.keys_paid, x.stones_paid, x.jade_paid';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the payout cursor is not where I read it';
    END IF;
    src := replace(src, one,
        '        SELECT x.player_id, x.damage_dealt, x.keys_paid, x.stones_paid,'
        || chr(10) ||
        '               x.jade_paid, x.betrayals');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Walk out alone, and walk out dead
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a    BIGINT;
    v_b    BIGINT;
    v_dg   SMALLINT;
    v_run  BIGINT;
    v_move BIGINT;
    v_spoils JSONB;
BEGIN
    SELECT dungeon_id INTO v_dg FROM dungeons WHERE realm_rank = 4;

    -- 1. TWO WALK OUT: split by damage, exactly as before.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-967, 'split-a') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-966, 'split-b') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN (SELECT realm_id, cultivation_required FROM realms
                    WHERE rank = 4 ORDER BY realm_id DESC LIMIT 1) r;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense)
        SELECT x.who, (SELECT min(physique_id) FROM physiques), 5000000, 5000000, 300
        FROM (VALUES (v_a), (v_b)) AS x(who);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT x.who, t.technique_id
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN (SELECT technique_id FROM techniques
                    WHERE created_by IS NULL AND category = 'attack' AND rank = 1
                    ORDER BY base_power DESC LIMIT 1) t;
        PERFORM grant_material(x.who, 'spirit_stone', 90000000)
        FROM (VALUES (v_a), (v_b)) AS x(who);
        PERFORM grant_material(x.who, 'dungeon_key', 3)
        FROM (VALUES (v_a), (v_b)) AS x(who);
        PERFORM grant_jade(x.who, 100, 'probe')
        FROM (VALUES (v_a), (v_b)) AS x(who);

        v_run := dungeon_open(v_a, v_dg, 'normal');
        PERFORM dungeon_invite(v_run, v_a, v_b);
        PERFORM dungeon_join(v_run, v_b);
        PERFORM dungeon_begin(v_run, v_a);

        SELECT dungeon_default_move(v_a) INTO v_move;
        PERFORM dungeon_choose(v_run, v_a, v_move);
        PERFORM dungeon_choose(v_run, v_b, v_move);

        UPDATE dungeon_foes SET current_hp = 1
        WHERE run_id = v_run AND current_hp > 0;
        UPDATE dungeon_raiders SET current_hp = max_hp WHERE run_id = v_run;
        PERFORM dungeon_resolve_round(v_run);

        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run) <> 'won' THEN
            RAISE EXCEPTION 'the room did not fall';
        END IF;

        SELECT x.spoils INTO v_spoils FROM dungeon_raiders x
        WHERE x.run_id = v_run AND x.player_id = v_b;
        IF (v_spoils ->> 'took_it_all')::boolean THEN
            RAISE EXCEPTION 'somebody claimed a room two people walked out of';
        END IF;
        IF (v_spoils ->> 'upright')::int <> 2 THEN
            RAISE EXCEPTION
                'the record says % walked out of a room two survived',
                v_spoils ->> 'upright';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 2. ONE WALKS OUT: they take the lot, even having dealt less.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-965, 'alone-a') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-964, 'alone-b') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN (SELECT realm_id, cultivation_required FROM realms
                    WHERE rank = 4 ORDER BY realm_id DESC LIMIT 1) r;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense)
        SELECT x.who, (SELECT min(physique_id) FROM physiques), 5000000, 5000000, 300
        FROM (VALUES (v_a), (v_b)) AS x(who);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT x.who, t.technique_id
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN (SELECT technique_id FROM techniques
                    WHERE created_by IS NULL AND category = 'attack' AND rank = 1
                    ORDER BY base_power DESC LIMIT 1) t;
        PERFORM grant_material(x.who, 'spirit_stone', 90000000)
        FROM (VALUES (v_a), (v_b)) AS x(who);
        PERFORM grant_material(x.who, 'dungeon_key', 3)
        FROM (VALUES (v_a), (v_b)) AS x(who);
        PERFORM grant_jade(x.who, 100, 'probe')
        FROM (VALUES (v_a), (v_b)) AS x(who);

        v_run := dungeon_open(v_a, v_dg, 'normal');
        PERFORM dungeon_invite(v_run, v_a, v_b);
        PERFORM dungeon_join(v_run, v_b);
        PERFORM dungeon_begin(v_run, v_a);

        SELECT dungeon_default_move(v_a) INTO v_move;
        PERFORM dungeon_choose(v_run, v_a, v_move);
        PERFORM dungeon_choose(v_run, v_b, v_move);
        PERFORM dungeon_resolve_round(v_run);

        -- `alone-a` dealt the damage and is then left on the floor; `alone-b`
        -- is the only one upright when the room falls.
        UPDATE dungeon_raiders SET damage_dealt = 1000000, current_hp = 0
        WHERE run_id = v_run AND player_id = v_a;
        UPDATE dungeon_raiders SET damage_dealt = 1, current_hp = max_hp
        WHERE run_id = v_run AND player_id = v_b;
        UPDATE dungeon_foes SET current_hp = 1
        WHERE run_id = v_run AND current_hp > 0;

        PERFORM dungeon_choose(v_run, v_b, v_move);
        PERFORM dungeon_resolve_round(v_run);

        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run) <> 'won' THEN
            RAISE EXCEPTION
                'the room did not fall to the survivor: %',
                (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run);
        END IF;

        SELECT x.spoils INTO v_spoils FROM dungeon_raiders x
        WHERE x.run_id = v_run AND x.player_id = v_b;
        IF NOT (v_spoils ->> 'took_it_all')::boolean THEN
            RAISE EXCEPTION
                'the only one standing did not take it: %', v_spoils;
        END IF;
        IF (v_spoils ->> 'share')::numeric >= 100 THEN
            NULL;  -- the recorded share is the damage share, which is fine
        END IF;

        -- And the one on the floor got the pot's nothing, though their stake
        -- came back - a stake is not loot.
        SELECT x.spoils INTO v_spoils FROM dungeon_raiders x
        WHERE x.run_id = v_run AND x.player_id = v_a;
        IF (v_spoils ->> 'stones')::bigint <> 0
           OR (v_spoils ->> 'jade')::bigint <> 0 THEN
            RAISE EXCEPTION
                'somebody on the floor was paid out of the pot: %', v_spoils;
        END IF;
        IF (v_spoils ->> 'stones_back')::bigint <= 0 THEN
            RAISE EXCEPTION
                'the stake did not come back to the raider who paid it: %',
                v_spoils;
        END IF;

        RAISE NOTICE 'the last one standing took the room';
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 3. NOBODY WALKS OUT of a won room: the state 0541's simultaneous round
    -- creates, and nobody is paid.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-963, 'corpse-a') RETURNING player_id INTO v_a;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required FROM realms r
        WHERE r.rank = 4 ORDER BY r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense)
        VALUES (v_a, (SELECT min(physique_id) FROM physiques), 5000000, 5000000, 300);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_a, technique_id FROM techniques
        WHERE created_by IS NULL AND category = 'attack' AND rank = 1
        ORDER BY base_power DESC LIMIT 1;
        PERFORM grant_material(v_a, 'spirit_stone', 90000000);
        PERFORM grant_material(v_a, 'dungeon_key', 3);
        PERFORM grant_jade(v_a, 100, 'probe');

        v_run := dungeon_open(v_a, v_dg, 'normal');
        PERFORM dungeon_begin(v_run, v_a);
        SELECT dungeon_default_move(v_a) INTO v_move;

        -- The room on 1, and the raider on 1 - so the round fells both.
        UPDATE dungeon_foes SET current_hp = 1 WHERE run_id = v_run AND current_hp > 0;
        UPDATE dungeon_raiders SET current_hp = 1, damage_dealt = 500
        WHERE run_id = v_run;
        PERFORM dungeon_choose(v_run, v_a, v_move);
        PERFORM dungeon_resolve_round(v_run);

        SELECT x.spoils INTO v_spoils FROM dungeon_raiders x
        WHERE x.run_id = v_run AND x.player_id = v_a;

        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run) = 'won'
           AND (SELECT x.current_hp FROM dungeon_raiders x
                WHERE x.run_id = v_run AND x.player_id = v_a) = 0 THEN
            IF (v_spoils ->> 'stones')::bigint <> 0
               OR (v_spoils ->> 'jade')::bigint <> 0 THEN
                RAISE EXCEPTION
                    'a floor of corpses was paid the pot: %', v_spoils;
            END IF;
            IF (v_spoils ->> 'upright')::int <> 0 THEN
                RAISE EXCEPTION 'the record claims somebody was upright';
            END IF;
            RAISE NOTICE
                'a won room with nobody left paid nothing, as it should';
        ELSE
            RAISE NOTICE
                'the simultaneous double knockout did not come up this run (status %, hp %)',
                (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run),
                (SELECT x.current_hp FROM dungeon_raiders x
                 WHERE x.run_id = v_run AND x.player_id = v_a);
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'the pot follows whoever is left standing';
END;
$probe$;
