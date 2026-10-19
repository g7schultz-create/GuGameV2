-- 0031_battle_act_reveal
--
-- `reveal` was declared RECORD and only assigned in the observe branch, so
-- every other action raised "record reveal is not assigned yet" the moment the
-- RETURN QUERY read it. An unassigned RECORD has no tuple structure at all -
-- unlike a %ROWTYPE variable, which is all NULLs and reads fine, which is why
-- `move`, `tech` and `species` were never a problem.
--
-- Scalars instead. There is no shape to be indeterminate about.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION battle_act(
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
    drops           JSONB
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

    -- ---- the player's half -------------------------------------------------
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

        external := player_external_multiplier(me.player_id, p_technique_id);
        SELECT * INTO hit FROM compute_technique_damage(
            me.player_id, p_technique_id, it.species_id, external,
            (it.snapshot ->> 'base_defense')::bigint);

        c_hp    := GREATEST(0, c_hp - hit.final_damage);
        dmg_out := hit.final_damage;
        my_move := tech.name;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
        VALUES (p_battle_id, 0, fight.turn_number, 'technique', p_technique_id, tech.name, 1,
                hit.base_power, hit.attainment_bonus, hit.matchup_modifier, hit.final_damage,
                jsonb_build_object('external', external, 'qi_spent', cost,
                                   'target_hp_after', c_hp));

        -- Swinging a Path at something teaches you what that Path does to it.
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
                                'You break away. Nothing follows you far.', loot;
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
                            my_move, NULL::text, rev_path, rev_effect, said, loot;
        RETURN;
    END IF;

    -- ---- the creature answers ----------------------------------------------
    SELECT * INTO move FROM creature_moves WHERE move_id = it.intent_move_id;
    guarded := (p_action = 'guard');

    SELECT * INTO hit FROM compute_creature_damage(
        it.species_id, me.player_id,
        COALESCE(move.power_multiplier, 1),
        (me.snapshot ->> 'defense')::bigint);

    dmg_in := hit.final_damage;
    IF guarded THEN
        dmg_in := GREATEST(0, floor(dmg_in * (1 - game_config_value('guard_damage_reduction'))));
    END IF;

    p_hp := GREATEST(0, p_hp - dmg_in);

    INSERT INTO battle_actions
        (battle_id, actor_no, turn_number, action, technique_name, target_no,
         base_power, attainment_bonus, matchup_modifier, damage, detail)
    VALUES (p_battle_id, 1, fight.turn_number, 'technique',
            COALESCE(move.name, species.name), 0,
            hit.base_power, hit.attainment_bonus, hit.matchup_modifier, dmg_in,
            jsonb_build_object('guarded', guarded, 'target_hp_after', p_hp));

    -- ---- next round --------------------------------------------------------
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
                            rev_path, rev_effect, said, loot;
        RETURN;
    END IF;

    RETURN QUERY SELECT FALSE, 'ongoing', dmg_out, dmg_in, p_hp, c_hp, qi, cost,
                        my_move, COALESCE(move.name, species.name),
                        rev_path, rev_effect, said, loot;
END;
$$;
