-- 0027_refine_fixes
--
-- Two defects in 0026's `refine`, both caught the first time it was called.
--
-- 1. `tier` is one of the function's OUT parameters AND a column of the temp
--    table it aggregates, so `max(tier) - min(tier)` was ambiguous and the
--    whole function raised. Same class of mistake as the `battle_id` shadow in
--    0017's hunt(): a RETURNS TABLE column silently competes with every table
--    the body touches. Aliased and qualified.
--
-- 2. The temp table is ON COMMIT DROP, which does not help two refinements in
--    the SAME transaction - the second found `_pages` already there. Dropped
--    explicitly first.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION refine(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE (
    succeeded   BOOLEAN,
    harmony     SMALLINT,
    manual_id   BIGINT,
    manual_name TEXT,
    tier        SMALLINT,
    archetype   TEXT,
    retained    NUMERIC,
    exp_gained  BIGINT,
    level_after SMALLINT,
    destroyed   INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill        SMALLINT;
    cap          SMALLINT;
    n            INTEGER;
    h            NUMERIC := 50;
    pair         RECORD;
    dominant     TEXT;
    dom_count    INTEGER;
    distinct_n   INTEGER;
    type_n       INTEGER;
    spread       INTEGER;
    avg_quality  NUMERIC;
    trait_h      INTEGER;
    resonant_n   INTEGER;
    total_power  NUMERIC;
    potential    NUMERIC;
    final_h      SMALLINT;
    keep         NUMERIC;
    new_tier     SMALLINT;
    budget       NUMERIC;
    arch         TEXT;
    lead_type    TEXT;
    new_manual   BIGINT;
    new_name     TEXT;
    gained       BIGINT;
    lvl          SMALLINT;
    killed       INTEGER := 0;
BEGIN
    -- ---- validate -------------------------------------------------------
    SELECT COALESCE(pr.level, 1) INTO skill
    FROM (SELECT 1) _ LEFT JOIN player_refinement pr ON pr.player_id = p_player_id;

    cap := refinement_max_pages(skill);
    n   := COALESCE(array_length(p_page_ids, 1), 0);

    IF n < 2 THEN
        RAISE EXCEPTION 'a refinement needs at least two pages'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n > cap THEN
        RAISE EXCEPTION 'your Refinement skill allows % pages at once, not %', cap, n
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_page_ids) AS want(id)
        WHERE NOT EXISTS (
            SELECT 1 FROM manual_pages mp
            WHERE mp.page_id = want.id
              AND mp.owner_id = p_player_id
              AND mp.consumed_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'those are not all your unused pages'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Dropped first: two refinements in one transaction would otherwise
    -- collide on a table that ON COMMIT DROP has not yet cleaned up.
    DROP TABLE IF EXISTS _pages;
    CREATE TEMP TABLE _pages ON COMMIT DROP AS
    SELECT mp.*, pt.manual_column, tr.harmony_bonus, tr.pairs_with_itself
    FROM manual_pages mp
    JOIN page_types pt ON pt.code = mp.page_type
    LEFT JOIN page_traits tr ON tr.code = mp.trait
    WHERE mp.page_id = ANY (p_page_ids);

    -- ---- harmony ---------------------------------------------------------
    FOR pair IN
        SELECT a.path_code AS pa, b.path_code AS pb
        FROM (SELECT DISTINCT path_code FROM _pages) a
        JOIN (SELECT DISTINCT path_code FROM _pages) b ON a.path_code < b.path_code
    LOOP
        h := h + pair_harmony(pair.pa, pair.pb);
    END LOOP;

    SELECT path_code, count(*) INTO dominant, dom_count
    FROM _pages GROUP BY path_code ORDER BY count(*) DESC, sum(power) DESC LIMIT 1;

    -- Aliased and fully qualified: this function's RETURNS TABLE declares an
    -- OUT parameter called `tier`, which otherwise shadows the column.
    SELECT count(DISTINCT g.path_code), count(DISTINCT g.page_type),
           max(g.tier) - min(g.tier), avg(g.quality),
           COALESCE(sum(g.harmony_bonus), 0),
           count(*) FILTER (WHERE g.pairs_with_itself),
           sum(g.power)
    INTO distinct_n, type_n, spread, avg_quality, trait_h, resonant_n, total_power
    FROM _pages g;

    h := h + 6 * (dom_count - 1);          -- a dominant Path steadies it
    h := h - 5 * (distinct_n - 1);         -- every extra Path is a seam
    h := h + 5 * (n - type_n);             -- pages doing the same job agree
    h := h - 3.5 * spread;                 -- mismatched grades sit badly
    h := h + (avg_quality - 75) * 0.35;
    h := h + skill * 0.75;
    h := h + trait_h;
    IF resonant_n >= 2 THEN
        h := h + 12;                       -- Resonant pages hum together
    END IF;
    h := h + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(140, round(h)))::smallint;

    -- ---- outcome ---------------------------------------------------------
    gained := GREATEST(10, round(total_power * 0.4 + final_h * 0.6));

    IF final_h < game_config_value('refinement_failure_threshold') THEN
        -- Some pages are lost, the rest come back.
        WITH doomed AS (
            SELECT page_id FROM _pages ORDER BY random() LIMIT GREATEST(1, n / 3)
        )
        DELETE FROM manual_pages WHERE page_id IN (SELECT page_id FROM doomed);
        GET DIAGNOSTICS killed = ROW_COUNT;

        lvl := grant_refinement_exp(p_player_id, gained / 3, FALSE);
        RETURN QUERY SELECT FALSE, final_h, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, 0::numeric,
                            gained / 3, lvl, killed;
        RETURN;
    END IF;

    keep := CASE
        WHEN final_h >= 100 THEN 1.30
        WHEN final_h >= 90  THEN 1.17
        WHEN final_h >= 75  THEN 1.02
        WHEN final_h >= 60  THEN 0.875
        WHEN final_h >= 40  THEN 0.70
        ELSE 0.50
    END;

    -- ---- tier ------------------------------------------------------------
    potential := total_power / game_config_value('refinement_potential_divisor');
    SELECT COALESCE(max(mt.tier), 1) INTO new_tier
    FROM manual_tiers mt WHERE mt.bonus_budget * 100 <= potential;

    SELECT mt.bonus_budget INTO budget FROM manual_tiers mt WHERE mt.tier = new_tier;
    budget := budget * keep;

    -- ---- archetype -------------------------------------------------------
    SELECT page_type INTO lead_type
    FROM _pages GROUP BY page_type ORDER BY sum(power) DESC LIMIT 1;

    arch := CASE lead_type
        WHEN 'cultivation'  THEN 'cultivation'
        WHEN 'attack'       THEN 'offensive'
        WHEN 'defense'      THEN 'defensive'
        WHEN 'vitality'     THEN 'body'
        WHEN 'speed'        THEN 'movement'
        WHEN 'breakthrough' THEN 'breakthrough'
        WHEN 'essence'      THEN 'essence'
        WHEN 'gathering'    THEN 'gathering'
        WHEN 'refinement'   THEN 'refinement'
        ELSE 'hybrid'
    END;
    IF type_n >= 3 THEN
        arch := 'hybrid';
    END IF;

    -- ---- the manual ------------------------------------------------------
    new_name := refined_manual_name(dominant, arch, final_h, new_tier);

    INSERT INTO manuals (name, tier, required_rank, archetype,
                         harmony, created_by, refined_at, description)
    VALUES (new_name, new_tier, GREATEST(1, LEAST(9, (new_tier + 1) / 2)), arch,
            final_h, p_player_id, now(),
            'Refined from ' || n || ' pages.')
    RETURNING manuals.manual_id INTO new_manual;

    -- Each page type pays into the column page_types says it feeds, in
    -- proportion to the power it brought.
    PERFORM apply_manual_bonus(new_manual, p.manual_column,
                               budget * p.share)
    FROM (
        SELECT manual_column, sum(power) / total_power AS share
        FROM _pages GROUP BY manual_column
    ) p;

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_manual, path_code, LEAST(1, sum(power) / total_power)
    FROM _pages GROUP BY path_code;

    -- A move it could plausibly teach: something of its dominant Path that a
    -- cultivator of its rank could hold. Often nothing, which is fine - most
    -- refined manuals are cultivation aids, not weapon books.
    INSERT INTO manual_techniques (manual_id, technique_id)
    SELECT new_manual, t.technique_id
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND tp.path_code = dominant
      AND t.rank <= GREATEST(1, LEAST(9, (new_tier + 1) / 2))
      AND arch = 'offensive'
    ORDER BY t.base_power DESC
    LIMIT 1
    ON CONFLICT DO NOTHING;

    UPDATE manual_pages
    SET consumed_by = new_manual, consumed_at = now()
    WHERE page_id = ANY (p_page_ids);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, new_manual);

    lvl := grant_refinement_exp(p_player_id, gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, new_manual, new_name, new_tier, arch,
                        keep, gained, lvl, 0;
END;
$$;
