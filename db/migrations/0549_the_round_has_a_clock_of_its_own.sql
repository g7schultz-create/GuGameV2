-- 0549_the_round_has_a_clock_of_its_own
--
-- 0548 put a deadline on `duel_force` and hung it on the wrong column.
--
--     IF EXISTS (SELECT 1 FROM battle_combatants c
--                WHERE c.chose_at > now() - duel_round_seconds) THEN refuse
--
-- which it justified like this: "if NOBODY has chosen there is nothing to
-- force them away from, both brace, and the turn counts toward the cap."
--
-- A round that nobody has answered yet and a round that JUST RESOLVED are the
-- same two rows. `duel_resolve` ends by setting both seats back to
--
--     intent_action = NULL, intent_technique_id = NULL, chose_at = NULL
--
-- so the instant a round is played, every `chose_at` is NULL again and 0548's
-- guard waves the next force straight through. Press it fifty times and both
-- cultivators brace fifty times: nobody takes a point of damage, the turn
-- counter runs to `battle_turn_cap`, and the duel is DRAWN. Which means the
-- side about to lose can deny the win outright - the same theft 0548 was
-- written to stop, through the hole 0548 left open on its way past.
--
-- The clock belongs to the ROUND, and the round has one. `duel_resolve` writes
-- two `battle_actions` rows every time it runs, each stamped `created_at`, so
-- the newest of those is when the current round opened; before the first one
-- exists, `battles.started_at` is. Neither can be reset by a player choosing,
-- unchoosing or being forced, and both move forward exactly once per round.
--
-- `chose_at` is still the right column for "has this cultivator answered" -
-- `duel_choose` and `duel_force` both read it that way, and that part of 0548
-- stands. It is only wrong as a clock.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    IF EXISTS (
        SELECT 1 FROM battle_combatants c
        WHERE c.battle_id = p_battle_id
          AND c.chose_at > now() - make_interval(
                  secs => game_config_value(''duel_round_seconds'')::double precision)
    ) THEN
        RAISE EXCEPTION ''they still have time to choose''
            USING ERRCODE = ''check_violation'';
    END IF;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'duel_force' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'duel_force does not carry the guard 0548 put in it';
    END IF;

    patched := replace(src, anchor,
'    -- THE ROUND''S OWN CLOCK, not either cultivator''s. `duel_resolve` clears
    -- both `chose_at` columns the moment it finishes, so a round that just
    -- resolved is indistinguishable from one nobody has answered - and 0548
    -- read that second case as permission. Pressed over and over it braced
    -- both sides to `battle_turn_cap` and drew the duel, which is how the
    -- losing side would have stolen a draw.
    --
    -- `battle_actions.created_at` moves forward exactly once a round, when
    -- the round is played, and nothing a player does resets it. Before the
    -- first round there are no rows, and the fight''s own start is the clock.
    IF COALESCE(
           (SELECT max(a.created_at) FROM battle_actions a
            WHERE a.battle_id = p_battle_id),
           (SELECT b.started_at FROM battles b
            WHERE b.battle_id = p_battle_id)
       ) > now() - make_interval(
               secs => game_config_value(''duel_round_seconds'')::double precision)
    THEN
        RAISE EXCEPTION ''the round still has time to run''
            USING ERRCODE = ''check_violation'';
    END IF;');

    IF patched = src THEN
        RAISE EXCEPTION 'the duel_force patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a    BIGINT;
    v_b    BIGINT;
    v_tech BIGINT;
    v_duel BIGINT;
    v_n    INTEGER;
    v_was  INTEGER;
    v_secs NUMERIC := game_config_value('duel_round_seconds');
BEGIN
    SELECT t.technique_id INTO v_tech FROM techniques t
    WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-966, 'clock-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-965, 'clock-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT r.realm_id, r.cultivation_required FROM realms r
            ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1) r;

        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT x.who, (SELECT min(physique_id) FROM physiques),
               src.max_hp, src.max_hp, src.defense, src.strength
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT pp.max_hp, pp.defense, pp.strength
            FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
            WHERE p.deleted_at IS NULL AND player_standing(p.player_id) >= 18
            ORDER BY pp.max_hp DESC LIMIT 1) src;

        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech), (v_b, v_tech);

        v_duel := duel_open(v_a, v_b);

        -- 1. A DUEL THAT HAS JUST OPENED CANNOT BE FORCED, with nobody having
        --    chosen at all. This is the case 0548 waved through.
        BEGIN
            PERFORM duel_force(v_duel);
            RAISE EXCEPTION 'a duel could be forced the second it opened';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- 2. Once the round has run out, it goes through. `started_at` is the
        --    clock until a round has been played, so that is what moves.
        UPDATE battles b
        SET started_at = now() - make_interval(secs => (v_secs + 5)::double precision)
        WHERE b.battle_id = v_duel;

        PERFORM duel_force(v_duel);
        SELECT b.turn_number INTO v_was FROM battles b WHERE b.battle_id = v_duel;
        IF v_was < 2 THEN
            RAISE EXCEPTION 'a round that had run out was still not played';
        END IF;

        -- 3. AND NOT AGAIN STRAIGHT AFTER. This is the theft: both seats are
        --    back to NULL, the fight is young again by 0548's reading, and
        --    fifty presses would have drawn it.
        BEGIN
            PERFORM duel_force(v_duel);
            RAISE EXCEPTION
                'a resolved round let the next one be forced at once - '
                'the duel could still be drawn on demand';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        SELECT b.turn_number INTO v_n FROM battles b WHERE b.battle_id = v_duel;
        IF v_n <> v_was THEN
            RAISE EXCEPTION 'a refused force played a round anyway (% -> %)',
                            v_was, v_n;
        END IF;

        -- 4. And when THAT round runs out in turn, it goes through - the clock
        --    now being the actions the last round wrote.
        UPDATE battle_actions a
        SET created_at = now() - make_interval(secs => (v_secs + 5)::double precision)
        WHERE a.battle_id = v_duel;

        PERFORM duel_force(v_duel);
        SELECT b.turn_number INTO v_n FROM battles b WHERE b.battle_id = v_duel;
        IF v_n <= v_was THEN
            RAISE EXCEPTION 'the second round never ran';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
    END;
END
$probe$;
