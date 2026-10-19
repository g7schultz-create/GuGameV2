-- 0157_a_technique_can_be_put_down
--
-- Learning has been one-way since 0126. That was fine while a technique was
-- only ever an option - the pickers take your best against whatever is in
-- front of you, so a weak one you never throw costs nothing.
--
-- 0151 changed that. A tournament takes a technique at RANDOM out of the
-- snapshot you signed up with, so every weak move you own is a chance to swing
-- with it. Fourteen rank 1 techniques and one rank 4 means thirteen swings in
-- fourteen are the wrong swing. A cultivator ought to be able to put something
-- down.
--
-- HALF THE STONES BACK, which is what `alchemy_refund`, `forge_refund` and
-- `gu_refine_refund` all pay. It makes putting a technique down a real choice
-- rather than a free toggle: learn-and-unlearn cycling is a straight loss, so
-- there is nothing to farm here.
--
-- IT WILL NOT LEAVE YOU UNARMED. Refused if it would take the last thing you
-- have that could hurt anything - the same condition `/hunt` refuses on,
-- checked against `player_usable_techniques` so a manual lending you something
-- counts. Being talked into disarming yourself is not a decision, it is a
-- trap.
--
-- The loadout needs no attention: `player_loadout`'s composite foreign key
-- into `player_techniques` cascades, so a slot holding this empties itself.
--
-- (The probe's variable is `keeper` rather than the obvious `only`: ONLY is
-- reserved in Postgres, the keyword in SELECT ... FROM ONLY table. Fourth
-- reserved word this week, after `both` twice and `placing`.)
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('technique_unlearn_refund', 0.5,
     'Share of the Spirit Stones handed back for putting a technique down. Half, as every other craft in this game refunds - so cycling is a loss and there is nothing to farm.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


CREATE FUNCTION unlearn_technique(p_player_id BIGINT, p_technique_id BIGINT)
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

    -- What would be left that could hurt something. An equipped manual counts,
    -- which is why this reads the view rather than `player_techniques`.
    SELECT count(*) INTO others
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    WHERE u.player_id = p_player_id
      AND t.base_power > 0
      AND t.technique_id <> p_technique_id;

    IF it.base_power > 0 AND others = 0 THEN
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

    -- The loadout row goes with it, by the composite foreign key from 0004.
    DELETE FROM player_techniques pt
    WHERE pt.player_id = p_player_id AND pt.technique_id = p_technique_id;

    IF back > 0 THEN
        held := grant_material(p_player_id, 'spirit_stone', back);
    ELSE
        held := COALESCE((SELECT pm.quantity FROM player_materials pm
                          WHERE pm.player_id = p_player_id
                            AND pm.material_code = 'spirit_stone'), 0);
    END IF;

    -- An equipped manual may still be teaching it, in which case putting it
    -- down bought the stones back and changed nothing else. Worth saying so.
    SELECT EXISTS (
        SELECT 1 FROM player_usable_techniques u
        WHERE u.player_id = p_player_id AND u.technique_id = p_technique_id
    ) INTO lent;

    RETURN QUERY
    SELECT it.name, it.rank, back, held, slot, lent,
           (SELECT count(*)::integer FROM player_techniques pt
            WHERE pt.player_id = p_player_id);
END;
$$;

COMMENT ON FUNCTION unlearn_technique(BIGINT, BIGINT) IS
    'Puts a learned technique down for half its price back. Refuses if it is the last thing that could hurt anything, and the loadout slot empties itself by cascade.';


DO $$
DECLARE
    ghost BIGINT;
    weak  BIGINT;
    keeper BIGINT;
    gone  RECORD;
    before_stones BIGINT;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999157, 'migration 0157 probe') RETURNING player_id INTO ghost;
    INSERT INTO player_cultivation (player_id, cultivation, realm_id)
    VALUES (ghost, 0, 1);

    SELECT technique_id INTO keeper FROM techniques
    WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0
    ORDER BY technique_id LIMIT 1;
    SELECT technique_id INTO weak FROM techniques
    WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0
      AND technique_id <> keeper
    ORDER BY technique_id LIMIT 1;

    INSERT INTO player_techniques (player_id, technique_id)
    VALUES (ghost, keeper), (ghost, weak);
    INSERT INTO player_loadout (player_id, slot_index, technique_id)
    VALUES (ghost, 0, weak);

    before_stones := COALESCE((SELECT quantity FROM player_materials
                               WHERE player_id = ghost
                                 AND material_code = 'spirit_stone'), 0);

    SELECT * INTO gone FROM unlearn_technique(ghost, weak);

    IF gone.refunded <= 0 THEN
        RAISE EXCEPTION 'putting a technique down handed back nothing';
    END IF;
    IF gone.stones_left <> before_stones + gone.refunded THEN
        RAISE EXCEPTION 'the refund did not reach the purse';
    END IF;
    IF NOT gone.slot_freed THEN
        RAISE EXCEPTION 'the screen did not notice the loadout slot';
    END IF;
    IF EXISTS (SELECT 1 FROM player_loadout WHERE player_id = ghost
                                              AND technique_id = weak) THEN
        RAISE EXCEPTION 'the loadout kept a technique nobody knows';
    END IF;
    IF gone.left_known <> 1 THEN
        RAISE EXCEPTION 'two learned minus one is %', gone.left_known;
    END IF;

    -- And the last one that could hurt anything stays put.
    BEGIN
        PERFORM unlearn_technique(ghost, keeper);
        RAISE EXCEPTION 'a cultivator was allowed to disarm themselves';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- Something never learned cannot be put down.
    BEGIN
        PERFORM unlearn_technique(ghost, weak);
        RAISE EXCEPTION 'a technique nobody knows was forgotten again';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    DELETE FROM player_loadout WHERE player_id = ghost;
    DELETE FROM player_techniques WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM player_cultivation WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
