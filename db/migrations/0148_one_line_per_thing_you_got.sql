-- 0148_one_line_per_thing_you_got
--
-- A world beast rolls its corpse and its boss-only spoils, and 0146 allowed
-- the same material on doubled on purpose: the Leviathan yields four to eight
-- Dragon Whale Bone on top of the two to five the corpse already gives, and
-- bulk is a fair reward.
--
-- What it should NOT do is report them separately. The kill announcement came
-- out as
--
--     grafv - 170 stones - Dragon Whale Bone x6 - Dragon Whale Bone x3
--
-- which is the screen being literal about the implementation. He got nine.
--
-- Both rolls still happen - two sources, two chances, which is the whole point
-- of the second table - they are summed per material before anything is
-- granted or written down. Fixed here rather than in the two screens that draw
-- it, because a payout that is one thing should be one row everywhere,
-- including in the ledger 0147 keeps.
--
-- (The probe's variable is `doubled` rather than the obvious `both`: BOTH is
-- reserved in Postgres, the keyword in trim(both '.' from x). 0143 learned
-- this and it did not stick.)
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION claim_boss_reward(p_player_id BIGINT)
RETURNS TABLE (
    encounter_id BIGINT,
    beast_name   TEXT,
    outcome      TEXT,
    my_damage    BIGINT,
    my_share     NUMERIC,
    stones       BIGINT,
    jade         BIGINT,
    spoils       JSONB,
    manual       TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    owed   RECORD;
    dealt  BIGINT;
    share  NUMERIC;
    weight NUMERIC;
    paid   BIGINT;
    coin   BIGINT := 0;
    d      RECORD;
    loot   JSONB := '[]'::jsonb;
    book   BIGINT;
    book_name TEXT;
BEGIN
    SELECT e.encounter_id, e.species_id, e.status, e.slayer_id,
           cs.name, bs.damage
    INTO owed
    FROM boss_strikes bs
    JOIN boss_encounters e ON e.encounter_id = bs.encounter_id
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE bs.player_id = p_player_id
      AND bs.rewarded_at IS NULL
      AND e.status <> 'open'
    ORDER BY e.ended_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have nothing owing from a world beast'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(bs.damage), 0) INTO dealt
    FROM boss_strikes bs WHERE bs.encounter_id = owed.encounter_id;

    share  := CASE WHEN dealt > 0 THEN owed.damage::numeric / dealt ELSE 0 END;
    weight := LEAST(1, 0.35 + 0.65 * share);

    paid := GREATEST(1, round(owed.damage * game_config_value('boss_stones_per_hp')
                              * CASE WHEN owed.status = 'slain' THEN 1 ELSE 0.5 END));
    PERFORM grant_material(p_player_id, 'spirit_stone', paid);

    coin := game_config_value('boss_jade_min')
            + floor(random() * (game_config_value('boss_jade_max')
                                - game_config_value('boss_jade_min') + 1));
    IF owed.status <> 'slain' THEN
        coin := GREATEST(1, round(coin / 2.0));
    END IF;
    PERFORM grant_jade(p_player_id, coin, 'world_beast');

    IF owed.status = 'slain' THEN
        -- Each source rolls on its own - two tables, two chances - and the
        -- results are summed per material, so a thing that came from doubled is
        -- granted once and read once.
        FOR d IN
            SELECT x.material_code, m.name, m.emoji,
                   sum(
                       CASE WHEN random() < x.chance * weight
                            THEN x.min_quantity
                                 + floor(random()
                                         * (x.max_quantity - x.min_quantity + 1))
                            ELSE 0 END
                   )::integer AS quantity
            FROM (
                SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity
                FROM creature_drops cd WHERE cd.species_id = owed.species_id
                UNION ALL
                SELECT bd.material_code, bd.chance, bd.min_quantity, bd.max_quantity
                FROM boss_drops bd WHERE bd.species_id = owed.species_id
            ) x
            JOIN materials m ON m.code = x.material_code
            GROUP BY x.material_code, m.name, m.emoji
        LOOP
            IF d.quantity > 0 THEN
                PERFORM grant_material(p_player_id, d.material_code, d.quantity);
                loot := loot || jsonb_build_object(
                    'code', d.material_code, 'name', d.name,
                    'emoji', d.emoji, 'quantity', d.quantity);
            END IF;
        END LOOP;

        IF random() < game_config_value('boss_manual_chance') * weight THEN
            SELECT m.manual_id, m.name INTO book, book_name
            FROM manuals m
            WHERE m.code IS NOT NULL
              AND m.archetype = 'technique'
              AND NOT EXISTS (
                  SELECT 1 FROM player_manuals pm
                  WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
              )
            ORDER BY random()
            LIMIT 1;

            IF book IS NOT NULL THEN
                INSERT INTO player_manuals (player_id, manual_id)
                VALUES (p_player_id, book)
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;
    END IF;

    UPDATE boss_strikes bs
    SET rewarded_at = now(),
        stones_paid = paid,
        jade_paid   = coin,
        spoils      = loot,
        manual_won  = book_name
    WHERE bs.encounter_id = owed.encounter_id AND bs.player_id = p_player_id;

    RETURN QUERY SELECT owed.encounter_id, owed.name, owed.status,
                        owed.damage, round(share, 4), paid, coin, loot, book_name;
END;
$$;


-- A material must appear at most once in a payout, and the double roll must
-- still be happening - a beast whose two tables collapsed into one would pass
-- the first check and quietly halve the reward.
DO $$
DECLARE
    ghost   BIGINT;
    beast   BIGINT;
    pay     RECORD;
    names   INTEGER;
    uniques INTEGER;
    bulk    INTEGER := 0;
    doubled    TEXT;
BEGIN
    SELECT bd.material_code INTO doubled
    FROM boss_drops bd
    JOIN creature_drops cd ON cd.species_id = bd.species_id
                          AND cd.material_code = bd.material_code
    LIMIT 1;
    IF doubled IS NULL THEN
        RAISE EXCEPTION 'no material is on both tables, so this fixes nothing';
    END IF;

    INSERT INTO players (discord_id, discord_name)
    VALUES (-999148, 'migration 0148 probe') RETURNING player_id INTO ghost;

    FOR i IN 1..25 LOOP
        INSERT INTO boss_encounters
            (species_id, region_code, max_hp, current_hp, status, closes_at,
             ended_at, slayer_id)
        SELECT cd.species_id, 'eastern', 100, 0, 'slain',
               now() + interval '1 day', now(), ghost
        FROM creature_drops cd
        WHERE cd.material_code = doubled LIMIT 1
        RETURNING encounter_id INTO beast;

        INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage)
        VALUES (beast, ghost, 25, 5000);

        SELECT * INTO pay FROM claim_boss_reward(ghost);

        SELECT count(*), count(DISTINCT item ->> 'code')
        INTO names, uniques
        FROM jsonb_array_elements(pay.spoils) AS item;

        IF names <> uniques THEN
            RAISE EXCEPTION 'a material was listed % times in one payout',
                names - uniques + 1;
        END IF;

        -- Somewhere in twenty-five payouts the doubled material has to come
        -- back with more than either table alone could give, or only one roll
        -- is happening.
        SELECT max((item ->> 'quantity')::int) INTO bulk
        FROM jsonb_array_elements(pay.spoils) AS item
        WHERE item ->> 'code' = doubled;

        EXIT WHEN bulk > (
            SELECT max(cd.max_quantity) FROM creature_drops cd
            WHERE cd.material_code = doubled
        );

        DELETE FROM boss_strikes WHERE encounter_id = beast;
        DELETE FROM boss_encounters WHERE encounter_id = beast;
    END LOOP;

    IF bulk IS NULL OR bulk <= (
        SELECT max(cd.max_quantity) FROM creature_drops cd
        WHERE cd.material_code = doubled
    ) THEN
        RAISE EXCEPTION
            'in twenty-five payouts % never exceeded one table''s worth; the second roll is gone',
            doubled;
    END IF;

    DELETE FROM boss_strikes WHERE player_id = ghost;
    DELETE FROM boss_encounters WHERE slayer_id = ghost;
    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
