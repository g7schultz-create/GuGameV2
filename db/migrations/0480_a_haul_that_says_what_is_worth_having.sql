-- 0480_a_haul_that_says_what_is_worth_having
--
-- pashu0 killed the thing from the deep and came out thinking it had given
-- him nothing. It had - and both halves of why he could not tell are real.
--
-- FIRST, THE TALLY SORTS BY QUANTITY, which is almost exactly backwards:
--
--     202x Light Sand                tier 2  uncommon
--     175x Formation Spirit Stone    tier 6  epic
--      37x Flowing Light Fruits      tier 8  rare
--      26x Phoenix Down                      epic     <- the deep thing
--       2x Primordial Blood                  legendary
--
-- The legendary is at the bottom and a pile of tier 2 sand is at the top. So
-- the haul carries what each thing IS now - its tier where it has one, its
-- rarity always - and sorts by that rather than by how much of it there is.
--
-- Beast materials have no tier at all, which is why Phoenix Down and
-- Primordial Blood show a rarity and nothing else: `materials.tier` is for
-- things that grow and `ores.tier` for things that are dug, and what comes
-- off a carcass is neither. Rarity is the one word that fits all three.
--
-- SECOND, THE GU IS A TWO PER CENT ROLL. `roll_gu_drop` opens with
--
--     IF random() >= game_config_value('gu_drop_chance')
--
-- and that is 0.02 - the right figure for an ambient find while exploring,
-- and nonsense as the headline reward of a creature you had to find in the
-- dark and survive at two and a half times your own measure. Ninety-eight
-- times in a hundred the deep thing gave exactly what an ordinary beast gives,
-- which is what pashu0 was looking at.
--
-- So the chance moves onto the tile. The deep thing rolls at one in four; an
-- ordinary beast does not roll at all, which it never did.
--
-- `roll_gu_drop` GAINS A PARAMETER rather than being copied. The two per cent
-- and the choosing-which-Gu are one function, and a second place that picked a
-- Gu would be a second place to keep the region rules in. Callers that pass
-- three arguments get the config exactly as before.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What each thing is
-- ---------------------------------------------------------------------------

ALTER TABLE delve_haul
    ADD COLUMN tier SMALLINT,
    ADD COLUMN rarity TEXT;

COMMENT ON COLUMN delve_haul.tier IS
    'The depth of the thing, where it has one - materials.tier for what grows, ores.tier for what is dug. Null for beast materials, which have neither.';

UPDATE delve_haul h
SET tier = COALESCE(m.tier, o.tier), rarity = m.rarity
FROM materials m
LEFT JOIN ores o ON o.material_code = m.code
WHERE m.name = h.what AND h.rarity IS NULL;


CREATE OR REPLACE FUNCTION delve_record(p_delve_id bigint, p_found jsonb)
RETURNS void
LANGUAGE sql
AS $fn$
    INSERT INTO delve_haul (delve_id, what, how_many, emoji, tier, rarity)
    SELECT p_delve_id, e ->> 'what', sum((e ->> 'how_many')::bigint),
           max(m.emoji), max(COALESCE(m.tier, o.tier)), max(m.rarity)
    FROM jsonb_array_elements(COALESCE(p_found, '[]'::jsonb)) e
    LEFT JOIN materials m ON m.name = e ->> 'what'
    LEFT JOIN ores o ON o.material_code = m.code
    WHERE e ->> 'what' IS NOT NULL
      AND COALESCE((e ->> 'how_many')::bigint, 0) > 0
    GROUP BY e ->> 'what'
    ON CONFLICT (delve_id, what) DO UPDATE
    SET how_many = delve_haul.how_many + EXCLUDED.how_many,
        emoji = COALESCE(delve_haul.emoji, EXCLUDED.emoji),
        tier = COALESCE(delve_haul.tier, EXCLUDED.tier),
        rarity = COALESCE(delve_haul.rarity, EXCLUDED.rarity);
$fn$;


CREATE OR REPLACE FUNCTION delve_haul_of(p_delve_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    -- Sorted by what a thing IS, not by how much of it fell out. Two
    -- Primordial Blood belong above two hundred of anything uncommon.
    SELECT string_agg(
        COALESCE(h.emoji || ' ', '') || h.how_many || 'x ' || h.what
        || COALESCE(
             ' (' || concat_ws(' ', 'T' || h.tier, h.rarity) || ')',
             ''),
        chr(10)
        ORDER BY COALESCE(ra.sort_order, 0) DESC, COALESCE(h.tier, 0) DESC,
                 h.how_many DESC, h.what)
    FROM delve_haul h
    LEFT JOIN rarities ra ON ra.code = h.rarity
    WHERE h.delve_id = p_delve_id;
$fn$;

COMMENT ON FUNCTION delve_haul_of(bigint) IS
    'The receipt for one delve, richest first and each line saying what it is. A tally sorted by quantity puts a pile of sand above a legendary, which is how somebody kills the deep thing and thinks it gave them nothing.';


-- ---------------------------------------------------------------------------
-- And what the deep thing is actually carrying
-- ---------------------------------------------------------------------------

ALTER TABLE delve_tile_kinds
    ADD COLUMN gu_chance NUMERIC(5,3) NOT NULL DEFAULT 0;

COMMENT ON COLUMN delve_tile_kinds.gu_chance IS
    'The odds this tile''s creature was keeping a Gu. Zero for everything that is not the thing at the bottom, whose own two per cent made its headline reward a coin nobody ever saw land.';

UPDATE delve_tile_kinds SET gu_chance = 0.250 WHERE kind = 'deep';


DROP FUNCTION IF EXISTS roll_gu_drop(bigint, text, smallint);

CREATE FUNCTION roll_gu_drop(p_player_id bigint, p_region text,
                             p_rank smallint, p_chance numeric DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    picked BIGINT;
    cap    NUMERIC;
BEGIN
    -- The ambient chance unless the caller has a better one. Three-argument
    -- callers behave exactly as they did.
    IF random() >= COALESCE(p_chance, game_config_value('gu_drop_chance')) THEN
        RETURN NULL;
    END IF;

    -- What this region hands out, which is not the same everywhere since
    -- 0340: behind a door that asks for immortality, Immortal Gu.
    SELECT CASE WHEN COALESCE(r.min_rank, 1) > 1
                THEN game_config_value('gu_max_immortal_droppable_rank')
                ELSE game_config_value('gu_max_droppable_rank') END
    INTO cap
    FROM regions r WHERE r.code = p_region;

    -- Nothing hands out a Gu of a higher rank than the thing guarding it.
    SELECT d.gu_type_id INTO picked
    FROM gu_region_drops d
    JOIN gu_types t ON t.gu_type_id = d.gu_type_id
    WHERE d.region_code = p_region
      AND t.rank <= LEAST(GREATEST(p_rank, 1), COALESCE(cap, 1))
    ORDER BY -ln(random()) / d.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN grant_gu(p_player_id, picked, p_region);
END;
$fn$;

COMMENT ON FUNCTION roll_gu_drop(bigint, text, smallint, numeric) IS
    'Rolls for a Gu in a region, at the ambient chance or at one the caller names. One function, because which Gu a region may hand out is a rule that must not exist in two places.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_act is missing';
    END IF;

    anchor := concat(
'            v_gu := roll_gu_drop(p_player_id, d.region_code,', chr(10),
'                                 player_realm_rank(p_player_id));');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer rolls for a Gu where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'            -- 0480: at the tile''''s own odds. The ambient two per cent is', chr(10),
'            -- right for stumbling on one and wrong for the reward of a', chr(10),
'            -- thing you had to survive.', chr(10),
'            v_gu := roll_gu_drop(p_player_id, d.region_code,', chr(10),
'                                 player_realm_rank(p_player_id),', chr(10),
'                                 (SELECT k.gu_chance FROM delve_tile_kinds k', chr(10),
'                                  WHERE k.kind = f.tile_kind));'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The richest thing is at the top, and the deep thing carries something
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_id    BIGINT;
    v_p     BIGINT;
    v_text  TEXT;
    v_first TEXT;
    i       INTEGER;
    hits    INTEGER := 0;
BEGIN
    -- The ambient roll is untouched for everybody who passes three arguments.
    IF game_config_value('gu_drop_chance') <> 0.02 THEN
        RAISE EXCEPTION 'the ambient Gu chance moved';
    END IF;
    IF (SELECT k.gu_chance FROM delve_tile_kinds k WHERE k.kind = 'deep')
       <= game_config_value('gu_drop_chance') THEN
        RAISE EXCEPTION 'the deep thing still rolls at the ambient chance';
    END IF;
    IF EXISTS (SELECT 1 FROM delve_tile_kinds k
               WHERE k.kind <> 'deep' AND k.gu_chance > 0) THEN
        RAISE EXCEPTION 'something other than the deep thing keeps a Gu';
    END IF;

    -- A named chance really fires at about that rate.
    SELECT p.player_id INTO v_p FROM players p
    JOIN player_location pl ON pl.player_id = p.player_id
    WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;
    IF v_p IS NOT NULL THEN
        FOR i IN 1..200 LOOP
            IF roll_gu_drop(v_p, (SELECT region_code FROM player_location
                                  WHERE player_id = v_p),
                            player_realm_rank(v_p), 1.0) IS NOT NULL THEN
                hits := hits + 1;
            END IF;
        END LOOP;
        IF hits = 0 THEN
            RAISE EXCEPTION 'a certainty rolled nothing in two hundred tries';
        END IF;
        RAISE NOTICE 'a named chance of 1.0 landed % times in 200', hits;
    END IF;

    BEGIN
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- A tally with a pile of common and a scrap of legendary in it.
        INSERT INTO delve_runs
            (player_id, region_code, width, height, at_x, at_y, actions_left)
        VALUES (v_p, (SELECT region_code FROM player_location WHERE player_id = v_p),
                5, 6, 2, 5, 1)
        RETURNING delve_id INTO v_id;

        PERFORM delve_record(v_id, jsonb_build_array(
            jsonb_build_object('what', (SELECT name FROM materials
                                        WHERE rarity = 'uncommon' AND tier IS NOT NULL
                                        ORDER BY code LIMIT 1),
                               'how_many', 202),
            jsonb_build_object('what', (SELECT name FROM materials
                                        WHERE rarity = 'legendary'
                                        ORDER BY code LIMIT 1),
                               'how_many', 2)));

        v_text := delve_haul_of(v_id);
        v_first := split_part(v_text, chr(10), 1);

        RAISE NOTICE 'the tally reads:%', chr(10) || v_text;

        IF v_first NOT LIKE '%legendary%' THEN
            RAISE EXCEPTION
                'two hundred of something uncommon is still above a legendary: %',
                v_first;
        END IF;

        -- And every line says what it is.
        IF v_text NOT LIKE '%(%' THEN
            RAISE EXCEPTION 'nothing on the tally says what it is';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
