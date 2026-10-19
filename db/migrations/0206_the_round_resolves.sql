-- 0206_the_round_resolves
--
-- One round: everybody who chose swings, everybody who did not swings with
-- their first attack technique, the boss hits one of them back, and the room
-- is checked for a winner.
--
-- THE DAMAGE IS NOT COMPUTED HERE. `compute_technique_damage` and
-- `compute_creature_damage` already know about Path matchups, attainment
-- tiers, equipment, Gu, manuals, armour and the rest, and they take a player,
-- a technique and a species - no battle context at all. A dungeon round calls
-- them exactly as a duel does. Writing the arithmetic again would make
-- dungeons a second opinion about how hard people hit, and the first thing to
-- disagree with the rest of the game.
--
-- THE BOSS STRIKES ONE RAIDER A ROUND, chosen among the living. That is the
-- whole reason to bring people: five raiders do not take five times the
-- damage, they take the same damage one fifth as often. It is also why the
-- health pool scales with the party and the boss's attack does not.
--
-- A raider at zero stays in the room. They stop swinging and stop being
-- picked as a target, and the run ends when the boss falls or the last one
-- standing goes down. Nobody is thrown out of a room their friends are still
-- fighting in.
--
-- SPOILS ARE SPLIT BY DAMAGE, the same rule the world boss uses, and the
-- difficulty multiplies the pot. A raider who went down early still gets the
-- share they earned before they did.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_stone_reward_per_rank', 900,
     'Spirit Stones in the pot per rank of the dungeon, before difficulty. '
     'The pot is split by damage dealt.'),
    ('dungeon_jade_reward_rank', 5,
     'From this dungeon rank upward a run also pays Spirit Jade. Below it the '
     'jade faucet would be wider than every other one put together.'),
    ('dungeon_key_refund_on_loss', 1,
     'A wiped party gets its keys back. The stones are spent either way - the '
     'door was opened - but a key is twelve hours and losing one to a fight '
     'you already lost is two punishments for one mistake.');


CREATE FUNCTION dungeon_resolve_round(p_run_id BIGINT)
RETURNS TABLE (
    round_no    SMALLINT,
    log         JSONB,
    boss_hp     BIGINT,
    status      TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    run     RECORD;
    one     RECORD;
    hit     RECORD;
    move    BIGINT;
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

    -- ---- the raiders swing ------------------------------------------------
    FOR one IN
        SELECT x.player_id, x.intent_id, p.discord_name
        FROM dungeon_raiders x
        JOIN players p ON p.player_id = x.player_id
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY x.joined_at, x.player_id
    LOOP
        -- Silence is not a skipped turn. The first attack technique, as the
        -- room's own instructions promise.
        move := COALESCE(one.intent_id, dungeon_default_move(one.player_id));

        IF move IS NULL THEN
            lines := lines || jsonb_build_object(
                'who', one.discord_name, 'kind', 'idle',
                'text', 'has no attack to make');
            CONTINUE;
        END IF;

        SELECT * INTO hit FROM compute_technique_damage(
            one.player_id, move, run.species_id,
            player_external_multiplier(one.player_id, move),
            (SELECT s.base_defense FROM creature_species s
             WHERE s.species_id = run.species_id)::bigint);

        dealt := GREATEST(0, hit.final_damage);

        UPDATE dungeon_raiders x
        SET damage_dealt = x.damage_dealt + dealt,
            intent_id = NULL, chose_at = NULL
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id;

        lines := lines || jsonb_build_object(
            'who', one.discord_name,
            'kind', 'strike',
            'move', (SELECT t.name FROM techniques t WHERE t.technique_id = move),
            'damage', dealt,
            'chosen', one.intent_id IS NOT NULL);
    END LOOP;

    UPDATE dungeon_runs r
    SET boss_hp = GREATEST(0, r.boss_hp - (
            SELECT COALESCE(sum(v.damage), 0)
            FROM jsonb_to_recordset(lines) AS v(damage BIGINT, kind TEXT)
            WHERE v.kind = 'strike'))
    WHERE r.run_id = p_run_id
    RETURNING r.boss_hp INTO pool;

    -- ---- and if it is still up, it answers --------------------------------
    IF pool > 0 THEN
        SELECT x.player_id INTO target
        FROM dungeon_raiders x
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY random()
        LIMIT 1;

        IF target IS NOT NULL THEN
            SELECT * INTO hit FROM compute_creature_damage(
                run.species_id, target, 1,
                (SELECT pp.defense FROM player_physique pp
                 WHERE pp.player_id = target)::bigint);

            taken := GREATEST(0, hit.final_damage);

            UPDATE dungeon_raiders x
            SET current_hp = GREATEST(0, x.current_hp - taken),
                damage_taken = x.damage_taken + taken
            WHERE x.run_id = p_run_id AND x.player_id = target;

            lines := lines || jsonb_build_object(
                'who', run.boss_name, 'kind', 'boss',
                'target', (SELECT p.discord_name FROM players p
                           WHERE p.player_id = target),
                'damage', taken,
                'downed', (SELECT x.current_hp = 0 FROM dungeon_raiders x
                           WHERE x.run_id = p_run_id AND x.player_id = target));
        END IF;
    END IF;

    -- ---- is anybody left ---------------------------------------------------
    ending := CASE
        WHEN pool <= 0 THEN 'won'
        WHEN NOT EXISTS (SELECT 1 FROM dungeon_raiders x
                         WHERE x.run_id = p_run_id AND x.current_hp > 0)
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
        PERFORM dungeon_pay_out(p_run_id);
    END IF;

    RETURN QUERY
    SELECT r.round_no, lines, r.boss_hp, r.status
    FROM dungeon_runs r WHERE r.run_id = p_run_id;
END;
$$;


-- Split by damage dealt, the world boss's rule. A raider who went down in
-- round two keeps the share they earned in round one.
CREATE FUNCTION dungeon_pay_out(p_run_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    run    RECORD;
    one    RECORD;
    total  BIGINT;
    stones BIGINT;
    jade   BIGINT;
    share  NUMERIC;
    paid_s BIGINT;
    paid_j BIGINT;
BEGIN
    SELECT * INTO run FROM dungeon_run_state s WHERE s.run_id = p_run_id;

    SELECT GREATEST(1, COALESCE(sum(x.damage_dealt), 0)) INTO total
    FROM dungeon_raiders x WHERE x.run_id = p_run_id;

    stones := round(game_config_value('dungeon_stone_reward_per_rank')
                    * run.realm_rank * run.reward_scale);
    jade := CASE
        WHEN run.realm_rank >= game_config_value('dungeon_jade_reward_rank')
        THEN GREATEST(1, round(run.realm_rank * run.reward_scale / 3))
        ELSE 0
    END;

    FOR one IN
        SELECT x.player_id, x.damage_dealt, x.keys_paid
        FROM dungeon_raiders x WHERE x.run_id = p_run_id
    LOOP
        IF run.status = 'won' THEN
            share  := one.damage_dealt::numeric / total;
            paid_s := floor(stones * share);
            paid_j := floor(jade * share);

            IF paid_s > 0 THEN
                PERFORM grant_material(one.player_id, 'spirit_stone', paid_s);
            END IF;
            IF paid_j > 0 THEN
                PERFORM grant_jade(one.player_id, paid_j, 'dungeon_spoils');
            END IF;
        ELSE
            paid_s := 0;
            paid_j := 0;
            -- The door was opened, so the stones are gone. The key is twelve
            -- hours and losing it to a fight already lost is two punishments
            -- for one mistake.
            IF game_config_value('dungeon_key_refund_on_loss') > 0
               AND one.keys_paid > 0 THEN
                PERFORM grant_material(one.player_id, 'dungeon_key',
                                       one.keys_paid);
            END IF;
        END IF;

        UPDATE dungeon_raiders x
        SET spoils = jsonb_build_object(
            'stones', paid_s, 'jade', paid_j,
            'damage', one.damage_dealt,
            'share', round(100.0 * one.damage_dealt / total, 1),
            'keys_back', CASE WHEN run.status = 'won' THEN 0
                              ELSE one.keys_paid END)
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id;
    END LOOP;
END;
$$;


-- The clock. A round whose sixty seconds are up resolves whether or not
-- everybody has spoken, and a party that never went in stops holding a door.
CREATE FUNCTION dungeon_runs_due()
RETURNS TABLE (run_id BIGINT, why TEXT)
LANGUAGE sql
STABLE
AS $$
    SELECT r.run_id, 'round'
    FROM dungeon_runs r
    WHERE r.status = 'fighting' AND r.round_ends_at <= now()
    UNION ALL
    SELECT r.run_id, 'expired'
    FROM dungeon_runs r
    WHERE r.status = 'forming'
      AND r.opened_at + make_interval(
              mins => game_config_value('dungeon_forming_minutes')::integer) <= now();
$$;


CREATE FUNCTION dungeon_abandon(p_run_id BIGINT)
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE dungeon_runs SET status = 'abandoned', ended_at = now()
    WHERE run_id = p_run_id AND status = 'forming';
$$;


DO $$
DECLARE
    who    BIGINT;
    mate   BIGINT;
    run    BIGINT;
    got    RECORD;
    before BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND EXISTS (SELECT 1 FROM player_usable_techniques u
                  WHERE u.player_id = p.player_id)
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can fight yet; tests carry it';
        RETURN;
    END IF;

    SELECT p.player_id INTO mate FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 AND p.player_id <> who
      AND EXISTS (SELECT 1 FROM player_usable_techniques u
                  WHERE u.player_id = p.player_id)
    ORDER BY pp.max_hp DESC LIMIT 1;

    BEGIN
        -- A real party, a real door, a real round - and thrown away after.
        PERFORM grant_material(who, 'dungeon_key', 5);
        PERFORM grant_material(who, 'spirit_stone', 1000000);
        PERFORM grant_jade(who, 50, 'probe');

        run := dungeon_open(who, 1::smallint, 'normal');

        IF mate IS NOT NULL THEN
            PERFORM grant_material(mate, 'dungeon_key', 5);
            PERFORM grant_material(mate, 'spirit_stone', 1000000);
            PERFORM grant_jade(mate, 50, 'probe');
            PERFORM dungeon_invite(run, who, mate);
            PERFORM dungeon_join(run, mate);
        END IF;

        PERFORM dungeon_begin(run, who);

        SELECT boss_hp INTO before FROM dungeon_runs WHERE run_id = run;
        IF before <= 0 THEN
            RAISE EXCEPTION 'the room opened with a dead boss in it';
        END IF;

        -- Nobody chooses. The round must still resolve, and must still hurt
        -- the boss - that is the timeout rule.
        SELECT * INTO got FROM dungeon_resolve_round(run);

        IF got.boss_hp >= before THEN
            RAISE EXCEPTION
                'a silent round did no damage: % of %', got.boss_hp, before;
        END IF;

        IF jsonb_array_length(got.log) = 0 THEN
            RAISE EXCEPTION 'the round produced no log';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
