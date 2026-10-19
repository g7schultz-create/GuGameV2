-- 0548_a_duel_nobody_can_stall_or_steal
--
-- `duel_open` is called by nothing. 0541 says so in so many words - the raid's
-- betrayal runs through `dungeon_resolve_round` and `player_swing`, and the
-- standalone duel loop 0534 built "stays for a standalone duel and is reached
-- from nowhere yet". That is the only reason none of the four holes below has
-- been used. A `/duel` command opens all of them at once.
--
-- 1. `duel_force` HAS NO DEADLINE.
--
--        UPDATE battle_combatants c SET intent_action = 'guard' ...
--        WHERE c.intent_action IS NULL
--
--    Whoever has not chosen braces. The comment calls that "the safe reading
--    of someone who walked away", and it is - but nothing says they walked
--    away. Choose your heaviest attack, call force, and the other cultivator
--    guards whether they were deciding or not. Repeat: you swing every round,
--    they never do, and you take nothing back. That is not a fix for
--    stalling, it is a way to win every duel without being hit once.
--
--    It now refuses while anybody has chosen recently. Not "while anybody is
--    still choosing" - the round opens when the FIRST of them chooses, and
--    `chose_at` on that seat is the only clock either seat carries.
--
--    When NEITHER has chosen there is nothing to force them away from, both
--    brace, nobody is harmed and the turn counts toward the cap below. That
--    is how a duel both of them walked out of ends, so it stays allowed.
--
-- 2. `duel_resolve` HAS NO TURN CAP.
--
--    `battle_act` caps everything that is not 'pve' at `battle_turn_cap`, and
--    the comment there says why: "`<> 'pve'` rather than `= 'tribulation'` so
--    a kind added later is capped until somebody decides otherwise". A duel
--    IS a kind added later, and it does not go through `battle_act`, so it
--    inherited none of that. Two cultivators who both guard take nothing from
--    each other forever - and `duel_open` writes `player_active_battle` for
--    both seats, so forever means locked out of hunting, delving, the horde
--    and the dungeon until somebody edits the table by hand.
--
-- 3. `battle_act` WOULD DRIVE A DUEL AS A HUNT.
--
--    It reads seat 1 as a creature (`species_id`, `creature_moves`,
--    `roll_creature_intent`) and takes no player argument, so it always acts
--    as seat 0. Pointed at a duel, the second cultivator would be swinging as
--    the first, against an opponent with no species at all. And it was one
--    command away: `/battle` finds your fight through `player_active_battle`.
--
-- 4. `battle_abandon` WOULD BE A FREE ESCAPE.
--
--    It is `battle_conclude(id, 'expired')` - no winner, both claims
--    released, everybody keeps the health they have left. On a hunt that is
--    the honest meaning of walking away. On a duel it means the cultivator
--    who is losing presses a button and the fight never happened.
--
--    So a duel is CONCEDED instead. Yielding is losing: the conceder drops to
--    nothing exactly as if they had been felled, because that is what
--    `battle_conclude` reads the winner from, and because a concession that
--    cost nothing would be the same escape wearing a politer word.
--
-- Nothing here touches a live fight. Every change is on the duel lane, which
-- no player has ever been in, plus two refusals on paths that can only be
-- reached by pointing a PvE function at a duel row that does not exist yet.


INSERT INTO game_config (key, value, description) VALUES
    ('duel_round_seconds', 60,
     'How long a duel round waits before `duel_force` may brace whoever has not chosen. Matches `dungeon_round_seconds`: the same promise in the same words, because the two screens look the same to the person reading them.');


-- ---------------------------------------------------------------------------
-- 1. The clock on a forced round
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    patched TEXT;
    anchor TEXT :=
'    UPDATE battle_combatants c SET
        intent_action = ''guard'', intent_technique_id = NULL, chose_at = now()
    WHERE c.battle_id = p_battle_id AND c.intent_action IS NULL';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'duel_force' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'duel_force is not the function 0534 left behind';
    END IF;

    patched := replace(src, anchor,
'    -- NOT UNTIL THE ROUND HAS ACTUALLY RUN OUT. Without this, either side
    -- could choose their heaviest attack and then force the other to brace
    -- on the spot - swinging every round, taking nothing back, winning every
    -- duel without being hit. See 0548.
    --
    -- `chose_at > deadline` ignores the NULL seat by itself, which is the
    -- behaviour wanted: if NOBODY has chosen there is nothing to force them
    -- away from, both brace, and the turn counts toward the cap. That is how
    -- a duel they both walked out of ends.
    IF EXISTS (
        SELECT 1 FROM battle_combatants c
        WHERE c.battle_id = p_battle_id
          AND c.chose_at > now() - make_interval(
                  secs => game_config_value(''duel_round_seconds'')::double precision)
    ) THEN
        RAISE EXCEPTION ''they still have time to choose''
            USING ERRCODE = ''check_violation'';
    END IF;

' || anchor);

    IF patched = src THEN
        RAISE EXCEPTION 'the duel_force patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- 2. A duel that always ends
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    v_end := (a_left <= 0 OR b_left <= 0);
    IF v_end THEN';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'duel_resolve' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'duel_resolve does not end where 0534 ended it';
    END IF;

    patched := replace(src, anchor,
'    v_end := (a_left <= 0 OR b_left <= 0);

    -- A CAP, for the reason `battle_act`''s own cap gives: "a kind added
    -- later is capped until somebody decides otherwise". A duel is a kind
    -- added later and does not come through `battle_act`, so it inherited
    -- none of it - and two cultivators who both guard take nothing from each
    -- other for as long as they keep pressing, while `player_active_battle`
    -- holds them both out of every other fight in the game.
    --
    -- `turn_number + 1` because the UPDATE above has already counted the
    -- round that was just played, exactly as `battle_act` reads it.
    IF NOT v_end
       AND fight.turn_number + 1 > game_config_value(''battle_turn_cap'') THEN
        v_end := TRUE;
        v_win := NULL;
        v_out := ''drawn'';
        PERFORM battle_conclude(p_battle_id, ''expired'');
    ELSIF v_end THEN');

    IF patched = src THEN
        RAISE EXCEPTION 'the duel_resolve patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- 3. The sign on the PvE door
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    SELECT * INTO fight FROM battles WHERE battle_id = p_battle_id FOR UPDATE;
    IF NOT FOUND OR fight.status <> ''active'' THEN
        RAISE EXCEPTION ''that fight is over'' USING ERRCODE = ''check_violation'';
    END IF;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'battle_act' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act does not open the way it used to';
    END IF;

    patched := replace(src, anchor, anchor || '

    -- A DUEL IS NOT THIS FUNCTION''S FIGHT. Seat 1 is read as a creature all
    -- the way down - `species_id`, `creature_moves`, `roll_creature_intent` -
    -- and this function takes no player argument, so it always acts as seat
    -- 0. On a duel the second cultivator would be swinging as the first, at
    -- an opponent with no species. `duel_choose`/`duel_resolve` are the lane
    -- for that, and this is the sign on the door.
    IF fight.kind = ''duel'' THEN
        RAISE EXCEPTION ''that is a duel - take your turn with /duel''
            USING ERRCODE = ''check_violation'';
    END IF;');

    IF patched = src THEN
        RAISE EXCEPTION 'the battle_act patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- 4. Yielding, which is losing
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT := '    PERFORM battle_conclude(p_battle_id, ''expired'');';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'battle_abandon' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'battle_abandon is not one line of conclude any more';
    END IF;

    patched := replace(src, anchor,
'    -- NOT A DUEL. ''expired'' means nobody won and releases both claims, so
    -- on a duel this is the losing cultivator pressing a button and the
    -- fight never having happened. `duel_concede` is the way out, and it
    -- costs what losing costs.
    IF EXISTS (SELECT 1 FROM battles b
               WHERE b.battle_id = p_battle_id AND b.kind = ''duel'') THEN
        RAISE EXCEPTION ''a duel ends when one of you yields or falls''
            USING ERRCODE = ''check_violation'';
    END IF;

' || anchor);

    IF patched = src THEN
        RAISE EXCEPTION 'the battle_abandon patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


CREATE OR REPLACE FUNCTION duel_concede(p_battle_id BIGINT, p_player_id BIGINT)
RETURNS TABLE(winner BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    them BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM battles b
                   WHERE b.battle_id = p_battle_id
                     AND b.status = 'active' AND b.kind = 'duel') THEN
        RAISE EXCEPTION 'that is not a duel you are standing in'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM battle_combatants c
                   WHERE c.battle_id = p_battle_id
                     AND c.player_id = p_player_id) THEN
        RAISE EXCEPTION 'that is not your duel'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT c.player_id INTO them FROM battle_combatants c
    WHERE c.battle_id = p_battle_id AND c.player_id <> p_player_id;

    -- YIELDING IS LOSING, and this line is what makes it one. `battle_conclude`
    -- reads the winner off who is left standing, so a duel ended with both of
    -- them upright is the free escape `battle_abandon` used to be - wearing a
    -- politer word. Being felled and yielding cost the same, which is the
    -- point: the choice is whether to keep swinging, not whether to pay.
    UPDATE battle_combatants c SET current_hp = 0
    WHERE c.battle_id = p_battle_id AND c.player_id = p_player_id;

    PERFORM battle_conclude(p_battle_id, 'complete');

    RETURN QUERY SELECT them;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a     BIGINT;
    v_b     BIGINT;
    v_tech  BIGINT;
    v_duel  BIGINT;
    v_batt  BIGINT;
    v_spec  BIGINT;
    v_won   BIGINT;
    v_cap   INTEGER;
    v_n     INTEGER;
    v_status TEXT;
    v_hp    BIGINT;
BEGIN
    SELECT t.technique_id INTO v_tech FROM techniques t
    WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
    SELECT cs.species_id INTO v_spec FROM creature_species cs
    WHERE cs.kind = 'beast' ORDER BY cs.rank, cs.species_id LIMIT 1;
    v_cap := game_config_value('battle_turn_cap');

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-968, 'duellist-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-967, 'duellist-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT r.realm_id, r.cultivation_required FROM realms r
            ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1) r;

        -- A REAL BODY, copied off the deepest one in the world, so the
        -- numbers these probes see are numbers a player could see. `>= 18`
        -- rather than `= 18`: 0536-0538 swept these readers onto
        -- `player_standing`, which answers 19 and up for a Venerable.
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

        -- 1. FORCING A ROUND THAT IS STILL YOUNG IS REFUSED.
        v_duel := duel_open(v_a, v_b);
        PERFORM duel_choose(v_duel, v_a, 'attack', v_tech);

        BEGIN
            PERFORM duel_force(v_duel);
            RAISE EXCEPTION
                'duel_force braced a cultivator who had just been asked';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- And once the round has actually run out, it goes through. The clock
        -- is moved rather than waited on, which is the only part of this a
        -- player cannot do.
        UPDATE battle_combatants c
        SET chose_at = now() - make_interval(
                secs => game_config_value('duel_round_seconds')::double precision + 5)
        WHERE c.battle_id = v_duel AND c.chose_at IS NOT NULL;

        PERFORM duel_force(v_duel);

        SELECT turn_number INTO v_n FROM battles WHERE battle_id = v_duel;
        IF v_n < 1 THEN
            RAISE EXCEPTION
                'duel_force left the round unplayed after the clock ran out';
        END IF;

        -- 2. AND WITH NOBODY WAITING ON ANYBODY, it goes through at once -
        -- which is how a duel they both walked out of reaches the cap.
        PERFORM duel_force(v_duel);
        SELECT turn_number INTO v_n FROM battles WHERE battle_id = v_duel;
        IF v_n < 2 THEN
            RAISE EXCEPTION
                'duel_force refused a round neither of them had answered';
        END IF;

        -- 3. BATTLE_ACT WILL NOT TOUCH IT.
        BEGIN
            PERFORM battle_act(v_duel, 'guard');
            RAISE EXCEPTION 'battle_act drove a duel as if it were a hunt';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- 4. NEITHER WILL BATTLE_ABANDON.
        BEGIN
            PERFORM battle_abandon(v_duel);
            RAISE EXCEPTION 'battle_abandon walked a cultivator out of a duel';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- 5. THE CAP ENDS IT. The turn number is moved rather than fifty
        -- rounds played, and the duel is then answered honestly: both brace,
        -- so nobody falls and only the cap can finish it.
        UPDATE battles SET turn_number = v_cap WHERE battle_id = v_duel;
        PERFORM duel_choose(v_duel, v_a, 'guard');
        PERFORM duel_choose(v_duel, v_b, 'guard');

        -- 'expired' is what `battle_conclude` writes for a fight nobody won;
        -- `battles_status_check` admits active/complete/fled/expired and
        -- nothing else, which is worth reading off the constraint rather than
        -- guessing a word like 'ended'.
        SELECT b.status INTO v_status FROM battles b WHERE b.battle_id = v_duel;
        IF v_status <> 'expired' THEN
            RAISE EXCEPTION
                'a duel at the turn cap ended as %, not expired', v_status;
        END IF;
        IF EXISTS (SELECT 1 FROM player_active_battle a
                   WHERE a.player_id IN (v_a, v_b)) THEN
            RAISE EXCEPTION
                'a duel ended at the cap and still held both of them';
        END IF;

        -- 6. YIELDING NAMES THE OTHER AND COSTS WHAT LOSING COSTS.
        UPDATE player_physique pp SET current_hp = pp.max_hp
        WHERE pp.player_id IN (v_a, v_b);

        v_duel := duel_open(v_a, v_b);
        SELECT c.winner INTO v_won FROM duel_concede(v_duel, v_a) c;

        IF v_won IS DISTINCT FROM v_b THEN
            RAISE EXCEPTION 'conceding named % as the winner, not the other one',
                            v_won;
        END IF;
        SELECT pp.current_hp INTO v_hp FROM player_physique pp
        WHERE pp.player_id = v_a;
        IF v_hp > 0 THEN
            RAISE EXCEPTION
                'the cultivator who yielded walked away with % health', v_hp;
        END IF;
        IF EXISTS (SELECT 1 FROM player_active_battle a
                   WHERE a.player_id IN (v_a, v_b)) THEN
            RAISE EXCEPTION 'a conceded duel still held one of them';
        END IF;

        -- 7. AND AN ORDINARY HUNT IS UNTOUCHED, which is the whole of what
        -- every live player has.
        UPDATE player_physique pp SET current_hp = pp.max_hp
        WHERE pp.player_id = v_a;
        v_batt := battle_open(v_a, v_spec);
        PERFORM battle_act(v_batt, 'guard');

        SELECT turn_number INTO v_n FROM battles WHERE battle_id = v_batt;
        IF v_n < 1 THEN
            RAISE EXCEPTION 'an ordinary fight stopped taking turns';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
    END;
END
$probe$;
