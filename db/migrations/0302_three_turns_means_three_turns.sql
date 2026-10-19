-- 0302_three_turns_means_three_turns
--
-- A mend worth a fifth of the body, applied for three turns, paid out twice.
-- Watched round by round on a real hunt: 200 health, then 8,200, then 16,200,
-- then nothing.
--
-- The cause is the ordering 0301 chose deliberately. `effect_tick` runs at
-- the TOP of an action - it has to, because `battle_act` returns from four
-- different places and a tick at the bottom is four ticks, one of which will
-- eventually be forgotten. But that means every action spends a round off an
-- effect BEFORE anything reads it, so the first of the three is gone before
-- it was ever worth anything. Three turns bought two.
--
-- An off-by-one nobody would ever see from the outside except as "this says
-- three and feels like two", which is the worst kind: it looks like balance.
--
-- THE FIX IS AT THE APPLYING END, NOT THE TICKING END. Moving the tick to
-- where it would be read after rather than before means finding every exit of
-- every lane - four in the hunt alone - and being right about all of them
-- forever. Instead `effect_apply` banks one extra round, because it knows
-- exactly why: the next action will spend one before reading it.
--
-- What this costs is that a row for a three turn effect reads 4 for a moment.
-- That is a real wart and it is written down here and in the function, which
-- is the trade against four ticking sites that must never drift apart.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    INSERT INTO battle_effects
        (scope, scope_id, player_id, effect_code, magnitude, turns_left,
         from_technique)
    VALUES (p_scope, p_scope_id, p_player_id, p_code, p_magnitude,
            p_turns::smallint, p_technique_id)
    RETURNING effect_id INTO made;';
    refresh TEXT :=
'        turns_left = GREATEST(turns_left, p_turns)::smallint,';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'effect_apply';

    IF body IS NULL THEN
        RAISE EXCEPTION 'effect_apply is missing';
    END IF;
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the insert in effect_apply is not where it was';
    END IF;
    IF (length(body) - length(replace(body, refresh, ''))) / length(refresh) <> 1 THEN
        RAISE EXCEPTION 'the refresh in effect_apply is not where it was';
    END IF;

    body := replace(body, refresh,
'        turns_left = GREATEST(turns_left, p_turns + 1)::smallint,');

    body := replace(body, anchor,
'    -- One more round than asked for, and this is the only place that knows
    -- why: `effect_tick` runs at the top of an action, so the very next
    -- action spends a round off this before anything reads it. Without the
    -- extra, a three turn effect is felt on two.
    INSERT INTO battle_effects
        (scope, scope_id, player_id, effect_code, magnitude, turns_left,
         from_technique)
    VALUES (p_scope, p_scope_id, p_player_id, p_code, p_magnitude,
            (p_turns + 1)::smallint, p_technique_id)
    RETURNING effect_id INTO made;');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- Three turns is felt on three rounds, in a real fight
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    sp     BIGINT;
    b_id   BIGINT;
    paid   INTEGER := 0;
    was    BIGINT;
    now_hp BIGINT;
    round  INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can swing; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE battles SET status = 'expired', ended_at = now()
        WHERE status = 'active'
          AND battle_id IN (SELECT battle_id FROM battle_combatants
                            WHERE player_id = who);

        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;
        b_id := battle_open(who, sp);

        -- A creature that cannot end this, and a body with room to mend into.
        UPDATE battle_combatants
        SET current_hp = 9223372036854775807 / 4,
            max_hp     = 9223372036854775807 / 4
        WHERE battle_id = b_id AND combatant_no = 1;
        UPDATE battle_combatants
        SET current_hp = 1, max_hp = 100000
        WHERE battle_id = b_id AND combatant_no = 0;

        PERFORM effect_apply('battle', b_id, who, 'regen', 0.10, 3);

        -- Four rounds, counting the ones that actually mended.
        FOR round IN 1..4 LOOP
            SELECT current_hp INTO was FROM battle_combatants
            WHERE battle_id = b_id AND combatant_no = 0;

            PERFORM battle_act(b_id, 'guard', NULL);

            SELECT current_hp INTO now_hp FROM battle_combatants
            WHERE battle_id = b_id AND combatant_no = 0;

            IF now_hp > was THEN
                paid := paid + 1;
            END IF;
        END LOOP;

        IF paid <> 3 THEN
            RAISE EXCEPTION
                'a three turn mend paid out on % rounds of four', paid;
        END IF;

        RAISE NOTICE 'three turns of mending paid on three rounds';

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
