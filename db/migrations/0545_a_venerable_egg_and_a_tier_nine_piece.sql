-- 0545_a_venerable_egg_and_a_tier_nine_piece
--
-- THE EQUIPMENT WAS NOT GOOD, which was the question asked. Measured against
-- what the roster already owns:
--
--     the Vault's drop      tier 8, harmony ~64  -> rare     1.15 x 0.92 = 1.06
--     29 pieces they wear   tier 8, harmony 100  -> legend   1.15 x 1.22 = 1.40
--     a forged tier 9       harmony 125+         -> mythic   1.65 x 1.60 = 2.64
--
-- So the deepest room in the game was handing over about forty percent of a
-- top forged piece, and three quarters of what a raider already had on. Two
-- separate reasons, and only one of them is a balance question.
--
-- THE STALE CEILING IS A BUG. `dungeon_mint_equipment` reads
--
--     grade := LEAST(GREATEST(p_rank,1),
--                    CASE WHEN p_rank >= 10 THEN 8 ELSE 7 END)
--
-- and its own comment explains the 8: "Tier 8 exists in both equipment_tiers
-- and ores and no room could ever reach it. The immortal rooms can." That was
-- true when it was written. 0506 added TIER 9 to `equipment_tiers` and 0504
-- took ores to tier 9, so the sentence is now wrong by one and the deepest
-- room mints one tier short of what the game contains. Raised to 9, by the
-- same rule the comment states: the deepest tier that exists, for rooms that
-- can reach it.
--
-- THE HARMONY ROLL IS LEFT ALONE, because that IS the balance question rather
-- than a stale number. `harm := 40 + random()*45 + scale*2` lands a normal
-- room in uncommon-to-epic, and lifting it would make every immortal room
-- more generous, not just the Vault. Say so and it is one expression.
--
-- AND A VENERABLE EGG, at 1% as asked. What makes it a Venerable egg rather
-- than a deep one:
--
--     the beast    one of the ten in the Heavenly Court, every one standing
--                  at immortal_rank 19. The ordinary egg roll draws from all
--                  52 huntable species, 48 of which are rank 1 or 2.
--     the shell    floored at legendary and weighted above it, where the
--                  ordinary roll is "weighted toward the plain end, the way
--                  every other roll in this game is".
--     the tier     9, which the ordinary roll can already reach - the tier is
--                  what makes the pet strong, and this is not about strength
--                  alone. It is about WHAT hatches.
--
-- Rolled before the ordinary egg and instead of it, so a clear cannot hand
-- over both and the 1% is a real 1% rather than a bonus on top of 24%.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_venerable_egg_chance', 0.01,
     'The chance a room past the realm ladder gives up an egg from the Heavenly Court itself - a beast standing at immortal_rank 19, in a shell of legendary or better. Rolled instead of the ordinary egg, never as well.'),
    ('dungeon_venerable_egg_from_rank', 19,
     'The shallowest room that may hold one. 19 - the Venerable door, because what hatches is a Court beast and the Court is not somewhere a mortal room opens onto.');


CREATE FUNCTION roll_venerable_egg(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    who  BIGINT;
    band TEXT;
    deep SMALLINT;
BEGIN
    -- One of the Court's own. `creature_regions` is how a species belongs
    -- somewhere, and the Court holds ten that lay eggs.
    SELECT cs.species_id INTO who
    FROM creature_species cs
    JOIN creature_regions cr ON cr.species_id = cs.species_id
    WHERE cr.region_code = 'heavenly_court'
      AND cs.kind IN ('beast', 'elite')
    ORDER BY random() LIMIT 1;

    IF who IS NULL THEN
        RETURN NULL;
    END IF;

    -- Legendary at worst, and weighted ABOVE it rather than toward the plain
    -- end - the inverse of `roll_beast_egg`, which is the whole point. The
    -- ordering is still the exponential race every roll in this game uses;
    -- what changes is that a richer band is favoured.
    SELECT r.code INTO band
    FROM rarities r
    WHERE r.sort_order >= (SELECT r2.sort_order FROM rarities r2
                           WHERE r2.code = 'legendary')
    ORDER BY -ln(random()) / r.sort_order
    LIMIT 1;

    IF band IS NULL THEN
        band := 'legendary';
    END IF;

    SELECT GREATEST(1, LEAST(9, max(o.tier)))::smallint INTO deep FROM ores o;

    RETURN grant_beast_egg(p_player_id, who, 9::smallint, band,
                           'heavenly_court');
END;
$fn$;

COMMENT ON FUNCTION roll_venerable_egg(BIGINT) IS
    'An egg from the Heavenly Court: one of the ten beasts standing there at immortal_rank 19, in a shell of legendary or better. The ordinary roll draws from all 52 huntable species and favours the plain end; this does neither.';


DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    -- ---- the piece --------------------------------------------------------
    src := pg_get_functiondef(
        'dungeon_mint_equipment(bigint,smallint,numeric,text)'::regprocedure);

    one := '    grade   SMALLINT := LEAST(GREATEST(p_rank, 1),' || chr(10) ||
           '                              CASE WHEN p_rank >= 10 THEN 8 ELSE 7 END);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the equipment grade is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- The deepest tier that EXISTS, for rooms that can reach it,' || chr(10) ||
        '    -- which is the rule the comment above already states. It said 8' || chr(10) ||
        '    -- because 8 was the deepest when it was written; 0506 added tier 9' || chr(10) ||
        '    -- to `equipment_tiers` and 0504 took ores to 9, so the deepest' || chr(10) ||
        '    -- room was minting one short of the game.' || chr(10) ||
        '    grade   SMALLINT := LEAST(GREATEST(p_rank, 1),' || chr(10) ||
        '                              CASE WHEN p_rank >= 10' || chr(10) ||
        '                                   THEN (SELECT max(et.tier)' || chr(10) ||
        '                                         FROM equipment_tiers et)' || chr(10) ||
        '                                   ELSE 7 END);');
    EXECUTE src;

    -- ---- the egg ----------------------------------------------------------
    src := pg_get_functiondef('dungeon_spoils_for(bigint,smallint,numeric)'::regprocedure);

    one := '    IF random() < LEAST(0.95, game_config_value(''dungeon_egg_chance'') * lean) THEN' || chr(10) ||
           '        made := roll_beast_egg(p_player_id, p_rank, NULL);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the egg roll is not where I read it';
    END IF;

    src := replace(src, one,
        '    -- A COURT EGG FIRST, and instead of the ordinary one - so a clear' || chr(10) ||
        '    -- cannot hand over both and the 1% means 1% rather than a bonus on' || chr(10) ||
        '    -- top of the 24% the ordinary roll already pays at this depth.' || chr(10) ||
        '    -- Not leaned on by difficulty either: a rarity this thin should not' || chr(10) ||
        '    -- quietly treble because somebody picked Insane.' || chr(10) ||
        '    IF p_rank >= game_config_value(''dungeon_venerable_egg_from_rank'')' || chr(10) ||
        '       AND random() < game_config_value(''dungeon_venerable_egg_chance'')' || chr(10) ||
        '    THEN' || chr(10) ||
        '        made := roll_venerable_egg(p_player_id);' || chr(10) ||
        '        IF made IS NOT NULL THEN' || chr(10) ||
        '            got := got || jsonb_build_object(''venerable_egg'',' || chr(10) ||
        '                (SELECT s.name FROM player_egg_shelf s WHERE s.egg_id = made));' || chr(10) ||
        '        END IF;' || chr(10) ||
        '    ELSIF random() < LEAST(0.95, game_config_value(''dungeon_egg_chance'') * lean) THEN' || chr(10) ||
        '        made := roll_beast_egg(p_player_id, p_rank, NULL);');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Mint a piece, and hatch the Court
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_path  TEXT;
    v_scale NUMERIC;
    v_made  BIGINT;
    v_eggs  INTEGER := 0;
    v_court INTEGER := 0;
    v_t9    INTEGER := 0;
    v_t     SMALLINT;
    v_band  TEXT;
    i       INTEGER;
BEGIN
    -- The ceiling follows the table rather than a literal.
    IF (SELECT max(tier) FROM equipment_tiers) <> 9 THEN
        RAISE EXCEPTION
            'equipment_tiers tops out at %, so this migration assumed wrong',
            (SELECT max(tier) FROM equipment_tiers);
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;
    SELECT reward_scale INTO v_scale FROM dungeon_difficulties WHERE code = 'normal';

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-961, 'egg-probe') RETURNING player_id INTO v_pid;
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

        -- 1. THE PIECE REACHES TIER 9 in a room past the mortal ladder.
        FOR i IN 1..30 LOOP
            v_made := dungeon_mint_equipment(v_pid, 19::smallint, v_scale, 'Vault');
            IF v_made IS NOT NULL THEN
                SELECT e.tier INTO v_t FROM player_equipment e
                WHERE e.equipment_id = v_made;
                IF v_t = 9 THEN v_t9 := v_t9 + 1; END IF;
            END IF;
        END LOOP;
        IF v_t9 <> 30 THEN
            RAISE EXCEPTION
                'only % of 30 Vault pieces were tier 9', v_t9;
        END IF;

        -- And a mortal room is untouched: still capped at 7.
        v_made := dungeon_mint_equipment(v_pid, 4::smallint, v_scale, 'Keep');
        SELECT e.tier INTO v_t FROM player_equipment e WHERE e.equipment_id = v_made;
        IF v_t > 7 THEN
            RAISE EXCEPTION 'a rank 4 room minted tier %', v_t;
        END IF;

        -- 2. THE COURT EGG. Rolled directly, because 1% of 200 clears proves
        -- nothing either way.
        FOR i IN 1..40 LOOP
            v_made := roll_venerable_egg(v_pid);
            IF v_made IS NULL THEN
                RAISE EXCEPTION 'the Court had no egg to give';
            END IF;
            v_eggs := v_eggs + 1;

            SELECT e.tier, e.rarity INTO v_t, v_band
            FROM player_beast_eggs e WHERE e.egg_id = v_made;

            IF v_t <> 9 THEN
                RAISE EXCEPTION 'a Court egg came out at tier %', v_t;
            END IF;
            IF (SELECT r.sort_order FROM rarities r WHERE r.code = v_band)
               < (SELECT r.sort_order FROM rarities r WHERE r.code = 'legendary') THEN
                RAISE EXCEPTION 'a Court egg came out %', v_band;
            END IF;

            IF EXISTS (
                SELECT 1 FROM player_beast_eggs e
                JOIN creature_species cs ON cs.species_id = e.species_id
                WHERE e.egg_id = v_made AND cs.immortal_rank = 19
            ) THEN
                v_court := v_court + 1;
            END IF;
        END LOOP;

        IF v_court <> 40 THEN
            RAISE EXCEPTION
                'only % of 40 Court eggs hold something standing at 19', v_court;
        END IF;

        RAISE NOTICE
            '40 Court eggs, all tier 9, all legendary or better, all rank 19 beasts';

        -- 3. AND THE TWO EGGS ARE EXCLUSIVE. A clear that gives the Court one
        -- must not also give the ordinary one.
        FOR i IN 1..300 LOOP
            IF (SELECT count(*) FROM jsonb_object_keys(
                    dungeon_spoils_for(v_pid, 19::smallint, v_scale)) k
                WHERE k IN ('egg', 'venerable_egg')) > 1 THEN
                RAISE EXCEPTION 'a clear handed over both eggs';
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'the Vault mints tier 9 and keeps one egg in a hundred from the Court';
END;
$probe$;
