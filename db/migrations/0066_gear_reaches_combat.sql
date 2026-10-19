-- 0066_gear_reaches_combat
--
-- Equipment stops being a row and starts being felt.
--
-- ONE CEILING, NOT THREE. `gu_effects.cap` has always been described as the
-- ceiling on an effect - 0053 put it plainly: "the ceiling belongs to the
-- effect and not to whichever table happens to be granting it." Until now that
-- was easy to say, because only Gu granted anything a fight reads. With
-- equipment there are three sources for the same word, and three separately
-- capped sums would let a player hold three times the ceiling by spreading the
-- same stat across a Gu, a body and a sword.
--
-- So `player_stat()` sums Gu, worn equipment and the physique, and caps the
-- SUM. Nothing a player owns today changes value: `gu_stat` is unchanged and
-- still means what it says, physiques grant no combat effect yet, and a
-- cultivator with no gear reads exactly the number they read yesterday.
--
-- THE CALL SITES ARE LIFTED, NOT RETYPED. Every function below is the latest
-- definition of itself, copied out of the migration that last wrote it with
-- one identifier changed. `battle_act` is two hundred and fifty lines; a
-- hand-copy is two hundred and fifty chances to change something else by
-- accident, and the one thing this migration must not do is quietly retune a
-- fight.
--
-- WHERE THE STACK IS ADDITIVE, IT STAYS ADDITIVE. +8% attack from a saber and
-- +5% from a Gu is +13%. This migration adds a term to sums that were already
-- sums; it introduces no product anywhere.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- player_stat
-- ---------------------------------------------------------------------------
-- Everything a cultivator is carrying, wearing or born with, in one effect,
-- under one ceiling.

CREATE FUNCTION player_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        (SELECT ef.cap FROM gu_effects ef WHERE ef.code = p_effect),
        gu_stat(p_player_id, p_effect)
        + equipment_stat(p_player_id, p_effect)
        + physique_stat(p_player_id, p_effect)
    );
$$;

COMMENT ON FUNCTION player_stat(BIGINT, TEXT) IS
    'One effect, summed across Gu, worn equipment and the body, capped once. The per-source functions still exist and still mean what they say.';


-- ---------------------------------------------------------------------------
-- skill_buys, with two more crafts in it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION skill_buys(p_skill TEXT, p_level SMALLINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE p_skill
        WHEN 'gu_refining' THEN
            gu_refine_aux_slots(p_level) || ' auxiliary materials on the bench'
        WHEN 'alchemy' THEN
            alchemy_herb_slots(p_level) || ' herbs in the cauldron'
        WHEN 'refinement' THEN
            refinement_max_pages(p_level) || ' pages in one refinement'
        WHEN 'mining' THEN
            'veins down to tier ' || mining_tier_cap(p_level)
        WHEN 'blacksmithing' THEN
            'tier ' || smith_tier_cap(p_level) || ' pieces, '
            || smith_part_slots(p_level) || ' beast materials on the anvil'
    END;
$$;


-- ---------------------------------------------------------------------------
-- player_external_multiplier, from 0036_gu
-- ---------------------------------------------------------------------------
-- Attack power, the damage every technique is multiplied through.

CREATE OR REPLACE FUNCTION player_external_multiplier(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT 1
    + COALESCE((
        SELECT SUM(tp.weight * (
            COALESCE((SELECT rpb.damage_bonus
                      FROM player_character pc
                      JOIN race_path_bonuses rpb
                        ON rpb.race_code = pc.race_code AND rpb.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT rob.damage_bonus
                      FROM player_character pc
                      JOIN root_path_bonuses rob
                        ON rob.root_code = pc.root_code AND rob.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT ppb.damage_bonus
                      FROM player_physique pp
                      JOIN physique_path_bonuses ppb
                        ON ppb.physique_id = pp.physique_id AND ppb.path_code = tp.path_code
                      WHERE pp.player_id = p_player_id), 0)
        ))
        FROM technique_paths tp
        WHERE tp.technique_id = p_technique_id
    ), 0)
    + COALESCE((SELECT b.attack_bonus FROM player_manual_bonuses b
                WHERE b.player_id = p_player_id), 0)
    + player_stat(p_player_id, 'attack_power');
$$;

-- ---------------------------------------------------------------------------
-- apply_physique_xp, from 0046_body_paths
-- ---------------------------------------------------------------------------
-- Max HP, which is STORED on player_physique and snapshotted by a battle -
-- which is why equip() recomputes the body.

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    base_def  NUMERIC := game_config_value('physique_base_defense');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    base_str  NUMERIC := game_config_value('physique_base_strength');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
    man_hp      NUMERIC := 0;
    man_def     NUMERIC := 0;
    man_str     NUMERIC := 0;
    path_hp     NUMERIC := 0;
    path_def    NUMERIC := 0;
    path_str    NUMERIC := 0;
    new_level   SMALLINT;
    new_max_hp  BIGINT;
    hp_gained   BIGINT;
BEGIN
    SELECT * INTO row_before FROM player_physique WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    SELECT tr.hp_multiplier, tr.defense_multiplier, tr.strength_multiplier
    INTO mult_hp, mult_def, mult_str
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;

    SELECT b.hp_bonus, b.defense_bonus, b.strength_bonus
    INTO man_hp, man_def, man_str
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    SELECT bp.hp_bonus, bp.defense_bonus, bp.strength_bonus
    INTO path_hp, path_def, path_str
    FROM body_paths bp WHERE bp.code = row_before.body_path;

    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0)
                + COALESCE(path_hp, 0) + player_stat(p_player_id, 'max_hp');
    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0)
                + COALESCE(path_def, 0);
    mult_str := COALESCE(mult_str, 1) + COALESCE(man_str, 0)
                + COALESCE(path_str, 0);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = greatest(0, round((base_def + def_rate * (new_level - 1)) * mult_def)),
        strength    = greatest(0, round((base_str + str_rate * (new_level - 1)) * mult_str))
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;

-- ---------------------------------------------------------------------------
-- battle_act, from 0037_gu_in_combat
-- ---------------------------------------------------------------------------
-- Seven of them: penetration, extra strikes, criticals, life steal,
-- evasion and damage reduction. This is where gear is felt.

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

        pen       := player_stat(me.player_id, 'armor_pen');
        mh        := player_stat(me.player_id, 'multi_hit');
        crit_pct  := player_stat(me.player_id, 'crit_rate');
        crit_mult := 1 + game_config_value('gu_crit_damage_base')
                       + player_stat(me.player_id, 'crit_damage');
        steal     := player_stat(me.player_id, 'lifesteal');

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
    evade   := player_stat(me.player_id, 'dodge');
    reduce  := player_stat(me.player_id, 'damage_reduction');

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

-- ---------------------------------------------------------------------------
-- settle_passive_cultivation, from 0060_a_spent_boost_does_not_crash_the_settle
-- ---------------------------------------------------------------------------
-- Cultivation speed, so a Soulstone helm is worth wearing while idle.

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
    cult_offered  BIGINT;
    cult_gain     BIGINT;
    cult_before   BIGINT;
    cult_after    BIGINT;
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
    cult_boost    NUMERIC := 0;
    cult_hours    NUMERIC := 0;
    att_boost     NUMERIC := 0;
    att_hours     NUMERIC := 0;
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

    -- A boost is hours, not a clock. Nothing in this game ticks, so a pill
    -- that "lasts twelve hours" would have had to invent one - and would then
    -- have burned those hours while nobody was cultivating. These are spent
    -- only by time that is actually settled, so an hour bought is an hour had.
    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO cult_boost, cult_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';

    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO att_boost, att_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

    cult_boost := COALESCE(cult_boost, 0);
    cult_hours := COALESCE(cult_hours, 0);
    att_boost  := COALESCE(att_boost, 0);
    att_hours  := COALESCE(att_hours, 0);

    SELECT b.cultivation_rate_bonus, b.physique_rate_bonus
    INTO manual_cult, manual_phys
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;
    manual_cult := COALESCE(manual_cult, 0) + player_stat(p_player_id, 'cultivation_rate');
    manual_phys := COALESCE(manual_phys, 0);

    SELECT pc.realm_id, pc.cultivation INTO r_before, cult_before
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_offered := round(
        (paid + cult_boost * cult_hours)
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
            (paid + att_boost * att_hours)
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_offered);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    -- What was actually banked, not what was offered. The bottleneck can
    -- refuse most of it, and a card that reports the offer is a card that lies.
    SELECT pc.cultivation INTO cult_after
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    cult_gain := GREATEST(0, cult_after - cult_before);

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

    -- Swept away FIRST, then spent. `hours_left > 0` is a CHECK, and it is
    -- the right one - a boost row with nothing left in it is not a state
    -- worth having - so the exhausted rows have to go before anything tries
    -- to write a zero into them.
    DELETE FROM player_boosts b
    WHERE b.player_id = p_player_id
      AND ((b.kind = 'cultivation_rate' AND b.hours_left <= cult_hours)
        OR (b.kind = 'attainment_rate'  AND b.hours_left <= att_hours));

    UPDATE player_boosts b SET hours_left = b.hours_left - cult_hours
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';
    UPDATE player_boosts b SET hours_left = b.hours_left - att_hours
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

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
-- gather, from 0036_gu
-- ---------------------------------------------------------------------------
-- Gathering yield.

CREATE OR REPLACE FUNCTION gather(p_player_id BIGINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, rarity TEXT, quantity BIGINT, held BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    picked  TEXT;
    lo      NUMERIC := game_config_value('gather_yield_min');
    hi      NUMERIC := game_config_value('gather_yield_max');
    bonus   NUMERIC := 0;
    amount  BIGINT;
    total   BIGINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    SELECT rm.material_code INTO picked
    FROM region_materials rm
    WHERE rm.region_code = here
    ORDER BY -ln(random()) / rm.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'nothing grows in %', here USING ERRCODE = 'check_violation';
    END IF;

    SELECT b.gathering_bonus INTO bonus
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1)))
        * (1 + COALESCE(bonus, 0) + player_stat(p_player_id, 'gathering_yield'))
    ));
    total  := grant_material(p_player_id, picked, amount);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, amount, total
    FROM materials m WHERE m.code = picked;
END;
$$;

-- ---------------------------------------------------------------------------
-- mine, from 0063_mining
-- ---------------------------------------------------------------------------
-- Mining yield, for the same reason.

CREATE OR REPLACE FUNCTION mine(p_player_id BIGINT)
RETURNS TABLE (
    material_code TEXT,
    material_name TEXT,
    rarity        TEXT,
    emoji         TEXT,
    ore_tier      SMALLINT,
    quantity      BIGINT,
    held          BIGINT,
    rich          BOOLEAN,
    exp_gained    BIGINT,
    level_after   SMALLINT,
    tier_cap      SMALLINT,
    deepest       SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    skill   SMALLINT;
    cap     SMALLINT;
    deep    SMALLINT;
    picked  TEXT;
    grade   SMALLINT;
    lo      NUMERIC := game_config_value('mine_yield_min');
    hi      NUMERIC := game_config_value('mine_yield_max');
    struck  BOOLEAN := random() < game_config_value('mine_rich_chance');
    amount  BIGINT;
    total   BIGINT;
    gained  BIGINT;
    lvl     SMALLINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    skill := profession_level(p_player_id, 'mining');
    cap   := mining_tier_cap(skill);

    SELECT max(o.tier) INTO deep
    FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = here;

    IF deep IS NULL THEN
        RAISE EXCEPTION 'there is no stone worth breaking in %', here
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT rv.material_code, o.tier INTO picked, grade
    FROM region_veins rv
    JOIN ores o ON o.material_code = rv.material_code
    WHERE rv.region_code = here AND o.tier <= cap
    ORDER BY -ln(random()) / rv.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'every vein here is deeper than you can work'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same additive stack as gathering. A Gu that finds more in a forage
    -- finds more in a seam; a second yield stat granted by nothing would be a
    -- word in the vocabulary with no speaker.
    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1)))
        * (1 + COALESCE((SELECT b.gathering_bonus FROM player_manual_bonuses b
                         WHERE b.player_id = p_player_id), 0)
             + player_stat(p_player_id, 'gathering_yield')
             + skill * game_config_value('mining_yield_per_level'))
    ));

    IF struck THEN
        amount := round(amount * game_config_value('mine_rich_multiplier'));
    END IF;

    total  := grant_material(p_player_id, picked, amount);

    gained := GREATEST(5, grade * game_config_value('mining_exp_per_tier'));
    lvl    := grant_profession_exp(p_player_id, 'mining', gained, TRUE);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, m.emoji, grade, amount, total, struck,
           gained, lvl, cap, deep
    FROM materials m WHERE m.code = picked;
END;
$$;
