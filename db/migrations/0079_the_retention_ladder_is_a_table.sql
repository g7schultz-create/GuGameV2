-- 0079_the_retention_ladder_is_a_table
--
-- The confirmation screen has to say what harmony is worth, and the answer was
-- a CASE inside `refine()`.
--
-- A screen cannot read a CASE. It could hard-code the same six numbers, and
-- then there would be two ladders that agree until somebody retunes one of
-- them - which is the exact failure 0077 was written to avoid one paragraph
-- higher up, so it would be a strange thing to reintroduce one migration
-- later.
--
-- Rows, then, like `equipment_qualities` and `pill_tiers` before it. The
-- screen reads the ladder, `refine()` reads the ladder, and retuning
-- refinement is an UPDATE rather than a function body.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE refinement_retention (
    min_harmony SMALLINT PRIMARY KEY CHECK (min_harmony >= 0),
    keep        NUMERIC(4, 3) NOT NULL CHECK (keep > 0),
    label       TEXT NOT NULL
);

INSERT INTO refinement_retention (min_harmony, keep, label) VALUES
    (  0, 0.500, 'Chaotic'),
    ( 40, 0.700, 'Stable'),
    ( 60, 0.875, 'Good'),
    ( 75, 1.020, 'Excellent'),
    ( 90, 1.170, 'Perfect Harmony'),
    (100, 1.300, 'Dao Resonance');

COMMENT ON TABLE refinement_retention IS
    'How much of a tier''s budget a harmony keeps, and what that band is called. Above 1.0 on purpose: exceeding the tier budget is the reward for refining well.';

CREATE FUNCTION refinement_keep(p_harmony SMALLINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT rr.keep FROM refinement_retention rr
    WHERE rr.min_harmony <= p_harmony
    ORDER BY rr.min_harmony DESC LIMIT 1;
$$;


-- ---------------------------------------------------------------------------
-- refine, reading the ladder
-- ---------------------------------------------------------------------------

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
    destroyed   INTEGER,
    quality     TEXT,
    draws       INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill      SMALLINT;
    cap        SMALLINT;
    n          INTEGER;
    look       RECORD;
    final_h    SMALLINT;
    keep       NUMERIC;
    band       TEXT;
    lift       NUMERIC;
    n_draws    INTEGER;
    budget     NUMERIC;
    new_manual BIGINT;
    new_name   TEXT;
    gained     BIGINT;
    lvl        SMALLINT;
    killed     INTEGER := 0;
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

    -- ---- what the pages are worth ---------------------------------------
    SELECT * INTO look FROM refine_forecast(p_player_id, p_page_ids);
    IF look IS NULL THEN
        RAISE EXCEPTION 'those pages could not be read'
            USING ERRCODE = 'check_violation';
    END IF;

    final_h := GREATEST(0, LEAST(140, round(look.base_harmony + (random() * 8 - 4))))::smallint;

    gained := GREATEST(10, round(look.total_power * 0.4 + final_h * 0.6));

    -- ---- failure ---------------------------------------------------------
    IF final_h < game_config_value('refinement_failure_threshold') THEN
        WITH doomed AS (
            SELECT mp.page_id FROM manual_pages mp
            WHERE mp.page_id = ANY (p_page_ids)
            ORDER BY random() LIMIT GREATEST(1, n / 3)
        )
        DELETE FROM manual_pages WHERE page_id IN (SELECT page_id FROM doomed);
        GET DIAGNOSTICS killed = ROW_COUNT;

        lvl := grant_refinement_exp(p_player_id, gained / 3, FALSE);
        RETURN QUERY SELECT FALSE, final_h, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, 0::numeric,
                            gained / 3, lvl, killed, NULL::text, 0;
        RETURN;
    END IF;

    keep := refinement_keep(final_h);

    -- ---- the last roll ---------------------------------------------------
    n_draws := manual_quality_draws(final_h);
    band    := roll_manual_quality(final_h);
    SELECT mq.budget_multiplier INTO lift
    FROM manual_qualities mq WHERE mq.rarity = band;

    SELECT mt.bonus_budget INTO budget
    FROM manual_tiers mt WHERE mt.tier = look.forecast_tier;
    budget := budget * keep * lift;

    -- ---- the manual ------------------------------------------------------
    new_name := refined_manual_name(look.dominant, look.archetype, final_h,
                                    look.forecast_tier);

    INSERT INTO manuals (name, tier, required_rank, archetype,
                         harmony, quality, created_by, refined_at, description)
    VALUES (new_name, look.forecast_tier,
            GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2)), look.archetype,
            final_h, band, p_player_id, now(),
            'Refined from ' || n || ' pages.')
    RETURNING manuals.manual_id INTO new_manual;

    -- Each page type pays into the column page_types says it feeds, in
    -- proportion to the power it brought.
    PERFORM apply_manual_bonus(new_manual, share.manual_column,
                               budget * share.part)
    FROM (
        SELECT pt.manual_column, sum(mp.power) / look.total_power AS part
        FROM manual_pages mp
        JOIN page_types pt ON pt.code = mp.page_type
        WHERE mp.page_id = ANY (p_page_ids)
        GROUP BY pt.manual_column
    ) AS share;

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_manual, mp.path_code,
           LEAST(1, sum(mp.power) / look.total_power)
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
    GROUP BY mp.path_code;

    -- A move it could plausibly teach: something of its dominant Path that a
    -- cultivator of its rank could hold. Often nothing, which is fine - most
    -- refined manuals are cultivation aids, not weapon books.
    INSERT INTO manual_techniques (manual_id, technique_id)
    SELECT new_manual, t.technique_id
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND tp.path_code = look.dominant
      AND t.rank <= GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2))
      AND look.archetype = 'offensive'
    ORDER BY t.base_power DESC
    LIMIT 1
    ON CONFLICT DO NOTHING;

    UPDATE manual_pages
    SET consumed_by = new_manual, consumed_at = now()
    WHERE page_id = ANY (p_page_ids);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, new_manual);

    lvl := grant_refinement_exp(p_player_id, gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, new_manual, new_name, look.forecast_tier,
                        look.archetype, keep * lift, gained, lvl, 0, band, n_draws;
END;
$$;
