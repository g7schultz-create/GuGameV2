-- 0534_two_cultivators_swing_at_once
--
-- The turn loop, and the last piece before the raid. 0529 priced a blow
-- against a cultivator, 0532 made damage matter, 0533 stopped a duel vanishing
-- from the screen. Nothing yet opens one.
--
-- SIMULTANEOUS, NOT ALTERNATING, and that is forced by the arithmetic rather
-- than chosen for flavour. 0532 leaves the fastest possible kill at two rounds
-- (`duel_max_bite` 0.50), so under alternating turns whoever swings first wins
-- almost every duel outright - the backstab would be a question of who clicked,
-- which is the thing the user asked to avoid. Both blows are therefore priced
-- against the health each side held at the START of the round, so a cultivator
-- cut down still lands theirs. Mutual destruction is possible. The world of
-- cultivation is harsh.
--
-- WHY NOT EXTEND `battle_act`. It is three hundred lines built around a
-- creature: a `creature_species%ROWTYPE`, a rolled `creature_moves` intent,
-- bestiary writes, incoming-path revelation, and `species.rank` inside the
-- damage term. Branching all of that on "is the opponent a person" is the
-- shape that has produced six separate faults in this programme - a guard
-- moves and a reader does not. It keeps the creature; duels get their own
-- loop. What they SHARE is `player_swing`, which is the one thing that knows
-- what a blow costs.
--
-- THE SHAPE:
--
--     duel_open(a, b)                  two player combatants, 0 and 1
--     duel_choose(battle, who, action, technique)
--                                      records an intent, refuses what cannot
--                                      be paid for, and resolves the round the
--                                      moment the second cultivator has chosen
--     duel_resolve(battle)             both blows, at once
--     duel_force(battle)               for a round nobody finished: whoever
--                                      has not chosen braces
--
-- Qi, the guard and the technique gate are all read the way `battle_act` reads
-- them - the cost off `qi_aperture` in the snapshot rather than off the pool,
-- `guard_qi_restore` plus the `guard_qi` stat, `guard_damage_reduction` on what
-- arrives - so a cultivator's build behaves the same in a duel as in a fight.
--
-- A DUEL PAYS NOTHING AND COSTS NOTHING BUT HEALTH. No bestiary, no drops, no
-- spoils; 0533 guarded all of that. What a betrayal is worth is the raid's
-- loot split, which is still to come.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE battle_combatants
    ADD COLUMN intent_action       TEXT,
    ADD COLUMN intent_technique_id BIGINT
        REFERENCES techniques(technique_id) ON DELETE SET NULL,
    ADD COLUMN chose_at            TIMESTAMPTZ,
    ADD CONSTRAINT battle_combatants_intent_action_check
        CHECK (intent_action IS NULL OR intent_action IN ('attack', 'guard')),
    ADD CONSTRAINT battle_combatants_attack_needs_a_technique
        CHECK (intent_action <> 'attack' OR intent_technique_id IS NOT NULL);

COMMENT ON COLUMN battle_combatants.intent_action IS
    'What this cultivator has chosen to do THIS round, held until the other one has chosen too. NULL in every creature fight - a beast telegraphs through intent_move_id instead, and a cultivator telegraphs nothing.';

CREATE INDEX battle_combatants_waiting_idx
    ON battle_combatants (battle_id) WHERE intent_action IS NULL;


-- ---------------------------------------------------------------------------
-- Opening one
-- ---------------------------------------------------------------------------

CREATE FUNCTION duel_open(p_a BIGINT, p_b BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    b_id  BIGINT;
    one   RECORD;
    seat  SMALLINT;
BEGIN
    IF p_a = p_b THEN
        RAISE EXCEPTION 'you cannot draw on yourself'
            USING ERRCODE = 'check_violation';
    END IF;

    FOREACH seat IN ARRAY ARRAY[0, 1]::SMALLINT[] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM player_physique pp
            WHERE pp.player_id = CASE seat WHEN 0 THEN p_a ELSE p_b END
              AND pp.current_hp > 0
        ) THEN
            RAISE EXCEPTION 'one of you has no body left to fight with'
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    -- The same refusal `battle_open` makes: nobody stands in two fights.
    IF EXISTS (SELECT 1 FROM player_active_battle a
               WHERE a.player_id IN (p_a, p_b)) THEN
        RAISE EXCEPTION 'one of you is already in a fight'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('duel', 'active', floor(random() * 9223372036854775806)::bigint)
    RETURNING battles.battle_id INTO b_id;

    -- Both seats built by the same statement, because two cultivators in one
    -- duel must be described identically or the fight favours a seat.
    FOR one IN
        SELECT 0::SMALLINT AS seat, p_a AS who
        UNION ALL
        SELECT 1::SMALLINT, p_b
    LOOP
        INSERT INTO battle_combatants
            (battle_id, combatant_no, side, player_id, snapshot,
             max_hp, current_hp, current_qi, shield)
        SELECT b_id, one.seat, one.seat, one.who,
               jsonb_build_object(
                   'max_hp', pp.max_hp,
                   'defense', pp.defense,
                   'strength', pp.strength,
                   'max_qi', player_max_qi(one.who),
                   'qi_aperture', player_qi_aperture(one.who),
                   'opened_hp', pp.current_hp),
               pp.max_hp, pp.current_hp, player_max_qi(one.who),
               battle_shield_for(one.who, pp.max_hp)
        FROM player_physique pp WHERE pp.player_id = one.who;

        INSERT INTO player_active_battle (player_id, battle_id)
        VALUES (one.who, b_id);
    END LOOP;

    RETURN b_id;
END;
$fn$;

COMMENT ON FUNCTION duel_open(BIGINT, BIGINT) IS
    'Open a fight between two cultivators. Both seats are built by one statement so neither is described more generously than the other.';


-- ---------------------------------------------------------------------------
-- A round
-- ---------------------------------------------------------------------------

CREATE FUNCTION duel_resolve(p_battle_id BIGINT)
RETURNS TABLE (turn_no INTEGER,
               a_player BIGINT, a_action TEXT, a_move TEXT,
               a_dealt BIGINT, a_hp BIGINT, a_max_hp BIGINT, a_qi BIGINT,
               b_player BIGINT, b_action TEXT, b_move TEXT,
               b_dealt BIGINT, b_hp BIGINT, b_max_hp BIGINT, b_qi BIGINT,
               finished BOOLEAN, winner BIGINT, outcome TEXT)
LANGUAGE plpgsql AS $fn$
DECLARE
    fight   battles%ROWTYPE;
    a       battle_combatants%ROWTYPE;
    b       battle_combatants%ROWTYPE;
    swung   RECORD;
    a_out   BIGINT := 0;
    b_out   BIGINT := 0;
    a_cost  BIGINT := 0;
    b_cost  BIGINT := 0;
    a_name  TEXT;
    b_name  TEXT;
    a_left  BIGINT;
    b_left  BIGINT;
    a_qi_n  BIGINT;
    b_qi_n  BIGINT;
    reduce  NUMERIC := game_config_value('guard_damage_reduction');
    v_end   BOOLEAN;
    v_win   BIGINT;
    v_out   TEXT;
BEGIN
    SELECT * INTO fight FROM battles WHERE battle_id = p_battle_id FOR UPDATE;
    IF NOT FOUND OR fight.status <> 'active' OR fight.kind <> 'duel' THEN
        RAISE EXCEPTION 'that is not a duel you are standing in'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO a FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0 FOR UPDATE;
    SELECT * INTO b FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 1 FOR UPDATE;

    IF a.intent_action IS NULL OR b.intent_action IS NULL THEN
        RAISE EXCEPTION 'both of you have to choose first'
            USING ERRCODE = 'check_violation';
    END IF;

    a_qi_n := a.current_qi;
    b_qi_n := b.current_qi;

    -- BOTH BLOWS AGAINST THE HEALTH EACH SIDE HELD WHEN THE ROUND OPENED.
    -- This is the whole reason the loop exists: a cultivator cut down this
    -- round still lands theirs, so a duel cannot be won by moving first.
    IF a.intent_action = 'attack' THEN
        SELECT t.name INTO a_name FROM techniques t
        WHERE t.technique_id = a.intent_technique_id;
        a_cost := ceil((SELECT t.qi_cost_pct FROM techniques t
                        WHERE t.technique_id = a.intent_technique_id)
                       * COALESCE((a.snapshot ->> 'qi_aperture')::bigint,
                                  (a.snapshot ->> 'max_qi')::bigint));
        SELECT * INTO swung FROM player_swing(
            a.player_id, a.intent_technique_id, NULL::bigint,
            b.current_hp, (b.snapshot ->> 'defense')::bigint,
            a.current_hp, a.max_hp, fight.turn_number, NULL, NULL,
            b.player_id);
        a_out  := COALESCE(swung.dealt, 0);
        a_qi_n := GREATEST(0, a_qi_n - a_cost);
    ELSE
        a_name := 'Guard';
        a_qi_n := LEAST((a.snapshot ->> 'max_qi')::bigint,
                        a_qi_n + ceil((game_config_value('guard_qi_restore')
                                       + player_stat(a.player_id, 'guard_qi'))
                                      * (a.snapshot ->> 'max_qi')::bigint));
    END IF;

    IF b.intent_action = 'attack' THEN
        SELECT t.name INTO b_name FROM techniques t
        WHERE t.technique_id = b.intent_technique_id;
        b_cost := ceil((SELECT t.qi_cost_pct FROM techniques t
                        WHERE t.technique_id = b.intent_technique_id)
                       * COALESCE((b.snapshot ->> 'qi_aperture')::bigint,
                                  (b.snapshot ->> 'max_qi')::bigint));
        SELECT * INTO swung FROM player_swing(
            b.player_id, b.intent_technique_id, NULL::bigint,
            a.current_hp, (a.snapshot ->> 'defense')::bigint,
            b.current_hp, b.max_hp, fight.turn_number, NULL, NULL,
            a.player_id);
        b_out  := COALESCE(swung.dealt, 0);
        b_qi_n := GREATEST(0, b_qi_n - b_cost);
    ELSE
        b_name := 'Guard';
        b_qi_n := LEAST((b.snapshot ->> 'max_qi')::bigint,
                        b_qi_n + ceil((game_config_value('guard_qi_restore')
                                       + player_stat(b.player_id, 'guard_qi'))
                                      * (b.snapshot ->> 'max_qi')::bigint));
    END IF;

    -- A brace halves what arrives, the same fraction `battle_act` gives it.
    IF a.intent_action = 'guard' THEN
        b_out := GREATEST(CASE WHEN b_out > 0 THEN 1 ELSE 0 END,
                          round(b_out * (1 - reduce)))::bigint;
    END IF;
    IF b.intent_action = 'guard' THEN
        a_out := GREATEST(CASE WHEN a_out > 0 THEN 1 ELSE 0 END,
                          round(a_out * (1 - reduce)))::bigint;
    END IF;

    a_left := GREATEST(0, a.current_hp - b_out);
    b_left := GREATEST(0, b.current_hp - a_out);

    UPDATE battle_combatants SET
        current_hp = a_left, current_qi = a_qi_n,
        guarding = (a.intent_action = 'guard'),
        intent_action = NULL, intent_technique_id = NULL, chose_at = NULL
    WHERE battle_id = p_battle_id AND combatant_no = 0;

    UPDATE battle_combatants SET
        current_hp = b_left, current_qi = b_qi_n,
        guarding = (b.intent_action = 'guard'),
        intent_action = NULL, intent_technique_id = NULL, chose_at = NULL
    WHERE battle_id = p_battle_id AND combatant_no = 1;

    -- `battle_actions.action` admits 'technique', 'pass', 'flee' and
    -- 'system' - a swing is a TECHNIQUE here as it is in every other lane,
    -- and the check that a technique is named is satisfied by `a_name`.
    --
    -- Whether the blow felled anybody goes in `detail`: `battle_actions` has
    -- no `felled` column. That one belongs to `tournament_blows`, and I used
    -- it from memory after listing these columns earlier the same day.
    INSERT INTO battle_actions
        (battle_id, actor_no, turn_number, action, technique_id,
         technique_name, target_no, damage, detail)
    VALUES
        (p_battle_id, 0, fight.turn_number,
         CASE WHEN a.intent_action = 'attack' THEN 'technique' ELSE 'pass' END,
         a.intent_technique_id, a_name, 1, a_out,
         jsonb_build_object('duel', TRUE, 'felled', b_left <= 0,
                            'guarded', a.intent_action = 'guard',
                            'qi_after', a_qi_n)),
        (p_battle_id, 1, fight.turn_number,
         CASE WHEN b.intent_action = 'attack' THEN 'technique' ELSE 'pass' END,
         b.intent_technique_id, b_name, 0, b_out,
         jsonb_build_object('duel', TRUE, 'felled', a_left <= 0,
                            'guarded', b.intent_action = 'guard',
                            'qi_after', b_qi_n));

    UPDATE battles SET turn_number = turn_number + 1
    WHERE battle_id = p_battle_id;

    -- BOTH CAN FALL. `battle_conclude` reads the winner off whether side 1 is
    -- standing, which would hand a double knockout to side 0, so the draw is
    -- named here and the fight is ended as one nobody won.
    v_end := (a_left <= 0 OR b_left <= 0);
    IF v_end THEN
        IF a_left <= 0 AND b_left <= 0 THEN
            v_win := NULL; v_out := 'both';
            PERFORM battle_conclude(p_battle_id, 'fled');
        ELSIF b_left <= 0 THEN
            v_win := a.player_id; v_out := 'felled';
            PERFORM battle_conclude(p_battle_id, 'complete');
        ELSE
            v_win := b.player_id; v_out := 'felled';
            PERFORM battle_conclude(p_battle_id, 'complete');
        END IF;
    END IF;

    RETURN QUERY SELECT
        fight.turn_number,
        a.player_id, a.intent_action, a_name, a_out, a_left, a.max_hp, a_qi_n,
        b.player_id, b.intent_action, b_name, b_out, b_left, b.max_hp, b_qi_n,
        v_end, v_win, v_out;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Choosing
-- ---------------------------------------------------------------------------

CREATE FUNCTION duel_choose(p_battle_id BIGINT, p_player_id BIGINT,
                            p_action TEXT, p_technique_id BIGINT DEFAULT NULL)
RETURNS TABLE (waiting BOOLEAN, on_whom BIGINT)
LANGUAGE plpgsql AS $fn$
DECLARE
    me    battle_combatants%ROWTYPE;
    them  battle_combatants%ROWTYPE;
    tech  techniques%ROWTYPE;
    cost  BIGINT;
BEGIN
    IF p_action NOT IN ('attack', 'guard') THEN
        RAISE EXCEPTION 'no such action: %', p_action
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT c.* INTO me FROM battle_combatants c
    JOIN battles b ON b.battle_id = c.battle_id
    WHERE c.battle_id = p_battle_id AND c.player_id = p_player_id
      AND b.status = 'active' AND b.kind = 'duel'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you are not standing in that duel'
            USING ERRCODE = 'check_violation';
    END IF;
    IF me.intent_action IS NOT NULL THEN
        RAISE EXCEPTION 'you have already chosen this round'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_action = 'attack' THEN
        SELECT * INTO tech FROM techniques WHERE technique_id = p_technique_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'no such technique' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM player_usable_techniques u
                       WHERE u.player_id = p_player_id
                         AND u.technique_id = p_technique_id) THEN
            RAISE EXCEPTION 'you cannot use %', tech.name
                USING ERRCODE = 'check_violation';
        END IF;

        -- Refused at the choice rather than at the resolve, so a cultivator
        -- who cannot pay for a move finds out while they can still pick
        -- another one.
        cost := ceil(tech.qi_cost_pct
                     * COALESCE((me.snapshot ->> 'qi_aperture')::bigint,
                                (me.snapshot ->> 'max_qi')::bigint));
        IF me.current_qi < cost THEN
            RAISE EXCEPTION 'not enough qi for %', tech.name
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    UPDATE battle_combatants SET
        intent_action = p_action,
        intent_technique_id = CASE WHEN p_action = 'attack'
                                   THEN p_technique_id ELSE NULL END,
        chose_at = now()
    WHERE battle_id = p_battle_id AND combatant_no = me.combatant_no;

    SELECT * INTO them FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no <> me.combatant_no;

    IF them.intent_action IS NULL THEN
        RETURN QUERY SELECT TRUE, them.player_id;
        RETURN;
    END IF;

    -- The second cultivator to choose resolves the round. Nobody has to press
    -- a third button, and neither of them learns what the other picked first.
    PERFORM duel_resolve(p_battle_id);
    RETURN QUERY SELECT FALSE, NULL::bigint;
END;
$fn$;


CREATE FUNCTION duel_force(p_battle_id BIGINT)
RETURNS TABLE (waiting BOOLEAN, on_whom BIGINT)
LANGUAGE plpgsql AS $fn$
BEGIN
    -- A round nobody finished. Whoever has not chosen BRACES - the safe
    -- reading of someone who walked away, and it cannot be used to make them
    -- spend qi or throw a move they did not pick.
    UPDATE battle_combatants c SET
        intent_action = 'guard', intent_technique_id = NULL, chose_at = now()
    WHERE c.battle_id = p_battle_id AND c.intent_action IS NULL
      AND EXISTS (SELECT 1 FROM battles b
                  WHERE b.battle_id = c.battle_id
                    AND b.status = 'active' AND b.kind = 'duel');

    IF EXISTS (SELECT 1 FROM battles b
               WHERE b.battle_id = p_battle_id AND b.status = 'active'
                 AND b.kind = 'duel') THEN
        PERFORM duel_resolve(p_battle_id);
    END IF;

    RETURN QUERY SELECT FALSE, NULL::bigint;
END;
$fn$;

COMMENT ON FUNCTION duel_force(BIGINT) IS
    'Resolve a round somebody walked away from. The absent cultivator braces rather than throwing a move they did not choose.';


-- ---------------------------------------------------------------------------
-- Fight one out
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a     BIGINT;
    v_b     BIGINT;
    v_bid   BIGINT;
    v_tech  BIGINT;
    v_r     RECORD;
    v_n     INTEGER := 0;
    v_both  BOOLEAN := FALSE;
    v_hp_a  BIGINT;
    v_hp_b  BIGINT;
    v_guard BIGINT;
    v_plain BIGINT;
BEGIN
    -- Nothing in a creature fight carries an intent, so the new columns are
    -- inert everywhere that already works.
    IF EXISTS (SELECT 1 FROM battle_combatants WHERE intent_action IS NOT NULL) THEN
        RAISE EXCEPTION 'a fight already carries a duel intent';
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-983, 'duel-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-982, 'duel-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_b, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;

        -- Two identical cultivators, so anything asymmetric in the loop shows
        -- up as a difference that has no cause.
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_a, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ORDER BY pp.max_hp DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_b, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp WHERE pp.player_id = v_a;

        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech), (v_b, v_tech) ON CONFLICT DO NOTHING;

        v_bid := duel_open(v_a, v_b);

        -- 1. NOBODY RESOLVES ALONE.
        IF NOT (SELECT d.waiting FROM duel_choose(v_bid, v_a, 'attack', v_tech) d) THEN
            RAISE EXCEPTION 'one cultivator choosing resolved the round';
        END IF;
        BEGIN
            PERFORM duel_choose(v_bid, v_a, 'guard');
            RAISE EXCEPTION 'chose twice in one round';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%already chosen%' THEN RAISE; END IF;
        END;
        BEGIN
            PERFORM duel_choose(v_bid, (SELECT min(player_id) FROM players
                                        WHERE player_id NOT IN (v_a, v_b)),
                                'guard');
            RAISE EXCEPTION 'a bystander chose in somebody else''s duel';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%not standing in that duel%' THEN RAISE; END IF;
        END;

        -- 2. THE SECOND CHOICE RESOLVES IT, AND BOTH BLOWS LAND.
        IF (SELECT d.waiting FROM duel_choose(v_bid, v_b, 'attack', v_tech) d) THEN
            RAISE EXCEPTION 'the round did not resolve when both had chosen';
        END IF;

        SELECT count(*) INTO v_n FROM battle_actions
        WHERE battle_id = v_bid AND turn_number = 1 AND damage > 0;
        IF v_n <> 2 THEN
            RAISE EXCEPTION
                'only % of two cultivators landed a blow in the same round', v_n;
        END IF;

        -- And the fight is over or both are hurt - either way it is symmetric,
        -- which two identical cultivators swinging at once must produce.
        SELECT c.current_hp INTO v_hp_a FROM battle_combatants c
        WHERE c.battle_id = v_bid AND c.combatant_no = 0;
        SELECT c.current_hp INTO v_hp_b FROM battle_combatants c
        WHERE c.battle_id = v_bid AND c.combatant_no = 1;
        IF (v_hp_a = 0) <> (v_hp_b = 0) THEN
            RAISE EXCEPTION
                'two identical cultivators ended the round at % and %',
                v_hp_a, v_hp_b;
        END IF;

        IF v_hp_a = 0 AND v_hp_b = 0 THEN
            v_both := TRUE;
            IF (SELECT b.status FROM battles b WHERE b.battle_id = v_bid)
               = 'active' THEN
                RAISE EXCEPTION 'both fell and the duel is still open';
            END IF;
            IF (SELECT b.winner_side FROM battles b WHERE b.battle_id = v_bid)
               IS NOT NULL THEN
                RAISE EXCEPTION 'a double knockout named a winner';
            END IF;
            -- Both bodies carry it, which is 0533's writeback on both seats.
            IF (SELECT pp.current_hp FROM player_physique pp
                WHERE pp.player_id = v_a) <> 0
               OR (SELECT pp.current_hp FROM player_physique pp
                   WHERE pp.player_id = v_b) <> 0 THEN
                RAISE EXCEPTION 'a felled duellist is still standing';
            END IF;
            RAISE NOTICE 'both cultivators fell in the same round';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 3. A BRACE HALVES WHAT ARRIVES. Measured on two fresh duels with bodies
    -- big enough that neither round ends the fight, so the two are comparable.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-981, 'brace-a') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-980, 'brace-b') RETURNING player_id INTO v_b;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, 0 FROM realms r ORDER BY r.rank, r.realm_id LIMIT 1;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_b, r.realm_id, 0 FROM realms r ORDER BY r.rank, r.realm_id LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        VALUES (v_a, (SELECT min(physique_id) FROM physiques),
                1000000000, 1000000000, 100, 100000),
               (v_b, (SELECT min(physique_id) FROM physiques),
                1000000000, 1000000000, 100, 100000);
        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech), (v_b, v_tech) ON CONFLICT DO NOTHING;

        v_bid := duel_open(v_a, v_b);
        PERFORM duel_choose(v_bid, v_a, 'attack', v_tech);
        PERFORM duel_choose(v_bid, v_b, 'attack', v_tech);
        SELECT damage INTO v_plain FROM battle_actions
        WHERE battle_id = v_bid AND actor_no = 0 AND turn_number = 1;

        PERFORM duel_choose(v_bid, v_a, 'attack', v_tech);
        PERFORM duel_choose(v_bid, v_b, 'guard');
        SELECT damage INTO v_guard FROM battle_actions
        WHERE battle_id = v_bid AND actor_no = 0 AND turn_number = 2;

        IF v_guard >= v_plain THEN
            RAISE EXCEPTION
                'bracing took % where standing took % - a guard is worth nothing',
                v_guard, v_plain;
        END IF;
        RAISE NOTICE
            'a brace took % of the % an unguarded round took', v_guard, v_plain;

        -- 4. AND A ROUND NOBODY FINISHED STILL RESOLVES, with the absent one
        -- bracing rather than swinging.
        PERFORM duel_choose(v_bid, v_a, 'attack', v_tech);
        PERFORM duel_force(v_bid);
        IF (SELECT count(*) FROM battle_actions
            WHERE battle_id = v_bid AND turn_number = 3) <> 2 THEN
            RAISE EXCEPTION 'a forced round did not record both cultivators';
        END IF;
        IF (SELECT action FROM battle_actions
            WHERE battle_id = v_bid AND turn_number = 3 AND actor_no = 1)
           <> 'pass' THEN
            RAISE EXCEPTION 'the absent cultivator threw a move they never chose';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing leaked.
    IF EXISTS (SELECT 1 FROM battles WHERE kind = 'duel') THEN
        RAISE EXCEPTION 'a probe duel survived the migration';
    END IF;

    RAISE NOTICE 'two cultivators can fight, at once, and both can lose';
END;
$probe$;
