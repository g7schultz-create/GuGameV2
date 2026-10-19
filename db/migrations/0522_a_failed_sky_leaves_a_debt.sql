-- 0522_a_failed_sky_leaves_a_debt
--
-- "Tribulation penalty will stop your cultivation till you pay 500 jade."
--
-- Until now a failed tribulation cost exactly one thing: an eight hour wait
-- before heaven would look at you again. Five cultivators have failed one -
-- at ranks 3, 5, 6, 10 and 11 - and all five simply came back and passed it.
--
-- So a failure now leaves a DEBT, and while it is owed cultivation does not
-- advance. The debt is a flat 500 jade.
--
-- WHERE THE HALT GOES. `apply_cultivation_xp` is the single choke point: all
-- five ways to gain cultivation - meditate, absorb_essence, take_pill,
-- resolve_training_session, settle_passive_cultivation - go through it. One
-- guard there covers every one of them, now and later.
--
-- AND IT BANKS NOTHING RATHER THAN REFUSING. A refusal would raise out of
-- `settle_passive_cultivation`, which is the passive tick that half the
-- screens in the bot call before they draw anything - so a debt would have
-- broken the game instead of slowing it. Banking nothing is safe, and the
-- callers already report it honestly: `settle_passive_cultivation` measures
-- what landed rather than what was offered ("a card that reports the offer is
-- a card that lies"), and `meditate` and `take_pill` both read cultivation
-- before and after. They will all say zero, correctly, without being touched.
--
-- THE TIME IS SPENT, NOT STORED. The reserve is not an option here: it exists
-- for cultivation waiting behind a realm ceiling, and `cultivation_reserve_cap`
-- is 0 at the peak of the ladder because there is no next gap to measure. So a
-- halted hour is a lost hour. That is the penalty, and it is the reason to pay
-- the 500 rather than shrug.
--
-- AND THE REAL TEETH ARE AT THE ASCENSION DOOR. At the peak of rank 18 -
-- the only place a rank 19 sky can be failed - cultivation has no ceiling left
-- to climb towards and buys nothing but leaderboard position and servant food,
-- so a cultivation halt alone would barely sting the people this is for.
-- `venerable_ascend` therefore refuses while a debt is owed: fail the Sovereign
-- Calamity and the door stays shut until the sky is paid, even after you
-- survive the retry. That is not a second penalty, it is the same one - the
-- ascension IS the advancement a stopped cultivator is not making.
--
-- SET, NOT ADDED. The fee is a flat gate. Failing twice leaves one debt of
-- 500, and concluding a battle twice cannot bill twice.
--
-- NOBODY IS CHARGED FOR THE PAST. The column defaults to 0 and is only ever
-- written by `battle_conclude`, so the five historical failures - all long
-- since retried and passed - leave nothing behind. The probe asserts that
-- rather than claiming it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('tribulation_failure_jade', 500,
     'The jade a failed tribulation leaves owed. Cultivation does not advance, and the Venerable door does not open, until it is paid.');


ALTER TABLE player_cultivation
    ADD COLUMN tribulation_debt BIGINT NOT NULL DEFAULT 0
        CHECK (tribulation_debt >= 0);

COMMENT ON COLUMN player_cultivation.tribulation_debt IS
    'Jade owed to the sky for a failed tribulation. While above zero, apply_cultivation_xp banks nothing and venerable_ascend refuses. Cleared only by pay_tribulation_debt.';


-- ---------------------------------------------------------------------------
-- One sentence, in one place
-- ---------------------------------------------------------------------------

CREATE FUNCTION cultivation_halt(p_player_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE AS $fn$
    -- NULL when nothing is in the way, so every caller can read it as a
    -- boolean and show it as a sentence. One definition, because the halt is
    -- checked in the cultivation choke point, at the ascension door, and on
    -- every screen that draws a cultivation bar.
    SELECT CASE WHEN pc.tribulation_debt > 0 THEN
        'the sky has not finished with you - your cultivation is stopped until '
        || pc.tribulation_debt || ' jade is paid. /paydebt'
    END
    FROM player_cultivation pc
    WHERE pc.player_id = p_player_id;
$fn$;

COMMENT ON FUNCTION cultivation_halt(BIGINT) IS
    'Why this cultivator is not advancing, or NULL if they are. Read as a boolean by the guards and as a sentence by the screens.';


-- ---------------------------------------------------------------------------
-- The debt is incurred where the ending is recorded
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('battle_conclude(bigint,text)'::regprocedure);

    anchor := '    WHERE pt.battle_id = p_battle_id AND pt.status = ''facing'';';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'the tribulation settlement in battle_conclude is not where 0386 left it';
    END IF;

    src := replace(src, anchor,
        anchor || chr(10) ||
        chr(10) ||
        '    -- A FAILED SKY LEAVES A DEBT. Written here because the statement' || chr(10) ||
        '    -- above is the one line every ending passes through - a flight and' || chr(10) ||
        '    -- an expiry are failures as surely as a death - and it has just' || chr(10) ||
        '    -- recorded which ending it was. SET rather than added, because the' || chr(10) ||
        '    -- fee is a flat gate: concluding twice cannot bill twice, and two' || chr(10) ||
        '    -- failures leave one debt.' || chr(10) ||
        '    UPDATE player_cultivation pc' || chr(10) ||
        '    SET tribulation_debt =' || chr(10) ||
        '        game_config_value(''tribulation_failure_jade'')::bigint' || chr(10) ||
        '    WHERE pc.player_id = me.player_id' || chr(10) ||
        '      AND EXISTS (SELECT 1 FROM player_tribulations pt' || chr(10) ||
        '                  WHERE pt.battle_id = p_battle_id' || chr(10) ||
        '                    AND pt.player_id = me.player_id' || chr(10) ||
        '                    AND pt.status = ''failed'');');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The halt, at the one choke point
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('apply_cultivation_xp(bigint,bigint)'::regprocedure);

    anchor := '    -- At the top of the ladder there is no door to wait at, so nothing is';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'the top-of-the-ladder branch in apply_cultivation_xp has moved';
    END IF;

    src := replace(src, anchor,
        '    -- A FAILED SKY STOPS CULTIVATION. Nothing is banked and nothing is' || chr(10) ||
        '    -- reserved while a debt is owed, so the hour is spent and gone -' || chr(10) ||
        '    -- which is the penalty, and the reason to pay rather than shrug.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- It banks nothing rather than refusing because this function is' || chr(10) ||
        '    -- called by `settle_passive_cultivation`, the tick that half the' || chr(10) ||
        '    -- screens in the bot run before they draw anything. A refusal here' || chr(10) ||
        '    -- would have broken the game instead of slowing it. Every caller' || chr(10) ||
        '    -- already reports what was banked rather than what was offered, so' || chr(10) ||
        '    -- they all say zero correctly without being touched.' || chr(10) ||
        '    IF cultivation_halt(p_player_id) IS NOT NULL THEN' || chr(10) ||
        '        RETURN (SELECT pc.realm_id FROM player_cultivation pc' || chr(10) ||
        '                WHERE pc.player_id = p_player_id);' || chr(10) ||
        '    END IF;' || chr(10) ||
        chr(10) ||
        anchor);

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the door the halt actually matters at
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('venerable_ascend(bigint)'::regprocedure);

    anchor := '    v_before := gu_capacity_of(p_player_id);';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'venerable_ascend is not shaped the way 0521 left it';
    END IF;

    src := replace(src, anchor,
        '    -- A stopped cultivator is not advancing, and the ascension IS the' || chr(10) ||
        '    -- advancement. At the peak of rank 18 cultivation has no ceiling' || chr(10) ||
        '    -- left to climb towards, so halting it alone would barely sting the' || chr(10) ||
        '    -- only people who can get here - this is where the debt bites.' || chr(10) ||
        '    IF cultivation_halt(p_player_id) IS NOT NULL THEN' || chr(10) ||
        '        RAISE EXCEPTION ''%'', cultivation_halt(p_player_id)' || chr(10) ||
        '            USING ERRCODE = ''check_violation'';' || chr(10) ||
        '    END IF;' || chr(10) ||
        chr(10) ||
        anchor);

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Paying it
-- ---------------------------------------------------------------------------

CREATE FUNCTION pay_tribulation_debt(p_player_id BIGINT)
RETURNS TABLE (paid BIGINT, jade_left BIGINT)
LANGUAGE plpgsql AS $fn$
DECLARE
    v_owed BIGINT;
    v_held BIGINT;
    v_left BIGINT;
BEGIN
    SELECT pc.tribulation_debt INTO v_owed
    FROM player_cultivation pc
    WHERE pc.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have not begun to cultivate'
            USING ERRCODE = 'check_violation';
    END IF;

    IF COALESCE(v_owed, 0) <= 0 THEN
        RAISE EXCEPTION 'you owe the sky nothing'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Checked before spending so the refusal says what is short. `spend_jade`
    -- would raise on its own, but about a material rather than about a sky.
    v_held := jade_held(p_player_id);
    IF v_held < v_owed THEN
        RAISE EXCEPTION
            'the sky wants % jade. You hold % - % short',
            v_owed, v_held, v_owed - v_held
            USING ERRCODE = 'check_violation';
    END IF;

    v_left := spend_jade(p_player_id, v_owed, 'tribulation debt');

    UPDATE player_cultivation pc SET tribulation_debt = 0
    WHERE pc.player_id = p_player_id;

    RETURN QUERY SELECT v_owed, v_left;
END;
$fn$;

COMMENT ON FUNCTION pay_tribulation_debt(BIGINT) IS
    'Settle what a failed tribulation left owed, which is the only thing that clears it. Until it is paid, cultivation banks nothing and the Venerable door stays shut.';


-- ---------------------------------------------------------------------------
-- Fail, stop, pay, resume
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_fee   BIGINT := game_config_value('tribulation_failure_jade')::bigint;
    v_path  TEXT;
    v_was   BIGINT;
    v_now   BIGINT;
    v_realm SMALLINT;
    v_pay   RECORD;
    v_n     INTEGER;
BEGIN
    IF v_fee <> 500 THEN
        RAISE EXCEPTION 'the fee is % jade, not the 500 that was asked for', v_fee;
    END IF;

    -- NOBODY IS CHARGED FOR THE PAST. Five cultivators have failed a
    -- tribulation and all five retried and passed it; none of them owes
    -- anything for a sky they already settled.
    SELECT count(*) INTO v_n FROM player_cultivation WHERE tribulation_debt <> 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators were charged for a past failure', v_n;
    END IF;

    -- And nobody alive is halted, so no screen changes today.
    SELECT count(*) INTO v_n FROM players p
    WHERE p.deleted_at IS NULL AND cultivation_halt(p.player_id) IS NOT NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators are stopped by this migration', v_n;
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-997, 'debt-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        -- 1. CULTIVATION RUNS NORMALLY while nothing is owed.
        SELECT pc.cultivation INTO v_was FROM player_cultivation pc
        WHERE pc.player_id = v_pid;
        PERFORM apply_cultivation_xp(v_pid, 1000000);
        SELECT pc.cultivation INTO v_now FROM player_cultivation pc
        WHERE pc.player_id = v_pid;
        IF v_now <> v_was + 1000000 THEN
            RAISE EXCEPTION
                'cultivation did not bank before any debt: % -> %', v_was, v_now;
        END IF;

        -- 2. THE SKY IS FAILED, through the one line every ending passes.
        PERFORM tribulation_face(v_pid);
        PERFORM battle_conclude(
            (SELECT pt.battle_id FROM player_tribulations pt
             WHERE pt.player_id = v_pid AND pt.status = 'facing'),
            'fled');

        IF (SELECT pt.status FROM player_tribulations pt
            WHERE pt.player_id = v_pid ORDER BY pt.attempt_id DESC LIMIT 1) <> 'failed' THEN
            RAISE EXCEPTION 'fleeing the sky was not recorded as a failure';
        END IF;
        IF (SELECT pc.tribulation_debt FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> v_fee THEN
            RAISE EXCEPTION
                'a failed sky left % owed, not %',
                (SELECT pc.tribulation_debt FROM player_cultivation pc
                 WHERE pc.player_id = v_pid), v_fee;
        END IF;
        IF cultivation_halt(v_pid) IS NULL THEN
            RAISE EXCEPTION 'a debt is owed but nothing says so';
        END IF;
        IF cultivation_halt(v_pid) NOT LIKE '%500 jade%' THEN
            RAISE EXCEPTION 'the halt does not name the price: %', cultivation_halt(v_pid);
        END IF;

        -- 3. AND CULTIVATION STOPS - banked nothing, reserved nothing, and
        -- without raising, because the passive tick runs through here.
        SELECT pc.cultivation INTO v_was FROM player_cultivation pc
        WHERE pc.player_id = v_pid;
        v_realm := apply_cultivation_xp(v_pid, 500000000);
        SELECT pc.cultivation INTO v_now FROM player_cultivation pc
        WHERE pc.player_id = v_pid;
        IF v_now <> v_was THEN
            RAISE EXCEPTION
                'cultivation advanced while stopped: % -> %', v_was, v_now;
        END IF;
        IF (SELECT pc.reserve FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> 0 THEN
            RAISE EXCEPTION 'the halt quietly stored the gain instead of stopping it';
        END IF;
        IF v_realm IS NULL THEN
            RAISE EXCEPTION
                'the halt returned no realm, which would strand its callers';
        END IF;

        -- The tick itself survives it, which is the thing a refusal would
        -- have broken.
        PERFORM settle_passive_cultivation(v_pid);
        IF (SELECT pc.cultivation FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> v_was THEN
            RAISE EXCEPTION 'the passive tick banked cultivation while stopped';
        END IF;

        -- 4. AND THE VENERABLE DOOR IS SHUT, even once the sky is survived.
        UPDATE player_tribulations SET status = 'passed', settled_at = now()
        WHERE player_id = v_pid;
        BEGIN
            PERFORM venerable_ascend(v_pid);
            RAISE EXCEPTION 'ascended while owing the sky';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%cultivation is stopped%' THEN RAISE; END IF;
        END;

        -- 5. PAYING IS REFUSED WITHOUT THE JADE, and says what is short.
        BEGIN
            PERFORM pay_tribulation_debt(v_pid);
            RAISE EXCEPTION 'paid 500 jade while holding none';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%short%' THEN RAISE; END IF;
        END;

        -- 6. PAY IT, and everything resumes.
        PERFORM grant_jade(v_pid, v_fee + 17, 'debt probe');
        SELECT * INTO v_pay FROM pay_tribulation_debt(v_pid);

        IF v_pay.paid <> v_fee THEN
            RAISE EXCEPTION 'paid % rather than %', v_pay.paid, v_fee;
        END IF;
        IF v_pay.jade_left <> 17 THEN
            RAISE EXCEPTION
                'paying left % jade rather than the 17 over', v_pay.jade_left;
        END IF;
        IF cultivation_halt(v_pid) IS NOT NULL THEN
            RAISE EXCEPTION
                'still stopped after paying: %', cultivation_halt(v_pid);
        END IF;

        SELECT pc.cultivation INTO v_was FROM player_cultivation pc
        WHERE pc.player_id = v_pid;
        PERFORM apply_cultivation_xp(v_pid, 1000000);
        IF (SELECT pc.cultivation FROM player_cultivation pc
            WHERE pc.player_id = v_pid) <> v_was + 1000000 THEN
            RAISE EXCEPTION 'cultivation did not resume after the debt was paid';
        END IF;

        -- And the door opens.
        PERFORM venerable_ascend(v_pid);
        IF NOT EXISTS (SELECT 1 FROM player_dao WHERE player_id = v_pid) THEN
            RAISE EXCEPTION 'the door stayed shut after the sky was paid';
        END IF;

        -- 7. And a cleared debt cannot be paid twice.
        BEGIN
            PERFORM pay_tribulation_debt(v_pid);
            RAISE EXCEPTION 'paid a debt that was already settled';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%owe the sky nothing%' THEN RAISE; END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- And none of that leaked.
    SELECT count(*) INTO v_n FROM player_cultivation WHERE tribulation_debt <> 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% debts survived the probe', v_n;
    END IF;

    RAISE NOTICE
        'a failed sky now leaves % jade owed; cultivation stops and the Venerable door shuts until it is paid',
        v_fee;
END;
$probe$;
