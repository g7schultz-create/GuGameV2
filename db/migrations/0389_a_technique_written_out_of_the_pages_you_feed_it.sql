-- 0389_a_technique_written_out_of_the_pages_you_feed_it
--
-- `/enlighten` forges a technique once a day and the sky decides everything
-- about it: the quality is a weighted draw, the Paths come off your attainment,
-- and the only steer you have is a focus that shifts one weight. A technique
-- page - four per hundred of everything a heaven drops, seven in the whole
-- world - can currently only be spent teaching you a move somebody else
-- already wrote.
--
-- This is the other door into the same forge. Not a second system: it writes a
-- row into `technique_forges` exactly as `forge_begin` does, and `forge_offer`
-- and `forge_take` carry it the rest of the way without knowing which door it
-- came through. Everything already true of a forged technique - that it scales
-- with the realm you forged it in, that its manual stats are rolled through
-- the destiny interface, that a bad board can hand you a curse - stays true.
--
-- WHAT THE PILE DECIDES, AND WHAT IT LEAVES TO THE ROLL. Three things move
-- from the sky to your hands, and each is a floor rather than a guarantee:
--
--   THE QUALITY FLOOR comes off the AVERAGE TIER of the pages. Every
--     `technique_forge_page_tiers_per_rung` tiers is one rung up the
--     `enlighten_qualities` ladder, and the draw then runs normally from that
--     rung upward. Deep pages cannot give you a Common Insight; they still
--     cannot promise you a Dao Revelation, because the top rung is never a
--     floor - it is the thing everybody is still gambling for.
--
--   THE PATHS come off the pages themselves, weighted by how many of each you
--     put in. Four Heaven pages and one Fire page is mostly Heaven, sometimes
--     Fire. This is the real prize: the daily forge draws Paths off attainment
--     and hands you what you are already good at, and a pile hands you what
--     you chose.
--
--     Which makes a rule worth learning: A DUAL PATH NEEDS A MIXED PILE. The
--     draw takes distinct Paths without replacement, so five pages of one Path
--     teach one Path however well the quality rolls. The strongest techniques
--     in the game are dual, and this is the cost of aiming.
--
--   WHERE IN THE GRADE BAND it lands is blended half and half with how well
--     the pages rolled inside their OWN tier. A tier 15 page is 163 to 263
--     power; one that came out at 250 is a better page than one that came out
--     at 170 and has never once mattered. Now it does, at half weight, so two
--     identical-looking piles are not identical and neither is decided.
--
-- IT DOES NOT SPEND THE DAY. `/enlighten` keeps its own cooldown and this
-- keeps none: the pages are the cost, and they are a far harder one. Somebody
-- who has hoarded six technique pages should be able to spend them in one
-- sitting if that is the plan.
--
-- THE SAME REALM GATE. `forge_begin` refuses below `technique_forge_min_rank`
-- and so does this. Two doors into one table with two different rules is how a
-- system starts lying about itself, and a technique forged at rank 1 would
-- scale to rank 1 anyway.
--
-- WHO CAN DO THIS TODAY. m_i_y_u_k_i, holding three - enslavement, metal and
-- theft, all rolled high in their bands. pashu0 and sylvrime are one and two
-- pages short. That is the shape a prestige route should have on the day it
-- ships.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('technique_forge_pages_needed', 3,
     'Technique pages a pile must hold before it can be forged into a move of your own. Three because that is a real hoard - four per hundred of what a heaven drops are technique pages.'),
    ('technique_forge_page_tiers_per_rung', 3,
     'How many tiers of average page depth buy one rung up the enlightenment ladder as a FLOOR. At 3, tier 13-15 pages floor at Heavenly Inspiration and nothing ever floors at Dao Revelation.'),
    ('technique_forge_page_step_chance', 0.15,
     'Chance per page ABOVE the minimum of lifting that floor one further rung, once, at most. What extra pages are for.'),
    ('technique_forge_page_grade_weight', 0.5,
     'How much of where a technique lands inside its quality band is decided by how well the pages rolled inside their own tiers, the rest being chance. At 0.5 a good pile matters and does not decide.');


-- Which pages were burned for it. The daily door leaves this NULL, which is
-- the honest way to say "the sky, not a pile".
ALTER TABLE technique_forges ADD COLUMN from_pages BIGINT[];

COMMENT ON COLUMN technique_forges.from_pages IS
    'The technique pages fed to this forge, or NULL when it came from a day of meditation instead.';


-- ---------------------------------------------------------------------------
-- What a pile is worth, before anything is burned
-- ---------------------------------------------------------------------------
--
-- Read by the screen that asks "are you sure" and by the function that does
-- it, so a pile that reads as forgeable is a pile that forges. The same
-- discipline `breakthrough_gate` keeps for a crossing.

CREATE FUNCTION forge_pile_reading(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE (pages INTEGER, needed INTEGER, avg_tier NUMERIC,
               floor_code TEXT, floor_name TEXT, floor_emoji TEXT,
               may_step BOOLEAN, distinct_paths INTEGER, dual_possible BOOLEAN,
               path_spread TEXT, band_position NUMERIC, ready BOOLEAN,
               refused TEXT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pages  INTEGER := 0;
    v_need   INTEGER := game_config_value('technique_forge_pages_needed')::int;
    v_tier   NUMERIC;
    v_paths  INTEGER;
    v_pos    NUMERIC;
    v_rung   INTEGER;
    v_floor  RECORD;
    v_spread TEXT;
    v_why    TEXT;
BEGIN
    -- Yours, unspent, and actually a technique page. Anything else in the
    -- array is ignored rather than refused, so a fat-fingered id is a pile one
    -- page short rather than an error with no number in it.
    SELECT count(*),
           avg(mp.tier),
           count(DISTINCT mp.path_code),
           -- How high each page rolled inside its OWN tier's band, averaged.
           -- GREATEST(1, ...) because a tier whose band has no width would
           -- otherwise divide by nothing.
           avg((mp.power - pt.power_min)::numeric
               / GREATEST(1, pt.power_max - pt.power_min)),
           string_agg(DISTINCT pa.name, ', ' ORDER BY pa.name)
    INTO v_pages, v_tier, v_paths, v_pos, v_spread
    FROM manual_pages mp
    JOIN page_tiers pt ON pt.tier = mp.tier
    JOIN paths pa ON pa.code = mp.path_code
    WHERE mp.page_id = ANY (p_page_ids)
      AND mp.owner_id = p_player_id
      AND mp.consumed_at IS NULL
      AND mp.page_type = 'technique';

    IF COALESCE(v_pages, 0) = 0 THEN
        RETURN QUERY SELECT 0, v_need, NULL::numeric, NULL::text, NULL::text,
                            NULL::text, FALSE, 0, FALSE, NULL::text,
                            NULL::numeric, FALSE,
                            'none of those are technique pages you still hold';
        RETURN;
    END IF;

    -- The floor: every N tiers of average depth is one rung. Never the top
    -- rung, which stays the thing nobody can buy.
    v_rung := floor((v_tier - 1)
              / game_config_value('technique_forge_page_tiers_per_rung'))::int;

    SELECT q.code, q.name, q.emoji INTO v_floor
    FROM (
        SELECT eq.code, eq.name, eq.emoji,
               row_number() OVER (ORDER BY eq.sort_order) - 1 AS rung,
               count(*) OVER () AS rungs
        FROM enlighten_qualities eq
    ) q
    -- Clamped one below the top: a floor at Dao Revelation would make the
    -- rarest thing in the system purchasable.
    WHERE q.rung = LEAST(v_rung, q.rungs - 2);

    IF v_pages < v_need THEN
        v_why := 'a pile wants ' || v_need || ' technique pages and holds '
                 || v_pages;
    END IF;

    RETURN QUERY SELECT
        v_pages, v_need, round(v_tier, 2),
        v_floor.code, v_floor.name, v_floor.emoji,
        v_pages > v_need,
        v_paths, v_paths > 1, v_spread,
        round(COALESCE(v_pos, 0.5), 3),
        v_why IS NULL, v_why;
END;
$$;

COMMENT ON FUNCTION forge_pile_reading(BIGINT, BIGINT[]) IS
    'What a pile of technique pages would be worth if it were burned: the quality it floors at, the Paths it can reach, and whether it is big enough yet.';


-- ---------------------------------------------------------------------------
-- And burning it
-- ---------------------------------------------------------------------------

CREATE FUNCTION forge_begin_from_pages(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_read   RECORD;
    v_open   BIGINT;
    v_mine   SMALLINT;
    v_rung   INTEGER;
    v_q      RECORD;
    v_grade  NUMERIC;
    v_want   INTEGER;
    v_picked TEXT[];
    v_burn   BIGINT[];
BEGIN
    SELECT forge_id INTO v_open FROM technique_forges
    WHERE player_id = p_player_id AND finished_at IS NULL;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION
            'you are already in the middle of forging something - finish it first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same door `forge_begin` keeps, word for word, because two doors into
    -- one table with two rules is how a system starts lying about itself.
    SELECT r.rank INTO v_mine
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;

    IF COALESCE(v_mine, 1) < game_config_value('technique_forge_min_rank') THEN
        RAISE EXCEPTION
            'forging a technique is an immortal''s work - reach %, and come back',
            (SELECT min(name) FROM realms
             WHERE rank = game_config_value('technique_forge_min_rank')::smallint)
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_read FROM forge_pile_reading(p_player_id, p_page_ids);
    IF v_read IS NULL OR NOT v_read.ready THEN
        RAISE EXCEPTION '%', COALESCE(v_read.refused, 'that pile is not a technique')
            USING ERRCODE = 'check_violation';
    END IF;

    -- The pages that count, named once so the burn and the record agree.
    SELECT array_agg(mp.page_id ORDER BY mp.page_id) INTO v_burn
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
      AND mp.owner_id = p_player_id
      AND mp.consumed_at IS NULL
      AND mp.page_type = 'technique';

    -- ---- the floor, and the one chance of standing higher -----------------
    v_rung := floor((v_read.avg_tier - 1)
              / game_config_value('technique_forge_page_tiers_per_rung'))::int;
    v_rung := LEAST(v_rung,
                    (SELECT count(*) - 2 FROM enlighten_qualities)::int);

    -- Every page above the minimum is a chance at one more rung, and only ever
    -- one more. Which is the only way a pile can floor at the top rung, and it
    -- is a chance rather than a price.
    IF v_read.pages > v_read.needed
       AND random() < 1 - power(
             1 - game_config_value('technique_forge_page_step_chance'),
             v_read.pages - v_read.needed) THEN
        v_rung := v_rung + 1;
    END IF;

    -- ---- the quality, drawn normally from that rung upward ----------------
    SELECT * INTO v_q FROM (
        SELECT eq.*, row_number() OVER (ORDER BY eq.sort_order) - 1 AS rung
        FROM enlighten_qualities eq WHERE eq.weight > 0
    ) q
    WHERE q.rung >= v_rung
    ORDER BY -ln(random()) / q.weight
    LIMIT 1;

    IF v_q IS NULL THEN
        RAISE EXCEPTION 'the enlightenment ladder has no rung at or above %', v_rung;
    END IF;

    -- ---- where in the band, half the pages and half the day ---------------
    v_grade := v_q.grade_min + (v_q.grade_max - v_q.grade_min) * (
        game_config_value('technique_forge_page_grade_weight') * v_read.band_position
        + (1 - game_config_value('technique_forge_page_grade_weight')) * random());

    v_want := v_q.min_paths
              + CASE WHEN v_q.max_paths > v_q.min_paths
                     THEN floor(random() * (v_q.max_paths - v_q.min_paths + 1))::int
                     ELSE 0 END;

    -- ---- and the Paths, off the pile rather than off your attainment ------
    -- Weighted by how many pages of each Path went in, and distinct - which is
    -- why a pile of one Path teaches one Path however well the quality rolled.
    SELECT array_agg(pick.path_code) INTO v_picked FROM (
        SELECT mp.path_code, count(*) AS weight
        FROM manual_pages mp
        WHERE mp.page_id = ANY (v_burn)
        GROUP BY mp.path_code
        ORDER BY -ln(random()) / count(*)
        LIMIT v_want
    ) AS pick;

    -- ---- the pages are gone ----------------------------------------------
    -- `consumed_by` stays NULL: it points at a manual, and this pile did not
    -- become one. Spent, and the forge itself records where they went.
    UPDATE manual_pages SET consumed_at = now()
    WHERE page_id = ANY (v_burn);

    INSERT INTO technique_forges
        (player_id, realm_rank, power_grade, dual, paths, quality, focus,
         from_pages)
    VALUES (p_player_id, v_mine, round(v_grade, 3),
            array_length(v_picked, 1) > 1, v_picked, v_q.code, NULL, v_burn)
    RETURNING forge_id INTO v_open;

    RETURN v_open;
END;
$$;

COMMENT ON FUNCTION forge_begin_from_pages(BIGINT, BIGINT[]) IS
    'Burns a pile of technique pages into a forge of your own. The pile sets the quality floor, the Paths and half of where it lands in the band; the rest is still the roll.';


-- ---------------------------------------------------------------------------
-- Deep pages floor high, one Path stays one Path, and nothing buys a Dao
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_ids   BIGINT[];
    v_read  RECORD;
    v_forge BIGINT;
    v_row   RECORD;
    v_top   TEXT;
    v_n     INTEGER;
    i       INTEGER;
BEGIN
    -- The top rung must never be a floor, at any depth, or the rarest thing in
    -- the system becomes a purchase.
    SELECT eq.code INTO v_top FROM enlighten_qualities eq
    ORDER BY eq.sort_order DESC LIMIT 1;

    SELECT count(*) INTO v_n FROM enlighten_qualities;

    FOR i IN 1..15 LOOP
        IF LEAST(floor((i - 1)
                 / game_config_value('technique_forge_page_tiers_per_rung'))::int,
                 v_n - 2) > v_n - 2 THEN
            RAISE EXCEPTION 'tier % floors above the second-highest rung', i;
        END IF;
    END LOOP;

    -- Somebody with a real pile, on real pages, rolled back.
    SELECT mp.owner_id, array_agg(mp.page_id) INTO v_who, v_ids
    FROM manual_pages mp
    WHERE mp.page_type = 'technique' AND mp.consumed_at IS NULL
    GROUP BY mp.owner_id
    HAVING count(*) >= game_config_value('technique_forge_pages_needed')
    ORDER BY count(*) DESC
    LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody holds a pile yet; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT * INTO v_read FROM forge_pile_reading(v_who, v_ids);
        IF NOT v_read.ready THEN
            RAISE EXCEPTION 'a full pile read as short: %', v_read.refused;
        END IF;
        IF v_read.floor_code = v_top THEN
            RAISE EXCEPTION 'a pile floored at the top rung';
        END IF;

        RAISE NOTICE
            'a pile of % pages, average tier %, floors at % and can reach %',
            v_read.pages, v_read.avg_tier, v_read.floor_name, v_read.path_spread;

        -- Clear the day's forge if one is open, so this measures the page door
        -- rather than colliding with the sky's.
        DELETE FROM technique_forges
        WHERE player_id = v_who AND finished_at IS NULL;

        v_forge := forge_begin_from_pages(v_who, v_ids);

        SELECT * INTO v_row FROM technique_forges WHERE forge_id = v_forge;

        IF v_row.from_pages IS NULL THEN
            RAISE EXCEPTION 'the forge does not remember what was burned for it';
        END IF;
        IF v_row.realm_rank IS NULL OR v_row.realm_rank < 1 THEN
            RAISE EXCEPTION 'a forge with no realm behind it scales to nothing';
        END IF;

        -- Never below the floor the pile promised.
        IF (SELECT eq.sort_order FROM enlighten_qualities eq
            WHERE eq.code = v_row.quality)
           < (SELECT eq.sort_order FROM enlighten_qualities eq
              WHERE eq.code = v_read.floor_code) THEN
            RAISE EXCEPTION
                'the pile floored at % and forged a %',
                v_read.floor_code, v_row.quality;
        END IF;

        -- Every Path it drew came out of the pile, which is the whole point.
        IF EXISTS (
            SELECT 1 FROM unnest(v_row.paths) AS drew(code)
            WHERE drew.code NOT IN (
                SELECT mp.path_code FROM manual_pages mp
                WHERE mp.page_id = ANY (v_row.from_pages))
        ) THEN
            RAISE EXCEPTION 'the forge drew a Path that was never in the pile';
        END IF;

        -- And the pages are spent, with nothing pointing at a manual that does
        -- not exist.
        IF EXISTS (SELECT 1 FROM manual_pages mp
                   WHERE mp.page_id = ANY (v_row.from_pages)
                     AND (mp.consumed_at IS NULL OR mp.consumed_by IS NOT NULL)) THEN
            RAISE EXCEPTION 'the pages were not cleanly spent';
        END IF;

        -- The board still works, which is the claim that it is one system.
        IF forge_offer(v_forge) IS NULL THEN
            RAISE EXCEPTION 'a page-forged technique has no board to choose from';
        END IF;

        RAISE NOTICE
            'burned % pages into a % forge on % at grade %',
            array_length(v_row.from_pages, 1), v_row.quality,
            array_to_string(v_row.paths, ' + '), v_row.power_grade;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
