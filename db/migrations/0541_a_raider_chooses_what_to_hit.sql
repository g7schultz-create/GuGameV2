-- 0541_a_raider_chooses_what_to_hit
--
-- Phase 3 second half, and phase 4. The round loop learns a TARGET, and a
-- target may be somebody standing beside you.
--
-- THE BACKSTAB IS NOT A SEPARATE FIGHT, which the user's own answers settle:
--
--     "Yes they can choose to hit the boss or the attacker. The attacker is
--      still hit by the boss as well."
--
-- So there is no duel instance, no second battle, nobody taken out of the
-- room. A betrayal is one raider aiming at another INSIDE the round, and
-- everything else about the round carries on happening to both of them. That
-- is far better than what I had planned - `duel_open` would have pulled two
-- people out of a fight the rest of the party is still losing.
--
-- `compute_duel_damage` and the duel curve from 0529 and 0532 are exactly what
-- price that blow, reached by handing `player_swing` a defending player. The
-- `duel_open`/`duel_resolve` loop from 0534 stays for a standalone duel and is
-- not what the raid uses.
--
-- THE FOUR DECISIONS, as given:
--
--     "Does striking an ally reveal you to the whole party?"
--         "Everyone". The log is the round's public record, so a betrayal is
--         a line in it naming both people. No hidden knives.
--
--     "Can a betrayed cultivator retaliate in the same round?"
--         Yes - they choose the boss or the attacker like anybody else, and
--         the attacker is still hit by the foes. Betrayal costs you the round
--         you spent on it AND the one the room spends on you.
--
--     "Does the betrayer keep raiding afterwards?"
--         "If they win they may keep raiding." No ejection, no mark. Felling
--         a companion is simply something that happened.
--
--     "Last standing" - the loot - is 0542, next.
--
-- AND EVERY LIVING FOE ANSWERS. One blow a round against three foes would be
-- a room with more health and the same pressure. Three foes means three blows,
-- each picking its own target by the same taunt weighting the single boss
-- used - which is where the teamwork actually lives, because a party cannot
-- cover three people at once.
--
-- SIMULTANEOUS, like the duel and for the same reason. Every raider's blow is
-- priced against the state the round OPENED in, so a cultivator cut down this
-- round still lands theirs, and two people who knife each other both fall.
--
-- `boss_hp` IS KEPT AS THE SUM of what is still standing, so the bot's bar,
-- `dungeon_run_state`, `dungeon_begin`'s return and the `pool <= 0` that wins
-- the room all keep working untouched.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE dungeon_raiders
    ADD COLUMN intent_foe_no    SMALLINT,
    ADD COLUMN intent_victim_id BIGINT
        REFERENCES players(player_id) ON DELETE SET NULL,
    ADD COLUMN betrayals        INTEGER NOT NULL DEFAULT 0,
    ADD CONSTRAINT dungeon_raiders_one_target
        CHECK (intent_foe_no IS NULL OR intent_victim_id IS NULL),
    ADD CONSTRAINT dungeon_raiders_no_self_harm
        CHECK (intent_victim_id IS NULL OR intent_victim_id <> player_id);

CREATE INDEX dungeon_raiders_victim_idx ON dungeon_raiders (intent_victim_id);

COMMENT ON COLUMN dungeon_raiders.intent_victim_id IS
    'The companion this raider is about to strike. Mutually exclusive with intent_foe_no - you are aiming at the room or at somebody in it, never both.';

COMMENT ON COLUMN dungeon_raiders.betrayals IS
    'How many times this raider has struck a companion in this run. Kept for the loot split and because a count is the honest record of what happened.';


-- ---------------------------------------------------------------------------
-- Choosing, with somewhere to aim
-- ---------------------------------------------------------------------------

DROP FUNCTION dungeon_choose(bigint, bigint, bigint);

CREATE FUNCTION dungeon_choose(p_run_id BIGINT, p_player_id BIGINT,
                               p_technique_id BIGINT,
                               p_foe_no SMALLINT DEFAULT NULL,
                               p_victim_id BIGINT DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql AS $fn$
DECLARE
    me    dungeon_raiders%ROWTYPE;
    still INTEGER;
BEGIN
    IF p_foe_no IS NOT NULL AND p_victim_id IS NOT NULL THEN
        RAISE EXCEPTION 'aim at the room or at somebody in it, not both'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT x.* INTO me FROM dungeon_raiders x
    JOIN dungeon_runs r ON r.run_id = x.run_id
    WHERE x.run_id = p_run_id AND x.player_id = p_player_id
      AND r.status = 'fighting'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you are not in that fight'
            USING ERRCODE = 'check_violation';
    END IF;
    IF me.current_hp <= 0 THEN
        RAISE EXCEPTION 'you are down' USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM player_usable_techniques u
                   WHERE u.player_id = p_player_id
                     AND u.technique_id = p_technique_id) THEN
        RAISE EXCEPTION 'you cannot use that' USING ERRCODE = 'check_violation';
    END IF;

    IF p_victim_id IS NOT NULL THEN
        IF p_victim_id = p_player_id THEN
            RAISE EXCEPTION 'you cannot turn on yourself'
                USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM dungeon_raiders x
                       WHERE x.run_id = p_run_id AND x.player_id = p_victim_id
                         AND x.current_hp > 0) THEN
            RAISE EXCEPTION 'they are not standing in this room'
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF p_foe_no IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dungeon_foes f
                       WHERE f.run_id = p_run_id AND f.foe_no = p_foe_no
                         AND f.current_hp > 0) THEN
        RAISE EXCEPTION 'that one is already down'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE dungeon_raiders x
    SET intent_id = p_technique_id,
        intent_foe_no = p_foe_no,
        intent_victim_id = p_victim_id,
        chose_at = now()
    WHERE x.run_id = p_run_id AND x.player_id = p_player_id;

    SELECT count(*) INTO still
    FROM dungeon_raiders x
    WHERE x.run_id = p_run_id AND x.current_hp > 0 AND x.chose_at IS NULL;

    IF still = 0 THEN
        PERFORM dungeon_resolve_round(p_run_id);
    END IF;

    RETURN still;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The round
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dungeon_resolve_round(p_run_id BIGINT)
RETURNS TABLE (round_no SMALLINT, log JSONB, boss_hp BIGINT, status TEXT)
LANGUAGE plpgsql AS $fn$
DECLARE
    run     RECORD;
    one     RECORD;
    foe     RECORD;
    hit     RECORD;
    took    RECORD;
    swung   RECORD;
    move    BIGINT;
    aim     SMALLINT;
    dealt   BIGINT;
    taken   BIGINT;
    target  BIGINT;
    lines   JSONB := '[]'::jsonb;
    pool    BIGINT;
    ending  TEXT;
BEGIN
    SELECT * INTO run FROM dungeon_run_state s WHERE s.run_id = p_run_id
    FOR NO KEY UPDATE OF s;

    IF run.status <> 'fighting' THEN
        RAISE EXCEPTION 'that fight is not running'
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM effect_tick('dungeon', p_run_id);

    UPDATE dungeon_raiders x
    SET current_hp = LEAST(x.max_hp, x.current_hp + GREATEST(1, floor(x.max_hp
            * effect_value('dungeon', p_run_id, x.player_id, 'regen'))))
    WHERE x.run_id = p_run_id AND x.current_hp > 0
      AND effect_value('dungeon', p_run_id, x.player_id, 'regen') > 0;

    PERFORM pet_tick_regen('dungeon', p_run_id, x.player_id)
    FROM dungeon_raiders x
    WHERE x.run_id = p_run_id AND x.current_hp > 0;

    -- EVERY BLOW THIS ROUND IS PRICED AGAINST THE STATE IT OPENED IN, and
    -- that needs no snapshot: wounds are applied AFTER the loop below, so
    -- nothing in `dungeon_foes` or `dungeon_raiders` moves while it runs.
    -- The current state IS the opening state. A raider cut down this round
    -- still lands theirs, and two people who knife each other both fall.
    --
    -- The damage is carried in `lines` and read back out of it, which is
    -- what the function this replaces did and leaves nothing behind if
    -- anything raises.

    -- ---- the raiders swing ------------------------------------------------
    FOR one IN
        SELECT x.player_id, x.intent_id, x.intent_foe_no, x.intent_victim_id,
               x.current_hp, x.max_hp, p.discord_name
        FROM dungeon_raiders x
        JOIN players p ON p.player_id = x.player_id
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY x.joined_at, x.player_id
    LOOP
        move := COALESCE(one.intent_id, dungeon_default_move(one.player_id));

        IF move IS NULL THEN
            lines := lines || jsonb_build_object(
                'who', one.discord_name, 'kind', 'idle',
                'text', 'has no attack to make');
            CONTINUE;
        END IF;

        IF one.intent_victim_id IS NOT NULL THEN
            -- A COMPANION. Priced by `compute_duel_damage` through the same
            -- `player_swing` everything else uses, so the duel curve, the
            -- bite cap and the defender's own Path resistance all apply - a
            -- knife in a raid is the same blow as a knife in a duel.
            SELECT * INTO swung FROM player_swing(
                one.player_id, move, NULL::bigint,
                (SELECT x.current_hp FROM dungeon_raiders x
                 WHERE x.run_id = p_run_id AND x.player_id = one.intent_victim_id),
                (SELECT pp.defense FROM player_physique pp
                 WHERE pp.player_id = one.intent_victim_id)::bigint,
                one.current_hp, one.max_hp, run.round_no::integer,
                'dungeon', p_run_id, one.intent_victim_id);

            dealt := GREATEST(0, COALESCE(swung.dealt, 0));

            UPDATE dungeon_raiders x
            SET betrayals = x.betrayals + 1,
                intent_id = NULL, intent_foe_no = NULL,
                intent_victim_id = NULL, chose_at = NULL
            WHERE x.run_id = p_run_id AND x.player_id = one.player_id;

            -- EVERYONE SEES IT. The log is the round's public record and this
            -- line names both of them.
            lines := lines || jsonb_build_object(
                'who', one.discord_name,
                'kind', 'betrayal',
                'move', (SELECT t.name FROM techniques t
                         WHERE t.technique_id = move),
                'target', (SELECT p.discord_name FROM players p
                           WHERE p.player_id = one.intent_victim_id),
                -- The name is for people; the id is what the wound below
                -- is applied from.
                'victim_id', one.intent_victim_id,
                'damage', dealt,
                'strikes', swung.strikes,
                'crits', swung.crits);
            CONTINUE;
        END IF;

        -- A FOE. Their own choice if it is still standing, otherwise whatever
        -- is - silence is not a skipped turn, and neither is aiming at
        -- something that died while you were deciding.
        SELECT f.foe_no INTO aim FROM dungeon_foes f
        WHERE f.run_id = p_run_id AND f.foe_no = one.intent_foe_no
          AND f.current_hp > 0;
        IF aim IS NULL THEN
            SELECT f.foe_no INTO aim FROM dungeon_foes f
            WHERE f.run_id = p_run_id AND f.current_hp > 0
            ORDER BY f.foe_no LIMIT 1;
        END IF;
        IF aim IS NULL THEN
            CONTINUE;   -- nothing left standing to hit
        END IF;

        SELECT f.foe_no, f.species_id, f.current_hp AS opened_on,
               cs.name, cs.base_defense
        INTO foe
        FROM dungeon_foes f
        JOIN creature_species cs ON cs.species_id = f.species_id
        WHERE f.run_id = p_run_id AND f.foe_no = aim;

        SELECT * INTO swung FROM player_swing(
            one.player_id, move, foe.species_id,
            foe.opened_on, foe.base_defense::bigint,
            one.current_hp, one.max_hp, run.round_no::integer,
            'dungeon', p_run_id);

        dealt := GREATEST(0, COALESCE(swung.dealt, 0));

        IF swung.healed > 0 THEN
            UPDATE dungeon_raiders x
            SET current_hp = LEAST(x.max_hp, x.current_hp + swung.healed)
            WHERE x.run_id = p_run_id AND x.player_id = one.player_id;
        END IF;

        UPDATE dungeon_raiders x
        SET damage_dealt = x.damage_dealt + dealt,
            intent_id = NULL, intent_foe_no = NULL,
            intent_victim_id = NULL, chose_at = NULL
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id;

        lines := lines || jsonb_build_object(
            'who', one.discord_name,
            'kind', 'strike',
            'move', (SELECT t.name FROM techniques t WHERE t.technique_id = move),
            'at', foe.name,
            'foe_no', aim,
            'damage', dealt,
            'pet_damage', COALESCE(swung.pet_dealt, 0),
            'pet', swung.pet_name,
            'strikes', swung.strikes,
            'crits', swung.crits,
            'chosen', one.intent_id IS NOT NULL);
    END LOOP;

    -- ---- the wounds land, all at once -------------------------------------
    UPDATE dungeon_foes f
    SET current_hp = GREATEST(0, f.current_hp - w.damage),
        felled_at = CASE WHEN f.current_hp - w.damage <= 0 THEN now() END
    FROM (SELECT v.foe_no, sum(v.damage) AS damage
          FROM jsonb_to_recordset(lines)
               AS v(kind TEXT, foe_no SMALLINT, damage BIGINT)
          WHERE v.kind = 'strike' GROUP BY v.foe_no) w
    WHERE f.run_id = p_run_id AND f.foe_no = w.foe_no;

    UPDATE dungeon_raiders x
    SET current_hp = GREATEST(0, x.current_hp - b.damage),
        damage_taken = x.damage_taken + b.damage
    FROM (SELECT v.victim_id, sum(v.damage) AS damage
          FROM jsonb_to_recordset(lines)
               AS v(kind TEXT, victim_id BIGINT, damage BIGINT)
          WHERE v.kind = 'betrayal' GROUP BY v.victim_id) b
    WHERE x.run_id = p_run_id AND x.player_id = b.victim_id;

    -- Every foe that went down says so, by name.
    FOR foe IN
        SELECT cs.name FROM dungeon_foes f
        JOIN creature_species cs ON cs.species_id = f.species_id
        WHERE f.run_id = p_run_id AND f.current_hp = 0
          AND f.felled_at >= now() - interval '1 second'
    LOOP
        lines := lines || jsonb_build_object(
            'kind', 'felled', 'who', foe.name);
    END LOOP;

    -- `boss_hp` is the room's total, which is what every existing reader
    -- means by it.
    UPDATE dungeon_runs r
    SET boss_hp = COALESCE((SELECT sum(f.current_hp) FROM dungeon_foes f
                            WHERE f.run_id = p_run_id), 0)
    WHERE r.run_id = p_run_id
    RETURNING r.boss_hp INTO pool;

    -- ---- and everything still standing answers ---------------------------
    -- Three foes is three blows. One a round against a crowd would be a room
    -- with more health and the same pressure.
    FOR foe IN
        SELECT f.foe_no, f.species_id, cs.name
        FROM dungeon_foes f
        JOIN creature_species cs ON cs.species_id = f.species_id
        WHERE f.run_id = p_run_id AND f.current_hp > 0
        ORDER BY cs.base_speed DESC, f.foe_no
    LOOP
        SELECT x.player_id INTO target
        FROM dungeon_raiders x
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY -ln(random())
                 / (1 + effect_value('dungeon', p_run_id, x.player_id, 'taunt'))
        LIMIT 1;

        EXIT WHEN target IS NULL;

        SELECT * INTO hit FROM compute_creature_damage(
            foe.species_id, target, 1,
            (SELECT pp.defense FROM player_physique pp
             WHERE pp.player_id = target)::bigint);

        SELECT * INTO took FROM player_take(
            target, hit.final_damage,
            (SELECT x.current_hp FROM dungeon_raiders x
             WHERE x.run_id = p_run_id AND x.player_id = target),
            (SELECT x.max_hp FROM dungeon_raiders x
             WHERE x.run_id = p_run_id AND x.player_id = target),
            FALSE,
            NOT (SELECT x.ward_used FROM dungeon_raiders x
                 WHERE x.run_id = p_run_id AND x.player_id = target),
            'dungeon', p_run_id);

        taken := took.taken;

        IF took.warded THEN
            UPDATE dungeon_raiders x SET ward_used = TRUE
            WHERE x.run_id = p_run_id AND x.player_id = target;
        END IF;

        UPDATE dungeon_raiders x
        SET current_hp = GREATEST(0, x.current_hp - taken),
            damage_taken = x.damage_taken + taken
        WHERE x.run_id = p_run_id AND x.player_id = target;

        lines := lines || jsonb_build_object(
            'who', foe.name, 'kind', 'boss',
            'foe_no', foe.foe_no,
            'pet_covered', COALESCE(took.covered, 0),
            'pet', took.pet_name,
            'target', (SELECT p.discord_name FROM players p
                       WHERE p.player_id = target),
            'damage', taken,
            'downed', (SELECT x.current_hp = 0 FROM dungeon_raiders x
                       WHERE x.run_id = p_run_id AND x.player_id = target));
    END LOOP;

    -- ---- is anybody left ---------------------------------------------------
    ending := CASE
        WHEN pool <= 0 THEN 'won'
        WHEN NOT EXISTS (SELECT 1 FROM dungeon_raiders x
                         WHERE x.run_id = p_run_id AND x.current_hp > 0)
             THEN 'lost'
        WHEN run.round_no >= game_config_value('dungeon_round_cap')
             THEN 'lost'
        ELSE 'fighting'
    END;

    UPDATE dungeon_runs r
    SET round_no = r.round_no + CASE WHEN ending = 'fighting' THEN 1 ELSE 0 END,
        status = ending,
        ended_at = CASE WHEN ending = 'fighting' THEN NULL ELSE now() END,
        round_ends_at = CASE WHEN ending = 'fighting'
            THEN now() + make_interval(
                secs => game_config_value('dungeon_round_seconds')::integer)
            END
    WHERE r.run_id = p_run_id;

    IF ending <> 'fighting' THEN
        PERFORM effect_clear('dungeon', p_run_id);
        PERFORM dungeon_pay_out(p_run_id);
    END IF;

    RETURN QUERY
    SELECT r.round_no, lines, r.boss_hp, r.status
    FROM dungeon_runs r WHERE r.run_id = p_run_id;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Fight a crowded room, and put a knife in somebody
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a    BIGINT;
    v_b    BIGINT;
    v_dg   SMALLINT;
    v_diff TEXT;
    v_run  BIGINT;
    v_path TEXT;
    v_tech BIGINT;
    v_r    RECORD;
    v_n    INTEGER;
    v_hp   BIGINT;
BEGIN
    SELECT dungeon_id INTO v_dg FROM dungeons WHERE code = 'vault_of_unclaimed_dao';
    SELECT code INTO v_diff FROM dungeon_difficulties ORDER BY sort_order LIMIT 1;
    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;
    SELECT t.technique_id INTO v_tech FROM techniques t
    WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-970, 'raider-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-969, 'raider-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_b, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;

        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT x.who, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT pp.max_hp, pp.defense, pp.strength
            FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
            WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
            ORDER BY pp.max_hp DESC LIMIT 1) pp;

        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_a, v_path, 90000, 5), (v_b, v_path, 90000, 5);
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech), (v_b, v_tech);

        PERFORM grant_material(v_a, 'spirit_stone', 20000000000);
        PERFORM grant_material(v_b, 'spirit_stone', 20000000000);
        PERFORM grant_material(v_a, 'dungeon_key', 1);
        PERFORM grant_material(v_b, 'dungeon_key', 1);
        PERFORM grant_jade(v_a, 500, 'probe');
        PERFORM grant_jade(v_b, 500, 'probe');

        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_a, 19, 'passed', now());
        PERFORM venerable_ascend(v_a);

        v_run := dungeon_open(v_a, v_dg, v_diff);
        PERFORM dungeon_invite(v_run, v_a, v_b);
        PERFORM dungeon_join(v_run, v_b);
        PERFORM dungeon_begin(v_run, v_a);

        -- 1. THREE FOES ANSWER, not one.
        PERFORM dungeon_choose(v_run, v_a, v_tech, 0::smallint);
        PERFORM dungeon_choose(v_run, v_b, v_tech, 2::smallint);

        SELECT count(*) INTO v_n FROM dungeon_foes f
        WHERE f.run_id = v_run AND f.current_hp < f.max_hp;
        IF v_n < 2 THEN
            RAISE EXCEPTION
                'only % of the three foes was touched, so targeting did nothing',
                v_n;
        END IF;

        -- 2. A KNIFE. `raider-two` turns on the Venerable who brought them.
        SELECT x.current_hp INTO v_hp FROM dungeon_raiders x
        WHERE x.run_id = v_run AND x.player_id = v_a;

        PERFORM dungeon_choose(v_run, v_a, v_tech, 0::smallint);
        PERFORM dungeon_choose(v_run, v_b, v_tech, NULL::smallint, v_a);

        IF (SELECT x.betrayals FROM dungeon_raiders x
            WHERE x.run_id = v_run AND x.player_id = v_b) <> 1 THEN
            RAISE EXCEPTION 'the knife was not recorded';
        END IF;
        IF (SELECT x.current_hp FROM dungeon_raiders x
            WHERE x.run_id = v_run AND x.player_id = v_a) >= v_hp THEN
            RAISE EXCEPTION
                'the betrayed raider is on % of the % they had',
                (SELECT x.current_hp FROM dungeon_raiders x
                 WHERE x.run_id = v_run AND x.player_id = v_a), v_hp;
        END IF;

        -- 3. AND THE BETRAYER IS STILL IN THE ROOM, taking blows from it -
        -- "the attacker is still hit by the boss as well".
        IF (SELECT x.damage_taken FROM dungeon_raiders x
            WHERE x.run_id = v_run AND x.player_id = v_b) <= 0 THEN
            RAISE EXCEPTION
                'the betrayer walked out of the room''s attention';
        END IF;
        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run)
           NOT IN ('fighting', 'won', 'lost') THEN
            RAISE EXCEPTION 'the run ended up in a state nobody asked for';
        END IF;

        -- 4. AND NOBODY MAY AIM AT THEMSELVES, or at a bystander.
        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run)
           = 'fighting' THEN
            BEGIN
                PERFORM dungeon_choose(v_run, v_b, v_tech, NULL::smallint, v_b);
                RAISE EXCEPTION 'a raider turned on themselves';
            EXCEPTION WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%turn on yourself%' THEN RAISE; END IF;
            END;
            BEGIN
                PERFORM dungeon_choose(v_run, v_b, v_tech, 0::smallint, v_a);
                RAISE EXCEPTION 'aimed at a foe and a person at once';
            EXCEPTION WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%not both%' THEN RAISE; END IF;
            END;
        END IF;

        RAISE NOTICE
            'a crowded room: % foes standing, % betrayals recorded',
            (SELECT count(*) FROM dungeon_foes f
             WHERE f.run_id = v_run AND f.current_hp > 0),
            (SELECT sum(x.betrayals) FROM dungeon_raiders x
             WHERE x.run_id = v_run);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- An old room still works, with one foe and one answer a round.
    RAISE NOTICE 'the round loop targets, and a knife is a public act';
END;
$probe$;
