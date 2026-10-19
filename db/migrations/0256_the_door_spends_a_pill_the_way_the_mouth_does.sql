-- 0256_the_door_spends_a_pill_the_way_the_mouth_does
--
-- 0253 spends the breakthrough pill by decrementing its quantity and then
-- deleting anything that reached zero. `player_pills` has a CHECK that a stack
-- holds at least one, and a CHECK fires on the UPDATE rather than waiting to
-- see what the next statement was going to do about it - so a cultivator
-- carrying exactly one pill could not use it, which is every cultivator who
-- brewed one for the door.
--
-- `take_pill` has done this correctly since it was written: spend from a stack
-- of more than one, delete a stack of one. There was no reason to invent a
-- second way, and the second way was wrong.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'breakthrough';

    old := '            UPDATE player_pills pl SET quantity = pl.quantity - 1
            WHERE pl.pill_id = (
                SELECT p2.pill_id FROM player_pills p2
                WHERE p2.owner_id = p_player_id AND p2.kind = gate.pill_kind
                  AND p2.tier >= gate.pill_tier AND p2.quantity > 0
                ORDER BY p2.tier, p2.magnitude LIMIT 1);
            DELETE FROM player_pills WHERE owner_id = p_player_id AND quantity <= 0;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer spends its pill the 0253 way';
    END IF;

    src := replace(src, old,
'            -- The weakest one that qualifies, so a hoard of good pills is not
            -- spent on a door a cheap one opens. Spent the way `take_pill`
            -- spends one: a stack of one is deleted rather than decremented
            -- into a value the table refuses to hold.
            SELECT p2.pill_id, p2.quantity INTO spend_pill, pill_left
            FROM player_pills p2
            WHERE p2.owner_id = p_player_id AND p2.kind = gate.pill_kind
              AND p2.tier >= gate.pill_tier AND p2.quantity > 0
            ORDER BY p2.tier, p2.magnitude
            LIMIT 1;

            IF pill_left > 1 THEN
                UPDATE player_pills SET quantity = quantity - 1
                WHERE pill_id = spend_pill;
            ELSE
                DELETE FROM player_pills WHERE pill_id = spend_pill;
            END IF;');

    old := '    gate      realm_gates%ROWTYPE;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer declares its gate';
    END IF;
    src := replace(src, old,
'    gate      realm_gates%ROWTYPE;
    spend_pill BIGINT;
    pill_left  SMALLINT;');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    gate  realm_gates%ROWTYPE;
    nx    realms%ROWTYPE;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc
    JOIN realms r  ON r.realm_id = pc.realm_id
    JOIN realms n2 ON n2.realm_id = pc.realm_id + 1 AND n2.rank > r.rank
    JOIN players p ON p.player_id = pc.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody stands at a rank door; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT n2.* INTO nx FROM player_cultivation pc
        JOIN realms n2 ON n2.realm_id = pc.realm_id + 1
        WHERE pc.player_id = who;
        SELECT * INTO gate FROM realm_gates WHERE rank = nx.rank;

        -- Exactly one pill, which is what somebody who brewed for the door has.
        DELETE FROM player_pills WHERE owner_id = who AND kind = gate.pill_kind;
        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (who, 'Door Pill', gate.pill_tier, gate.pill_kind,
                (SELECT code FROM paths ORDER BY code LIMIT 1), 1, 1, 50);

        PERFORM grant_material(who, 'spirit_stone', gate.stones);
        PERFORM grant_material(who, gate.treasure_code, gate.treasure_qty);
        UPDATE player_cultivation pc SET cultivation = nx.cultivation_required
        WHERE pc.player_id = who;

        PERFORM breakthrough(who);

        IF EXISTS (SELECT 1 FROM player_pills
                   WHERE owner_id = who AND kind = gate.pill_kind
                     AND tier = gate.pill_tier) THEN
            RAISE EXCEPTION 'the door did not spend the pill it took';
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
