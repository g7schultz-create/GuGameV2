-- 0546_what_only_the_vault_can_give
--
-- "Make venerable gear that's better and is only a drop. Make the pages
-- higher tier."
--
-- ---------------------------------------------------------------------------
-- ONLY A DROP, STRUCTURALLY, with no flag to forget to check
-- ---------------------------------------------------------------------------
--
-- `forge` decides a piece's tier as
--
--     grade := LEAST(tier_by_pot, best_tier, smith_tier_cap(skill))
--
-- `best_tier` is the best ore on the anvil and the deepest ore in the game is
-- tier 9. `smith_tier_cap` is `LEAST(9, ...)` - a hard nine written into the
-- function. So A TIER 10 CANNOT BE FORGED BECAUSE THERE IS NO METAL FOR IT,
-- whatever a smith finds and however good they get. That is a better
-- guarantee than a `drop_only` column, which would be one more thing for a
-- future minter not to know about.
--
-- Tier 10 continues the ladder it belongs to: 0.80, 1.15, 1.65 rise by about
-- 1.43 a tier, so 10 is 2.37.
--
-- AND IT IS BETTER IN BOTH WAYS A PIECE CAN BE. The tier is the frame; the
-- harmony is the work. 0545 raised the Vault to tier 9 and left the harmony
-- roll alone because that was the balance question rather than a stale
-- number. It is answered now, for this piece only:
--
--     an ordinary room      40 + random()*45   -> uncommon to epic
--     the Venerable piece   92 + random()*45   -> legendary, divine, mythic
--
--     a forged tier 9 mythic    1.65 x 1.60 = 2.64
--     this at its FLOOR         2.37 x 1.22 = 2.89
--     this at mythic            2.37 x 1.60 = 3.79
--
-- So the floor of a Venerable piece beats the ceiling of anything forgeable,
-- which is what "better and only a drop" has to mean to be worth saying.
--
-- IT IS THE SAME MINTER, NOT A SECOND ONE. `dungeon_mint_equipment` already
-- knows how a piece gets its stats - the ore's signature effect, the slot's
-- own spread, the budget split by `forge_ore_share` and
-- `forge_signature_share`. My first draft of this migration wrote that out
-- again in a new function and called a helper that does not exist. It takes
-- two optional arguments instead: a forced tier and a harmony floor. One
-- definition of what a piece IS.
--
-- ONE IN TEN CLEARS, and I chose that figure: the ordinary piece is 30% and
-- the Venerable egg is 1%, so a piece nothing can be forged to match sits
-- between them. It replaces the ordinary roll rather than adding to it, and
-- it is not leaned on by difficulty.
--
-- AND ROOMS 10 TO 18 STAY AT TIER 9. 0545 pointed their ceiling at
-- `max(equipment_tiers.tier)` so it could never go stale - which would now
-- hand them tier 10 too. It points at the deepest ORE instead, which is the
-- honest ceiling for a piece somebody could have forged.
--
-- ---------------------------------------------------------------------------
-- THE PAGES, where the ladder already knew the answer
-- ---------------------------------------------------------------------------
--
-- `LEAST(7, ...)` is not the rule, and raising it does not work.
-- `page_tiers` carries the rule as a ROLL WEIGHT:
--
--      7   Peak naturally obtainable        roll_weight 2.00
--      8   Refined beyond the drop table    roll_weight 0.00
--     13   Venerable's own hand             roll_weight 0.00
--
-- and `mint_page` filters `roll_weight > 0`, so asking it for a tier 13
-- raises "no droppable page tier between 13 and 13". My first attempt did
-- exactly that. Giving tier 13 a weight instead would make it rollable in
-- any range that happens to include it, which is the opposite of what the
-- ladder says.
--
-- `mint_page_at(owner, tier, ...)` names a tier and skips the roll.
-- `rogue_pages` and `unbind_manuals` already use it for this: a page
-- somebody is deliberately HANDED rather than one that fell out of a table.
-- So the Vault names tier 13 - "Venerable's own hand", which is what a
-- vault of dead Venerables is full of - `roll_weight 0` keeps meaning what
-- it means, and every shallower room still rolls the same table it always
-- did.
--
-- Rooms 10 to 18 are left alone deliberately rather than by oversight.
-- Lifting them is a decision about the immortal rooms generally.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE equipment_tiers DROP CONSTRAINT equipment_tiers_tier_check;
ALTER TABLE equipment_tiers ADD CONSTRAINT equipment_tiers_tier_check
    CHECK (tier >= 1 AND tier <= 10);

INSERT INTO equipment_tiers (tier, potency_required, base_magnitude)
VALUES (10, 4200.00, 2.3700);

COMMENT ON TABLE equipment_tiers IS
    'The frame a piece is built on. Tiers 1 to 9 are forgeable; tier 10 is not, and not by a flag - the deepest ore is tier 9 and smith_tier_cap is a hard LEAST(9, ...), so there is no metal and no skill that reaches it. It comes out of the Vault of Unclaimed Dao or it does not come out at all.';


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_venerable_gear_chance', 0.10,
     'The chance a room past the realm ladder gives up a tier 10 piece - the frame no smith can reach, at legendary harmony or better. Rolled instead of the ordinary piece, never as well.'),
    ('dungeon_venerable_gear_from_rank', 19,
     'The shallowest room that may hold one.'),
    ('dungeon_venerable_harmony_floor', 92,
     'Where a Venerable piece''s harmony roll starts, against the ordinary 40. 92 is legendary''s floor in equipment_qualities, so the worst one is still legendary.'),
    ('dungeon_venerable_page_tier', 13,
     'The page tier a room past the realm ladder may reach. 13 is "Venerable''s own hand" in page_tiers. Every shallower room still stops at 7, "Peak naturally obtainable".'),
    ('dungeon_venerable_page_tier_from_rank', 19,
     'The shallowest room that reaches past "Peak naturally obtainable" for pages.');


-- ---------------------------------------------------------------------------
-- The one minter learns two overrides
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef(
        'dungeon_mint_equipment(bigint,smallint,numeric,text)'::regprocedure);

    one := 'public.dungeon_mint_equipment(p_player_id bigint, p_rank smallint, '
           || 'p_scale numeric, p_word text)';
    IF strpos(src, one) = 0 THEN
        RAISE EXCEPTION 'dungeon_mint_equipment is not the shape I read';
    END IF;
    src := replace(src, one,
        'public.dungeon_mint_equipment(p_player_id bigint, p_rank smallint, '
        || 'p_scale numeric, p_word text, p_force_tier smallint DEFAULT NULL, '
        || 'p_harmony_floor smallint DEFAULT NULL)');

    -- The frame. Forced when asked; otherwise the deepest METAL, because tier
    -- 10 exists now and no anvil reaches it.
    one := '    grade   SMALLINT := LEAST(GREATEST(p_rank, 1),' || chr(10) ||
           '                              CASE WHEN p_rank >= 10' || chr(10) ||
           '                                   THEN (SELECT max(et.tier)' || chr(10) ||
           '                                         FROM equipment_tiers et)' || chr(10) ||
           '                                   ELSE 7 END);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the grade 0545 set is not where I left it';
    END IF;
    src := replace(src, one,
        '    grade   SMALLINT := COALESCE(p_force_tier,' || chr(10) ||
        '        LEAST(GREATEST(p_rank, 1),' || chr(10) ||
        '              CASE WHEN p_rank >= 10' || chr(10) ||
        '                   -- The deepest METAL, not the deepest frame: tier' || chr(10) ||
        '                   -- 10 exists and no anvil reaches it, so no' || chr(10) ||
        '                   -- ordinary room hands it over either.' || chr(10) ||
        '                   THEN (SELECT max(o2.tier) FROM ores o2)' || chr(10) ||
        '                   ELSE 7 END));');

    -- The work. The same spread, started higher when asked.
    one := '    harm := GREATEST(0, LEAST(150,' || chr(10) ||
           '        round(40 + random() * 45 + p_scale * 2)))::smallint;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the harmony roll is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- The same forty-five point spread, started wherever it is asked' || chr(10) ||
        '    -- to start. 40 lands a room in uncommon-to-epic; 92 is' || chr(10) ||
        '    -- legendary''s floor, so a Venerable piece cannot come out worse' || chr(10) ||
        '    -- than legendary.' || chr(10) ||
        '    harm := GREATEST(0, LEAST(150,' || chr(10) ||
        '        round(COALESCE(p_harmony_floor, 40) + random() * 45' || chr(10) ||
        '              + p_scale * 2)))::smallint;');

    -- The ore is the best the ROOM could hold, which for a forced frame means
    -- the best there is - there is no tier 10 metal to ask for.
    one := '    SELECT o.* INTO ore FROM ores o' || chr(10) ||
           '    WHERE o.tier <= grade ORDER BY o.tier DESC, random() LIMIT 1;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the ore pick is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- `<=` still, and a forced tier 10 therefore takes the best metal' || chr(10) ||
        '    -- there is - tier 9, because there is no tier 10 ore. That is the' || chr(10) ||
        '    -- whole reason the frame is unforgeable.' || chr(10) ||
        '    SELECT o.* INTO ore FROM ores o' || chr(10) ||
        '    WHERE o.tier <= grade ORDER BY o.tier DESC, random() LIMIT 1;');

    DROP FUNCTION dungeon_mint_equipment(bigint, smallint, numeric, text);
    EXECUTE src;
END;
$patch$;


CREATE FUNCTION mint_venerable_gear(p_player_id BIGINT, p_scale NUMERIC DEFAULT 1)
RETURNS BIGINT
LANGUAGE sql AS $fn$
    -- A thin wrapper, deliberately. How a piece gets its stats - the ore's
    -- signature, the slot's spread, the budget split - lives in one place and
    -- this is not a second copy of it.
    SELECT dungeon_mint_equipment(
        p_player_id,
        game_config_value('dungeon_venerable_gear_from_rank')::smallint,
        p_scale,
        'Venerable',
        (SELECT max(et.tier) FROM equipment_tiers et)::smallint,
        game_config_value('dungeon_venerable_harmony_floor')::smallint);
$fn$;

COMMENT ON FUNCTION mint_venerable_gear(BIGINT, NUMERIC) IS
    'A tier 10 piece at legendary harmony or better, through the one minter. Unforgeable by construction rather than by rule: the deepest ore is tier 9 and smith_tier_cap is a hard nine, so no anvil reaches this frame.';


-- ---------------------------------------------------------------------------
-- And the drop table learns both
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('dungeon_spoils_for(bigint,smallint,numeric)'::regprocedure);

    -- `tier_hi` is left exactly as it was: it feeds the ROLL, and the roll
    -- cannot reach past 7 because tiers 8 and up carry no weight. The
    -- Venerable page names its tier instead of widening the range.
    one := '        FOR i IN 1..n_pages LOOP' || chr(10) ||
           '            PERFORM mint_page(p_player_id,' || chr(10) ||
           '                              LEAST(tier_hi, GREATEST(1, p_rank))::smallint,' || chr(10) ||
           '                              tier_hi, NULL, NULL, NULL);' || chr(10) ||
           '        END LOOP;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the page loop is not where I read it';
    END IF;
    src := replace(src, one,
        '        FOR i IN 1..n_pages LOOP' || chr(10) ||
        '            IF p_rank >= game_config_value(' || chr(10) ||
        '                   ''dungeon_venerable_page_tier_from_rank'') THEN' || chr(10) ||
        '                -- NAMED, not rolled. Tiers past 7 carry' || chr(10) ||
        '                -- `roll_weight 0` - that is how the ladder says' || chr(10) ||
        '                -- "Refined beyond the drop table" - so' || chr(10) ||
        '                -- `mint_page` cannot produce one at any range.' || chr(10) ||
        '                -- `mint_page_at` is the path `rogue_pages` and' || chr(10) ||
        '                -- `unbind_manuals` already use for a page' || chr(10) ||
        '                -- somebody is deliberately handed.' || chr(10) ||
        '                PERFORM mint_page_at(p_player_id,' || chr(10) ||
        '                    game_config_value(''dungeon_venerable_page_tier'')::smallint,' || chr(10) ||
        '                    NULL, NULL, NULL);' || chr(10) ||
        '            ELSE' || chr(10) ||
        '                PERFORM mint_page(p_player_id,' || chr(10) ||
        '                                  LEAST(tier_hi, GREATEST(1, p_rank))::smallint,' || chr(10) ||
        '                                  tier_hi, NULL, NULL, NULL);' || chr(10) ||
        '            END IF;' || chr(10) ||
        '        END LOOP;');

    one := '    IF random() < LEAST(0.95, game_config_value(''dungeon_equipment_chance'') * lean) THEN' || chr(10) ||
           '        made := dungeon_mint_equipment(p_player_id, p_rank, p_scale,';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the equipment roll is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- A VENERABLE PIECE FIRST, and instead of the ordinary one - so a' || chr(10) ||
        '    -- clear cannot hand over both and the 10% means 10%. Not leaned on' || chr(10) ||
        '    -- by difficulty: the frame is already the deepest there is.' || chr(10) ||
        '    IF p_rank >= game_config_value(''dungeon_venerable_gear_from_rank'')' || chr(10) ||
        '       AND random() < game_config_value(''dungeon_venerable_gear_chance'')' || chr(10) ||
        '    THEN' || chr(10) ||
        '        made := mint_venerable_gear(p_player_id, p_scale);' || chr(10) ||
        '        IF made IS NOT NULL THEN' || chr(10) ||
        '            got := got || jsonb_build_object(''venerable_gear'',' || chr(10) ||
        '                (SELECT e.name FROM player_equipment e' || chr(10) ||
        '                 WHERE e.equipment_id = made));' || chr(10) ||
        '        END IF;' || chr(10) ||
        '    ELSIF random() < LEAST(0.95, game_config_value(''dungeon_equipment_chance'') * lean) THEN' || chr(10) ||
        '        made := dungeon_mint_equipment(p_player_id, p_rank, p_scale,');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing can forge it, and the Vault hands it over
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_path  TEXT;
    v_scale NUMERIC;
    v_made  BIGINT;
    v_t     SMALLINT;
    v_band  TEXT;
    v_low   INTEGER := 0;
    v_pages INTEGER := 0;
    v_deep  INTEGER := 0;
    i       INTEGER;
BEGIN
    -- 1. NO SMITH CAN REACH IT, and that is arithmetic rather than a rule.
    IF (SELECT max(tier) FROM ores) >= (SELECT max(tier) FROM equipment_tiers) THEN
        RAISE EXCEPTION
            'the deepest ore is tier % and the deepest frame %, so a forge reaches it',
            (SELECT max(tier) FROM ores), (SELECT max(tier) FROM equipment_tiers);
    END IF;
    IF smith_tier_cap(32767::smallint) >= (SELECT max(tier) FROM equipment_tiers) THEN
        RAISE EXCEPTION
            'a smith of unlimited skill reaches tier %', smith_tier_cap(32767::smallint);
    END IF;

    -- And the floor of a Venerable piece beats the ceiling of a forged one.
    IF (SELECT max(et.base_magnitude) FROM equipment_tiers et)
       * (SELECT eq.keep FROM equipment_qualities eq WHERE eq.rarity = 'legendary')
       <= (SELECT et.base_magnitude FROM equipment_tiers et
           WHERE et.tier = (SELECT max(tier) FROM ores))
          * (SELECT max(eq.keep) FROM equipment_qualities eq) THEN
        RAISE EXCEPTION
            'a Venerable piece at its floor does not beat a forged one at its ceiling';
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;
    SELECT reward_scale INTO v_scale FROM dungeon_difficulties WHERE code = 'normal';

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-960, 'gear-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());
        PERFORM venerable_ascend(v_pid);

        -- 2. TIER 10, LEGENDARY OR BETTER, every time.
        FOR i IN 1..40 LOOP
            v_made := mint_venerable_gear(v_pid, v_scale);
            IF v_made IS NULL THEN
                RAISE EXCEPTION 'the Vault had no piece to give';
            END IF;
            SELECT e.tier, e.rarity INTO v_t, v_band
            FROM player_equipment e WHERE e.equipment_id = v_made;

            IF v_t <> (SELECT max(tier) FROM equipment_tiers) THEN
                RAISE EXCEPTION 'a Venerable piece came out tier %', v_t;
            END IF;
            IF (SELECT r.sort_order FROM rarities r WHERE r.code = v_band)
               < (SELECT r.sort_order FROM rarities r WHERE r.code = 'legendary') THEN
                v_low := v_low + 1;
            END IF;
            -- And it carries stats, which is what the shared minter is for.
            IF NOT EXISTS (SELECT 1 FROM equipment_effects
                           WHERE equipment_id = v_made) THEN
                RAISE EXCEPTION 'a Venerable piece came out with no effects at all';
            END IF;
        END LOOP;
        IF v_low > 0 THEN
            RAISE EXCEPTION
                '% of 40 Venerable pieces came out under legendary', v_low;
        END IF;

        -- 3. AN ORDINARY IMMORTAL ROOM STILL MINTS THE DEEPEST FORGEABLE.
        v_made := dungeon_mint_equipment(v_pid, 14::smallint, v_scale, 'Vine');
        SELECT e.tier INTO v_t FROM player_equipment e WHERE e.equipment_id = v_made;
        IF v_t <> (SELECT max(tier) FROM ores) THEN
            RAISE EXCEPTION
                'a rank 14 room minted tier %, not the deepest forgeable', v_t;
        END IF;

        -- 4. PAGES REACH "VENERABLE'S OWN HAND" in the Vault and nowhere else.
        DELETE FROM manual_pages WHERE owner_id = v_pid;
        FOR i IN 1..80 LOOP
            PERFORM dungeon_spoils_for(v_pid, 19::smallint, v_scale);
        END LOOP;
        SELECT count(*) FILTER (WHERE p.tier > 7),
               count(*) FILTER (WHERE p.tier
                   = game_config_value('dungeon_venerable_page_tier')::smallint)
        INTO v_pages, v_deep
        FROM manual_pages p WHERE p.owner_id = v_pid;

        IF v_pages = 0 THEN
            RAISE EXCEPTION 'eighty Vault clears produced no page past tier 7';
        END IF;
        RAISE NOTICE
            '% pages past tier 7, % of them "Venerable''s own hand"',
            v_pages, v_deep;

        DELETE FROM manual_pages WHERE owner_id = v_pid;
        FOR i IN 1..80 LOOP
            PERFORM dungeon_spoils_for(v_pid, 18::smallint, v_scale);
        END LOOP;
        IF EXISTS (SELECT 1 FROM manual_pages p
                   WHERE p.owner_id = v_pid AND p.tier > 7) THEN
            RAISE EXCEPTION
                'a rank 18 room handed over a page past "Peak naturally obtainable"';
        END IF;

        -- 5. AND THE TWO PIECES ARE EXCLUSIVE.
        FOR i IN 1..300 LOOP
            IF (SELECT count(*) FROM jsonb_object_keys(
                    dungeon_spoils_for(v_pid, 19::smallint, v_scale)) k
                WHERE k IN ('equipment', 'venerable_gear')) > 1 THEN
                RAISE EXCEPTION 'a clear handed over both pieces';
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody alive holds one, because nobody has been in there.
    IF EXISTS (SELECT 1 FROM player_equipment
               WHERE tier > (SELECT max(tier) FROM ores)) THEN
        RAISE EXCEPTION 'somebody already owns an unforgeable piece';
    END IF;

    RAISE NOTICE
        'tier 10 exists, no anvil reaches it, and the Vault writes in a Venerable''s own hand';
END;
$probe$;
