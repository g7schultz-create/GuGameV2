-- 0246_three_pages_make_a_better_one
--
-- There are 3,117 pages of tier 3 and below sitting in inventories with
-- nowhere to go. Clearwest alone holds 1,198 of them - seventy-four per cent
-- of her collection - and they are worse than dead weight in a refinement:
-- low power drags the forecast tier down, and mixing tiers costs 3.5 harmony
-- per rung of spread. The only outlets a page has ever had are a refinement
-- that does not want it and the auction house.
--
-- SO THREE MAKE ONE, A RUNG UP. Same tier, same Path, same kind of page -
-- strict on purpose, because a fusion that laundered anything into anything
-- would make Paths and page types stop meaning what they mean everywhere
-- else. Fusing toward a stack of tier 7 Illusion attack pages is a project
-- somebody chooses, not a way to wash junk.
--
-- IT IS THE ONLY THING THAT MAKES A TIER 8 PAGE. `page_tiers` has carried
-- rows for tiers 8, 9 and 10 since it was written, with power curves and
-- everything, and `mint_page` stops at 7 - so those three rows have never
-- described a page that exists. Fusion is their producer. That also gives the
-- mechanic a ceiling worth walking toward: a tier 10 page is 59 fusions and
-- 243 tier 1 pages away, and nothing else in the game will ever hand you one.
--
-- QUALITY CARRIES THROUGH, so feeding good pages is rewarded and feeding
-- rubbish is not. The new page's quality is the average of what went in, plus
-- a small lift; its power follows from that against the higher tier's curve.
-- A trait on any of the three survives into the result rather than being
-- destroyed - the best of them, if more than one had one.
--
-- NO REFINEMENT EXP. Fusing makes pages; refining makes exp. The loop is that
-- better pages make better refinements which make more exp, and paying twice
-- for one action would flatten that back into a grind.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE manual_pages
    ADD COLUMN fused_into BIGINT REFERENCES manual_pages (page_id) ON DELETE SET NULL;

CREATE INDEX manual_pages_fused_idx ON manual_pages (fused_into);

COMMENT ON COLUMN manual_pages.fused_into IS
    'The page this one became. `consumed_by` could not say it - that column points at a manual - and a page that vanished with no account of where it went is the thing this records.';


INSERT INTO game_config (key, value, description) VALUES
    ('page_fusion_count', 3,
     'How many pages go into a fusion. They must share a tier, a Path and a '
     'kind - a fusion that took anything would make those three stop meaning '
     'what they mean everywhere else.'),
    ('page_fusion_quality_lift', 3,
     'Added to the average quality of what went in. Small: the reward for '
     'fusing is the tier, and quality is meant to be carried rather than '
     'conjured.');


CREATE FUNCTION fuse_pages(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE (
    page_id   BIGINT,
    tier      SMALLINT,
    path_code TEXT,
    page_type TEXT,
    trait     TEXT,
    power     SMALLINT,
    quality   SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    want     INTEGER;
    held     INTEGER;
    from_t   SMALLINT;
    n_tiers  INTEGER;
    n_paths  INTEGER;
    n_types  INTEGER;
    the_path TEXT;
    the_type TEXT;
    the_home TEXT;
    up       SMALLINT;
    lo       SMALLINT;
    hi       SMALLINT;
    keep_tr  TEXT;
    q        SMALLINT;
    pow      SMALLINT;
    made     BIGINT;
BEGIN
    want := game_config_value('page_fusion_count')::integer;

    IF p_page_ids IS NULL
       OR array_length(p_page_ids, 1) IS DISTINCT FROM want THEN
        RAISE EXCEPTION 'a fusion takes exactly % pages', want
            USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT count(DISTINCT x) FROM unnest(p_page_ids) x) <> want THEN
        RAISE EXCEPTION 'the same page cannot be fused with itself'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything about the three, read once and under a lock so two fusions
    -- cannot spend the same page.
    PERFORM 1 FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids) AND mp.owner_id = p_player_id
    FOR UPDATE;

    SELECT count(*)::integer,
           min(mp.tier)::smallint,
           count(DISTINCT mp.tier)::integer,
           count(DISTINCT mp.path_code)::integer,
           count(DISTINCT mp.page_type)::integer,
           min(mp.path_code),
           min(mp.page_type),
           min(mp.found_in)
    INTO held, from_t, n_tiers, n_paths, n_types, the_path, the_type, the_home
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
      AND mp.owner_id = p_player_id
      AND mp.consumed_at IS NULL;

    IF held <> want THEN
        RAISE EXCEPTION 'those are not all yours to fuse'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_tiers <> 1 THEN
        RAISE EXCEPTION 'a fusion takes pages of one tier'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_paths <> 1 THEN
        RAISE EXCEPTION 'a fusion takes pages of one Path'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_types <> 1 THEN
        RAISE EXCEPTION 'a fusion takes pages of one kind'
            USING ERRCODE = 'check_violation';
    END IF;

    up := (from_t + 1)::smallint;

    SELECT t.power_min, t.power_max INTO lo, hi
    FROM page_tiers t WHERE t.tier = up;

    IF lo IS NULL THEN
        RAISE EXCEPTION 'there is nothing above tier %', from_t
            USING ERRCODE = 'check_violation';
    END IF;

    -- The best trait among them survives. A fusion that destroyed traits
    -- would make a traited page something you hoard rather than build with.
    SELECT mp.trait INTO keep_tr
    FROM manual_pages mp
    LEFT JOIN page_traits tr ON tr.code = mp.trait
    WHERE mp.page_id = ANY (p_page_ids) AND mp.trait IS NOT NULL
    ORDER BY COALESCE(tr.quality_bonus, 0) DESC,
             COALESCE(tr.power_multiplier, 1) DESC
    LIMIT 1;

    IF keep_tr IS NULL AND random() < game_config_value('page_trait_chance') THEN
        SELECT tr.code INTO keep_tr FROM page_traits tr
        WHERE tr.roll_weight > 0
        ORDER BY -ln(random()) / tr.roll_weight
        LIMIT 1;
    END IF;

    -- Quality is carried, not conjured: the average of what went in, lifted a
    -- little, so feeding good pages is what makes a good page.
    SELECT round(avg(mp.quality))::smallint INTO q
    FROM manual_pages mp WHERE mp.page_id = ANY (p_page_ids);

    q := GREATEST(1, LEAST(100,
         q + game_config_value('page_fusion_quality_lift')::smallint
           + COALESCE((SELECT tr.quality_bonus FROM page_traits tr
                       WHERE tr.code = keep_tr), 0)))::smallint;

    pow := GREATEST(1, round(
        (lo + (hi - lo) * (q / 100.0))
        * COALESCE((SELECT tr.power_multiplier FROM page_traits tr
                    WHERE tr.code = keep_tr), 1)))::smallint;

    INSERT INTO manual_pages
        (owner_id, tier, path_code, page_type, trait, power, quality, found_in)
    VALUES (p_player_id, up, the_path, the_type, keep_tr, pow, q, the_home)
    RETURNING manual_pages.page_id INTO made;

    UPDATE manual_pages mp
    SET consumed_at = now(), fused_into = made
    WHERE mp.page_id = ANY (p_page_ids);

    RETURN QUERY
    SELECT mp.page_id, mp.tier, mp.path_code, mp.page_type,
           mp.trait, mp.power, mp.quality
    FROM manual_pages mp WHERE mp.page_id = made;
END;
$$;

COMMENT ON FUNCTION fuse_pages(BIGINT, BIGINT[]) IS
    'Three pages of one tier, one Path and one kind become a single page a rung higher. The only thing in the game that makes a page above tier 7.';


-- What a cultivator could fuse right now, so no screen has to work it out.
CREATE VIEW page_fusion_shelf AS
SELECT mp.owner_id AS player_id,
       mp.tier, mp.path_code, mp.page_type,
       p.name  AS path_name,
       pt.name AS type_name,
       count(*)::integer AS held,
       (count(*) / game_config_value('page_fusion_count'))::integer AS fusions,
       round(avg(mp.quality))::smallint AS avg_quality
FROM manual_pages mp
JOIN paths p       ON p.code = mp.path_code
JOIN page_types pt ON pt.code = mp.page_type
WHERE mp.consumed_at IS NULL
  AND EXISTS (SELECT 1 FROM page_tiers t WHERE t.tier = mp.tier + 1)
GROUP BY mp.owner_id, mp.tier, mp.path_code, mp.page_type, p.name, pt.name
HAVING count(*) >= game_config_value('page_fusion_count');

COMMENT ON VIEW page_fusion_shelf IS
    'Every stack a cultivator holds that is three deep in one tier, one Path and one kind - which is exactly what a fusion needs.';


DO $$
DECLARE
    who   BIGINT;
    stack RECORD;
    ids   BIGINT[];
    born  RECORD;
    was_q NUMERIC;
BEGIN
    SELECT s.player_id INTO who FROM page_fusion_shelf s LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds three of a kind; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT * INTO stack FROM page_fusion_shelf s
        WHERE s.player_id = who ORDER BY s.tier DESC LIMIT 1;

        SELECT array_agg(mp.page_id), round(avg(mp.quality))
        INTO ids, was_q
        FROM (SELECT mp.page_id, mp.quality FROM manual_pages mp
              WHERE mp.owner_id = who AND mp.consumed_at IS NULL
                AND mp.tier = stack.tier AND mp.path_code = stack.path_code
                AND mp.page_type = stack.page_type
              ORDER BY mp.quality DESC
              LIMIT game_config_value('page_fusion_count')::int) mp;

        SELECT * INTO born FROM fuse_pages(who, ids);

        IF born.tier <> stack.tier + 1 THEN
            RAISE EXCEPTION 'three tier % pages made a tier % one',
                stack.tier, born.tier;
        END IF;
        IF born.path_code <> stack.path_code OR born.page_type <> stack.page_type THEN
            RAISE EXCEPTION 'the fusion changed what the pages were about';
        END IF;
        IF born.power <= 0 THEN
            RAISE EXCEPTION 'the fused page has no power';
        END IF;

        -- The three are spent, and each one says what it became.
        IF EXISTS (SELECT 1 FROM manual_pages mp
                   WHERE mp.page_id = ANY (ids) AND mp.consumed_at IS NULL) THEN
            RAISE EXCEPTION 'a fused page is still on the shelf';
        END IF;
        IF EXISTS (SELECT 1 FROM manual_pages mp
                   WHERE mp.page_id = ANY (ids)
                     AND mp.fused_into IS DISTINCT FROM born.page_id) THEN
            RAISE EXCEPTION 'a spent page does not say what it became';
        END IF;

        -- And they cannot be spent twice.
        BEGIN
            PERFORM fuse_pages(who, ids);
            RAISE EXCEPTION 'the same three pages fused twice';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
