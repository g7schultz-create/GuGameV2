-- 0304_the_last_three_lanes_read_the_fight_too
--
-- The world beast, the gauntlet and the tide. All three are single-swing
-- lanes - one press, one exchange, no round loop - so there is far less to do
-- here than in the hunt or the room, but the scoping rules are the same.
--
-- WHAT A "ROUND" IS IN A LANE WITH NO ROUNDS. A press IS the round. Each of
-- these ticks once per press, at the top, before anything reads an effect -
-- the same rule the other two follow, and the rule `effect_apply` compensates
-- for by banking an extra turn. A three turn ward bought in a gauntlet lasts
-- three presses.
--
-- THE TIDE TAKES NO SCOPE FOR DEFENCE, because nothing swings back at you in
-- a channel: `horde_strike` never calls `player_take` at all. It gets the
-- offensive half and nothing else, which is not an omission - there is no
-- defensive half of that fight to have.
--
-- WHERE EACH ONE CLEARS. The beast and the tide both end for everybody at
-- once and are swept elsewhere, so their effects are cleared where the
-- encounter is settled rather than inside the strike. The gauntlet ends for
-- one cultivator at a time and clears itself the moment the run stops
-- walking.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The world beast
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body  TEXT;
    swing TEXT :=
'        p_player_id, move, live.species_id, live.current_hp, 0::bigint,
        body.current_hp, body.max_hp, 1);';
    take  TEXT :=
'            NOT COALESCE((SELECT bs.ward_used FROM boss_strikes bs
                          WHERE bs.encounter_id = live.encounter_id
                            AND bs.player_id = p_player_id), FALSE));';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'strike_boss';

    IF (length(body) - length(replace(body, swing, ''))) / length(swing) <> 1 THEN
        RAISE EXCEPTION 'boss: the swing is not where it was';
    END IF;
    IF (length(body) - length(replace(body, take, ''))) / length(take) <> 1 THEN
        RAISE EXCEPTION 'boss: the bite is not where it was';
    END IF;

    body := replace(body, swing,
'        p_player_id, move, live.species_id, live.current_hp, 0::bigint,
        body.current_hp, body.max_hp, 1, ''boss'', live.encounter_id);');

    body := replace(body, take,
'            NOT COALESCE((SELECT bs.ward_used FROM boss_strikes bs
                          WHERE bs.encounter_id = live.encounter_id
                            AND bs.player_id = p_player_id), FALSE),
            ''boss'', live.encounter_id);');

    -- One press is one round. Ticked before the swing reads anything.
    body := replace(body, '    hit := swung;',
'    hit := swung;' || chr(10) || chr(10) ||
'    PERFORM effect_tick(''boss'', live.encounter_id);');

    DROP FUNCTION strike_boss(BIGINT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The gauntlet
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body  TEXT;
    swing TEXT :=
'            run.player_id, p_technique_id, run.species_id, pool,
            species.base_defense::bigint, body, run.max_hp, run.exchanges + 1);';
    take  TEXT :=
'            run.player_id, bit.final_damage, body, run.max_hp,
            brace, NOT run.ward_used);';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_gauntlet_swing';

    IF (length(body) - length(replace(body, swing, ''))) / length(swing) <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the swing is not where it was';
    END IF;
    IF (length(body) - length(replace(body, take, ''))) / length(take) <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the bite is not where it was';
    END IF;

    body := replace(body, swing,
'            run.player_id, p_technique_id, run.species_id, pool,
            species.base_defense::bigint, body, run.max_hp, run.exchanges + 1,
            ''gauntlet'', p_gauntlet_id);');

    body := replace(body, take,
'            run.player_id, bit.final_damage, body, run.max_hp,
            brace, NOT run.ward_used, ''gauntlet'', p_gauntlet_id);');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The tide. Offence only, because nothing in a channel swings back.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body  TEXT;
    swing TEXT :=
'        p_player_id, move, met.species_id, met.hp, met.base_defense::bigint);';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_strike';

    IF (length(body) - length(replace(body, swing, ''))) / length(swing) <> 1 THEN
        RAISE EXCEPTION 'tide: the swing is not where it was';
    END IF;

    body := replace(body, swing,
'        p_player_id, move, met.species_id, met.hp, met.base_defense::bigint,
        NULL, NULL, 0, ''horde'', met.horde_id);');

    body := replace(body, '    hurt  := GREATEST(1, swung.dealt);',
'    PERFORM effect_tick(''horde'', met.horde_id);' || chr(10) || chr(10) ||
'    hurt  := GREATEST(1, swung.dealt);');

    DROP FUNCTION horde_strike(BIGINT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- All five lanes now name the fight they are in
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    missing TEXT := '';
    want    TEXT[][] := ARRAY[
        ARRAY['battle_act',            '''battle'', p_battle_id'],
        ARRAY['dungeon_resolve_round', '''dungeon'', p_run_id'],
        ARRAY['strike_boss',           '''boss'', live.encounter_id'],
        ARRAY['horde_gauntlet_swing',  '''gauntlet'', p_gauntlet_id'],
        ARRAY['horde_strike',          '''horde'', met.horde_id']
    ];
    i INTEGER;
BEGIN
    FOR i IN 1..array_length(want, 1) LOOP
        IF (SELECT prosrc FROM pg_proc WHERE proname = want[i][1])
           NOT LIKE '%' || want[i][2] || '%' THEN
            missing := missing || ' ' || want[i][1];
        END IF;
    END LOOP;

    IF missing <> '' THEN
        RAISE EXCEPTION 'these lanes still do not name their fight:%', missing;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- And every one of them still swings
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who  BIGINT;
    sp   BIGINT;
    got  RECORD;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can swing; the tests carry this';
        RETURN;
    END IF;

    SELECT species_id INTO sp FROM creature_species
    WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

    BEGIN
        -- The choke point still answers a bare call and a scoped one alike.
        SELECT * INTO got FROM player_swing(
            who, dungeon_default_move(who), sp, 1000000::bigint, 0::bigint);
        IF got.dealt IS NULL THEN
            RAISE EXCEPTION 'an unscoped swing stopped answering';
        END IF;

        SELECT * INTO got FROM player_swing(
            who, dungeon_default_move(who), sp, 1000000::bigint, 0::bigint,
            NULL, NULL, 0, 'boss', -4);
        IF got.dealt IS NULL THEN
            RAISE EXCEPTION 'a scoped swing stopped answering';
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
