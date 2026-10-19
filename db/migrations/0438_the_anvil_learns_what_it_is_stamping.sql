-- 0438_the_anvil_learns_what_it_is_stamping
--
-- 0437 gave a piece of gear a Level, a Rank, an honest `rarity` and a real
-- `quality`, and left four functions still writing to a column that no longer
-- exists. plpgsql resolves names on first execution rather than at CREATE, so
-- nothing complained when they were replaced - `forge` has been broken since
-- 0437 landed and would have thrown on the next swing of the hammer.
--
--     forge                   INSERT ... (..., quality, ...)
--     dungeon_mint_equipment  INSERT ... (..., quality, ...)
--     broker_offer            pe.quality in a description
--     broker_price_equipment  material_grade(pe.quality)
--
-- All four are repaired here, and the two that MINT gear are taught the rest
-- of the shape while they are open.
--
-- WHAT THE ANVIL NOW DECIDES, and from what:
--
--   LEVEL    the smith's own realm rank. A cultivator forges for the realm
--            they stand in; they cannot make gear for a door they have not
--            walked through.
--   RANK     always 1. Rank is fused, never forged - that is what makes a
--            duplicate worth keeping.
--   RARITY   `smith_rarity_cap(level)`, which is the ceiling rather than the
--            result: the roll walks DOWN from it on a poor harmony, so a deep
--            smith having a bad day still makes something ordinary. A bench
--            that always returned its own ceiling would make the roll pointless.
--   QUALITY  the harmony band. The number the forge has always rolled.
--
-- AND WHAT QUALITY IS WORTH. `equipment_qualities.keep` used to scale the
-- budget off the rarity band; that table was harmony read twice and is now
-- replaced in this path by `equipment_quality_bands.stat_share`, which is the
-- same idea said once. Crude is 0.70 of a budget and Flawless is 1.50, so the
-- roll matters more than it did rather than less.
--
-- `equipment_qualities` is NOT dropped. `dungeon_mint_equipment` is left on
-- the old shape deliberately - a dungeon hands out gear rather than forging
-- it, there is no smith to take a level from, and inventing one would be
-- inventing a system. It gets the column rename it needs and nothing else.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The forge: the rename, and then the rest of the stamp
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    after  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'forge' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'forge is missing';
    END IF;

    -- 1. Rarity stops being harmony's band and becomes the smith's ceiling,
    --    walked down by how the forging actually went.
    anchor := concat(
'    SELECT eq.rarity, eq.keep INTO band, keep_frac', chr(10),
'    FROM equipment_qualities eq WHERE eq.min_harmony <= final_h', chr(10),
'    ORDER BY eq.min_harmony DESC LIMIT 1;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer reads its band where it did';
    END IF;

    after := replace(body, anchor, concat(
'    -- Since 0438 the band is the SMITH''s, not the harmony''s. Harmony says', chr(10),
'    -- how well it went and that is Quality; rarity says what the smith is', chr(10),
'    -- capable of. They were the same number read twice until now, which is', chr(10),
'    -- why no screen could ever tell them apart.', chr(10),
'    --', chr(10),
'    -- The roll walks DOWN from the ceiling on a poor harmony: a bench that', chr(10),
'    -- always returned its own best would make the roll pointless.', chr(10),
'    band := smith_rarity_cap(skill);', chr(10),
'    SELECT r2.code INTO band', chr(10),
'    FROM rarities r2', chr(10),
'    WHERE r2.sort_order <= (SELECT r3.sort_order FROM rarities r3', chr(10),
'                            WHERE r3.code = smith_rarity_cap(skill))', chr(10),
'    ORDER BY abs(r2.sort_order -', chr(10),
'                 (SELECT r4.sort_order FROM rarities r4', chr(10),
'                  WHERE r4.code = smith_rarity_cap(skill))', chr(10),
'                 * GREATEST(0.35, LEAST(1.0, final_h / 120.0)))', chr(10),
'    LIMIT 1;', chr(10),
'', chr(10),
'    made_quality := equipment_quality_for(final_h);', chr(10),
'    SELECT q.stat_share INTO keep_frac', chr(10),
'    FROM equipment_quality_bands q WHERE q.code = made_quality;'));

    -- 2. The declarations the new lines need.
    anchor := '    skill       SMALLINT;';
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer declares its skill where it did';
    END IF;
    after := replace(after, anchor, concat(
'    skill       SMALLINT;', chr(10),
'    made_quality TEXT;      -- how well this one went, since 0438', chr(10),
'    made_level  SMALLINT;   -- the realm it is built for'));

    -- 3. The stamp itself.
    anchor := concat(
'    INSERT INTO player_equipment', chr(10),
'        (owner_id, name, slot, tier, quality, harmony, path_code, ore_code, reaction)', chr(10),
'    VALUES (p_player_id, made_name, p_slot, grade, band, final_h,', chr(10),
'            ore_path, lead_ore, react_word)');
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer stamps the piece where it did';
    END IF;
    after := replace(after, anchor, concat(
'    -- A smith forges for the realm they stand in. Rank is always 1: stars', chr(10),
'    -- are fused rather than forged, which is what makes a duplicate worth', chr(10),
'    -- keeping instead of selling.', chr(10),
'    SELECT COALESCE(r5.rank, 1) INTO made_level', chr(10),
'    FROM player_cultivation pc5', chr(10),
'    JOIN realms r5 ON r5.realm_id = pc5.realm_id', chr(10),
'    WHERE pc5.player_id = p_player_id;', chr(10),
'', chr(10),
'    INSERT INTO player_equipment', chr(10),
'        (owner_id, name, slot, tier, rarity, harmony, path_code, ore_code,', chr(10),
'         reaction, level, rank, quality)', chr(10),
'    VALUES (p_player_id, made_name, p_slot, grade, band, final_h,', chr(10),
'            ore_path, lead_ore, react_word,', chr(10),
'            COALESCE(made_level, 1), 1, made_quality)'));

    EXECUTE after;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The three that only needed the column to be called what it is
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    r      RECORD;
    body   TEXT;
    hits   INTEGER;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('dungeon_mint_equipment',
             '(owner_id, name, slot, tier, quality, harmony, path_code, ore_code)',
             '(owner_id, name, slot, tier, rarity, harmony, path_code, ore_code)'),
            ('broker_offer',
             'pe.quality', 'pe.rarity'),
            ('broker_price_equipment',
             'material_grade(pe.quality)', 'material_grade(pe.rarity)')
        ) AS t (fn, anchor, becomes)
    LOOP
        SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
        WHERE proname = r.fn AND pronamespace = 'public'::regnamespace;
        IF body IS NULL THEN
            RAISE EXCEPTION '% is missing', r.fn;
        END IF;

        hits := (length(body) - length(replace(body, r.anchor, '')))
                / length(r.anchor);
        IF hits <> 1 THEN
            RAISE EXCEPTION
                '% names the gear column % time(s), expected 1', r.fn, hits;
        END IF;

        EXECUTE replace(body, r.anchor, r.becomes);
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing anywhere still writes to a column that is not there
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_who BIGINT;
    r     RECORD;
BEGIN
    -- The fault 0437 left behind, asked of every function rather than of the
    -- four that were noticed. plpgsql compiles on first call, so a name that
    -- is wrong here is a runtime error waiting for a player to find it.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prosrc LIKE '%player_equipment%'
      AND (p.prosrc LIKE '%.quality%' OR p.prosrc LIKE '%, quality,%')
      AND p.proname <> 'equipment_quality_for';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these still name a gear column that was renamed in 0437: %', v_bad;
    END IF;

    -- And the anvil actually works, which is the only check that matters.
    -- Run against the deepest smith in the game, inside a subtransaction that
    -- is rolled back - a probe must not hand anybody a free piece of armour.
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL
        ORDER BY profession_level(p.player_id, 'blacksmithing') DESC LIMIT 1;
        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Enough of something to swing with, granted and then rolled back.
        PERFORM grant_material(v_who, 'spirit_iron', 50);

        BEGIN
            PERFORM forge(v_who, 'armour', ARRAY['spirit_iron'], ARRAY[20],
                          ARRAY[]::text[], ARRAY[]::integer[]);
        EXCEPTION WHEN undefined_column THEN
            RAISE EXCEPTION
                'the anvil still writes to a column that does not exist: %', SQLERRM;
        WHEN check_violation THEN
            -- Refused for a game reason - not enough ore, wrong tier. That is
            -- the anvil working, which is what this asks.
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT c.min_level, c.rarity,
               (SELECT count(*) FROM players p
                WHERE p.deleted_at IS NULL
                  AND profession_level(p.player_id, 'blacksmithing') >= c.min_level) AS smiths
        FROM smith_rarity_caps c ORDER BY c.min_level
    LOOP
        RAISE NOTICE 'level %+ may reach % : % smith(s) qualify',
            lpad(r.min_level::text, 3), rpad(r.rarity, 10), r.smiths;
    END LOOP;
END;
$probe$;
