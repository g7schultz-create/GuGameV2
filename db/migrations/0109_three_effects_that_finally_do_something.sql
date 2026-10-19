-- 0109_three_effects_that_finally_do_something
--
-- `heal`, `shield` and `suppression` have carried `is_live FALSE` since 0036.
-- They render on a Gu with the italics that mean "this is decoration", and
-- their own descriptions say why: no shield system, nothing heals mid-battle,
-- and creatures had no abilities to interfere with.
--
-- Two of those three reasons have expired. 0037 gave creatures moves and an
-- intent rolled each turn, so there is something to suppress; the fight has
-- had a turn structure since 0030, so there is somewhere for healing to land.
-- Only the shield genuinely had nowhere to live, and it needs one column.
--
-- WHAT EACH ONE NOW MEANS.
--
--   Shield      a pool of `magnitude` of your maximum HP, granted once when
--               the fight opens. Damage comes off it before it comes off you,
--               and what it spends is gone for the rest of the fight.
--
--   Restoration `magnitude` of your maximum HP returned each turn you act.
--               Per turn rather than per second, because a fight here is
--               counted in turns.
--
--   Suppression the chance that the move the creature had chosen for this
--               turn never comes out.
--
-- All three read through `player_stat`, so a Gu, a piece of gear, a physique
-- or a root can grant them without any of those knowing about this file.
--
-- WHY IT MATTERS THAT THEY WERE FALSE. An effect that renders and does
-- nothing is worse than one that is missing: Moonshadow Gu has advertised
-- 10% Suppression to everybody who ever looked at it, and delivered nothing.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE battle_combatants
    ADD COLUMN shield BIGINT NOT NULL DEFAULT 0 CHECK (shield >= 0);

COMMENT ON COLUMN battle_combatants.shield IS
    'What is left of the pool that eats damage before health does. Set when the fight opens and spent down; never refilled mid-fight.';


-- ---------------------------------------------------------------------------
-- battle_open, which now hands out the shield
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION battle_shield_for(p_player_id BIGINT, p_max_hp BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(0, floor(p_max_hp * player_stat(p_player_id, 'shield')))::bigint;
$$;

COMMENT ON FUNCTION battle_shield_for(BIGINT, BIGINT) IS
    'The pool a cultivator walks into a fight carrying. A fraction of the body, so it grows with the body.';


UPDATE gu_effects SET is_live = TRUE, description = CASE code
    WHEN 'shield' THEN 'A pool of your maximum health that absorbs damage before you do, granted once at the start of a fight.'
    WHEN 'heal' THEN 'A fraction of your maximum health returned every turn you act.'
    WHEN 'suppression' THEN 'The chance a creature''s chosen move never comes out.'
    ELSE description
END
WHERE code IN ('heal', 'shield', 'suppression');


-- ---------------------------------------------------------------------------
-- battle_open, which hands the shield out at the door
-- ---------------------------------------------------------------------------
-- Lifted from 0075 with one column added to the cultivator's row.

CREATE OR REPLACE FUNCTION battle_open(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    species  creature_species%ROWTYPE;
    body     player_physique%ROWTYPE;
    max_qi   BIGINT;
    b_id     BIGINT;
BEGIN
    SELECT * INTO STRICT species FROM creature_species WHERE species_id = p_species_id;
    SELECT * INTO STRICT body FROM player_physique WHERE player_id = p_player_id;

    IF body.current_hp <= 0 THEN
        RAISE EXCEPTION 'no strength left to fight' USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_active_battle WHERE player_id = p_player_id) THEN
        RAISE EXCEPTION 'already in a battle' USING ERRCODE = 'check_violation';
    END IF;

    max_qi := player_max_qi(p_player_id);

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('pve', 'active', floor(random() * 9223372036854775806)::bigint)
    RETURNING battles.battle_id INTO b_id;

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp,
         current_qi, shield)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'max_qi', max_qi),
            body.max_hp, body.current_hp, max_qi,
            -- Granted once, at the door. A shield that refilled every turn
            -- would be damage reduction wearing a different hat.
            battle_shield_for(p_player_id, body.max_hp));

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp,
         intent_move_id)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, species.base_hp,
            roll_creature_intent(p_species_id));

    INSERT INTO player_active_battle (player_id, battle_id) VALUES (p_player_id, b_id);

    INSERT INTO player_bestiary (player_id, species_id, times_encountered)
    VALUES (p_player_id, p_species_id, 1)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            last_seen_at      = now();

    -- A body that reads a thing before it moves already knows the weakness, so
    -- it is written down at the door rather than revealed by spending a turn
    -- on Observe. 'insight' is what that kind of discovery is.
    --
    -- AFTER the bestiary row, and that is the whole point of this migration:
    -- `player_bestiary_paths` carries a COMPOSITE foreign key to
    -- (player_id, species_id) in `player_bestiary`, so a path recorded for a
    -- creature the player has no bestiary entry for is a foreign key
    -- violation - and this runs inside battle_open, so the violation is not a
    -- missing note. It is a body that cannot start a fight.
    IF random() < player_stat(p_player_id, 'foresight') THEN
        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT p_player_id, p_species_id, cip.path_code, 'insight'
        FROM creature_incoming_paths cip
        WHERE cip.species_id = p_species_id AND cip.interaction = 'advantage'
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN b_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- battle_act, with the three of them read
-- ---------------------------------------------------------------------------
-- Lifted from 0071. The strike, the Qi, the matchups, the ward and the
-- bestiary are all untouched; what is added is a heal after your turn, a
-- suppression roll before the creature's, and a shield in front of your health.

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
    shielded   BIGINT := 0;
    soaked     BIGINT := 0;
    mended     BIGINT := 0;
    hushed     BOOLEAN := FALSE;
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
    mom        NUMERIC := 0;
    wounded    NUMERIC := 0;
    warded     BOOLEAN := FALSE;
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

        -- Momentum builds with the fight and a cornered body hits harder.
        -- Both join the external stack, which is a sum.
        mom := player_stat(me.player_id, 'momentum');
        IF mom > 0 THEN
            mom := LEAST((SELECT ef.cap FROM gu_effects ef WHERE ef.code = 'momentum'),
                         mom * GREATEST(0, fight.turn_number - 1));
        END IF;
        IF p_hp * 2 <= me.max_hp THEN
            wounded := player_stat(me.player_id, 'wounded_power');
        END IF;

        external := player_external_multiplier(me.player_id, p_technique_id)
                    + mom + wounded;

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

        -- Restoration. A fraction of the whole body, once per turn taken,
        -- which is what "healing over a fight" has to mean in a fight that
        -- is counted in turns rather than seconds.
        IF player_stat(me.player_id, 'heal') > 0 THEN
            mended := LEAST(
                floor(me.max_hp * player_stat(me.player_id, 'heal')),
                GREATEST(0, me.max_hp - p_hp)
            );
            p_hp := p_hp + mended;
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
                    qi + ceil((game_config_value('guard_qi_restore')
                               + player_stat(me.player_id, 'guard_qi'))
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
                     WHEN 'advantage' THEN 0 WHEN 'resistance' THEN 1 ELSE 2 END,
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

    -- Suppression. `roll_creature_intent` chose a move for this turn, and
    -- this is the chance it never comes out - which is the only honest
    -- reading of "interferes with an enemy's abilities" now that creatures
    -- have abilities to interfere with.
    hushed := move.move_id IS NOT NULL
              AND random() < player_stat(me.player_id, 'suppression');

    guarded := (p_action = 'guard');
    evade   := player_stat(me.player_id, 'dodge');
    reduce  := player_stat(me.player_id, 'damage_reduction');

    -- Some bodies are hardest to hurt while they are still mostly whole.
    IF p_hp * 100 >= me.max_hp * game_config_value('braced_hp_threshold') THEN
        reduce := reduce + player_stat(me.player_id, 'braced');
    END IF;
    reduce := LEAST(game_config_value('damage_reduction_ceiling'), reduce);

    SELECT * INTO hit FROM compute_creature_damage(
        it.species_id, me.player_id,
        COALESCE(move.power_multiplier, 1),
        (me.snapshot ->> 'defense')::bigint);

    dmg_in := CASE WHEN hushed THEN 0 ELSE hit.final_damage END;

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

    -- A killing blow lands where the body has already stopped being. Once,
    -- and the fight remembers that it was spent.
    IF dmg_in >= p_hp AND p_hp > 0 AND NOT me.ward_used
       AND random() < player_stat(me.player_id, 'death_ward') THEN
        dmg_in := p_hp - 1;
        warded := TRUE;
        said   := trim(both ' ' FROM said ||
                       ' The blow lands where you have already stopped being.');
    END IF;

    -- Shield. What is left of the pool eats the blow first, and only what
    -- it cannot hold reaches the body. Spent for the rest of the fight, so
    -- it is a thing you are given once rather than every turn.
    IF dmg_in > 0 AND me.shield > 0 THEN
        soaked   := LEAST(me.shield, dmg_in);
        dmg_in   := dmg_in - soaked;
        shielded := me.shield - soaked;
    ELSE
        shielded := me.shield;
    END IF;

    p_hp := GREATEST(0, p_hp - dmg_in);

    INSERT INTO battle_actions
        (battle_id, actor_no, turn_number, action, technique_name, target_no,
         base_power, attainment_bonus, matchup_modifier, damage, detail)
    VALUES (p_battle_id, 1, fight.turn_number, 'technique',
            COALESCE(move.name, species.name), 0,
            hit.base_power, hit.attainment_bonus, hit.matchup_modifier, dmg_in,
            jsonb_build_object('guarded', guarded, 'dodged', was_dodged,
                               'reduction', reduce, 'target_hp_after', p_hp,
                               'suppressed', hushed, 'absorbed', soaked,
                               'mended', mended));

    UPDATE battle_combatants bc
    SET current_hp = p_hp, current_qi = qi, guarding = FALSE,
        ward_used = bc.ward_used OR warded,
        shield = shielded
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
    'One exchange. Since 0109 it also reads shield, heal and suppression, which had been rendering on Gu and doing nothing since 0036.';
