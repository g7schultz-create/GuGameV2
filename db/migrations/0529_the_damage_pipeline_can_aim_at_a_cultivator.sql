-- 0529_the_damage_pipeline_can_aim_at_a_cultivator
--
-- Phase 1 of the Venerable raid: before anybody can be knifed, one cultivator
-- has to be able to HURT another through the real pipeline. Today they cannot.
-- `battles.kind` has permitted `'duel'` since the table was written and not
-- one of the 13,718 battles in this database has ever had two players in it.
--
-- WHAT ALREADY WORKS, which is more than I expected:
--
--     battle_combatants   its constraints already allow a player on either
--                         side - `(player_id IS NULL) <> (species_id IS NULL)`,
--                         `side` 0 or 1, UNIQUE (battle_id, player_id)
--     player_path_resistance   what a cultivator's BODY and ATTAINMENT refuse,
--                         per Path. The defender's half of a matchup, already
--                         built, already used by the tournament
--     player_swing        crits, extra strikes, lifesteal, armour pen, the
--                         whole gu stack - and its target is already passed in
--                         as `p_target_hp` / `p_target_def` rather than looked
--                         up, so the target does not have to be a creature
--
-- WHAT WOULD HAVE SILENTLY RUINED IT. `compute_technique_damage` scales the
-- defence divisor by the DEFENDER'S CREATURE RANK:
--
--     their_rank := COALESCE(cs.immortal_rank, cs.rank, 1)
--     scale      := defense_scale * per_rank ^ (their_rank - 1)
--     after      := raw * scale / (scale + defence)
--
-- A cultivator has no `creature_species` row, so `their_rank` falls to 1 and
-- the divisor sits at the rank 1 scale of 60 - against a Venerable's defence,
-- which is in the billions. `60 / (60 + 2e9)` is zero to nine places, so
-- EVERY DUEL IN THE GAME WOULD HAVE LANDED FOR EXACTLY 1. That is the
-- "immunity by rank 5" the function's own comment warns about, arriving by a
-- different door. The probe below demonstrates it rather than describing it.
--
-- SO A DUEL GETS ITS OWN DAMAGE FUNCTION, not a branch inside the creature
-- one. Three things differ and all three are about what a cultivator IS:
--
--     the matchup   read off `player_path_resistance` weighted by the
--                   technique's own typing, where a creature uses
--                   `creature_incoming_paths`
--     beast_damage  not applied - a cultivator is not a beast
--     the scale     `player_standing`, where a creature uses its own rank.
--                   This is the fix above
--
-- AND `player_swing` LEARNS ONE OPTIONAL ARGUMENT rather than being copied.
-- Eleven functions call it and it is the one place that knows what a blow
-- costs; a `duel_swing` beside it would be a second definition of crits,
-- strikes and lifesteal to keep in step for ever. Adding a parameter means
-- DROP and CREATE - a defaulted 11th argument would otherwise be ambiguous
-- against the 10-argument version and every existing call would fail - so the
-- body is LIFTED, patched on asserted anchors, and reinstalled. Nothing is
-- retyped. No view depends on either function, and the eleven callers resolve
-- by name at runtime.
--
-- The pet gets the same two fixes, because a cultivator who paid for a beast
-- should not find it absent from the one fight that matters, and `pet_blow`
-- carries the identical rank-1 divisor fault.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What a blow is worth against a cultivator
-- ---------------------------------------------------------------------------

CREATE FUNCTION compute_duel_damage(
    p_attacker_player_id  BIGINT,
    p_technique_id        BIGINT,
    p_defender_player_id  BIGINT,
    p_external_multiplier NUMERIC DEFAULT 1,
    p_defense             BIGINT  DEFAULT 0)
RETURNS TABLE (base_power BIGINT, attainment_bonus NUMERIC, matchup_modifier NUMERIC,
               pre_defense NUMERIC, final_damage BIGINT, body_power BIGINT)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    tech_base     BIGINT;
    thews         BIGINT;
    attainment    NUMERIC;
    matchup       NUMERIC;
    scale         NUMERIC;
    raw           NUMERIC;
    their_rank    SMALLINT;
    after_defense NUMERIC;
BEGIN
    -- Deliberately the same shape as `compute_technique_damage`, term for
    -- term, so the two can be read side by side and only the three
    -- differences stand out. The columns match it exactly too, because
    -- `player_swing` reads the result into one RECORD either way.
    SELECT t.base_power INTO STRICT tech_base
    FROM techniques t WHERE t.technique_id = p_technique_id;

    tech_base := technique_power_for(p_attacker_player_id, p_technique_id);

    thews := GREATEST(0, round(
        COALESCE((SELECT pp.strength FROM player_physique pp
                  WHERE pp.player_id = p_attacker_player_id), 0)
        * game_config_value('physique_strength_damage')))::bigint;

    attainment := technique_attainment_bonus(p_attacker_player_id, p_technique_id);

    -- DIFFERENCE 1. A cultivator has no `creature_incoming_paths` row, so the
    -- matchup is what their body and their understanding REFUSE, weighted by
    -- the technique's own typing - which is what `snapshot_blow` has done for
    -- the tournament since it was written. Negated, because the term below is
    -- `(1 + matchup)` and resistance takes away.
    --
    -- It can never reach immunity: every one of the 396 techniques has path
    -- weights summing to exactly 1, and `player_path_resistance` is capped at
    -- `physique_resistance_cap` (0.75), so the worst case is -0.75.
    matchup := -COALESCE((
        SELECT sum(tp.weight
                   * player_path_resistance(p_defender_player_id, tp.path_code))
        FROM technique_paths tp
        WHERE tp.technique_id = p_technique_id), 0);

    -- Softened by the attacker's relief, exactly as a creature's resistance
    -- is. This is the only place `matchup_relief` has ever meant anything in
    -- a fight between cultivators.
    IF matchup < 0 AND matchup > -1 THEN
        matchup := matchup * (1 - LEAST(1,
            player_stat(p_attacker_player_id, 'matchup_relief')));
    END IF;

    -- DIFFERENCE 2. No `beast_damage`. A cultivator is not a beast, and a
    -- worm that promises more against beasts must not quietly pay out against
    -- a rival.
    IF tech_base <= 0 THEN
        raw := 0;
    ELSE
        raw := (tech_base + thews) * (1 + attainment) * (1 + matchup)
               * p_external_multiplier;
    END IF;

    -- DIFFERENCE 3, AND THE ONE THAT MATTERS. The standing they fight at,
    -- where a creature uses its own rank. Left at the creature default of 1
    -- this divisor is 60 against a defence in the billions, and every duel in
    -- the game lands for exactly 1.
    their_rank := COALESCE(player_standing(p_defender_player_id), 1);

    scale := game_config_value('defense_scale')
             * power(game_config_value('creature_defense_scale_per_rank'),
                     GREATEST(0, their_rank - 1));

    after_defense := raw * scale / (scale + GREATEST(p_defense, 0));

    RETURN QUERY SELECT
        tech_base,
        attainment,
        matchup,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END,
        thews;
END;
$fn$;

COMMENT ON FUNCTION compute_duel_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'What one cultivator''s technique is worth against another. The sibling of compute_technique_damage, differing only in what a cultivator IS: the matchup comes from player_path_resistance rather than creature_incoming_paths, beast_damage does not apply, and the defence divisor scales with player_standing rather than a creature rank - without which every duel lands for exactly 1.';


-- ---------------------------------------------------------------------------
-- The beast beside them, which carries the same fault
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('pet_blow(bigint,bigint,bigint)'::regprocedure);

    one := 'public.pet_blow(p_beast_id bigint, p_defender_species_id bigint, p_defense bigint DEFAULT 0)';
    IF strpos(src, one) = 0 THEN
        RAISE EXCEPTION 'pet_blow does not have the signature I read';
    END IF;
    src := replace(src, one,
        'public.pet_blow(p_beast_id bigint, p_defender_species_id bigint, '
        || 'p_defense bigint DEFAULT 0, p_defender_player_id bigint DEFAULT NULL)');

    -- The matchup, when the thing in front of it is a cultivator.
    one := '    IF mine IS NOT NULL THEN' || chr(10) ||
           '        SELECT COALESCE(mi.damage_modifier, 0) INTO matchup';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the pet matchup block is not where I read it';
    END IF;
    src := replace(src, one,
        '    IF mine IS NOT NULL AND p_defender_player_id IS NOT NULL THEN' || chr(10) ||
        '        -- What a cultivator refuses, where a creature offers an' || chr(10) ||
        '        -- incoming-path row. Negated for the same reason as 0529''s' || chr(10) ||
        '        -- duel damage: the term below adds the modifier.' || chr(10) ||
        '        matchup := -player_path_resistance(p_defender_player_id, mine);' || chr(10) ||
        '    ELSIF mine IS NOT NULL THEN' || chr(10) ||
        '        SELECT COALESCE(mi.damage_modifier, 0) INTO matchup');

    -- The divisor. `COALESCE(cs.rank, 1)` is 1 for a cultivator, and 60
    -- against a Venerable's defence is nothing.
    one := '    SELECT COALESCE(cs.rank, 1) INTO their' || chr(10) ||
           '    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the pet defence scale is not where I read it';
    END IF;
    src := replace(src, one,
        '    IF p_defender_player_id IS NOT NULL THEN' || chr(10) ||
        '        their := COALESCE(player_standing(p_defender_player_id), 1);' || chr(10) ||
        '    ELSE' || chr(10) ||
        '        SELECT COALESCE(cs.rank, 1) INTO their' || chr(10) ||
        '        FROM creature_species cs WHERE cs.species_id = p_defender_species_id;' || chr(10) ||
        '    END IF;');

    -- A defaulted fourth argument would be ambiguous against the three
    -- argument version, so the old one goes before the new one arrives.
    DROP FUNCTION pet_blow(bigint, bigint, bigint);
    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the one function that knows what a blow costs
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint)'::regprocedure);

    one := 'p_scope_id bigint DEFAULT NULL::bigint)';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'player_swing does not end its argument list where I read it';
    END IF;
    src := replace(src, one,
        'p_scope_id bigint DEFAULT NULL::bigint, '
        || 'p_defender_player_id bigint DEFAULT NULL::bigint)');

    one := '        SELECT * INTO hit FROM compute_technique_damage(' || chr(10) ||
           '            p_player_id, p_technique_id, p_species_id, external, eff_def);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the damage call in player_swing is not where I read it';
    END IF;
    src := replace(src, one,
        '        -- AIMED AT A CULTIVATOR, when there is one. Everything around' || chr(10) ||
        '        -- this loop - the strikes, the crit, the lifesteal, the' || chr(10) ||
        '        -- armour pen, the whole gu stack - is the same either way,' || chr(10) ||
        '        -- which is the entire reason this takes a parameter instead' || chr(10) ||
        '        -- of there being a second copy of it called duel_swing.' || chr(10) ||
        '        IF p_defender_player_id IS NOT NULL THEN' || chr(10) ||
        '            SELECT * INTO hit FROM compute_duel_damage(' || chr(10) ||
        '                p_player_id, p_technique_id, p_defender_player_id,' || chr(10) ||
        '                external, eff_def);' || chr(10) ||
        '        ELSE' || chr(10) ||
        '            SELECT * INTO hit FROM compute_technique_damage(' || chr(10) ||
        '                p_player_id, p_technique_id, p_species_id, external, eff_def);' || chr(10) ||
        '        END IF;');

    one := '        beast_hit := pet_blow(beast, p_species_id, eff_def);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the pet call in player_swing is not where I read it';
    END IF;
    src := replace(src, one,
        '        beast_hit := pet_blow(beast, p_species_id, eff_def,' || chr(10) ||
        '                              p_defender_player_id);');

    DROP FUNCTION player_swing(
        bigint, bigint, bigint, bigint, bigint, bigint, bigint, integer, text, bigint);
    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Demonstrate the fault, then that it is gone, then that nothing else moved
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a      BIGINT;
    v_b      BIGINT;
    v_tech   BIGINT;
    v_def    BIGINT;
    v_rank1  BIGINT;
    v_stood  BIGINT;
    v_swung  RECORD;
    v_bad    TEXT;
    v_n      INTEGER;
    v_scale  NUMERIC;
BEGIN
    -- Every caller still resolves. A signature change that left one of them
    -- calling a function that no longer exists would only be found in
    -- somebody's fight.
    --
    -- NAMED, NOT COUNTED. My first draft counted functions whose source
    -- mentions `player_swing` and expected eleven; it got twelve, because
    -- `compute_duel_damage`'s own comment says the word. A count cannot tell a
    -- call from a sentence.
    SELECT string_agg(x.name, ', ') INTO v_bad
    FROM (VALUES
        ('battle_act'), ('creature_body_for'), ('delve_act'),
        ('delve_rehearse'), ('dungeon_rehearse'), ('dungeon_resolve_round'),
        ('horde_gauntlet_swing'), ('horde_strike'), ('strike_boss'),
        ('trial_rehearse'), ('trial_resolve_round')
    ) AS x(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = x.name
          AND p.prosrc ~ 'player_swing');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lost their swing: %', v_bad;
    END IF;

    SELECT string_agg(x.name, ', ') INTO v_bad
    FROM (VALUES ('boss_hp_pool'), ('horde_walker_burst')) AS x(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = x.name
          AND p.prosrc ~ 'pet_blow');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lost their pet: %', v_bad;
    END IF;

    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'player_swing') <> 1 THEN
        RAISE EXCEPTION
            'player_swing is overloaded, so a ten-argument call is ambiguous';
    END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'pet_blow') <> 1 THEN
        RAISE EXCEPTION 'pet_blow is overloaded';
    END IF;

    BEGIN
        -- Two cultivators at the top of the realm ladder, which is where the
        -- first duels will actually happen.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-992, 'duel-a') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-991, 'duel-b') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_b, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;

        -- A body in proportion to rank 18, taken off somebody who has one
        -- rather than invented.
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_a, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ORDER BY pp.defense DESC LIMIT 1;

        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_b, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp WHERE pp.player_id = v_a;

        SELECT pp.defense INTO v_def FROM player_physique pp WHERE pp.player_id = v_b;
        IF COALESCE(v_def, 0) < 1000 THEN
            RAISE EXCEPTION
                'the probe defender carries only % defence, which proves nothing',
                v_def;
        END IF;

        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech) ON CONFLICT DO NOTHING;

        -- 1. THE FAULT. Priced with the divisor a cultivator would have got
        -- from the creature path, where their rank reads as 1.
        -- `pre_defense` IS the raw figure, so this is the same blow priced
        -- with the other divisor rather than an estimate of it.
        v_scale := game_config_value('defense_scale');
        v_rank1 := GREATEST(1, round(
            (SELECT h.pre_defense
             FROM compute_duel_damage(v_a, v_tech, v_b, 1, v_def) h)
            * v_scale / (v_scale + v_def)))::bigint;

        -- 2. AND WHAT IT ACTUALLY LANDS FOR, with the divisor on standing.
        SELECT * INTO v_swung FROM compute_duel_damage(v_a, v_tech, v_b, 1, v_def);
        v_stood := v_swung.final_damage;

        -- Measured against a real rank 18 body rather than asserted: 7.08e12
        -- health behind 7.50e11 defence. The creature divisor leaves a blow of
        -- 1,352 - about five BILLION rounds to fell them - where the standing
        -- divisor lands 9.78e12. A factor of seven billion. "Exactly 1" was my
        -- first claim and it was wrong in magnitude; the probe now asserts the
        -- ratio, which is the part that matters and the part I measured.
        IF v_stood / GREATEST(v_rank1, 1) < 1000000 THEN
            RAISE EXCEPTION
                'the two divisors differ by only %x (% against %), so this probe is not demonstrating the fault',
                v_stood / GREATEST(v_rank1, 1), v_stood, v_rank1;
        END IF;

        IF (SELECT pp.max_hp FROM player_physique pp WHERE pp.player_id = v_b)
           / GREATEST(v_rank1, 1) < 1000000 THEN
            RAISE EXCEPTION
                'the creature divisor would already have been survivable, at % rounds',
                (SELECT pp.max_hp FROM player_physique pp WHERE pp.player_id = v_b)
                / GREATEST(v_rank1, 1);
        END IF;

        RAISE NOTICE
            'a duel blow lands % where the creature divisor gave % - a factor of %',
            v_stood, v_rank1, v_stood / GREATEST(v_rank1, 1);

        -- 3. THE MATCHUP IS THE DEFENDER'S OWN. Resistance must reduce it.
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        SELECT v_b, tp.path_code, 90000,
               (SELECT max(t.tier) FROM attainment_tiers t WHERE t.resistance_bonus > 0)
        FROM technique_paths tp WHERE tp.technique_id = v_tech
        ON CONFLICT (player_id, path_code) DO UPDATE
        SET tier = EXCLUDED.tier, insight = EXCLUDED.insight;

        IF (SELECT h.matchup_modifier
            FROM compute_duel_damage(v_a, v_tech, v_b, 1, v_def) h) >= 0 THEN
            RAISE EXCEPTION
                'a cultivator who resists this Path takes no less for it';
        END IF;
        IF (SELECT h.final_damage
            FROM compute_duel_damage(v_a, v_tech, v_b, 1, v_def) h) >= v_stood THEN
            RAISE EXCEPTION 'resistance did not reduce the blow';
        END IF;

        -- 4. AND NOTHING IS ADDED TO THE EXTERNAL STACK. The creature path
        -- adds `beast_damage` to it when the defender is a beast; a worm that
        -- promises more against beasts must not quietly pay out against a
        -- rival.
        --
        -- Asserted from the returned columns rather than by grepping the
        -- source: my first version searched the body for "beast_damage" and
        -- matched the COMMENT saying there isn't any. An external multiplier
        -- of 1 must come out the other side as exactly 1, which it only does
        -- if nothing was added to it.
        SELECT * INTO v_swung FROM compute_duel_damage(v_a, v_tech, v_b, 1, v_def);
        IF abs(v_swung.pre_defense
               - (v_swung.base_power + v_swung.body_power)
                 * (1 + v_swung.attainment_bonus)
                 * (1 + v_swung.matchup_modifier)) > 1 THEN
            RAISE EXCEPTION
                'something was added to the external stack: raw is % against a formula of %',
                v_swung.pre_defense,
                (v_swung.base_power + v_swung.body_power)
                * (1 + v_swung.attainment_bonus)
                * (1 + v_swung.matchup_modifier);
        END IF;

        -- 5. `player_swing` reaches it, which is what every lane will use.
        SELECT * INTO v_swung FROM player_swing(
            v_a, v_tech, NULL::bigint,
            (SELECT pp.max_hp FROM player_physique pp WHERE pp.player_id = v_b),
            v_def, NULL, NULL, 0, NULL, NULL, v_b);
        IF COALESCE(v_swung.dealt, 0) <= 1 THEN
            RAISE EXCEPTION
                'player_swing lands % on a cultivator', v_swung.dealt;
        END IF;
        RAISE NOTICE 'player_swing deals % in % strike(s) to a peer',
            v_swung.dealt, v_swung.strikes;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 6. THE OLD CALL STILL WORKS, which is the whole risk of a signature
    -- change. Eleven functions call `player_swing` with ten arguments and two
    -- call `pet_blow` with three; if the defaulted argument broke either
    -- shape, it would only be found in somebody's fight.
    --
    -- Driven rather than grepped: my first draft of this probe compared
    -- `compute_technique_damage` against ITSELF and could not fail, which is
    -- the same worthless assertion 0510 shipped.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-990, 'pve-probe') RETURNING player_id INTO v_a;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_a, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ORDER BY pp.strength DESC LIMIT 1;

        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech) ON CONFLICT DO NOTHING;

        -- Ten positional arguments, exactly as the eleven callers pass them.
        SELECT * INTO v_swung FROM player_swing(
            v_a, v_tech,
            (SELECT cs.species_id FROM creature_species cs
             WHERE cs.kind = 'beast' ORDER BY cs.species_id LIMIT 1),
            1000000000000::bigint, 500::bigint, NULL, NULL, 0, NULL, NULL);
        IF COALESCE(v_swung.dealt, 0) <= 0 THEN
            RAISE EXCEPTION
                'a ten-argument player_swing against a creature deals %',
                v_swung.dealt;
        END IF;

        -- Three positional arguments, as `boss_hp_pool` and
        -- `horde_walker_burst` pass them.
        IF pet_blow(
               (SELECT b.beast_id FROM player_beasts b ORDER BY b.beast_id LIMIT 1),
               (SELECT cs.species_id FROM creature_species cs
                WHERE cs.kind = 'beast' ORDER BY cs.species_id LIMIT 1),
               500::bigint) IS NULL THEN
            RAISE EXCEPTION 'a three-argument pet_blow returned NULL';
        END IF;

        RAISE NOTICE
            'the creature lane still deals % through the ten-argument call',
            v_swung.dealt;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'the pipeline can aim at a cultivator, and the eleven creature lanes are untouched';
END;
$probe$;
