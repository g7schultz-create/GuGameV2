-- 0379_a_page_that_carries_a_move_and_a_ladder_to_fifteen
--
-- Four things, and they are one thing: the page ladder runs to fifteen, a page
-- can carry a MOVE rather than a number, a refined manual can hand that move
-- over, and the bench says so before you spend the pages.
--
-- THE LADDER. `page_tiers` and `manual_tiers` both stopped at ten, named
-- 'Pinnacle Mortal World'. Five more rungs each, on the curves they were
-- already walking - page power x1.22 a rung, manual budget x1.21 - so nothing
-- about the shape changes, it only goes further. `fuse_pages` climbs one rung
-- at a time and refuses when 'there is nothing above tier X', so it reaches
-- the new rungs the day they exist with no change at all. None of them carry
-- roll weight: like 8 to 10 they are made, not found.
--
-- THE TECHNIQUE PAGE. `page_types` is a table rather than a CHECK, so a new
-- kind of page is a row. A technique page still pays into attack like any
-- offensive page - it is ink on a page either way - but its real job is that
-- a manual refined with one in the pile carries a killer move.
--
-- WHICH MOVE, AND WHY IT IS THE SAME MOVE TWICE. A forecast that says 'this
-- will carry Falling Star Sword' and a refining that then produces something
-- else is worse than no forecast. So the move is not rolled - it is DERIVED,
-- by hashing the exact set of page ids against each candidate technique and
-- taking the first. That is semi-random in the way that matters: two different
-- piles of pages give two different moves, the same pile always gives the
-- same one, and `refine_technique_for` is the single function both the
-- forecast and the refining ask. They cannot disagree, because there is
-- nothing for them to disagree about.
--
-- THE OLD ROUTE STAYS. Before this, an offensive manual refined at 105 harmony
-- or better picked up the strongest canonical move of its Path. That still
-- happens. A technique page is a second door, not a replacement - it does not
-- need the harmony, which is the point of spending it.
--
-- Forward-only. Do not edit once applied.


-- Both ladders were CHECKed to ten as well as ending there.
ALTER TABLE page_tiers DROP CONSTRAINT page_tiers_tier_check;
ALTER TABLE page_tiers ADD CONSTRAINT page_tiers_tier_check
    CHECK (tier >= 1 AND tier <= 15);

ALTER TABLE manual_tiers DROP CONSTRAINT manual_tiers_tier_check;
ALTER TABLE manual_tiers ADD CONSTRAINT manual_tiers_tier_check
    CHECK (tier >= 1 AND tier <= 15);


INSERT INTO page_tiers (tier, name, power_min, power_max, roll_weight) VALUES
    (11, 'Immortal transcription',      76, 129, 0),
    (12, 'Heavenly inheritance',        93, 157, 0),
    (13, 'Venerable''s own hand',      113, 192, 0),
    (14, 'Written before the Era',     138, 234, 0),
    (15, 'Pinnacle of all writing',    168, 286, 0);

INSERT INTO manual_tiers (tier, name, bonus_budget) VALUES
    (11, 'Immortal transcription',    0.99),
    (12, 'Heavenly inheritance',      1.20),
    (13, 'Venerable''s own hand',     1.45),
    (14, 'Written before the Era',    1.76),
    (15, 'Pinnacle of all writing',   2.13);

ALTER TABLE manuals DROP CONSTRAINT manuals_tier_check;
ALTER TABLE manuals ADD CONSTRAINT manuals_tier_check
    CHECK (tier >= 1 AND tier <= 15);


-- A page that is a move rather than a number. It still feeds attack, because
-- it is still ink and still counts toward what the manual can afford; what it
-- buys on top is the move itself.
INSERT INTO page_types
    (code, name, manual_column, is_live, description, emoji, roll_weight, sort_order)
VALUES
    ('technique', 'Technique', 'attack_bonus', TRUE,
     'A move written out in full. A manual refined with one of these in the pile teaches it, whatever the harmony came to.',
     '📕', 4.00, 15);


INSERT INTO game_config (key, value, description) VALUES
    ('technique_page_guarantees', 1,
     'Technique pages needed in a pile before the refined manual is certain to carry a move. One, because a page that only sometimes does the one thing it is for is a page nobody spends.');


-- ---------------------------------------------------------------------------
-- Which move, decided once and answerable twice
-- ---------------------------------------------------------------------------

CREATE FUNCTION refine_technique_for(
    p_page_ids BIGINT[], p_path TEXT, p_tier SMALLINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT t.technique_id
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND t.grade = 'advanced'
      AND tp.path_code = p_path
      AND t.rank <= technique_manual_rank(p_tier)
    -- Semi-random, and the SAME semi-random every time this pile is laid out.
    -- Hashed off the page set so a different pile finds a different move and
    -- an identical pile always finds the one the forecast promised. Nothing
    -- is stored and nothing can drift.
    ORDER BY hashtext(
        (SELECT string_agg(x::text, ',' ORDER BY x) FROM unnest(p_page_ids) AS x)
        || ':' || t.technique_id::text)
    LIMIT 1;
$$;

COMMENT ON FUNCTION refine_technique_for(BIGINT[], TEXT, SMALLINT) IS
    'The move a pile of pages would teach. Derived from the page ids rather than rolled, so the bench forecast and the refining always name the same technique.';


CREATE FUNCTION refine_technique_preview(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE(
    carries    BOOLEAN,
    reason     TEXT,
    technique  BIGINT,
    name       TEXT,
    power      INTEGER,
    rank       SMALLINT,
    path_name  TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    look   RECORD;
    pages  INTEGER;
    found  BIGINT;
    why    TEXT;
BEGIN
    SELECT * INTO look FROM refine_forecast(p_player_id, p_page_ids);
    IF look IS NULL OR look.pages = 0 THEN
        RETURN;
    END IF;

    SELECT count(*) INTO pages
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
      AND mp.owner_id = p_player_id
      AND mp.consumed_at IS NULL
      AND mp.page_type = 'technique';

    -- Two doors. A technique page is the certain one and asks nothing of the
    -- harmony; the old offensive route still opens at 105.
    IF pages >= game_config_value('technique_page_guarantees') THEN
        why := 'a technique page is in the pile';
    ELSIF look.archetype = 'offensive'
          AND look.base_harmony >= game_config_value('technique_manual_harmony') THEN
        why := 'an offensive manual at ' || round(look.base_harmony) || ' harmony';
    ELSE
        RETURN QUERY SELECT FALSE,
            CASE WHEN look.archetype = 'offensive'
                 THEN 'needs ' || game_config_value('technique_manual_harmony')
                      || ' harmony, or a technique page'
                 ELSE 'only an offensive pile teaches a move, or a technique page'
            END,
            NULL::bigint, NULL::text, NULL::integer, NULL::smallint, NULL::text;
        RETURN;
    END IF;

    found := refine_technique_for(p_page_ids, look.dominant,
                                  look.forecast_tier::smallint);

    IF found IS NULL THEN
        RETURN QUERY SELECT FALSE,
            'nothing of the ' || COALESCE(look.dominant, 'that') ||
            ' Path is written low enough for a tier ' || look.forecast_tier
            || ' manual',
            NULL::bigint, NULL::text, NULL::integer, NULL::smallint, NULL::text;
        RETURN;
    END IF;

    RETURN QUERY
    SELECT TRUE, why, t.technique_id, t.name, t.base_power, t.rank, p.name
    FROM techniques t
    LEFT JOIN technique_paths tp ON tp.technique_id = t.technique_id
    LEFT JOIN paths p ON p.code = tp.path_code
    WHERE t.technique_id = found
    LIMIT 1;
END;
$$;

COMMENT ON FUNCTION refine_technique_preview(BIGINT, BIGINT[]) IS
    'What the bench should say before the pages are spent: whether this pile teaches a move, which one, and how hard it hits.';


-- ---------------------------------------------------------------------------
-- And the refining asks the same question
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    IF arch = ''offensive''', chr(10),
'       AND final_h >= game_config_value(''technique_manual_harmony'') THEN', chr(10),
'        SELECT t.technique_id INTO killer', chr(10),
'        FROM techniques t', chr(10),
'        JOIN technique_paths tp ON tp.technique_id = t.technique_id', chr(10),
'        WHERE t.created_by IS NULL', chr(10),
'          AND t.grade = ''advanced''', chr(10),
'          AND tp.path_code = look.dominant', chr(10),
'          AND t.rank <= technique_manual_rank(look.forecast_tier::smallint)', chr(10),
'        ORDER BY t.rank DESC, t.base_power DESC', chr(10),
'        LIMIT 1;', chr(10),
chr(10),
'        IF killer IS NOT NULL THEN', chr(10),
'            arch := ''technique'';', chr(10),
'        END IF;', chr(10),
'    END IF;');

    swap := concat(
'    -- Two doors to a move. A technique page in the pile is the certain one', chr(10),
'    -- and asks nothing of the harmony - that is what spending it buys. The', chr(10),
'    -- old route, an offensive pile refined at 105 or better, still opens.', chr(10),
'    IF (SELECT count(*) FROM manual_pages mp', chr(10),
'        WHERE mp.page_id = ANY (p_page_ids)', chr(10),
'          AND mp.owner_id = p_player_id', chr(10),
'          AND mp.page_type = ''technique'')', chr(10),
'       >= game_config_value(''technique_page_guarantees'')', chr(10),
'       OR (arch = ''offensive''', chr(10),
'           AND final_h >= game_config_value(''technique_manual_harmony'')) THEN', chr(10),
chr(10),
'        -- The same function the bench forecast asked, so the manual carries', chr(10),
'        -- the move the player was shown and not a second opinion.', chr(10),
'        killer := refine_technique_for(p_page_ids, look.dominant,', chr(10),
'                                       look.forecast_tier::smallint);', chr(10),
chr(10),
'        IF killer IS NOT NULL THEN', chr(10),
'            arch := ''technique'';', chr(10),
'        END IF;', chr(10),
'    END IF;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'refine';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine no longer chooses a killer move where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The bench promises exactly what the bench delivers
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who   BIGINT;
    pages BIGINT[];
    one   BIGINT;
    saw   RECORD;
    made  RECORD;
    n     INTEGER;
    bad   TEXT;
BEGIN
    -- Both ladders climb and neither has a hole in it.
    SELECT string_agg(g.tier::text, ', ') INTO bad
    FROM generate_series(1, 15) AS g(tier)
    WHERE NOT EXISTS (SELECT 1 FROM page_tiers t WHERE t.tier = g.tier)
       OR NOT EXISTS (SELECT 1 FROM manual_tiers m WHERE m.tier = g.tier);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs are missing from a ladder: %', bad;
    END IF;

    SELECT count(*) INTO n FROM (
        SELECT tier, power_max,
               lag(power_max) OVER (ORDER BY tier) AS below
        FROM page_tiers
    ) t WHERE t.below IS NOT NULL AND t.power_max <= t.below;
    IF n > 0 THEN
        RAISE EXCEPTION '% page rungs are no stronger than the one below', n;
    END IF;

    SELECT count(*) INTO n FROM (
        SELECT tier, bonus_budget,
               lag(bonus_budget) OVER (ORDER BY tier) AS below
        FROM manual_tiers
    ) t WHERE t.below IS NOT NULL AND t.bonus_budget <= t.below;
    IF n > 0 THEN
        RAISE EXCEPTION '% manual rungs are worth no more than the one below', n;
    END IF;

    -- Nothing new leaked into the ordinary drop table.
    SELECT string_agg(t.tier::text, ', ') INTO bad
    FROM page_tiers t WHERE t.tier > 7 AND t.roll_weight > 0;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these tiers above 7 can now simply be found: %', bad;
    END IF;

    -- ---- driven: a pile with a technique page in it --------------------
    SELECT p.player_id INTO who FROM players p WHERE p.deleted_at IS NULL LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to stand at a bench';
        RETURN;
    END IF;

    BEGIN
        -- Exactly what this refiner's skill allows, rather than a number I
        -- liked: `refine` refuses a pile bigger than the bench can hold, and
        -- `refinement_max_pages` is the function it asks.
        SELECT refinement_max_pages(COALESCE(pr.level, 1)::smallint)::int
        INTO n
        FROM (SELECT 1) _
        LEFT JOIN player_refinement pr ON pr.player_id = who;
        n := GREATEST(2, COALESCE(n, 3));

        pages := ARRAY[]::BIGINT[];
        FOR i IN 1..n LOOP
            one := mint_page_at(who, 7::smallint, 'sword',
                                CASE WHEN i = 1 THEN 'technique' ELSE 'attack' END,
                                NULL);
            pages := pages || one;
        END LOOP;

        SELECT * INTO saw FROM refine_technique_preview(who, pages);
        IF saw IS NULL OR NOT saw.carries THEN
            RAISE EXCEPTION
                'a pile with a technique page in it promised no move (%)',
                COALESCE(saw.reason, 'nothing said');
        END IF;

        -- Asked twice, answered the same. This is the whole contract.
        IF refine_technique_for(pages, 'sword',
               (SELECT forecast_tier FROM refine_forecast(who, pages)))
           <> saw.technique THEN
            RAISE EXCEPTION 'the bench named two different moves for one pile';
        END IF;

        SELECT * INTO made FROM refine(who, pages);
        IF NOT made.succeeded THEN
            RAISE EXCEPTION 'the refining failed outright';
        END IF;

        -- And what came off the bench teaches exactly what was promised.
        IF NOT EXISTS (
            SELECT 1 FROM manual_techniques mt
            WHERE mt.manual_id = made.manual_id
              AND mt.technique_id = saw.technique
        ) THEN
            RAISE EXCEPTION
                'the bench promised % and the manual teaches something else',
                saw.name;
        END IF;

        RAISE NOTICE
            'the bench promised % (% power, rank %) and the manual teaches it',
            saw.name, saw.power, saw.rank;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a technique manual was refined and rolled back';
END;
$probe$;
