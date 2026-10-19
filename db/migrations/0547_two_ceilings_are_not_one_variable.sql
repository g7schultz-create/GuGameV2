-- 0547_two_ceilings_are_not_one_variable
--
-- 0544 repointed `ceiling` in `dungeon_spoils_for` from the world's Gu drop
-- limit to the dungeon's own, so a room could reach rank 9. One variable,
-- used twice:
--
--     ceiling := game_config_value('dungeon_gu_max_rank');   -- now 9
--     ...
--     jackpot := ceiling + dungeon_jackpot_rank_bonus;       -- became 10
--
-- and there is no rank 10 Gu, so THE JACKPOT STOPPED FIRING ALTOGETHER.
-- `test_the_deep_rooms_pay_a_jackpot_and_only_one_rung_of_it` caught it with
-- "three hundred clears of the deep room paid nothing".
--
-- The two are different questions and were always different questions:
--
--     how deep a room may roll          the dungeon's own reach
--     the one exception to the WORLD's  `gu_max_droppable_rank` + a bonus,
--     ceiling                           which is what the jackpot IS
--
-- So the jackpot gets its own variable off the world ceiling, as it had, and
-- the ordinary roll keeps the dungeon's.
--
-- AND THE JACKPOT IS NOW VESTIGIAL, which is worth saying rather than quietly
-- restoring. It hands over a rank 6 worm - one past the world's 5 - in a room
-- whose ordinary roll now reaches rank 9. It was "the one exception to the
-- ceiling" when the dungeon shared that ceiling; the dungeon does not any
-- more, so the exception is to a rule it no longer follows. It fires, its two
-- tests pass, and nothing it gives is worth having at depth. Retiring it or
-- repointing it at the apex is a decision I have not been asked to make, and
-- making it would be the fourth balance call I had taken on my own today.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('dungeon_spoils_for(bigint,smallint,numeric)'::regprocedure);

    -- A second local, named for the question it answers.
    one := '    jackpot SMALLINT;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the jackpot declaration is not where I read it';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        '    world   SMALLINT;   -- 0547. The WORLD''s drop ceiling, which the' || chr(10) ||
        '                        -- jackpot is the exception to. Not the same' || chr(10) ||
        '                        -- number as how deep this room may roll.');

    one := '    ceiling := game_config_value(''dungeon_gu_max_rank'')::smallint;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the room''s reach is not where 0544 set it';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        '    world   := game_config_value(''gu_max_droppable_rank'')::smallint;');

    one := '    jackpot := ceiling + game_config_value(''dungeon_jackpot_rank_bonus'')::smallint;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the jackpot rank is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- One rung past the WORLD''s ceiling, which is what makes it an' || chr(10) ||
        '    -- exception. Taking it off the room''s own reach instead made it' || chr(10) ||
        '    -- rank 10, and no such Gu exists, so it never fired at all.' || chr(10) ||
        '    jackpot := world + game_config_value(''dungeon_jackpot_rank_bonus'')::smallint;');

    one := '    IF jackpot > ceiling AND p_rank >= jackpot';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the jackpot gate is not where I read it';
    END IF;
    src := replace(src, one,
        '    IF jackpot > world AND p_rank >= jackpot');

    EXECUTE src;
END;
$patch$;


DO $probe$
DECLARE
    v_who  BIGINT;
    v_hits INTEGER := 0;
    v_deep INTEGER := 0;
    v_max  SMALLINT;
    i      INTEGER;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-959, 'jackpot-probe') RETURNING player_id INTO v_who;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_who, r.realm_id, r.cultivation_required FROM realms r
        WHERE r.rank = 4 ORDER BY r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_who, (SELECT min(physique_id) FROM physiques));

        -- 1. THE JACKPOT FIRES AGAIN, from the room one rung past the world's
        -- ceiling - which is the room the test names.
        FOR i IN 1..400 LOOP
            IF dungeon_spoils_for(v_who, 6::smallint, 11.0) ? 'jackpot' THEN
                v_hits := v_hits + 1;
            END IF;
        END LOOP;
        IF v_hits = 0 THEN
            RAISE EXCEPTION '400 clears of the rank 6 room paid no jackpot';
        END IF;
        RAISE NOTICE '% of 400 rank 6 clears paid a jackpot', v_hits;

        -- 2. AND IT IS STILL ONE RUNG, not the apex: a rank 9 room cannot use
        -- the jackpot to reach past rank 6 through that door.
        IF (SELECT game_config_value('gu_max_droppable_rank')
                 + game_config_value('dungeon_jackpot_rank_bonus')) <> 6 THEN
            RAISE EXCEPTION
                'the jackpot is rank %, not the 6 its tests expect',
                (SELECT game_config_value('gu_max_droppable_rank')
                      + game_config_value('dungeon_jackpot_rank_bonus'));
        END IF;

        -- 3. AND THE ORDINARY ROLL STILL REACHES RANK 9, which is what 0544
        -- was for - so this fix did not undo it.
        DELETE FROM player_gu WHERE owner_id = v_who;
        FOR i IN 1..600 LOOP
            PERFORM dungeon_spoils_for(v_who, 19::smallint, 1.0);
        END LOOP;
        SELECT COALESCE(max(t.rank), 0) INTO v_max
        FROM player_gu g JOIN gu_types t USING (gu_type_id)
        WHERE g.owner_id = v_who;
        IF v_max < 7 THEN
            RAISE EXCEPTION
                '600 Vault clears never reached past rank % - 0544 is undone',
                v_max;
        END IF;
        RAISE NOTICE 'the deepest worm out of 600 Vault clears was rank %', v_max;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
