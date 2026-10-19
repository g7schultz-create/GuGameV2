-- 0456_the_trial_was_never_allowed_to_write_what_it_reads
--
-- The Peer Trial's whole design is that a round ASKS what the party applied:
--
--     EXISTS (SELECT 1 FROM battle_effects b
--             WHERE b.scope = 'trial' AND b.scope_id = p_run_id ...)
--
-- `battle_effects` has never accepted a row at that scope.
--
--     CHECK (scope IN ('battle', 'dungeon', 'boss', 'horde', 'gauntlet'))
--
-- So the first peer to throw a taunt, a regen or a hardening inside a Trial
-- would not have failed to answer the threat - the round would have died with
-- a constraint violation, mid-fight, and taken the party's turn with it.
--
-- IT HID BEHIND THE FACT THAT NOBODY HAS ONE. Three players in the game know a
-- support technique and one knows a defence technique, and none of them has
-- been in a Trial. Every round run so far was a party of attackers, every
-- attack applies nothing, so nothing was ever written and nothing ever threw.
-- The engine looked finished because the only path through it that works is
-- the path where the party does nothing interesting.
--
-- 0454 WALKED INTO THE SAME HOLE. The rehearsal swings at scope 'rehearsal',
-- which is not on that list either, so sizing a Trial would have thrown the
-- moment one member's default move applied something. Both arms of the same
-- missing permission, so both are fixed here.
--
-- AND A RALLY REACHED ONE PERSON. `technique_cast_effects` fans a party-aimed
-- effect out to everybody in the room and knows exactly one room:
--
--     IF shared AND p_scope = 'dungeon' THEN
--         FOR who IN SELECT x.player_id FROM dungeon_raiders x ...
--
-- so a Trial went down the self path. That one would not have thrown; it would
-- have quietly healed the caster and told the party it was covered, which is
-- worse. The branch now reads whichever room the scope names.
--
-- THE LESSON IS THE RECURRING ONE. 0452 gave the Trial a scope of its own and
-- passed it to the same machinery a dungeon uses, and three separate places
-- had a list of rooms in them that nobody updated. A scope is not a string you
-- invent at the call site; it is a thing the rest of the game has to have been
-- told about.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The rooms an effect may be applied in
-- ---------------------------------------------------------------------------

ALTER TABLE battle_effects DROP CONSTRAINT battle_effects_scope_check;

ALTER TABLE battle_effects ADD CONSTRAINT battle_effects_scope_check
    CHECK (scope IN ('battle', 'dungeon', 'boss', 'horde', 'gauntlet',
                     'trial', 'rehearsal'));

COMMENT ON COLUMN battle_effects.scope IS
    'Which fight this effect belongs to. Every room that calls player_swing must be named here - a scope the table refuses is a round that throws mid-fight rather than a technique that quietly does nothing. See 0456.';


-- ---------------------------------------------------------------------------
-- And who hears a thing shouted at the company
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    better TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'technique_cast_effects'
      AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'technique_cast_effects is missing';
    END IF;

    anchor := concat(
'        IF shared AND p_scope = ''dungeon'' THEN', chr(10),
'            -- Everybody still standing in the room, the caster included.', chr(10),
'            FOR who IN', chr(10),
'                SELECT x.player_id FROM dungeon_raiders x', chr(10),
'                WHERE x.run_id = p_scope_id AND x.current_hp > 0', chr(10),
'            LOOP');

    better := concat(
'        IF shared AND p_scope IN (''dungeon'', ''trial'') THEN', chr(10),
'            -- Everybody still standing in the room, the caster included.', chr(10),
'            -- Which room that is comes from the scope rather than from a', chr(10),
'            -- name written in here: 0456, after a rally in a Peer Trial', chr(10),
'            -- reached only the peer who shouted it.', chr(10),
'            FOR who IN', chr(10),
'                SELECT x.player_id FROM dungeon_raiders x', chr(10),
'                WHERE p_scope = ''dungeon''', chr(10),
'                  AND x.run_id = p_scope_id AND x.current_hp > 0', chr(10),
'                UNION ALL', chr(10),
'                SELECT x.player_id FROM trial_raiders x', chr(10),
'                WHERE p_scope = ''trial''', chr(10),
'                  AND x.run_id = p_scope_id AND x.current_hp > 0', chr(10),
'            LOOP');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'technique_cast_effects no longer gathers the room where it did';
    END IF;

    EXECUTE replace(body, anchor, better);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A support peer can actually support, and is heard by everybody
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_run   BIGINT;
    v_tech  BIGINT;
    v_code  TEXT;
    v_who   INTEGER;
    v_size  INTEGER;
    v_said  TEXT;
    got     RECORD;
    r       RECORD;
BEGIN
    -- Every room that swings is named in the constraint. Asked of the schema
    -- rather than of the five I happened to think of.
    FOR r IN
        SELECT unnest(ARRAY['battle', 'dungeon', 'boss', 'horde', 'gauntlet',
                            'trial', 'rehearsal']) AS scope
    LOOP
        BEGIN
            INSERT INTO battle_effects
                (scope, scope_id, player_id, effect_code, magnitude, turns_left)
            VALUES (r.scope, -1, (SELECT min(player_id) FROM players),
                    'regen', 0.1, 1);
            RAISE EXCEPTION 'probe-ok';
        EXCEPTION
            WHEN check_violation THEN
                RAISE EXCEPTION 'the scope % is still refused', r.scope;
            WHEN OTHERS THEN
                IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
        END;
    END LOOP;

    BEGIN
        -- A technique that is aimed at the company, whichever one it is.
        SELECT t.technique_id, e ->> 'code' INTO v_tech, v_code
        FROM techniques t
        CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(t.effects -> 'apply', '[]'::jsonb)) e
        WHERE e ->> 'target' = 'party'
        ORDER BY t.technique_id LIMIT 1;

        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_lead IS NULL OR v_tech IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;
        PERFORM trial_party_seal(v_lead);

        SELECT count(*) INTO v_size FROM trial_party_members m
        WHERE m.party_id = v_party;
        IF v_size < 2 THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT t.run_id INTO v_run FROM trial_begin(v_lead) t;

        -- The leader shouts it. Before this migration that threw, and before
        -- the patch above it reached exactly one person.
        PERFORM technique_cast_effects(v_lead, v_tech, 'trial', v_run);

        SELECT count(DISTINCT b.player_id) INTO v_who
        FROM battle_effects b
        WHERE b.scope = 'trial' AND b.scope_id = v_run
          AND b.effect_code = v_code;

        IF v_who < v_size THEN
            RAISE EXCEPTION
                'a party effect reached % of the % peers standing there',
                v_who, v_size;
        END IF;

        -- And a whole round still resolves on top of those effects, which is
        -- the thing that would have thrown in a live fight.
        SELECT * INTO got FROM trial_resolve_round(v_run);
        IF got IS NULL THEN
            RAISE EXCEPTION 'the round would not resolve at all';
        END IF;

        RAISE NOTICE
            'the rally reached all % peers, and the round answered: %',
            v_who, got.said;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- The dungeon was not traded away for the trial.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'technique_cast_effects'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%dungeon_raiders%' THEN
        RAISE EXCEPTION 'the dungeon lost its company in the process';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'technique_cast_effects'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%trial_raiders%' THEN
        RAISE EXCEPTION 'the trial never gained one';
    END IF;
END;
$probe$;
