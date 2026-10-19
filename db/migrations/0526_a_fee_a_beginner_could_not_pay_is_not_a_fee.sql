-- 0526_a_fee_a_beginner_could_not_pay_is_not_a_fee
--
-- 0522 made a failed tribulation cost 500 jade AT EVERY RANK, because the
-- instruction - "Tribulation penalty will stop your cultivation till you pay
-- 500 jade" - named no rank. Measured against fourteen days of the jade
-- ledger, that is not one penalty but two different ones:
--
--     realm 18   1,771 jade a day across six cultivators   1.7 days to pay
--     realm 17      96 a day                               5.2 days
--     realm  6      54 a day across two                   18.7 days
--     realm  5      11 a day                              45.2 days
--     realm  3      18 a day across two                   56.5 days
--     realm  1      11 a day across five                 234.9 days
--
-- At the top it is a real cost somebody pays over a weekend. At the bottom it
-- stops a beginner cultivating for the better part of a year for losing one
-- fight - and cultivation is the pillar they have, so it is close to ending
-- the character. That is not a penalty, it is a wall, and nobody asked for it.
--
-- SO THE FEE GETS A FLOOR, IN CONFIG. `tribulation_debt_from_rank` is 19: the
-- Venerable door and above, which is the tribulation the whole conversation
-- was about. Below it a failed sky costs what it has always cost - the fight,
-- and eight hours before heaven looks at you again.
--
-- The 500 is untouched and the threshold is one row in `game_config`, so if
-- the intent really was every rank it is an UPDATE and not a migration. It is
-- a floor rather than a scaling fee because a flat number was asked for, and
-- inventing a curve would be answering a question that was not put.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('tribulation_debt_from_rank', 19,
     'The lowest rank at which a failed tribulation leaves jade owed. 19 - the Venerable door - because at realm 1 the fee is 235 days of income and would end the character rather than cost it something. Lower this if the fee should reach further down.');


DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('battle_conclude(bigint,text)'::regprocedure);

    one := '                    AND pt.status = ''failed'');';

    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION
            'the debt 0522 added to battle_conclude is not where I left it';
    END IF;

    EXECUTE replace(src, one,
        '                    AND pt.status = ''failed''' || chr(10) ||
        '                    -- 0526. Below the Venerable door the fee is worth' || chr(10) ||
        '                    -- months of a beginner''s jade income, which ends a' || chr(10) ||
        '                    -- character rather than costing it something.' || chr(10) ||
        '                    AND pt.rank >=' || chr(10) ||
        '                        game_config_value(''tribulation_debt_from_rank''));');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The sky above still bills, the skies below still do not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_path  TEXT;
    v_fight BIGINT;
    v_floor INTEGER := game_config_value('tribulation_debt_from_rank')::int;
    v_fee   BIGINT  := game_config_value('tribulation_failure_jade')::bigint;
    v_n     INTEGER;
BEGIN
    IF v_floor <> 19 OR v_fee <> 500 THEN
        RAISE EXCEPTION
            'the fee is % jade from rank %, wanted 500 from 19', v_fee, v_floor;
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    -- 1. A LOW SKY STILL COSTS NOTHING BUT THE WAIT. Driven through
    -- `battle_conclude` rather than asserted, because the branch being tested
    -- lives there.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-994, 'low-sky-probe') RETURNING player_id INTO v_pid;
        -- The NEXT realm's requirement, not this one's: the door asks what the
        -- rank above costs, so a cultivator holding exactly their own floor is
        -- turned away for cultivation and never reaches the fight.
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, nxt.cultivation_required
        FROM realms r JOIN realms nxt ON nxt.realm_id = r.realm_id + 1
        WHERE r.rank = 2 AND r.stage = 'peak';
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques),
                10000000000000, 10000000000000);
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        IF (SELECT s.rank FROM tribulation_standing(v_pid) s) >= v_floor THEN
            RAISE EXCEPTION 'the probe cultivator is not below the fee''s floor';
        END IF;

        -- Opened the way `tribulation_face` opens one, rather than by calling
        -- it: a rank 3 door also wants a Body Tempering Pill and whatever else
        -- `breakthrough_gate` asks for, and satisfying eighteen prerequisites
        -- would be building a character to test a branch in `battle_conclude`
        -- that only reads `player_tribulations.rank`. The high sky below DOES
        -- go through `tribulation_face`, so the real path is still proven.
        SELECT battle_open(v_pid, s.species_id) INTO v_fight
        FROM tribulation_standing(v_pid) s;
        UPDATE battles SET kind = 'tribulation' WHERE battle_id = v_fight;
        INSERT INTO player_tribulations (player_id, rank, battle_id, status)
        SELECT v_pid, s.rank, v_fight, 'facing' FROM tribulation_standing(v_pid) s;

        PERFORM battle_conclude(v_fight, 'fled');

        IF (SELECT pt.status FROM player_tribulations pt
            WHERE pt.battle_id = v_fight) <> 'failed' THEN
            RAISE EXCEPTION 'the low sky was not recorded as failed';
        END IF;
        IF (SELECT pc.tribulation_debt FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> 0 THEN
            RAISE EXCEPTION
                'a beginner was billed % jade for losing one fight',
                (SELECT pc.tribulation_debt FROM player_cultivation pc
                 WHERE pc.player_id = v_pid);
        END IF;
        IF cultivation_halt(v_pid) IS NOT NULL THEN
            RAISE EXCEPTION 'a beginner''s cultivation was stopped: %',
                cultivation_halt(v_pid);
        END IF;
        -- And the wait that has always been the cost is still there.
        IF (SELECT s.wait_seconds FROM tribulation_standing(v_pid) s) <= 0 THEN
            RAISE EXCEPTION 'the low sky now costs nothing at all';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 2. AND THE VENERABLE DOOR STILL BILLS, so this did not simply switch
    -- the penalty off.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-993, 'high-sky-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques),
                10000000000000, 10000000000000);
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        IF (SELECT s.rank FROM tribulation_standing(v_pid) s) <> 19 THEN
            RAISE EXCEPTION 'the probe cultivator is not in the Venerable door';
        END IF;

        v_fight := tribulation_face(v_pid);
        PERFORM battle_conclude(v_fight, 'fled');

        IF (SELECT pc.tribulation_debt FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> v_fee THEN
            RAISE EXCEPTION
                'the Venerable door billed % rather than %',
                (SELECT pc.tribulation_debt FROM player_cultivation pc
                 WHERE pc.player_id = v_pid), v_fee;
        END IF;
        IF cultivation_halt(v_pid) IS NULL THEN
            RAISE EXCEPTION 'a failed Venerable sky stopped nothing';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody alive owes anything, and nothing leaked out of the probes.
    SELECT count(*) INTO v_n FROM player_cultivation WHERE tribulation_debt <> 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% debts survived this migration', v_n;
    END IF;

    RAISE NOTICE
        'a failed sky costs % jade from rank % up, and the wait alone below it',
        v_fee, v_floor;
END;
$probe$;
