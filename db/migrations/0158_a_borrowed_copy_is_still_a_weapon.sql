-- 0158_a_borrowed_copy_is_still_a_weapon
--
-- 0157 refuses to put down the last thing you have that could hurt anything.
-- It worked out what would be left by counting your usable techniques and
-- excluding the one being put down:
--
--     WHERE t.base_power > 0 AND t.technique_id <> p_technique_id
--
-- which also excludes the MANUAL'S copy of that same technique. So a
-- cultivator who had learned Ember Lash and was also carrying a book that
-- teaches it - the exact "borrow before you buy" case 0130 encourages and
-- 0143 deduplicates - was told putting the learned copy down would disarm
-- them, when the book in their hand teaches it either way.
--
-- The question is not "what else do I know". It is "what could I still throw
-- afterwards", and a book teaching the very technique being forgotten answers
-- it. That lend is now computed once, before the delete, and used both for the
-- guard and for the line telling the player their manual still has it - which
-- is the same fact and was already being computed separately afterwards.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION unlearn_technique(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS TABLE (
    forgotten   TEXT,
    tech_rank   SMALLINT,
    refunded    BIGINT,
    stones_left BIGINT,
    slot_freed  BOOLEAN,
    still_lent  BOOLEAN,
    left_known  INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     RECORD;
    back   BIGINT;
    slot   BOOLEAN;
    lent   BOOLEAN;
    held   BIGINT;
    others INTEGER;
BEGIN
    SELECT t.technique_id, t.name, t.rank, t.base_power
    INTO it
    FROM player_techniques pt
    JOIN techniques t ON t.technique_id = pt.technique_id
    WHERE pt.player_id = p_player_id AND pt.technique_id = p_technique_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have not learned that'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Would an equipped manual still be teaching this after the learned copy
    -- goes? Computed here, before the delete, because the view reports a
    -- technique you both own and borrow as 'learned' (0143) - so asking it
    -- afterwards is the only way to see the book underneath, and asking it
    -- BEFORE would only ever see the copy about to be removed.
    --
    -- The rank gate is repeated rather than borrowed from the view for the
    -- same reason: this needs the manual's half of it specifically.
    SELECT EXISTS (
        SELECT 1
        FROM player_manual_slots s
        JOIN manual_techniques mt ON mt.manual_id = s.manual_id
        JOIN techniques t2 ON t2.technique_id = mt.technique_id
        LEFT JOIN player_cultivation pc ON pc.player_id = s.player_id
        LEFT JOIN realms r ON r.realm_id = pc.realm_id
        WHERE s.player_id = p_player_id
          AND mt.technique_id = p_technique_id
          AND t2.rank <= COALESCE(r.rank, 1)
    ) INTO lent;

    SELECT count(*) INTO others
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    WHERE u.player_id = p_player_id
      AND t.base_power > 0
      AND t.technique_id <> p_technique_id;

    -- Armed afterwards if something else can hurt, or if the book still holds
    -- this one.
    IF it.base_power > 0 AND others = 0 AND NOT lent THEN
        RAISE EXCEPTION
            'that is the last thing you have that could hurt anything'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM player_loadout l
        WHERE l.player_id = p_player_id AND l.technique_id = p_technique_id
    ) INTO slot;

    back := floor(technique_stone_cost(it.rank)
                  * game_config_value('technique_unlearn_refund'));

    DELETE FROM player_techniques pt
    WHERE pt.player_id = p_player_id AND pt.technique_id = p_technique_id;

    IF back > 0 THEN
        held := grant_material(p_player_id, 'spirit_stone', back);
    ELSE
        held := COALESCE((SELECT pm.quantity FROM player_materials pm
                          WHERE pm.player_id = p_player_id
                            AND pm.material_code = 'spirit_stone'), 0);
    END IF;

    RETURN QUERY
    SELECT it.name, it.rank, back, held, slot, lent,
           (SELECT count(*)::integer FROM player_techniques pt
            WHERE pt.player_id = p_player_id);
END;
$$;


DO $$
DECLARE
    ghost  BIGINT;
    book   BIGINT;
    move   BIGINT;
    gone   RECORD;
    usable INTEGER;
BEGIN
    SELECT m.manual_id, t.technique_id INTO book, move
    FROM manuals m
    JOIN manual_techniques mt ON mt.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    WHERE m.code IS NOT NULL AND t.rank = 1 AND t.base_power > 0
    LIMIT 1;

    IF book IS NULL THEN
        RAISE NOTICE 'no rank 1 manual teaches a damaging technique; nothing to probe';
        RETURN;
    END IF;

    INSERT INTO players (discord_id, discord_name)
    VALUES (-999158, 'migration 0158 probe') RETURNING player_id INTO ghost;
    INSERT INTO player_cultivation (player_id, cultivation, realm_id)
    VALUES (ghost, 0, 1);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (ghost, book);
    INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
    VALUES (ghost, 0, book);
    INSERT INTO player_techniques (player_id, technique_id) VALUES (ghost, move);

    -- The only thing learned, and the book teaches the same one. 0157 refused
    -- this; it is exactly the case the guard was written to allow.
    SELECT * INTO gone FROM unlearn_technique(ghost, move);

    IF NOT gone.still_lent THEN
        RAISE EXCEPTION 'the manual was not noticed';
    END IF;

    SELECT count(*) INTO usable FROM player_usable_techniques u
    WHERE u.player_id = ghost;
    IF usable <> 1 THEN
        RAISE EXCEPTION
            'the borrowed copy went with the learned one; % usable left', usable;
    END IF;

    DELETE FROM player_manual_slots WHERE player_id = ghost;
    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM player_techniques WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM player_cultivation WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
