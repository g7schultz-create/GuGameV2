-- 0071_the_conditional_half_of_the_vocabulary
--
-- Effects that only apply SOMETIMES, and the five functions that read them.
--
-- 0070 paid every body it could with the effects that already existed, and
-- left seventeen still owing a clause. Most of those clauses were never
-- waiting on a system - they were waiting on a WORD. "More damage to beasts",
-- "harder to hurt while mostly whole", "hits harder when it is going badly",
-- "a killing blow finds nothing there" are all conditions this engine can
-- already evaluate; there was simply no way to say them.
--
-- So ten more words, each with exactly one consumer, exactly as `gu_effects`
-- has said since 0036: "a new effect is a row plus one consumer, and it is
-- never a schema change." Nothing here is physique-specific. A Gu that hits
-- beasts harder, or a helm that steadies a guard, is now a row.
--
-- WHAT WAS DROPPED, and why, because deciding not to build something is worth
-- as much as building it:
--
--   Phoenix Rebirth's "on a kill, 5% battle Qi returned" is not built. A kill
--   ENDS the encounter in this engine, and battle Qi does not outlive it - so
--   the effect would fire into a pool that is about to be discarded. It stays
--   in `unmodelled` with that noted.
--
--   Celestial Emperor's "the lowest foundation stat gains 7%" is not built.
--   HP, defence and strength are on different scales - 120, 20 and 35 - so
--   "lowest" always means defence and the sentence stops meaning what it says.
--   It needs the comparison to be against the body's own multipliers, and that
--   is a decision about what the clause means rather than a missing consumer.
--
-- ONE THING FIXED IN PASSING. `battle_act`'s Observe ordered its reveal by
-- CASE interaction WHEN 'weakness' THEN 0 - and `creature_incoming_paths`
-- holds 'advantage', 'resistance' and 'immunity'. There is no 'weakness',
-- so the branch has never matched and Observe has been showing immunities
-- ahead of the thing you actually want to know since 0030.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Ten more words
-- ---------------------------------------------------------------------------

INSERT INTO gu_effects (code, name, description, cap, is_live, emoji, sort_order, step) VALUES
    ('beast_damage', 'Beast Slaying',
     'Harder against beasts, and only beasts. A rogue cultivator is unimpressed.',
     0.5000, TRUE, '🐗', 170, 0.0300),
    ('matchup_relief', 'Hard to Counter',
     'How much of a creature''s resistance to your Path it fails to bring to bear. An outright immunity still holds.',
     1.0000, TRUE, '🫥', 180, 0.0400),
    ('momentum', 'Momentum',
     'Damage that builds with every turn a fight lasts, up to a ceiling.',
     0.6000, TRUE, '📈', 190, 0.0040),
    ('wounded_power', 'Cornered Strength',
     'Damage while below half health. The worse it is going, the harder this lands.',
     1.0000, TRUE, '💢', 200, 0.0400),
    ('braced', 'Braced',
     'Damage turned aside while still mostly whole. It stops helping once you are not.',
     0.5000, TRUE, '🧱', 210, 0.0200),
    ('guard_qi', 'Recovering Guard',
     'Extra Qi returned by guarding, on top of what a guard already gives.',
     0.5000, TRUE, '🌊', 220, 0.0200),
    ('death_ward', 'Death Ward',
     'Chance that the first killing blow of a fight leaves you at one health instead.',
     1.0000, TRUE, '🕯️', 230, 0.0500),
    ('foresight', 'Foresight',
     'A creature''s weakness is legible on sight, without spending a turn to look.',
     1.0000, TRUE, '👁️', 240, 0.0500),
    ('pill_potency', 'Apothecary''s Body',
     'More out of every pill you take.',
     1.0000, TRUE, '🍯', 250, 0.0400),
    ('realm_tempering', 'Realm Tempering',
     'Physique XP granted by crossing a realm, measured in body levels.',
     2.0000, TRUE, '🏔️', 260, 0.0800);

INSERT INTO game_config (key, value, description) VALUES
    ('braced_hp_threshold', 60,
     'Percent of maximum health at or above which a braced body is still braced.'),
    ('damage_reduction_ceiling', 0.9,
     'Most of an incoming blow that reduction may turn aside, however the sources add up.');


-- ---------------------------------------------------------------------------
-- A ward is spent, so the fight has to remember spending it
-- ---------------------------------------------------------------------------
-- On the combatant rather than on the player: it resets when a fight opens
-- because a new row is what opening a fight means, and nothing has to
-- remember to clear it.

ALTER TABLE battle_combatants
    ADD COLUMN ward_used BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN battle_combatants.ward_used IS
    'Whether the death ward has already fired in this fight. Per combatant, so it clears itself.';


-- ---------------------------------------------------------------------------
-- compute_technique_damage, from 0008_damage_pipeline
-- ---------------------------------------------------------------------------
-- Beast slaying and counter-resistance. Here rather than in `battle_act`
-- so that /damage's preview and what actually happens cannot disagree.

CREATE OR REPLACE FUNCTION compute_technique_damage(
    p_attacker_player_id  BIGINT,
    p_technique_id        BIGINT,
    p_defender_species_id BIGINT,
    p_external_multiplier NUMERIC DEFAULT 1,
    p_defense             BIGINT  DEFAULT 0
) RETURNS TABLE (
    base_power       INTEGER,
    attainment_bonus NUMERIC,
    matchup_modifier NUMERIC,
    pre_defense      NUMERIC,
    final_damage     BIGINT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    tech_base     INTEGER;
    attainment    NUMERIC;
    matchup       NUMERIC;
    scale         NUMERIC;
    ext           NUMERIC;
    raw           NUMERIC;
    after_defense NUMERIC;
BEGIN
    SELECT t.base_power INTO STRICT tech_base
    FROM techniques t
    WHERE t.technique_id = p_technique_id;

    attainment := technique_attainment_bonus(p_attacker_player_id, p_technique_id);
    matchup    := technique_matchup_modifier(p_technique_id, p_defender_species_id);

    -- A body that is hard to counter cleanly. Only a RESISTANCE is softened.
    -- Immunity is left exactly where it is: -1 is a rule about the Path rather
    -- than a large resistance, and a body arguing with it would be arguing
    -- with the matchup chart itself.
    IF matchup < 0 AND matchup > -1 THEN
        matchup := matchup * (1 - LEAST(1,
            player_stat(p_attacker_player_id, 'matchup_relief')));
    END IF;

    -- Added to the external stack rather than multiplied through it, because
    -- everything in this game that raises damage adds.
    ext := p_external_multiplier
         + CASE WHEN (SELECT cs.kind FROM creature_species cs
                      WHERE cs.species_id = p_defender_species_id) = 'beast'
                THEN player_stat(p_attacker_player_id, 'beast_damage')
                ELSE 0 END;

    IF tech_base <= 0 OR matchup = -1 THEN
        raw := 0;
    ELSE
        raw := tech_base * (1 + attainment) * (1 + matchup) * ext;
    END IF;

    SELECT value INTO scale FROM game_config WHERE key = 'defense_scale';
    after_defense := raw * scale / (scale + GREATEST(p_defense, 0));

    RETURN QUERY SELECT
        tech_base,
        attainment,
        matchup,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;

-- ---------------------------------------------------------------------------
-- battle_act, from 0066_gear_reaches_combat
-- ---------------------------------------------------------------------------
-- Five of the ten, and the Observe ordering fix.

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

    -- A killing blow lands where the body has already stopped being. Once,
    -- and the fight remembers that it was spent.
    IF dmg_in >= p_hp AND p_hp > 0 AND NOT me.ward_used
       AND random() < player_stat(me.player_id, 'death_ward') THEN
        dmg_in := p_hp - 1;
        warded := TRUE;
        said   := trim(both ' ' FROM said ||
                       ' The blow lands where you have already stopped being.');
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
    SET current_hp = p_hp, current_qi = qi, guarding = FALSE,
        ward_used = bc.ward_used OR warded
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
-- battle_open, from 0069_a_body_resists_and_holds
-- ---------------------------------------------------------------------------
-- Foresight. What Observe would have cost a turn to learn.

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
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp, current_qi)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'max_qi', max_qi),
            body.max_hp, body.current_hp, max_qi);

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp,
         intent_move_id)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, species.base_hp,
            roll_creature_intent(p_species_id));

    -- A body that reads a thing before it moves already knows the weakness,
    -- so it is written to the bestiary at the door rather than revealed by
    -- spending a turn on Observe. 'insight' is what that discovery is.
    IF player_stat(p_player_id, 'foresight') > 0 THEN
        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT p_player_id, p_species_id, cip.path_code, 'insight'
        FROM creature_incoming_paths cip
        WHERE cip.species_id = p_species_id AND cip.interaction = 'advantage'
        ON CONFLICT DO NOTHING;
    END IF;

    INSERT INTO player_active_battle (player_id, battle_id) VALUES (p_player_id, b_id);

    INSERT INTO player_bestiary (player_id, species_id, times_encountered)
    VALUES (p_player_id, p_species_id, 1)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            last_seen_at      = now();

    RETURN b_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- take_pill, from 0069_a_body_resists_and_holds
-- ---------------------------------------------------------------------------
-- Pill potency. `it` is a local copy of the row, so scaling it there
-- reaches every branch and touches neither the shelf nor the table.

CREATE OR REPLACE FUNCTION take_pill(p_player_id BIGINT, p_pill_id BIGINT)
RETURNS TABLE (
    pill_name  TEXT,
    kind       TEXT,
    granted    BIGINT,
    detail     TEXT,
    remaining  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     player_pills%ROWTYPE;
    before BIGINT;
    after  BIGINT;
    bonus  NUMERIC;
    banked NUMERIC;
    said   TEXT;
    left_n SMALLINT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    -- What this body gets out of the pill, which is not always what is in it.
    -- Scaled once on the local copy of the row, so all five branches below pay
    -- the adjusted dose without any of them having to remember to - and every
    -- one of them still measures what it actually banked, as 0058 insisted.
    it.magnitude := GREATEST(1, round(
        it.magnitude * (1 + player_stat(p_player_id, 'pill_potency'))));

    IF it.kind IN ('cultivation_rate', 'attainment_rate') THEN
        SELECT pt.rate_bonus INTO bonus FROM pill_tiers pt WHERE pt.tier = it.tier;
        banked := grant_boost(p_player_id, it.kind, bonus, it.magnitude);
        after  := it.magnitude;
        said   := percent_text(bonus) || ' for ' || round(it.magnitude)
                  || ' hours of cultivation, ' || round(banked) || ' banked in total.';

    ELSIF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The bottleneck refused the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        SELECT pp.physique_xp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        SELECT pp.physique_xp INTO after FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        after := after - before;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        SELECT COALESCE(a.insight, 0) INTO before
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        PERFORM grant_path_insight(p_player_id, it.path_code, it.magnitude, 0, 0);
        SELECT COALESCE(a.insight, 0) INTO after
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        after := after - before;
        said := 'Insight into ' || it.path_code || '.';

    ELSIF it.kind = 'healing' THEN
        SELECT pp.current_hp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The body could not hold all of it.'
                     ELSE 'Health, at once.' END;

    ELSE
        SELECT pc.qi INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        UPDATE player_cultivation pc
        SET qi = LEAST(
                player_max_qi(p_player_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id
        RETURNING pc.qi INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The aperture would not hold the rest.'
                     ELSE 'Battle Qi, at once.' END;
    END IF;

    IF it.quantity > 1 THEN
        UPDATE player_pills SET quantity = quantity - 1 WHERE pill_id = p_pill_id
        RETURNING quantity INTO left_n;
    ELSE
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
        left_n := 0;
    END IF;

    RETURN QUERY SELECT it.name, it.kind, GREATEST(0, COALESCE(after, 0)), said, left_n;
END;
$$;
