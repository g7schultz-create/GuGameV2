-- 0567_gear_that_can_be_raised
--
-- A piece of equipment's LEVEL is fixed the moment it is made and nothing in
-- the game has ever been able to change it. `forge` sets it from the realm of
-- whoever swung the hammer; `fuse_equipment` raises RANK and explicitly
-- refuses two pieces whose levels differ; nothing else writes it at all.
--
-- That is a problem everywhere and a disaster for dropped gear, because
-- `dungeon_mint_equipment` does not set the column - it takes the default:
--
--     level  DEFAULT 1       ->  equipment_level_scales says max_rank 2
--
-- while a forged piece is born at its smith's realm and reaches level 18 and
-- rank 5. The world as it stands:
--
--     tier 9   9 pieces    every one at level 1, rank ceiling 2
--     tier 8  69 pieces    up to level 18, rank 5
--
-- So the deepest gear anybody has ever pulled out of a room is permanently
-- capped at two effects, while a tier 8 off an anvil carries five. The Vault's
-- tier 10 piece would have landed in exactly the same hole.
--
-- SO A PIECE CAN BE FED. Two ways into the same meter, both asked for:
--
--   MATERIALS - herbs, ore, hide. Worth `tier^2` each, so a deep material is
--   worth eighty-one times a shallow one rather than nine times it: pouring
--   in rank 1 weeds should not be a route to a rank 18 sword. Beast parts
--   carry no tier and are priced off the beast they came from.
--
--   OTHER GEAR - a piece fed in is worth what it IS: its tier, its level and
--   the rank it reached. Fusing already eats a twin to raise rank; this eats
--   anything to raise level, which is what somebody with a pile of unusable
--   drops actually wants to do with them.
--
-- Currency is deliberately not food. Spirit stones are held in the quadrillions
-- and would make the meter meaningless in one pour.
--
-- Nothing already owned changes. `exp` starts at zero on every existing piece
-- and levels are left exactly where they are - this opens a road forward, it
-- does not retroactively promote anybody's shelf.


ALTER TABLE player_equipment
    ADD COLUMN exp BIGINT NOT NULL DEFAULT 0 CHECK (exp >= 0);

COMMENT ON COLUMN player_equipment.exp IS
    'Work poured into this piece since it was made, in the direction of the next level. Spent on each level and carried over past it. 0567.';


INSERT INTO game_config (key, value, description) VALUES
    ('equipment_exp_base', 240,
     'Work to take a piece from level 1 to level 2. Every level after costs `equipment_exp_growth` times the one before.'),
    ('equipment_exp_growth', 1.42,
     'How much dearer each equipment level is than the one below it. Geometric, because the rank ceiling it buys is not.'),
    ('equipment_exp_per_material_tier', 1.0,
     'Multiplier on the `tier^2` a fed material is worth. Squared rather than linear so a deep material is worth eighty-one shallow ones, and a pile of weeds is not a road to the top.'),
    ('equipment_exp_gear_scale', 6.0,
     'Multiplier on what a piece of equipment fed into another is worth: tier^2 x level x (1 + rank) x this.');


-- ---------------------------------------------------------------------------
-- What a level costs, and what a thing is worth
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION equipment_exp_needed(p_level SMALLINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    -- NULL at the top of the ladder, which is how every caller knows to stop
    -- rather than by comparing against a number written somewhere else.
    SELECT CASE
        WHEN p_level >= (SELECT max(level) FROM equipment_level_scales)
        THEN NULL
        ELSE GREATEST(1, round(
            game_config_value('equipment_exp_base')
            * power(game_config_value('equipment_exp_growth'),
                    GREATEST(0, p_level - 1))))::bigint
    END;
$fn$;


CREATE OR REPLACE FUNCTION equipment_food_value(p_material_code TEXT, p_quantity BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    -- `tier^2`, so depth matters more than volume. A beast part carries no
    -- tier of its own - it is priced off the rank of the beast it came from,
    -- which is the same information wearing a different name.
    SELECT GREATEST(0, round(
        p_quantity
        * game_config_value('equipment_exp_per_material_tier')
        * power(GREATEST(1, COALESCE(
            m.tier,
            -- `beast_parts` names the part and nothing else - the link to
            -- a creature lives in `creature_drops`, which is what actually
            -- knows how deep a hide is.
            (SELECT max(cs.rank) FROM creature_drops cd
             JOIN creature_species cs ON cs.species_id = cd.species_id
             WHERE cd.material_code = m.code),
            1)), 2)
    ))::bigint
    FROM materials m
    WHERE m.code = p_material_code
      -- CURRENCY IS NOT FOOD, and `category` does not say which is which:
      -- Spirit Stone is filed under `gathering` beside the herbs, so a
      -- category test let a quadrillion stones max any piece in one pour.
      -- The probe caught it.
      --
      -- A TIER is the real signal. Spirit Stone, Spirit Jade and Dungeon Key
      -- are the three materials with none - they are counters rather than
      -- things - and the only other tierless materials are beast parts, which
      -- are food and are admitted by name.
      AND (m.tier IS NOT NULL OR m.category = 'beast');
$fn$;


-- ---------------------------------------------------------------------------
-- Pouring it in
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION equipment_absorb(p_equipment_id BIGINT, p_exp BIGINT)
RETURNS TABLE (level_before SMALLINT, level_after SMALLINT, exp_after BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    piece RECORD;
    need  BIGINT;
    pool  BIGINT;
    was   SMALLINT;
    now_l SMALLINT;
BEGIN
    SELECT * INTO piece FROM player_equipment WHERE equipment_id = p_equipment_id
    FOR UPDATE;
    was   := piece.level;
    now_l := piece.level;
    pool  := piece.exp + GREATEST(0, p_exp);

    -- A LOOP, because one pour can carry a piece through several levels and
    -- stopping at the first would quietly eat the rest.
    LOOP
        need := equipment_exp_needed(now_l);
        EXIT WHEN need IS NULL OR pool < need;
        pool  := pool - need;
        now_l := now_l + 1;
    END LOOP;

    -- At the top of the ladder there is nothing left to buy, so the meter is
    -- not allowed to fill with work that can never be spent.
    IF equipment_exp_needed(now_l) IS NULL THEN
        pool := 0;
    END IF;

    UPDATE player_equipment
    SET level = now_l, exp = pool
    WHERE equipment_id = p_equipment_id;

    RETURN QUERY SELECT was, now_l, pool;
END;
$fn$;


CREATE OR REPLACE FUNCTION feed_equipment(
    p_player_id BIGINT, p_equipment_id BIGINT,
    p_material_code TEXT, p_quantity BIGINT
)
RETURNS TABLE (level_before SMALLINT, level_after SMALLINT,
               exp_gained BIGINT, exp_after BIGINT, toward BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    piece RECORD;
    worth BIGINT;
    got   RECORD;
BEGIN
    SELECT * INTO piece FROM player_equipment
    WHERE equipment_id = p_equipment_id AND owner_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that piece is not yours'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Worn gear is snapshotted into fights, the same reason fusing refuses it.
    IF EXISTS (SELECT 1 FROM player_equipped e
               WHERE e.equipment_id = p_equipment_id) THEN
        RAISE EXCEPTION 'take it off before working on it'
            USING ERRCODE = 'check_violation';
    END IF;

    IF equipment_exp_needed(piece.level) IS NULL THEN
        RAISE EXCEPTION 'that piece is already at the top of its ladder'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'feed it something' USING ERRCODE = 'check_violation';
    END IF;

    worth := equipment_food_value(p_material_code, p_quantity);
    IF COALESCE(worth, 0) <= 0 THEN
        RAISE EXCEPTION 'an anvil has no use for that'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refuses rather than going negative, so a short stack costs nothing.
    PERFORM spend_material(p_player_id, p_material_code, p_quantity);

    SELECT * INTO got FROM equipment_absorb(p_equipment_id, worth);
    RETURN QUERY SELECT got.level_before, got.level_after, worth, got.exp_after,
                        equipment_exp_needed(got.level_after);
END;
$fn$;


CREATE OR REPLACE FUNCTION feed_equipment_gear(
    p_player_id BIGINT, p_keeper BIGINT, p_fodder BIGINT
)
RETURNS TABLE (level_before SMALLINT, level_after SMALLINT,
               exp_gained BIGINT, exp_after BIGINT, toward BIGINT,
               eaten TEXT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    keep  RECORD;
    feed  RECORD;
    worth BIGINT;
    got   RECORD;
BEGIN
    SELECT * INTO keep FROM player_equipment
    WHERE equipment_id = p_keeper AND owner_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that piece is not yours'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO feed FROM player_equipment
    WHERE equipment_id = p_fodder AND owner_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'the piece being fed in is not yours'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_keeper = p_fodder THEN
        RAISE EXCEPTION 'a piece cannot be fed to itself'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_equipped e
               WHERE e.equipment_id IN (p_keeper, p_fodder)) THEN
        RAISE EXCEPTION 'take it off before working on it'
            USING ERRCODE = 'check_violation';
    END IF;

    IF equipment_exp_needed(keep.level) IS NULL THEN
        RAISE EXCEPTION 'that piece is already at the top of its ladder'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Worth what it IS: how deep, how far raised, and what rank it reached.
    worth := GREATEST(1, round(
        power(GREATEST(1, feed.tier), 2)
        * GREATEST(1, feed.level)
        * (1 + GREATEST(0, feed.rank))
        * game_config_value('equipment_exp_gear_scale')))::bigint;

    DELETE FROM player_equipment WHERE equipment_id = p_fodder;

    SELECT * INTO got FROM equipment_absorb(p_keeper, worth);
    RETURN QUERY SELECT got.level_before, got.level_after, worth, got.exp_after,
                        equipment_exp_needed(got.level_after), feed.name;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_a    BIGINT;
    v_b    BIGINT;
    v_got  RECORD;
    v_lvl  SMALLINT;
    v_top  SMALLINT;
    v_sum  BIGINT := 0;
BEGIN
    SELECT max(level) INTO v_top FROM equipment_level_scales;

    -- 1. THE LADDER CLIMBS AND ENDS. A level that cost the same as the one
    --    below it would make the top free; one that never returned NULL would
    --    let a piece eat for ever.
    -- `FOR i IN` declares its own INTEGER and shadows the SMALLINT above, so
    -- every call is cast rather than relying on the declaration.
    FOR i IN 1..(v_top - 1) LOOP
        IF equipment_exp_needed(i::smallint) IS NULL THEN
            RAISE EXCEPTION 'level % has no price', i;
        END IF;
        IF i > 1 AND equipment_exp_needed(i::smallint)
                     <= equipment_exp_needed((i - 1)::smallint) THEN
            RAISE EXCEPTION 'level % is no dearer than the one below it', i;
        END IF;
        v_sum := v_sum + equipment_exp_needed(i::smallint);
    END LOOP;
    IF equipment_exp_needed(v_top) IS NOT NULL THEN
        RAISE EXCEPTION 'the top of the ladder still has a price above it';
    END IF;
    RAISE NOTICE
        'level 1 to % costs % work in total; the last step alone is %',
        v_top, v_sum, equipment_exp_needed((v_top - 1)::smallint);

    -- 2. CURRENCY IS NOT FOOD.
    IF COALESCE(equipment_food_value('spirit_stone', 1000000), 0) <> 0 THEN
        RAISE EXCEPTION 'spirit stones can be poured into a sword';
    END IF;

    -- 3. AND DEPTH BEATS VOLUME. The whole reason the value is squared.
    IF (SELECT equipment_food_value(m.code, 1) FROM materials m
        WHERE m.tier = 13 LIMIT 1)
       <= (SELECT equipment_food_value(m.code, 1) * 50 FROM materials m
           WHERE m.tier = 1 LIMIT 1) THEN
        RAISE EXCEPTION
            'fifty shallow materials outvalue one deep one - volume wins';
    END IF;

    -- 4. PLAYED: a piece is made, fed, and rises - then a second piece is fed
    --    to it and it rises again.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1801, 'anvil-probe') RETURNING player_id INTO v_who;

        -- `ore_code` is NOT NULL: a piece is made OF something, and the
        -- probe has to say so like the forge does.
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, ore_code)
        SELECT v_who, 'Probe Blade', s.code, 10, 'legendary', 80,
               (SELECT material_code FROM ores ORDER BY tier DESC LIMIT 1)
        FROM equipment_slots s ORDER BY s.code LIMIT 1
        RETURNING equipment_id INTO v_a;

        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, level, rank, ore_code)
        SELECT v_who, 'Probe Fodder', s.code, 9, 'rare', 50, 12, 3,
               (SELECT material_code FROM ores ORDER BY tier DESC LIMIT 1)
        FROM equipment_slots s ORDER BY s.code LIMIT 1
        RETURNING equipment_id INTO v_b;

        -- Materials first.
        PERFORM grant_material(v_who, m.code, 500)
        FROM materials m WHERE m.tier = 13 LIMIT 1;

        SELECT * INTO v_got FROM feed_equipment(
            v_who, v_a, (SELECT code FROM materials WHERE tier = 13 LIMIT 1), 500);

        IF v_got.level_after <= v_got.level_before THEN
            RAISE EXCEPTION
                'five hundred of the deepest material raised nothing (% work)',
                v_got.exp_gained;
        END IF;
        RAISE NOTICE
            'five hundred tier 13 materials: level % -> %',
            v_got.level_before, v_got.level_after;

        -- Then a whole piece of gear.
        SELECT * INTO v_got FROM feed_equipment_gear(v_who, v_a, v_b);
        RAISE NOTICE
            'feeding in "%": level % -> %, % work',
            v_got.eaten, v_got.level_before, v_got.level_after, v_got.exp_gained;

        IF EXISTS (SELECT 1 FROM player_equipment WHERE equipment_id = v_b) THEN
            RAISE EXCEPTION 'the piece that was fed in is still on the shelf';
        END IF;

        -- 5. AND A WORN PIECE IS REFUSED, the same rule fusing has.
        INSERT INTO player_equipped (player_id, slot, equipment_id)
        SELECT v_who, e.slot, v_a FROM player_equipment e WHERE e.equipment_id = v_a;
        BEGIN
            PERFORM feed_equipment(v_who, v_a,
                (SELECT code FROM materials WHERE tier = 13 LIMIT 1), 1);
            RAISE EXCEPTION 'a worn piece was worked on';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 6. NOBODY'S SHELF MOVED. The column is new and defaults to zero; no
    --    existing piece should have gained a level from this migration.
    IF EXISTS (SELECT 1 FROM player_equipment WHERE exp <> 0) THEN
        RAISE EXCEPTION 'an existing piece already carries work';
    END IF;
END
$probe$;
