-- 0299_the_two_choke_points_honour_a_lasting_effect
--
-- 0298 built somewhere to put a buff. This is the pair of functions that read
-- it: `player_swing` for anything that changes what you deal, `player_take`
-- for anything that changes what you suffer. Every lane in the game goes
-- through those two, so wiring them here is what makes an effect real
-- everywhere at once rather than five times over.
--
-- THE SCOPE ARRIVES AS TWO NEW ARGUMENTS, BOTH DEFAULTING TO NULL. A caller
-- that says nothing gets exactly the behaviour it had before - no lookup, no
-- effects, not even a query. That is deliberate: this migration changes the
-- shape of the choke points and NOTHING about any fight, so if something is
-- wrong here it is wrong immediately and in isolation, rather than tangled up
-- with the lane wiring that follows.
--
-- WHY NOT `CREATE OR REPLACE`. Adding a parameter makes an overload, not a
-- replacement - the old eight-argument `player_swing` would still be sitting
-- there, still be what every existing caller resolves to, and the new one
-- would be dead code that looked live. Both are dropped and rebuilt from
-- their own lifted source instead.
--
-- AND BOTH ARE LIFTED, NOT RETYPED. `pg_get_functiondef`, asserted replaces,
-- EXECUTE. `player_swing` is the single function every combat lane in this
-- game swings through, and the one time I retyped it instead of lifting it,
-- it took live combat down for four minutes.
--
-- WHERE EACH EFFECT LANDS:
--
--   attack_up   onto `external`, the additive stack momentum and a cornered
--               body already join. Multiplying it in would have compounded
--               with those two; everything that raises damage here adds.
--   defence_up  onto `reduce`, before the existing damage_reduction_ceiling
--               clamps it - so it is capped by its own kind AND by the same
--               0.9 wall every other source of reduction hits.
--   block_up    onto the Guard fraction, and only on the branch where the
--               cultivator actually guarded.
--
-- `regen` and `taunt` are not read here. Neither is about one blow: regen
-- belongs to the end of a round and taunt to choosing a victim, and both of
-- those live in the lanes.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What you deal
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    sig    TEXT := 'p_turn integer DEFAULT 0)';
    stack  TEXT :=
'    external := player_external_multiplier(p_player_id, p_technique_id)
                + mom + wounded;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'player_swing';

    IF body IS NULL THEN
        RAISE EXCEPTION 'player_swing is missing';
    END IF;

    IF (length(body) - length(replace(body, sig, ''))) / length(sig) <> 1 THEN
        RAISE EXCEPTION 'player_swing: the signature anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, stack, ''))) / length(stack) <> 1 THEN
        RAISE EXCEPTION 'player_swing: the external stack is not where it was';
    END IF;

    body := replace(body, sig,
        'p_turn integer DEFAULT 0, p_scope text DEFAULT NULL, ' ||
        'p_scope_id bigint DEFAULT NULL)');

    body := replace(body, stack,
'    external := player_external_multiplier(p_player_id, p_technique_id)
                + mom + wounded;

    -- Anything a technique rallied this fight with. Added rather than
    -- multiplied, because momentum and a cornered body are already sitting
    -- on this same stack and compounding the three would be a different
    -- game. A caller that passes no scope pays for no lookup.
    IF p_scope IS NOT NULL AND p_scope_id IS NOT NULL THEN
        external := external
                  + effect_value(p_scope, p_scope_id, p_player_id, ''attack_up'');
    END IF;');

    DROP FUNCTION player_swing(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, INTEGER);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- What you suffer
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body  TEXT;
    sig   TEXT := 'p_may_ward boolean DEFAULT false)';
    ward  TEXT := '    reduce := LEAST(game_config_value(''damage_reduction_ceiling''), reduce);';
    guard TEXT := '            dmg := floor(dmg * (1 - game_config_value(''guard_damage_reduction'')));';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'player_take';

    IF body IS NULL THEN
        RAISE EXCEPTION 'player_take is missing';
    END IF;

    IF (length(body) - length(replace(body, sig, ''))) / length(sig) <> 1 THEN
        RAISE EXCEPTION 'player_take: the signature anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, ward, ''))) / length(ward) <> 1 THEN
        RAISE EXCEPTION 'player_take: the reduction ceiling is not where it was';
    END IF;
    IF (length(body) - length(replace(body, guard, ''))) / length(guard) <> 1 THEN
        RAISE EXCEPTION 'player_take: the guard line is not where it was';
    END IF;

    body := replace(body, sig,
        'p_may_ward boolean DEFAULT false, p_scope text DEFAULT NULL, ' ||
        'p_scope_id bigint DEFAULT NULL)');

    -- Before the ceiling, so a warded cultivator is still held to the same
    -- 0.9 wall as one in very good armour.
    body := replace(body, ward,
'    IF p_scope IS NOT NULL AND p_scope_id IS NOT NULL THEN
        reduce := reduce
                + effect_value(p_scope, p_scope_id, p_player_id, ''defence_up'');
    END IF;
' || ward);

    body := replace(body, guard,
'            dmg := floor(dmg * (1 - LEAST(0.95,
                      game_config_value(''guard_damage_reduction'')
                      + CASE WHEN p_scope IS NULL OR p_scope_id IS NULL THEN 0
                             ELSE effect_value(p_scope, p_scope_id,
                                               p_player_id, ''block_up'')
                        END)));');

    DROP FUNCTION player_take(BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, BOOLEAN);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- Both still answer the way every existing caller asks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    args TEXT;
BEGIN
    SELECT pg_get_function_identity_arguments(oid) INTO args
    FROM pg_proc WHERE proname = 'player_swing';
    IF args NOT LIKE '%p_scope text%' OR args NOT LIKE '%p_scope_id bigint%' THEN
        RAISE EXCEPTION 'player_swing did not take the scope: %', args;
    END IF;

    SELECT pg_get_function_identity_arguments(oid) INTO args
    FROM pg_proc WHERE proname = 'player_take';
    IF args NOT LIKE '%p_scope text%' OR args NOT LIKE '%p_scope_id bigint%' THEN
        RAISE EXCEPTION 'player_take did not take the scope: %', args;
    END IF;

    -- Exactly one of each: an overload left behind would be the real failure
    -- here, because every existing caller would go on resolving to it.
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'player_swing') <> 1 THEN
        RAISE EXCEPTION 'there is more than one player_swing';
    END IF;
    IF (SELECT count(*) FROM pg_proc WHERE proname = 'player_take') <> 1 THEN
        RAISE EXCEPTION 'there is more than one player_take';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- Silent without a scope, and worth something with one
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    sp    BIGINT;
    move  BIGINT;
    plain BIGINT;
    buffed BIGINT;
    took  RECORD;
    bare  BIGINT;
BEGIN
    SELECT p.player_id, dungeon_default_move(p.player_id) INTO who, move
    FROM players p
    WHERE p.deleted_at IS NULL AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can swing; the tests carry this';
        RETURN;
    END IF;

    SELECT species_id INTO sp FROM creature_species
    WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

    BEGIN
        -- Averaged, because a swing rolls criticals and extra strikes and one
        -- sample of each proves nothing. The first draft of this probe
        -- compared two single swings and duly reported a rallied blow of
        -- 117,100 against an unrallied 282,578 - which was variance, not a
        -- bug, and would have been a false alarm either way it fell.
        SELECT round(avg(d)) INTO plain FROM (
            SELECT (SELECT dealt FROM player_swing(
                        who, move, sp, 5000000000::bigint, 0::bigint)) AS d
            FROM generate_series(1, 40)) a;

        PERFORM effect_apply('battle', -2, who, 'attack_up', 0.50, 3);

        SELECT round(avg(d)) INTO buffed FROM (
            SELECT (SELECT dealt FROM player_swing(
                        who, move, sp, 5000000000::bigint, 0::bigint,
                        NULL, NULL, 0, 'battle', -2)) AS d
            FROM generate_series(1, 40)) a;

        IF buffed <= plain THEN
            RAISE EXCEPTION
                'a rally of half again averaged % against an unrallied %',
                buffed, plain;
        END IF;

        -- And the same swing WITHOUT the scope is untouched by it.
        SELECT round(avg(d)) INTO bare FROM (
            SELECT (SELECT dealt FROM player_swing(
                        who, move, sp, 5000000000::bigint, 0::bigint)) AS d
            FROM generate_series(1, 40)) a;

        IF bare >= buffed THEN
            RAISE EXCEPTION
                'a swing with no scope averaged % - as high as the rallied %',
                bare, buffed;
        END IF;

        -- A warded body suffers less.
        PERFORM effect_apply('battle', -2, who, 'defence_up', 0.40, 3);
        SELECT * INTO took FROM player_take(
            who, 1000000::bigint, 100000000::bigint, 100000000::bigint,
            FALSE, FALSE, 'battle', -2);

        IF took.reduced <= player_stat(who, 'damage_reduction') THEN
            RAISE EXCEPTION
                'a ward of 0.40 left reduction at %, the same as bare gear',
                took.reduced;
        END IF;

        RAISE NOTICE
            'rallied % against %, and a ward took reduction to %',
            buffed, plain, round(took.reduced, 3);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
