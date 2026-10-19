-- 0213_a_room_worth_opening
--
-- The dungeon paid Spirit Stones and, from rank 5, a little Jade. Nothing
-- else. Against entry costs that climb about 2.8x a rank while the pot climbed
-- linearly at 900 a rank, the two crossed between rank 3 and rank 4 and never
-- came back: The First Burrow cost 800,000 stones and paid 8,100, a hundredth
-- of the fee. Only the difficulty multiplier rescued it, which made the
-- difficulty choice no choice at all - Insane pays 11x for the same entry, so
-- Insane was the only sane button.
--
-- CLEARING IT RETURNS THE STAKE. Every stone and every jade a raider paid at
-- the door comes back to THAT raider on a win - not into the pot, because a
-- stake is not spoils and splitting it by damage would mean the raider who
-- died first paid for everyone else. The stones pot is now a bonus on top,
-- and it keeps its difficulty scaling. A wipe still costs the stake; the door
-- was opened either way, and the key still comes back.
--
-- That alone makes every rank worth running, and it makes the difficulty a
-- real question again: Normal returns your stake plus a little, Insane returns
-- your stake plus a lot, and the boss has 6.5x the health.
--
-- AND THE ROOM HAS THINGS IN IT. Five more kinds, rolled per raider:
--
--     herbs        always - the pile scales with rank and difficulty
--     pages        usually
--     equipment    sometimes, forged the way /forge forges
--     a pill       sometimes, brewed the way /brew brews
--     a Gu         rarely
--
-- Everything is minted through the same rules the crafting professions use, so
-- a dungeon piece is a piece and not a special case: the quality comes off the
-- harmony roll through `equipment_qualities`, the magnitudes off
-- `equipment_tiers` and `slot_effects` and the ore's signature, the pill's
-- through `pill_tiers` and `pill_kind_for`. A found item can be traded,
-- auctioned, worn and swallowed like any other, because it IS any other.
--
-- Difficulty raises the harmony roll rather than handing out a better band
-- directly - so an Insane clear tends to produce Legendary gear the same way a
-- good smith does, through a better result and not through a different table.
--
-- THE GU RESPECTS THE WORLD'S CEILING. A dungeon is part of the world, so
-- `gu_max_droppable_rank` binds here too: the rank 9 room does not hand out
-- Immortal Gu while every other corpse in the game is barred from it. Raising
-- that one config opens both at once, which is the point of it being one.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_refund_on_clear', 1,
     'A cleared dungeon returns each raider the stones and jade they paid at '
     'the door. The pot is a bonus on top. Set to 0 to make a run a gamble '
     'again.'),
    ('dungeon_herb_per_rank', 14,
     'Herbs in the pile per rank of the dungeon, before difficulty. Split '
     'across two or three kinds that grow at or below that rank.'),
    ('dungeon_page_chance', 0.60,
     'Chance of a manual page per raider on a clear, before difficulty.'),
    ('dungeon_equipment_chance', 0.30,
     'Chance of a forged piece per raider on a clear, before difficulty.'),
    ('dungeon_pill_chance', 0.28,
     'Chance of a pill per raider on a clear, before difficulty.'),
    ('dungeon_gu_chance', 0.10,
     'Chance of a whole Gu per raider on a clear, before difficulty. The '
     'rarest thing in the room, and still far commoner than a corpse.');


-- ---------------------------------------------------------------------------
-- A piece, forged by whatever left it there
-- ---------------------------------------------------------------------------
-- The same shape `forge` uses, minus the smith: there is no Smith's Hand on a
-- piece nobody made, and no parts list, so the share the parts would have
-- carried goes to the slot instead. A found piece is whole rather than thin.

CREATE FUNCTION dungeon_mint_equipment(
    p_player_id BIGINT,
    p_rank      SMALLINT,
    p_scale     NUMERIC,
    p_word      TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    grade   SMALLINT := LEAST(GREATEST(p_rank, 1), 7);
    worn    TEXT;
    ore     RECORD;
    harm    SMALLINT;
    band    TEXT;
    keep    NUMERIC;
    basem   NUMERIC;
    budget  NUMERIC;
    sig     NUMERIC;
    made    BIGINT;
BEGIN
    SELECT s.code INTO worn FROM equipment_slots s ORDER BY random() LIMIT 1;

    -- The best metal the room could plausibly hold, not always the best there
    -- is: a rank 2 room turning out Origin ore would make the ladder pointless.
    SELECT o.* INTO ore FROM ores o
    WHERE o.tier <= grade ORDER BY o.tier DESC, random() LIMIT 1;

    IF ore IS NULL OR worn IS NULL THEN
        RETURN NULL;
    END IF;

    -- Difficulty leans on the roll rather than on the band. A hard room tends
    -- to give up better work; it does not read from a different table.
    harm := GREATEST(0, LEAST(150,
        round(40 + random() * 45 + p_scale * 2)))::smallint;

    SELECT eq.rarity, eq.keep INTO band, keep
    FROM equipment_qualities eq WHERE eq.min_harmony <= harm
    ORDER BY eq.min_harmony DESC LIMIT 1;

    SELECT et.base_magnitude INTO basem
    FROM equipment_tiers et WHERE et.tier = grade;

    budget := basem * keep;
    sig    := budget * game_config_value('forge_ore_share')
                     * game_config_value('forge_signature_share');

    INSERT INTO player_equipment
        (owner_id, name, slot, tier, quality, harmony, path_code, ore_code)
    VALUES (p_player_id,
            forged_name(ore.word, p_word, worn, harm, NULL),
            worn, grade, band, harm,
            (SELECT m.path_code FROM materials m WHERE m.code = ore.material_code),
            ore.material_code)
    RETURNING player_equipment.equipment_id INTO made;

    INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
    SELECT made, c.effect_code, LEAST(ef.cap, round(sum(c.magnitude), 4))
    FROM (
        SELECT ore.signature AS effect_code, sig AS magnitude
        UNION ALL
        SELECT se.effect_code, (budget - sig) * se.share
        FROM slot_effects se WHERE se.slot = worn
    ) c
    JOIN gu_effects ef ON ef.code = c.effect_code
    GROUP BY c.effect_code, ef.cap
    HAVING round(sum(c.magnitude), 4) > 0;

    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- A pill, left by whoever did not get out
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_mint_pill(
    p_player_id BIGINT,
    p_rank      SMALLINT,
    p_scale     NUMERIC
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    grade SMALLINT := LEAST(GREATEST(p_rank, 1), 7);
    path  TEXT;
    kind  TEXT;
    harm  SMALLINT;
    keep  NUMERIC;
    basem NUMERIC;
    floor_p NUMERIC;
    per   NUMERIC;
    made  BIGINT;
BEGIN
    SELECT p.code INTO path FROM paths p
    WHERE EXISTS (SELECT 1 FROM path_words w WHERE w.path_code = p.code)
    ORDER BY random() LIMIT 1;
    IF path IS NULL THEN
        RETURN NULL;
    END IF;

    kind := pill_kind_for(path, grade);
    SELECT pk.per_point INTO per FROM pill_kinds pk WHERE pk.code = kind;

    SELECT pt.base_magnitude, pt.potency_required INTO basem, floor_p
    FROM pill_tiers pt WHERE pt.tier = grade;

    harm := GREATEST(0, LEAST(150,
        round(40 + random() * 45 + p_scale * 2)))::smallint;

    -- The same ladder `brew` keeps: harmony is what you get to keep of what
    -- went in, and a found pill is subject to it like any other.
    keep := CASE
        WHEN harm >= 100 THEN 1.30
        WHEN harm >= 90  THEN 1.17
        WHEN harm >= 75  THEN 1.02
        WHEN harm >= 60  THEN 0.875
        WHEN harm >= 40  THEN 0.70
        ELSE 0.50
    END;

    INSERT INTO player_pills
        (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony,
         potency)
    VALUES (p_player_id, brewed_pill_name(path, kind, harm), grade, kind, path,
            GREATEST(1, round(basem * per * keep)), 1, harm,
            -- 0203: potency above the tier floor is what makes one pill worth
            -- more than another of the same grade. A found pill sits a little
            -- above the floor, and further above it in a harder room.
            round(floor_p * (1 + p_scale / 20), 2))
    RETURNING player_pills.pill_id INTO made;

    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- What one raider carries out
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_spoils_for(
    p_player_id  BIGINT,
    p_rank       SMALLINT,
    p_scale      NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lean    NUMERIC := sqrt(GREATEST(p_scale, 1));  -- difficulty, gently
    herbs   BIGINT  := round(game_config_value('dungeon_herb_per_rank')
                             * GREATEST(p_rank, 1) * p_scale);
    kinds   INTEGER := 2 + floor(random() * 2)::int;
    one     RECORD;
    got     JSONB := '{}'::jsonb;
    names   TEXT[] := '{}';
    n_pages INTEGER := 0;
    made    BIGINT;
    tier_hi SMALLINT;
BEGIN
    -- ---- herbs, always ---------------------------------------------------
    FOR one IN
        SELECT m.code, m.name FROM materials m
        WHERE m.tier IS NOT NULL AND m.tier <= GREATEST(p_rank, 1)
          AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
        ORDER BY random() LIMIT kinds
    LOOP
        -- Integer division on purpose: a pile of herbs is a count, and
        -- round() on a bigint would push the whole expression to a float that
        -- grant_material has no signature for.
        PERFORM grant_material(p_player_id, one.code,
                               GREATEST(1, herbs / kinds)::bigint);
        names := names || (GREATEST(1, herbs / kinds)::bigint || 'x ' || one.name);
    END LOOP;
    got := got || jsonb_build_object('herbs', to_jsonb(names));

    -- ---- pages -----------------------------------------------------------
    -- Pages stop at tier 7, so the top two rooms hand out the top page.
    tier_hi := LEAST(7, GREATEST(1, p_rank + 1))::smallint;
    IF random() < LEAST(0.95, game_config_value('dungeon_page_chance') * lean) THEN
        n_pages := 1 + floor(random() * GREATEST(1, round(lean)))::int;
        FOR i IN 1..n_pages LOOP
            PERFORM mint_page(p_player_id,
                              LEAST(tier_hi, GREATEST(1, p_rank))::smallint,
                              tier_hi, NULL, NULL, NULL);
        END LOOP;
    END IF;
    got := got || jsonb_build_object('pages', n_pages);

    -- ---- a piece ---------------------------------------------------------
    IF random() < LEAST(0.95, game_config_value('dungeon_equipment_chance') * lean) THEN
        made := dungeon_mint_equipment(p_player_id, p_rank, p_scale,
                                       coalesce(nullif(split_part(
                                           (SELECT cs.name FROM dungeons d
                                            JOIN creature_species cs ON cs.species_id = d.species_id
                                            WHERE d.realm_rank = p_rank), ' ', 1), ''), 'Dungeon'));
        IF made IS NOT NULL THEN
            got := got || jsonb_build_object('equipment',
                (SELECT e.name FROM player_equipment e WHERE e.equipment_id = made));
        END IF;
    END IF;

    -- ---- a pill ----------------------------------------------------------
    IF random() < LEAST(0.95, game_config_value('dungeon_pill_chance') * lean) THEN
        made := dungeon_mint_pill(p_player_id, p_rank, p_scale);
        IF made IS NOT NULL THEN
            got := got || jsonb_build_object('pill',
                (SELECT pl.name FROM player_pills pl WHERE pl.pill_id = made));
        END IF;
    END IF;

    -- ---- a Gu ------------------------------------------------------------
    -- The world's ceiling binds in here too. A room that handed out Immortal
    -- Gu while every corpse in the game is barred from them would make
    -- `gu_max_droppable_rank` a rule with a door beside it.
    IF random() < LEAST(0.95, game_config_value('dungeon_gu_chance') * lean) THEN
        SELECT t.gu_type_id INTO made FROM gu_types t
        WHERE t.rank <= LEAST(GREATEST(p_rank, 1),
                              game_config_value('gu_max_droppable_rank'))
        ORDER BY random() LIMIT 1;
        IF made IS NOT NULL THEN
            PERFORM grant_gu(p_player_id, made, NULL);
            got := got || jsonb_build_object('gu',
                (SELECT t.name FROM gu_types t WHERE t.gu_type_id = made));
        END IF;
    END IF;

    RETURN got;
END;
$$;


-- ---------------------------------------------------------------------------
-- The payout
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dungeon_pay_out(p_run_id BIGINT)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    run    RECORD;
    one    RECORD;
    total  BIGINT;
    stones BIGINT;
    jade   BIGINT;
    share  NUMERIC;
    paid_s BIGINT;
    paid_j BIGINT;
    back_s BIGINT;
    back_j BIGINT;
    loot   JSONB;
BEGIN
    SELECT * INTO run FROM dungeon_run_state s WHERE s.run_id = p_run_id;

    SELECT GREATEST(1, COALESCE(sum(x.damage_dealt), 0)) INTO total
    FROM dungeon_raiders x WHERE x.run_id = p_run_id;

    stones := round(game_config_value('dungeon_stone_reward_per_rank')
                    * run.realm_rank * run.reward_scale);
    jade := CASE
        WHEN run.realm_rank >= game_config_value('dungeon_jade_reward_rank')
        THEN GREATEST(1, round(run.realm_rank * run.reward_scale / 3))
        ELSE 0
    END;

    FOR one IN
        SELECT x.player_id, x.damage_dealt, x.keys_paid, x.stones_paid, x.jade_paid
        FROM dungeon_raiders x WHERE x.run_id = p_run_id
    LOOP
        back_s := 0;
        back_j := 0;
        loot   := '{}'::jsonb;

        IF run.status = 'won' THEN
            -- The stake comes back whole, to the raider who paid it. Splitting
            -- it by damage would mean the one who went down first bought the
            -- run for everybody else.
            IF game_config_value('dungeon_refund_on_clear') > 0 THEN
                back_s := one.stones_paid;
                back_j := one.jade_paid;
                IF back_s > 0 THEN
                    PERFORM grant_material(one.player_id, 'spirit_stone', back_s);
                END IF;
                IF back_j > 0 THEN
                    PERFORM grant_jade(one.player_id, back_j, 'dungeon_refund');
                END IF;
            END IF;

            -- The pot is the bonus, and it is still split by damage.
            share  := one.damage_dealt::numeric / total;
            paid_s := floor(stones * share);
            paid_j := floor(jade * share);

            IF paid_s > 0 THEN
                PERFORM grant_material(one.player_id, 'spirit_stone', paid_s);
            END IF;
            IF paid_j > 0 THEN
                PERFORM grant_jade(one.player_id, paid_j, 'dungeon_spoils');
            END IF;

            loot := dungeon_spoils_for(one.player_id, run.realm_rank,
                                       run.reward_scale);
        ELSE
            paid_s := 0;
            paid_j := 0;
            -- The door was opened, so the stones are gone. The key is a day's
            -- worth and losing it to a fight already lost is two punishments
            -- for one mistake.
            IF game_config_value('dungeon_key_refund_on_loss') > 0
               AND one.keys_paid > 0 THEN
                PERFORM grant_material(one.player_id, 'dungeon_key',
                                       one.keys_paid);
            END IF;
        END IF;

        UPDATE dungeon_raiders x
        SET spoils = jsonb_build_object(
            'stones', paid_s, 'jade', paid_j,
            'stones_back', back_s, 'jade_back', back_j,
            'damage', one.damage_dealt,
            'share', round(100.0 * one.damage_dealt / total, 1),
            'keys_back', CASE WHEN run.status = 'won' THEN 0
                              ELSE one.keys_paid END) || loot
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- Opening the room and counting what came out
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    got   JSONB;
    r     SMALLINT;
    n     INTEGER;
    piece BIGINT;
    pill  BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody to loot for; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- Every rank, on the hardest setting, so every branch is walked and
        -- the rank 8 and 9 rooms are made to prove they can mint a page at a
        -- tier that stops at 7.
        FOR r IN 1..9 LOOP
            FOR i IN 1..12 LOOP
                got := dungeon_spoils_for(who, r::smallint, 11.0);
                IF got->'herbs' IS NULL THEN
                    RAISE EXCEPTION 'rank % handed over no herbs at all', r;
                END IF;
            END LOOP;

            piece := dungeon_mint_equipment(who, r::smallint, 11.0, 'Probe');
            IF piece IS NULL THEN
                RAISE EXCEPTION 'rank % could not forge a piece', r;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM equipment_effects e
                           WHERE e.equipment_id = piece) THEN
                RAISE EXCEPTION 'the rank % piece does nothing', r;
            END IF;

            pill := dungeon_mint_pill(who, r::smallint, 11.0);
            IF pill IS NULL THEN
                RAISE EXCEPTION 'rank % could not leave a pill', r;
            END IF;
        END LOOP;

        -- Nothing above the world's ceiling came out of any of that.
        SELECT count(*) INTO n
        FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE g.owner_id = who
          AND t.rank > game_config_value('gu_max_droppable_rank');
        IF n > 0 THEN
            RAISE EXCEPTION '% Immortal Gu fell out of a dungeon', n;
        END IF;

        -- No piece eats a whole ceiling, the same rule the Gu obey.
        SELECT count(*) INTO n
        FROM equipment_effects e JOIN gu_effects f ON f.code = e.effect_code
        WHERE e.magnitude > f.cap;
        IF n > 0 THEN
            RAISE EXCEPTION '% equipment effects are over their cap', n;
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
