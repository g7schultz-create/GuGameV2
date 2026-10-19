-- 0235_a_fight_applies_what_it_did
--
-- Open a hunt, go and lose seven hundred health to the world boss, come back
-- and finish the hunt: full again. A player found this and said so out loud.
--
-- `battle_conclude` writes the body from the battle's pool:
--
--     UPDATE player_physique SET current_hp = LEAST(me.current_hp, pp.max_hp)
--
-- and `me.current_hp` began as a snapshot of the body taken at `battle_open`.
-- So the fight does not apply what it DID - it asserts what it believes you
-- are, from a reading that may be an hour old. Anything that happened to the
-- body while the fight was open is overwritten on the way out.
--
-- 0032's comment says the two pools "are allowed to disagree by the time this
-- runs" and clamps, which is the right observation and the wrong conclusion:
-- clamping picks the battle's number as the true one. It only ever needed to
-- be the DELTA. The fight took some health; apply that much to whatever the
-- body is now.
--
-- IT CUTS BOTH WAYS, which is why this is a correctness fix rather than an
-- exploit patch. A pill drunk between two turns of a hunt was erased at the
-- end of it, and so was a rest. The body and the battle were never reconciled
-- in either direction - only the losses happened to be the ones somebody
-- noticed, because they were the ones that felt free.
--
-- The battle has to remember where it started for this to be computable, so
-- the opening health goes in the snapshot beside the other things the body was
-- at the door. A battle already in flight has no such key: it applies a delta
-- of nothing and leaves the body alone, which stops the healing without
-- inventing a number for a fight that was opened before this rule existed.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The door records where the body started
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'battle_open';

    old := '            jsonb_build_object(''max_hp'', body.max_hp, ''defense'', body.defense,
                               ''strength'', body.strength, ''max_qi'', max_qi),';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_open no longer snapshots the body the old way';
    END IF;

    EXECUTE replace(src, old,
        '            jsonb_build_object(''max_hp'', body.max_hp, ''defense'', body.defense,
                               ''strength'', body.strength, ''max_qi'', max_qi,
                               -- Where the body was when this fight started.
                               -- `battle_conclude` needs it to work out what
                               -- the fight actually cost, rather than assuming
                               -- the body is untouched meanwhile.
                               ''opened_hp'', body.current_hp),');
END;
$$;


-- ---------------------------------------------------------------------------
-- And the exit applies the difference
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'battle_conclude';

    old := '    -- Clamped, because the battle''s pool and the body''s pool are allowed to
    -- disagree by the time this runs. See 0032.
    UPDATE player_physique pp
    SET current_hp = LEAST(me.current_hp, pp.max_hp)
    WHERE pp.player_id = me.player_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_conclude no longer writes the body the old way';
    END IF;

    EXECUTE replace(src, old,
        '    -- What the fight DID, applied to whatever the body is now. 0032 saw
    -- that the two pools disagree and clamped, which takes the battle''s
    -- reading as the true one and erases everything that happened to the body
    -- while the fight was open - a boss''s blows, and a pill, and a rest.
    --
    -- A battle opened before 0235 carries no `opened_hp`, so it applies a
    -- delta of nothing rather than a number invented for it.
    UPDATE player_physique pp
    SET current_hp = GREATEST(0, LEAST(pp.max_hp,
        pp.current_hp
        - (COALESCE((me.snapshot ->> ''opened_hp'')::bigint, me.current_hp)
           - me.current_hp)))
    WHERE pp.player_id = me.player_id;');
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    beast BIGINT;
    fight BIGINT;
    body  BIGINT;
    top   BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND pp.max_hp > 200
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody with a body to measure; the tests carry it';
        RETURN;
    END IF;

    SELECT cs.species_id INTO beast FROM creature_species cs
    WHERE cs.kind = 'beast' LIMIT 1;

    BEGIN
        SELECT pp.max_hp INTO top FROM player_physique pp WHERE pp.player_id = who;

        DELETE FROM player_active_battle WHERE player_id = who;
        UPDATE player_physique SET current_hp = max_hp WHERE player_id = who;

        -- Open a hunt at full health.
        fight := battle_open(who, beast);

        -- Get hurt somewhere else entirely, the way the world boss does it.
        UPDATE player_physique SET current_hp = 100 WHERE player_id = who;

        -- The hunt costs a little, then ends.
        UPDATE battle_combatants
        SET current_hp = current_hp - 50
        WHERE battle_id = fight AND combatant_no = 0;
        UPDATE battle_combatants
        SET current_hp = 0
        WHERE battle_id = fight AND combatant_no = 1;

        PERFORM battle_conclude(fight, 'complete');

        SELECT pp.current_hp INTO body FROM player_physique pp WHERE pp.player_id = who;

        IF body >= top THEN
            RAISE EXCEPTION
                'the hunt healed the body back to % of %', body, top;
        END IF;
        IF body <> 50 THEN
            RAISE EXCEPTION
                'the hunt should have left 50 (100 hurt, 50 taken) and left %', body;
        END IF;

        -- And the other direction: a pill drunk mid-fight is not erased.
        DELETE FROM player_active_battle WHERE player_id = who;
        UPDATE player_physique SET current_hp = 200 WHERE player_id = who;
        fight := battle_open(who, beast);
        UPDATE player_physique SET current_hp = 400 WHERE player_id = who;
        UPDATE battle_combatants SET current_hp = 0
        WHERE battle_id = fight AND combatant_no = 1;
        PERFORM battle_conclude(fight, 'complete');

        SELECT pp.current_hp INTO body FROM player_physique pp WHERE pp.player_id = who;
        IF body <> 400 THEN
            RAISE EXCEPTION 'a heal taken during the fight came out as %', body;
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
