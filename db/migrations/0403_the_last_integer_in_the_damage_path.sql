-- 0403_the_last_integer_in_the_damage_path
--
-- pashu0 cannot attack. Every swing raises
--
--     value "3704409293" is out of range for type integer
--
-- which is Borrowed Flame's live power, and Discord shows it to him as
-- "GuV2 didn't respond in time" because the bot never gets to answer the
-- interaction at all. It reads as a timeout and is a crash.
--
-- 0392 widened `compute_technique_damage` and `battle_actions.base_power`.
-- 0394 widened `techniques.base_power` and both writers. Neither looked at the
-- CAST on the way into the column 0392 had just widened:
--
--     (b ->> 'base_power')::integer
--
-- The column is bigint, the value is bigint, and the cast in between is not.
-- It is the fourth place this same 32-bit ceiling has been found in two days,
-- and each time it was found by somebody hitting it rather than by looking.
--
-- SO THIS TIME IT IS SWEPT FOR. Every function in the schema was searched for
-- a narrow cast on anything named for power, damage, attack, health or
-- strength. Two matched: this one, and `dungeon_resolve_round` casting a round
-- NUMBER, which is genuinely small and stays as it is. A test added alongside
-- this keeps that sweep running, so the fifth one is caught by the suite
-- rather than by a player who cannot fight.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'battle_act';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    anchor := '               (b ->> ''base_power'')::integer,';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'battle_act no longer logs its base power where 0392 left it';
    END IF;

    EXECUTE replace(body, anchor,
        '               -- bigint since 0403: the column has been bigint since' || chr(10) ||
        '               -- 0392 and this cast was still narrowing the value on' || chr(10) ||
        '               -- its way in, so every swing past INT_MAX threw.' || chr(10) ||
        '               (b ->> ''base_power'')::bigint,');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The deepest cultivator in the game can attack
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_move BIGINT;
    v_foe  BIGINT;
    v_f    BIGINT;
    v_a    RECORD;
    v_bad  TEXT;
    v_n    INTEGER := 0;
BEGIN
    -- Nothing in the damage path narrows a power on its way anywhere.
    SELECT string_agg(p.proname || ': ' || trim(l.line), ' | ') INTO v_bad
    FROM pg_proc p
    CROSS JOIN LATERAL unnest(string_to_array(p.prosrc, chr(10))) AS l(line)
    WHERE p.pronamespace = 'public'::regnamespace
      AND l.line ~ '::integer'
      AND l.line ~* 'power|damage|dealt|thews'
      AND l.line !~ '^\s*--';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still narrow a power: %', left(v_bad, 300);
    END IF;

    -- And the thing that actually threw: every technique every deep
    -- cultivator holds, swung for real in a fight, rolled back.
    BEGIN
        FOR v_who, v_move IN
            SELECT p.player_id, u.technique_id
            FROM players p
            JOIN player_usable_techniques u ON u.player_id = p.player_id
            JOIN techniques t ON t.technique_id = u.technique_id
            JOIN player_cultivation pc ON pc.player_id = p.player_id
            JOIN realms r ON r.realm_id = pc.realm_id
            WHERE p.deleted_at IS NULL AND r.rank >= 10 AND t.base_power > 0
        LOOP
            SELECT species_id INTO v_foe FROM creature_species
            WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

            DELETE FROM player_active_battle WHERE player_id = v_who;
            UPDATE player_physique SET current_hp = max_hp WHERE player_id = v_who;
            UPDATE player_cultivation pc SET qi = player_max_qi(pc.player_id)
            WHERE pc.player_id = v_who;

            v_f := battle_open(v_who, v_foe);
            SELECT * INTO v_a FROM battle_act(v_f, 'attack', v_move);

            IF v_a.dealt IS NULL THEN
                RAISE EXCEPTION 'a swing came back with nothing';
            END IF;
            v_n := v_n + 1;
        END LOOP;

        RAISE NOTICE
            '% swings from immortal cultivators, all of them landing', v_n;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
