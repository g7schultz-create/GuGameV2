-- 0037_gu_in_combat
--
-- The six build axes, resolved in the round.
--
-- 0036 gave Gu a vocabulary and a place to sit. This is the half that makes a
-- build mean something: extra strikes, criticals, armour penetration, life
-- steal, evasion and damage reduction all resolve inside `battle_act`, which
-- is already the only place a round happens.
--
-- WHY THEY PULL AGAINST EACH OTHER. Defence is subtracted from EVERY strike,
-- so a three-strike build loses three lots of it and wants penetration badly;
-- a one-big-hit build barely notices. Life steal scales with damage dealt, so
-- it rides on either. Evasion and reduction are the answer to a telegraphed
-- heavy move, which the enemy shows you before you choose. None of these is a
-- flat upgrade over any other, which is the whole point of building.
--
-- The signature grows four columns, so this drops and recreates rather than
-- replacing - CREATE OR REPLACE cannot change a function's return type.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Cultivation reads the Gu
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
RETURNS TABLE (
    hours              NUMERIC,
    capped             BOOLEAN,
    cultivation_gained BIGINT,
    physique_gained    BIGINT,
    insight_gained     BIGINT,
    hp_restored        BIGINT,
    focus_path         TEXT,
    realm_before       SMALLINT,
    realm_after        SMALLINT,
    level_before       SMALLINT,
    level_after        SMALLINT,
    tier_before        SMALLINT,
    tier_after         SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult          player_cultivation%ROWTYPE;
    rates         player_trait_rates%ROWTYPE;
    baseline      NUMERIC := game_config_value('training_aptitude_baseline');
    cap_hours     NUMERIC := game_config_value('passive_cap_hours');
    manual_cult   NUMERIC := 0;
    manual_phys   NUMERIC := 0;
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_gain     BIGINT;
    phys_gain     BIGINT;
    insight_gain  BIGINT := 0;
    hp_gain       BIGINT := 0;
    hp_before     BIGINT;
    hp_after      BIGINT;
    r_before      SMALLINT;
    r_after       SMALLINT;
    l_before      SMALLINT;
    l_after       SMALLINT;
    t_before      SMALLINT;
    t_after       SMALLINT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    elapsed    := EXTRACT(EPOCH FROM (now() - cult.last_tick_at)) / 3600.0;
    was_capped := elapsed > cap_hours;
    paid       := LEAST(elapsed, cap_hours);

    SELECT * INTO rates FROM player_trait_rates WHERE player_id = p_player_id;

    SELECT b.cultivation_rate_bonus, b.physique_rate_bonus
    INTO manual_cult, manual_phys
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;
    manual_cult := COALESCE(manual_cult, 0) + gu_stat(p_player_id, 'cultivation_rate');
    manual_phys := COALESCE(manual_phys, 0);

    SELECT pc.realm_id INTO r_before FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_gain := round(
        paid
        * game_config_value('passive_cultivation_per_hour')
        * (COALESCE(rates.cultivation_multiplier, 1) + manual_cult)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * (COALESCE(rates.physique_multiplier, 1) + manual_phys)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            paid
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_gain);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    SELECT pp.current_hp INTO hp_before
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    UPDATE player_physique pp
    SET current_hp = least(pp.max_hp,
                           pp.current_hp + floor(paid * 60 * pp.regeneration)::bigint)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO hp_after;

    hp_gain := GREATEST(0, COALESCE(hp_after, 0) - COALESCE(hp_before, 0));

    IF cult.focus_path IS NOT NULL THEN
        t_after := grant_path_insight(
            p_player_id, cult.focus_path, insight_gain, round(paid * 3600)::bigint, 0
        );
    ELSE
        t_after := t_before;
    END IF;

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;


-- ---------------------------------------------------------------------------
-- The round, with the build in it
-- ---------------------------------------------------------------------------

DROP FUNCTION battle_act(BIGINT, TEXT, BIGINT);

CREATE FUNCTION battle_act(
    p_battle_id    BIGINT,
    p_action       TEXT,
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    finished        BOOLEAN,
    outcome         TEXT,
    dealt           BIGINT,
    taken           BIGINT,
    player_hp       BIGINT,
    creature_hp     BIGINT,
    qi_after        BIGINT,
    qi_spent        BIGINT,
    move_name       TEXT,
    enemy_move      TEXT,
    revealed_path   TEXT,
    revealed_effect TEXT,
    note            TEXT,
    drops           JSONB,
    strikes         SMALLINT,
    crits           SMALLINT,
    dodged          BOOLEAN,
    healed          BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    fight      battles%ROWTYPE;
    me         battle_combatants%ROWTYPE;
    it         battle_combatants%ROWTYPE;
    species    creature_species%ROWTYPE;
    tech       techniques%ROWTYPE;
    move       creature_moves%ROWTYPE;
    hit        RECORD;
    external   NUMERIC;
    cost       BIGINT := 0;
    p_hp       BIGINT;
    c_hp       BIGINT;
    qi         BIGINT;
    dmg_out    BIGINT := 0;
    dmg_in     BIGINT := 0;
    my_move    TEXT;
    escaped    BOOLEAN := FALSE;
    chance     NUMERIC;
    my_rank    SMALLINT;
    rev_path   TEXT;
    rev_effect TEXT;
    rev_text   TEXT;
    rev_name   TEXT;
    said       TEXT := '';
    ends_as    TEXT;
    loot       JSONB := '[]'::jsonb;
    guarded    BOOLEAN;

    -- the build
    pen        NUMERIC;
    mh         NUMERIC;
    crit_pct   NUMERIC;
    crit_mult  NUMERIC;
    steal      NUMERIC;
    evade      NUMERIC;
    reduce     NUMERIC;
    eff_def    BIGINT;
    n_strikes  SMALLINT := 1;
    n_crits    SMALLINT := 0;
    was_dodged BOOLEAN := FALSE;
    healed_by  BIGINT := 0;
    strike     INTEGER;
    one_hit    BIGINT;
BEGIN
    SELECT * INTO fight FROM battles WHERE battle_id = p_battle_id FOR UPDATE;
    IF NOT FOUND OR fight.status <> 'active' THEN
        RAISE EXCEPTION 'that fight is over' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0 FOR UPDATE;
    SELECT * INTO it FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 1 FOR UPDATE;

    SELECT * INTO species FROM creature_species WHERE species_id = it.species_id;

    p_hp := me.current_hp;
    c_hp := it.current_hp;
    qi   := me.current_qi;

    IF p_action = 'attack' THEN
        SELECT * INTO tech FROM techniques WHERE technique_id = p_technique_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'no such technique' USING ERRCODE = 'check_violation';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM player_usable_techniques u
            WHERE u.player_id = me.player_id AND u.technique_id = p_technique_id
        ) THEN
            RAISE EXCEPTION 'you cannot use %', tech.name USING ERRCODE = 'check_violation';
        END IF;

        cost := ceil(tech.qi_cost_pct * (me.snapshot ->> 'max_qi')::bigint);
        IF qi < cost THEN
            RAISE EXCEPTION 'not enough qi for %', tech.name USING ERRCODE = 'check_violation';
        END IF;
        qi := qi - cost;

        pen       := gu_stat(me.player_id, 'armor_pen');
        mh        := gu_stat(me.player_id, 'multi_hit');
        crit_pct  := gu_stat(me.player_id, 'crit_rate');
        crit_mult := 1 + game_config_value('gu_crit_damage_base')
                       + gu_stat(me.player_id, 'crit_damage');
        steal     := gu_stat(me.player_id, 'lifesteal');

        -- Penetration is applied to the defence the pipeline subtracts, which
        -- is why it matters most to a build that strikes several times.
        eff_def := GREATEST(0, round((it.snapshot ->> 'base_defense')::numeric * (1 - pen)));

        -- One strike, plus a whole one per point of multi-hit, plus a roll for
        -- the remainder.
        n_strikes := 1 + floor(mh)::int + CASE WHEN random() < (mh - floor(mh)) THEN 1 ELSE 0 END;

        external := player_external_multiplier(me.player_id, p_technique_id);

        FOR strike IN 1..n_strikes LOOP
            EXIT WHEN c_hp <= 0;

            SELECT * INTO hit FROM compute_technique_damage(
                me.player_id, p_technique_id, it.species_id, external, eff_def);

            one_hit := hit.final_damage;
            IF strike > 1 THEN
                one_hit := GREATEST(0, floor(one_hit * game_config_value('gu_multi_hit_power')));
            END IF;
            IF random() < crit_pct THEN
                one_hit := floor(one_hit * crit_mult);
                n_crits := n_crits + 1;
            END IF;

            c_hp    := GREATEST(0, c_hp - one_hit);
            dmg_out := dmg_out + one_hit;

            INSERT INTO battle_actions
                (battle_id, actor_no, turn_number, action, technique_id, technique_name,
                 target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
            VALUES (p_battle_id, 0, fight.turn_number, 'technique', p_technique_id,
                    tech.name, 1,
                    hit.base_power, hit.attainment_bonus, hit.matchup_modifier, one_hit,
                    jsonb_build_object('external', external, 'qi_spent',
                                       CASE WHEN strike = 1 THEN cost ELSE 0 END,
                                       'strike', strike, 'of', n_strikes,
                                       'armor_pen', pen,
                                       'target_hp_after', c_hp));
        END LOOP;

        my_move := tech.name;

        IF steal > 0 AND dmg_out > 0 THEN
            healed_by := LEAST(
                floor(dmg_out * steal),
                GREATEST(0, me.max_hp - p_hp)
            );
            p_hp := p_hp + healed_by;
        END IF;

        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT me.player_id, it.species_id, cip.path_code, 'combat'
        FROM creature_incoming_paths cip
        JOIN technique_paths tp ON tp.path_code = cip.path_code
        WHERE cip.species_id = it.species_id AND tp.technique_id = p_technique_id
        ON CONFLICT DO NOTHING;

    ELSIF p_action = 'guard' THEN
        my_move := 'Guard';
        qi := LEAST((me.snapshot ->> 'max_qi')::bigint,
                    qi + ceil(game_config_value('guard_qi_restore')
                              * (me.snapshot ->> 'max_qi')::bigint));
        said := 'You brace. The next blow lands on your terms.';

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'pass', 1,
                jsonb_build_object('guard', TRUE, 'qi_after', qi));

    ELSIF p_action = 'observe' THEN
        my_move := 'Observe';

        SELECT cip.path_code, cip.interaction, cip.flavour_text, p.name
        INTO rev_path, rev_effect, rev_text, rev_name
        FROM creature_incoming_paths cip
        JOIN paths p ON p.code = cip.path_code
        WHERE cip.species_id = it.species_id
          AND NOT EXISTS (
              SELECT 1 FROM player_bestiary_paths bp
              WHERE bp.player_id = me.player_id
                AND bp.species_id = it.species_id
                AND bp.path_code = cip.path_code
          )
        ORDER BY CASE cip.interaction
                     WHEN 'weakness' THEN 0 WHEN 'immunity' THEN 1 ELSE 2 END,
                 random()
        LIMIT 1;

        IF rev_path IS NULL THEN
            said := 'You watch it move. There is nothing left about it you do not know.';
        ELSE
            INSERT INTO player_bestiary_paths
                (player_id, species_id, path_code, discovered_via)
            VALUES (me.player_id, it.species_id, rev_path, 'combat')
            ON CONFLICT DO NOTHING;
            said := COALESCE(NULLIF(rev_text, ''),
                             'You see how it takes ' || rev_name || '.');
        END IF;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, discovered_path, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'system', 1, rev_path,
                jsonb_build_object('observed', TRUE));

    ELSIF p_action = 'flee' THEN
        my_move := 'Flee';

        SELECT r.rank INTO my_rank
        FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
        WHERE pc.player_id = me.player_id;

        chance := game_config_value('flee_base_chance')
                  + game_config_value('flee_rank_step')
                    * (COALESCE(my_rank, 1) - species.rank);
        chance := GREATEST(game_config_value('flee_min_chance'),
                           LEAST(game_config_value('flee_max_chance'), chance));
        escaped := random() < chance;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, target_no, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'flee', 1,
                jsonb_build_object('chance', round(chance, 4), 'escaped', escaped));

        IF escaped THEN
            UPDATE battle_combatants bc SET current_hp = p_hp, current_qi = qi, guarding = FALSE
            WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

            loot := battle_conclude(p_battle_id, 'fled');
            RETURN QUERY SELECT TRUE, 'fled', 0::bigint, 0::bigint, p_hp, c_hp, qi, 0::bigint,
                                my_move, NULL::text, NULL::text, NULL::text,
                                'You break away. Nothing follows you far.', loot,
                                0::smallint, 0::smallint, FALSE, 0::bigint;
            RETURN;
        END IF;
        said := 'It cuts you off.';
    ELSE
        RAISE EXCEPTION 'no such action: %', p_action USING ERRCODE = 'check_violation';
    END IF;

    -- ---- did that finish it? ----------------------------------------------
    IF c_hp <= 0 THEN
        UPDATE battle_combatants bc SET current_hp = c_hp
        WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 1;
        UPDATE battle_combatants bc SET current_hp = p_hp, current_qi = qi, guarding = FALSE
        WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

        loot := battle_conclude(p_battle_id, 'complete');
        RETURN QUERY SELECT TRUE, 'won', dmg_out, 0::bigint, p_hp, c_hp, qi, cost,
                            my_move, NULL::text, rev_path, rev_effect, said, loot,
                            n_strikes, n_crits, FALSE, healed_by;
        RETURN;
    END IF;

    -- ---- the creature answers ----------------------------------------------
    SELECT * INTO move FROM creature_moves WHERE move_id = it.intent_move_id;
    guarded := (p_action = 'guard');
    evade   := gu_stat(me.player_id, 'dodge');
    reduce  := gu_stat(me.player_id, 'damage_reduction');

    SELECT * INTO hit FROM compute_creature_damage(
        it.species_id, me.player_id,
        COALESCE(move.power_multiplier, 1),
        (me.snapshot ->> 'defense')::bigint);

    dmg_in := hit.final_damage;

    IF random() < evade THEN
        was_dodged := TRUE;
        dmg_in := 0;
        said := trim(both ' ' FROM said || ' You are not where the blow goes.');
    ELSE
        -- Multiplicative with Guard, per the design's guardrail: two halvings
        -- must not add up to taking nothing.
        IF guarded THEN
            dmg_in := floor(dmg_in * (1 - game_config_value('guard_damage_reduction')));
        END IF;
        IF reduce > 0 THEN
            dmg_in := floor(dmg_in * (1 - reduce));
        END IF;
        dmg_in := GREATEST(0, dmg_in);
    END IF;

    p_hp := GREATEST(0, p_hp - dmg_in);

    INSERT INTO battle_actions
        (battle_id, actor_no, turn_number, action, technique_name, target_no,
         base_power, attainment_bonus, matchup_modifier, damage, detail)
    VALUES (p_battle_id, 1, fight.turn_number, 'technique',
            COALESCE(move.name, species.name), 0,
            hit.base_power, hit.attainment_bonus, hit.matchup_modifier, dmg_in,
            jsonb_build_object('guarded', guarded, 'dodged', was_dodged,
                               'reduction', reduce, 'target_hp_after', p_hp));

    UPDATE battle_combatants bc
    SET current_hp = p_hp, current_qi = qi, guarding = FALSE
    WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;

    UPDATE battle_combatants bc
    SET current_hp = c_hp, intent_move_id = roll_creature_intent(bc.species_id)
    WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 1;

    UPDATE battles b SET turn_number = b.turn_number + 1 WHERE b.battle_id = p_battle_id;

    IF p_hp <= 0 THEN
        ends_as := 'lost';
    ELSIF fight.turn_number + 1 > game_config_value('battle_turn_cap') THEN
        ends_as := 'drawn';
    END IF;

    IF ends_as IS NOT NULL THEN
        loot := battle_conclude(p_battle_id,
                                CASE WHEN ends_as = 'lost' THEN 'complete' ELSE 'expired' END);
        RETURN QUERY SELECT TRUE, ends_as, dmg_out, dmg_in, p_hp, c_hp, qi, cost,
                            my_move, COALESCE(move.name, species.name),
                            rev_path, rev_effect, said, loot,
                            n_strikes, n_crits, was_dodged, healed_by;
        RETURN;
    END IF;

    RETURN QUERY SELECT FALSE, 'ongoing', dmg_out, dmg_in, p_hp, c_hp, qi, cost,
                        my_move, COALESCE(move.name, species.name),
                        rev_path, rev_effect, said, loot,
                        n_strikes, n_crits, was_dodged, healed_by;
END;
$$;

COMMENT ON FUNCTION battle_act(BIGINT, TEXT, BIGINT) IS
    'One round, with the equipped Gu in it: strikes, criticals, penetration, life steal, evasion and reduction all resolve here.';
