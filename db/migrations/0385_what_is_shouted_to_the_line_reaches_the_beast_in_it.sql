-- 0385_what_is_shouted_to_the_line_reaches_the_beast_in_it
--
-- Eighteen techniques declare `target: party` - Rally the Line, Bulwark
-- Formation, Mandate of the Nine, Ten Thousand Hearts As One. They land on
-- every raider standing in the room. They do not land on the beasts standing
-- beside them, and a beast eats thirty per cent of every blow those raiders
-- take.
--
-- WHAT ALREADY REACHED THE BEAST, AND WHY IT IS NOT BEING TOUCHED. Two of the
-- four kinds already do, by construction rather than by accident:
--
--   defence_up, block_up. `player_take` mitigates the blow FIRST and hands the
--     beast a share of what is left, which 0285 chose deliberately so that
--     armour would protect the beast too. A Ward on the cultivator is already
--     a Ward on the beast covering for them.
--
--   attack_up, WHERE THE BEAST IS AT ITS CAP. `player_swing` holds the beast's
--     blow to `pet_share_cap` of what its owner just did, and the owner's blow
--     was rallied before that share was measured. Every beast in the game is
--     currently pinned there - visha's tier 9 elder swings 9.2M raw against a
--     cap of 1.8M - so for them the rally is already arriving.
--
-- WHAT DOES NOT REACH IT.
--
--   regen. `battle_act` and `dungeon_resolve_round` mend the cultivator and
--     nothing else. The Table That Seats the Line returns 14 per cent of the
--     company's health a round for four rounds and none of it to the company's
--     beasts. This is the hole worth the migration.
--
--   attack_up, WHERE THE BEAST IS NOT AT ITS CAP. A shallow egg beside a deep
--     cultivator swings its own small blow, under the cap, unrallied. Narrow
--     today and wide the moment somebody walks a low beast on purpose.
--
-- HOW A BEAST IS TOLD. Not by giving it rows in `battle_effects` - that table
-- is keyed on a player and a beast is not one, and inventing a combatant for
-- it would put the beast in the initiative order, the targeting and the
-- reporting, which is a different feature. The beast reads its OWNER'S
-- effects, and only the ones that were aimed at the company: a new
-- `reaches_pet` flag, set from the spec at the moment the technique is cast.
--
-- FROM THE SPEC, NOT FROM THE ROOM. `technique_cast_effects` has a branch for
-- "a rally shouted in a duel still rallies the one person who heard it" - a
-- party effect cast with no party falls through to the self path. The flag is
-- settled before that fork, so a rally in a duel reaches the beast standing in
-- that duel. Where else would it have gone.
--
-- A self-targeted Bone Shield Art still shields only you. That is the whole
-- distinction the request draws and it is the one drawn here.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- An effect knows whether it was aimed at the company
-- ---------------------------------------------------------------------------

ALTER TABLE battle_effects
    ADD COLUMN reaches_pet BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN battle_effects.reaches_pet IS
    'Whether this was cast at the company rather than at one body. Set from the technique spec, so it is true in a duel as well as in a room. A beast at heel reads its owner''s rows that carry it.';


CREATE FUNCTION pet_party_effect(
    p_scope TEXT, p_scope_id BIGINT, p_player_id BIGINT, p_code TEXT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- `effect_value` for a beast: the same sum under the same kind ceiling,
    -- narrowed to what was shouted rather than what was muttered.
    SELECT LEAST(
        (SELECT k.cap FROM battle_effect_kinds k WHERE k.code = p_code),
        COALESCE((SELECT sum(e.magnitude) FROM battle_effects e
                  WHERE e.scope = p_scope AND e.scope_id = p_scope_id
                    AND e.player_id = p_player_id AND e.effect_code = p_code
                    AND e.turns_left > 0 AND e.reaches_pet), 0)
    );
$$;

COMMENT ON FUNCTION pet_party_effect(TEXT, BIGINT, BIGINT, TEXT) IS
    'How much of an effect on a cultivator reaches the beast at their heel - which is the part of it that was aimed at the whole company.';


-- ---------------------------------------------------------------------------
-- The caster says which it was
-- ---------------------------------------------------------------------------
--
-- A parameter with a default cannot be added by CREATE OR REPLACE: the old
-- and new signatures would both match a seven-argument call and Postgres
-- refuses the ambiguity. `technique_cast_effects` is the only caller and is
-- patched below in the same migration.

DROP FUNCTION effect_apply(TEXT, BIGINT, BIGINT, TEXT, NUMERIC, INTEGER, BIGINT);

CREATE FUNCTION effect_apply(
    p_scope TEXT, p_scope_id BIGINT, p_player_id BIGINT, p_code TEXT,
    p_magnitude NUMERIC, p_turns INTEGER, p_technique_id BIGINT DEFAULT NULL,
    p_reaches_pet BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    IF COALESCE(p_magnitude, 0) <= 0 OR COALESCE(p_turns, 0) <= 0 THEN
        RETURN NULL;
    END IF;

    -- Re-applying refreshes rather than stacks with itself. Two castings of
    -- the same guard by the same person is one guard that lasts longer, which
    -- is the reading that does not turn a cooldown-free technique into
    -- arbitrary numbers.
    --
    -- `reaches_pet` ORs rather than overwrites, for the same reason the other
    -- two take the greater: refreshing a Ward with a self-cast version of it
    -- must not quietly take the beast back out of it.
    UPDATE battle_effects
    SET magnitude   = GREATEST(magnitude, p_magnitude),
        turns_left  = GREATEST(turns_left, p_turns + 1)::smallint,
        reaches_pet = reaches_pet OR COALESCE(p_reaches_pet, FALSE),
        applied_at  = now()
    WHERE scope = p_scope AND scope_id = p_scope_id
      AND player_id = p_player_id AND effect_code = p_code
      AND from_technique IS NOT DISTINCT FROM p_technique_id
    RETURNING effect_id INTO made;

    IF made IS NOT NULL THEN
        RETURN made;
    END IF;

    -- One more round than asked for, and this is the only place that knows
    -- why: `effect_tick` runs at the top of an action, so the very next
    -- action spends a round off this before anything reads it. Without the
    -- extra, a three turn effect is felt on two.
    INSERT INTO battle_effects
        (scope, scope_id, player_id, effect_code, magnitude, turns_left,
         from_technique, reaches_pet)
    VALUES (p_scope, p_scope_id, p_player_id, p_code, p_magnitude,
            (p_turns + 1)::smallint, p_technique_id,
            COALESCE(p_reaches_pet, FALSE))
    RETURNING effect_id INTO made;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION effect_apply(TEXT, BIGINT, BIGINT, TEXT, NUMERIC, INTEGER, BIGINT, BOOLEAN) IS
    'Lays a lasting effect on a combatant, refreshing rather than stacking with itself. The last argument records that it was aimed at the company, which is what lets it reach a beast.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
    n      INTEGER;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'technique_cast_effects';

    IF body IS NULL THEN
        RAISE EXCEPTION 'technique_cast_effects is missing';
    END IF;

    -- ---- somewhere to keep the answer -------------------------------------
    anchor := '    who     BIGINT;';
    swap   := concat(
'    who     BIGINT;', chr(10),
'    shared  BOOLEAN;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'technique_cast_effects no longer declares who once';
    END IF;
    body := replace(body, anchor, swap);

    -- ---- settled before the fork, not inside it ---------------------------
    anchor := '        IF COALESCE(one ->> ''target'', ''self'') = ''party'' AND p_scope = ''dungeon'' THEN';
    swap := concat(
'        -- Whether this was aimed at the company, read off the spec rather', chr(10),
'        -- than off whether the room happened to hold anybody else. The fork', chr(10),
'        -- below sends a party effect with no party down the self path, and a', chr(10),
'        -- rally shouted in a duel still reaches the beast that heard it.', chr(10),
'        shared := COALESCE(one ->> ''target'', ''self'') = ''party'';', chr(10),
'', chr(10),
'        IF shared AND p_scope = ''dungeon'' THEN');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'technique_cast_effects no longer forks on target once';
    END IF;
    body := replace(body, anchor, swap);

    -- ---- and both calls carry it ------------------------------------------
    -- The two continuation indents are built rather than typed, because the
    -- self branch's anchor is a SUBSTRING of the party branch's - four spaces
    -- shallower and otherwise identical. The deeper one therefore has to go
    -- first, and both assert their own count after the other has moved.
    anchor := repeat(' ', 37) || 'p_technique_id);';
    n := (length(body) - length(replace(body, anchor, ''))) / length(anchor);
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected one party-branch effect_apply, found %', n;
    END IF;
    body := replace(body, anchor, repeat(' ', 37) || 'p_technique_id, shared);');

    anchor := repeat(' ', 33) || 'p_technique_id);';
    n := (length(body) - length(replace(body, anchor, ''))) / length(anchor);
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected one self-branch effect_apply, found %', n;
    END IF;
    body := replace(body, anchor, repeat(' ', 33) || 'p_technique_id, shared);');

    EXECUTE body;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A rally reaches the beast's blow
-- ---------------------------------------------------------------------------
--
-- Applied to `pet_blow`'s result inside `player_swing` rather than inside
-- `pet_blow` itself, which keeps that function what it is - a statement about
-- the beast, its species and the thing in front of it, with no opinion about
-- what fight it is in.
--
-- BEFORE the share cap on purpose. The cap is a LEAST against what the owner
-- just did, and the owner's blow was rallied by the same effect three lines
-- earlier - so a beast already pinned at the cap gains nothing here and cannot
-- be paid twice, while a beast under the cap finally gets the shout.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'player_swing';

    IF body IS NULL THEN
        RAISE EXCEPTION 'player_swing is missing';
    END IF;

    anchor := '        beast_hit := pet_blow(beast, p_species_id, eff_def);';
    swap := concat(
'        beast_hit := pet_blow(beast, p_species_id, eff_def);', chr(10),
'', chr(10),
'        -- What was shouted to the company reaches the beast standing in it.', chr(10),
'        -- Before the cap below, which is a LEAST against a blow that was', chr(10),
'        -- rallied by the same effect - so this can lift a beast under its', chr(10),
'        -- share and can never pay one at its share twice.', chr(10),
'        IF p_scope IS NOT NULL AND p_scope_id IS NOT NULL THEN', chr(10),
'            beast_hit := round(beast_hit * (1 + pet_party_effect(', chr(10),
'                p_scope, p_scope_id, p_player_id, ''attack_up'')))::bigint;', chr(10),
'        END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'player_swing no longer calls pet_blow exactly once';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And a mending meant for the company mends the beast in it
-- ---------------------------------------------------------------------------
--
-- Of the BEAST'S maximum, not its owner's. A share is the only reading that
-- works across a cap that is itself a share of a body which varies by forty
-- times between the cultivators walking one.

CREATE FUNCTION pet_tick_regen(
    p_scope TEXT, p_scope_id BIGINT, p_player_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    beast BIGINT;
    share NUMERIC;
BEGIN
    IF p_scope IS NULL OR p_scope_id IS NULL OR p_player_id IS NULL THEN
        RETURN 0;
    END IF;

    -- `pet_at_heel` rather than `pet_standing`: a mending that refuses to
    -- reach the beast on the floor is the one that would matter most. Same
    -- choice `rest` and the healing pill make.
    beast := pet_at_heel(p_player_id);
    IF beast IS NULL THEN
        RETURN 0;
    END IF;

    share := pet_party_effect(p_scope, p_scope_id, p_player_id, 'regen');
    IF COALESCE(share, 0) <= 0 THEN
        RETURN 0;
    END IF;

    RETURN pet_mend(beast,
        GREATEST(1, floor(pet_max_hp(beast) * share))::bigint);
END;
$$;

COMMENT ON FUNCTION pet_tick_regen(TEXT, BIGINT, BIGINT) IS
    'Mends the beast at a cultivator''s heel by the share of its own maximum that a company-wide Mending is returning to them.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- the duel ---------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'battle_act';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    anchor := '    qi   := me.current_qi;';
    swap := concat(
'    -- And whatever of that Mending was meant for the whole company mends', chr(10),
'    -- the beast walking in it. Outside the branch above, which only runs', chr(10),
'    -- when the cultivator themselves had something to gain.', chr(10),
'    PERFORM pet_tick_regen(''battle'', p_battle_id, me.player_id);', chr(10),
'', chr(10),
'    qi   := me.current_qi;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'battle_act does not read its Qi where it used to';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- the room ---------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_resolve_round';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_resolve_round is missing';
    END IF;

    anchor := concat(
'      AND effect_value(''dungeon'', p_run_id, x.player_id, ''regen'') > 0;');
    swap := concat(
'      AND effect_value(''dungeon'', p_run_id, x.player_id, ''regen'') > 0;', chr(10),
'', chr(10),
'    -- Every beast in the room, on the same tick. A share of its own', chr(10),
'    -- maximum, and only the part of the Mending that was meant for the', chr(10),
'    -- whole company.', chr(10),
'    PERFORM pet_tick_regen(''dungeon'', p_run_id, x.player_id)', chr(10),
'    FROM dungeon_raiders x', chr(10),
'    WHERE x.run_id = p_run_id AND x.current_hp > 0;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer gates its regen there';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A shout carries, a mutter does not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who     BIGINT;
    beast   BIGINT;
    top     BIGINT;
    rally   BIGINT;
    guard   BIGINT;
    mend    BIGINT;
    fight   BIGINT;
    v_got   NUMERIC;
    v_hp    BIGINT;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    WHERE b.at_heel AND pet_max_hp(b.beast_id) > 100
    ORDER BY pet_max_hp(b.beast_id) DESC
    LIMIT 1;

    -- The techniques the distinction is actually drawn between: one shouted
    -- at the line, one kept to yourself, both the same kind of effect.
    SELECT technique_id INTO rally FROM techniques
    WHERE code IS NOT NULL AND effects @> '{"apply": [{"target": "party"}]}'
      AND effects::text LIKE '%attack_up%' ORDER BY rank LIMIT 1;
    SELECT technique_id INTO guard FROM techniques
    WHERE code IS NOT NULL
      AND effects::text LIKE '%attack_up%'
      AND NOT (effects @> '{"apply": [{"target": "party"}]}')
    ORDER BY rank LIMIT 1;
    SELECT technique_id INTO mend FROM techniques
    WHERE code IS NOT NULL AND effects @> '{"apply": [{"target": "party"}]}'
      AND effects::text LIKE '%regen%' ORDER BY rank LIMIT 1;

    IF rally IS NULL OR guard IS NULL OR mend IS NULL THEN
        RAISE EXCEPTION
            'the roster no longer holds both a shouted and a private buff';
    END IF;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- A scope id nothing else is using. `battle_effects` is keyed on the
        -- pair, not on a foreign key, so this touches no live fight.
        fight := 9000000000;
        top   := pet_max_hp(beast);

        -- ---- the shout -----------------------------------------------------
        PERFORM technique_cast_effects(who, rally, 'battle', fight);
        v_got := pet_party_effect('battle', fight, who, 'attack_up');
        IF v_got <= 0 THEN
            RAISE EXCEPTION 'a rally at the whole line did not reach the beast';
        END IF;
        IF v_got <> effect_value('battle', fight, who, 'attack_up') THEN
            RAISE EXCEPTION
                'the beast got % of the %  its owner did',
                v_got, effect_value('battle', fight, who, 'attack_up');
        END IF;

        -- ---- and the mutter ------------------------------------------------
        PERFORM effect_clear('battle', fight);
        PERFORM technique_cast_effects(who, guard, 'battle', fight);
        IF effect_value('battle', fight, who, 'attack_up') <= 0 THEN
            RAISE EXCEPTION 'the private buff did not land on its own caster';
        END IF;
        IF pet_party_effect('battle', fight, who, 'attack_up') <> 0 THEN
            RAISE EXCEPTION
                'a buff kept to yourself leaked to the beast anyway';
        END IF;

        -- ---- a mending meant for the company -------------------------------
        PERFORM effect_clear('battle', fight);
        UPDATE player_beasts SET hp = GREATEST(1, top / 10)
        WHERE beast_id = beast;
        PERFORM technique_cast_effects(who, mend, 'battle', fight);

        v_hp := pet_hp(beast);
        IF pet_tick_regen('battle', fight, who) <= 0 THEN
            RAISE EXCEPTION 'a company-wide Mending mended no beast';
        END IF;
        IF pet_hp(beast) <= v_hp THEN
            RAISE EXCEPTION 'the beast is no better for a Mending that ran';
        END IF;

        -- And a beast at full is not a place for it to disappear into.
        UPDATE player_beasts SET hp = NULL WHERE beast_id = beast;
        IF pet_tick_regen('battle', fight, who) <> 0 THEN
            RAISE EXCEPTION 'a whole beast was mended further';
        END IF;

        PERFORM effect_clear('battle', fight);
        RAISE NOTICE
            'a shout carries to the beast, a mutter does not';
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
