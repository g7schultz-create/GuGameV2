-- 0172_a_manual_read_until_it_falls_apart
--
-- A technique manual gives exactly half the bonus of a stat manual at the
-- same tier - 0130 wrote it that way - and there are only two manual slots.
-- So an advanced technique costs one of two slots forever, at half the stat
-- value that slot could otherwise carry. There has never been a way to stop
-- paying that rent.
--
--   tier 2   stat 0.10   technique 0.05
--   tier 4   stat 0.21   technique 0.105
--   tier 6   stat 0.36   technique 0.18
--
-- The half is right as RENT. What was missing is the option to buy. Studying
-- takes the technique out of the book permanently and the book leaves your
-- hands: `player_manuals` loses the row, the equipped slot cascades away with
-- it, and `collect_unowned_manual` turns a refined one to actual dust because
-- nobody owns it any more. A canonical one keeps its definition - eighteen
-- other cultivators may hold a copy - but yours is gone.
--
-- THE GATE IS THE WHOLE DESIGN. Studying frees the slot and keeps the move,
-- so without a cost that wearing does not have, nobody would ever equip a
-- technique manual again and the half-budget would stop meaning anything.
-- Wearing asks for realm rank alone. Studying asks for realm rank AND the
-- attainment `/learn` demands of a basic technique at that rank -
-- `technique_required_tier` - in the manual's dominant Path. Rank 3 wants
-- Expert; rank 5 wants Master. So you rent early and own once you have
-- actually mastered the Path, which is when a cultivator has earned the slot
-- back.
--
-- Only 'technique' manuals. Stat manuals carry a BASIC technique too - 22 of
-- them do - and those are on the shelf for stones. Studying one would destroy
-- a manual to get something buyable.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION study_manual(p_player_id BIGINT, p_manual_id BIGINT)
RETURNS TABLE (
    manual_name    TEXT,
    technique_id   BIGINT,
    technique_name TEXT,
    technique_rank SMALLINT,
    path_name      TEXT,
    stones_spent   BIGINT,
    stones_left    BIGINT,
    slot_freed     BOOLEAN,
    crumbled       BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    book    manuals%ROWTYPE;
    move    RECORD;
    realm   SMALLINT;
    have    SMALLINT;
    want    SMALLINT;
    cost    BIGINT;
    left_n  BIGINT;
    equipped BOOLEAN;
    dust    BOOLEAN;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM player_manuals pm
        WHERE pm.player_id = p_player_id AND pm.manual_id = p_manual_id
    ) THEN
        RAISE EXCEPTION 'that is not yours to read'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO book FROM manuals WHERE manual_id = p_manual_id;

    IF book.archetype <> 'technique' THEN
        RAISE EXCEPTION
            'there is no killer move in that one - what it teaches is on the '
            'shelf for stones, and burning a manual is a poor way to buy it'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT t.technique_id, t.name, t.rank, t.grade,
           dom.path_code, dom.path_name
    INTO move
    FROM manual_techniques mt
    JOIN techniques t ON t.technique_id = mt.technique_id
    CROSS JOIN LATERAL (
        SELECT tp.path_code, p.name AS path_name
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        WHERE tp.technique_id = t.technique_id
        ORDER BY tp.weight DESC, p.sort_order
        LIMIT 1
    ) dom
    WHERE mt.manual_id = p_manual_id
    ORDER BY t.rank DESC, t.base_power DESC
    LIMIT 1;

    IF move IS NULL THEN
        RAISE EXCEPTION 'there is nothing written in it to learn'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM player_techniques pt
        WHERE pt.player_id = p_player_id AND pt.technique_id = move.technique_id
    ) THEN
        RAISE EXCEPTION 'you already know %', move.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same realm gate wearing it has, so studying is never the easier of
    -- the two on the axis they share.
    SELECT COALESCE(r.rank, 0) INTO realm
    FROM (SELECT 1) _
    LEFT JOIN player_cultivation pc ON pc.player_id = p_player_id
    LEFT JOIN realms r ON r.realm_id = pc.realm_id;

    IF move.rank > realm THEN
        RAISE EXCEPTION
            '% is a rank % move and you are realm % - you could carry the '
            'book, but not read it',
            move.name, move.rank, realm
            USING ERRCODE = 'check_violation';
    END IF;

    -- And the gate wearing does NOT have, which is the whole reason both
    -- ways of holding a technique remain worth something.
    want := technique_required_tier(move.rank);
    SELECT COALESCE(a.tier, 0) INTO have
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
           ON a.player_id = p_player_id AND a.path_code = move.path_code;

    IF have < want THEN
        RAISE EXCEPTION
            'reading it needs %s in the % - you are %s. Carry it equipped '
            'until then',
            (SELECT name FROM attainment_tiers WHERE tier = want),
            move.path_name,
            (SELECT name FROM attainment_tiers WHERE tier = have)
            USING ERRCODE = 'check_violation';
    END IF;

    cost := technique_stone_cost(move.rank);
    IF COALESCE((SELECT pm.quantity FROM player_materials pm
                 WHERE pm.player_id = p_player_id
                   AND pm.material_code = 'spirit_stone'), 0) < cost THEN
        RAISE EXCEPTION 'studying it costs % Spirit Stones', cost
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything is settled; now it is spent.
    left_n := spend_material(p_player_id, 'spirit_stone', cost);

    INSERT INTO player_techniques (player_id, technique_id)
    VALUES (p_player_id, move.technique_id);

    equipped := EXISTS (
        SELECT 1 FROM player_manual_slots sl
        WHERE sl.player_id = p_player_id AND sl.manual_id = p_manual_id
    );

    -- The slot cascades off this delete, and `collect_unowned_manual` turns a
    -- refined book to dust on it. Neither needs saying here beyond the fact
    -- that both happen.
    DELETE FROM player_manuals
    WHERE player_id = p_player_id AND manual_id = p_manual_id;

    dust := NOT EXISTS (SELECT 1 FROM manuals WHERE manual_id = p_manual_id);

    RETURN QUERY SELECT book.name, move.technique_id, move.name, move.rank,
                        move.path_name, cost, left_n, equipped, dust;
END;
$$;


-- Read for real by a throwaway cultivator, inside a subtransaction that is
-- rolled away. The failure worth catching is a manual that leaves the satchel
-- without the technique arriving.

DO $$
DECLARE
    book   BIGINT;
    move   BIGINT;
    rank_n SMALLINT;
    path_c TEXT;
    who    BIGINT;
    got    RECORD;
BEGIN
    SELECT m.manual_id, t.technique_id, t.rank,
           (SELECT tp.path_code FROM technique_paths tp
            WHERE tp.technique_id = t.technique_id
            ORDER BY tp.weight DESC LIMIT 1)
    INTO book, move, rank_n, path_c
    FROM manuals m
    JOIN manual_techniques mt ON mt.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    WHERE m.archetype = 'technique'
    ORDER BY t.rank
    LIMIT 1;

    IF book IS NULL THEN
        RAISE NOTICE 'no technique manual to probe with; tests carry it';
        RETURN;
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-9101, 'Probe Reader') RETURNING player_id INTO who;

        INSERT INTO player_cultivation (player_id, cultivation, realm_id)
        SELECT who, 0, min(realm_id) FROM realms WHERE rank >= rank_n;

        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (who, path_c, 1000000, technique_required_tier(rank_n));

        INSERT INTO player_manuals (player_id, manual_id) VALUES (who, book);
        PERFORM grant_material(who, 'spirit_stone',
                               technique_stone_cost(rank_n) + 10);

        SELECT * INTO got FROM study_manual(who, book);

        IF NOT EXISTS (SELECT 1 FROM player_techniques
                       WHERE player_id = who AND technique_id = move) THEN
            RAISE EXCEPTION 'the book was spent and nothing was learned';
        END IF;
        IF EXISTS (SELECT 1 FROM player_manuals
                   WHERE player_id = who AND manual_id = book) THEN
            RAISE EXCEPTION 'the book survived being studied';
        END IF;
        IF got.stones_spent <> technique_stone_cost(rank_n) THEN
            RAISE EXCEPTION 'charged % rather than %',
                got.stones_spent, technique_stone_cost(rank_n);
        END IF;

        -- And a second reading is refused rather than eating another copy.
        INSERT INTO player_manuals (player_id, manual_id) VALUES (who, book);
        BEGIN
            PERFORM * FROM study_manual(who, book);
            RAISE EXCEPTION 'it was studied twice';
        EXCEPTION
            WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%already know%' THEN
                    RAISE EXCEPTION 'refused for the wrong reason: %', SQLERRM;
                END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
