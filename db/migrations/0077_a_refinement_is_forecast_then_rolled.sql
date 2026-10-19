-- 0077_a_refinement_is_forecast_then_rolled
--
-- Look before you burn six pages, and one last roll at the end.
--
-- THE FORECAST IS THE SAME CODE AS THE REFINEMENT. A preview computed by a
-- second function is a second opinion, and this schema has spent four
-- migrations on screens that disagreed with what actually happened (0045,
-- 0058, 0072 and the /cultivation rate that forgot the Gu bonus). So the
-- deterministic half of `refine()` is lifted out into `refine_forecast()`, and
-- `refine()` CALLS IT. There is one implementation of what pages are worth;
-- the screen and the outcome cannot drift apart because there is nothing to
-- drift from.
--
-- AND THE FORECAST STOPS BEFORE THE ROLL. Everything up to `random()` is
-- knowable - the tier the pages buy, the archetype, which Paths are fighting,
-- the harmony before the last eight points of luck. Showing the RESULT and
-- then offering to accept it would be a free reroll: decline, refine again,
-- keep the good one. So the confirmation shows a range and a shape, and the
-- dice are thrown after the player commits.
--
-- ONE MORE ROLL, AND HARMONY BUYS THE DRAWS. A finished manual now lands in a
-- band on the rarity ladder, and the band multiplies what it is worth - up to
-- 2.2x at Extreme. The roll is not free of skill: harmony buys DRAWS rather
-- than shifting weights, so a refinement at 125 takes four draws at the ladder
-- and keeps the best of them. That is legible in a way that a tilted weight is
-- not - "three chances instead of one" is a sentence a player can hold - and
-- it cannot be tuned into a certainty.
--
-- UNIQUE IS NOT IN THE LADDER HERE. `rarities` carries it between Divine and
-- Extreme for roots and physiques; a manual is a thing that can be made twice,
-- so the band that means "there is one" does not apply. It is left out of
-- `manual_qualities` rather than given a zero weight, because a band with no
-- members never comes up and says so, which 0011 settled.
--
-- THE TEMP TABLE IS GONE. `refine()` built `_pages ON COMMIT DROP` and then
-- had to `DROP TABLE IF EXISTS` it first, because a second refinement in one
-- transaction collided with the first. 0039 removed exactly this hazard from
-- `refine_gu` and left it here. The forecast is set-based, so there is nothing
-- to collide with.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- manual_qualities
-- ---------------------------------------------------------------------------

CREATE TABLE manual_qualities (
    rarity            TEXT PRIMARY KEY REFERENCES rarities (code) ON DELETE RESTRICT,

    -- Relative, not a percentage: a band removed from this table renormalises
    -- the rest away rather than leaving a hole in the odds.
    weight            NUMERIC(8, 4) NOT NULL CHECK (weight > 0),

    -- What the band does to the manual's bonus budget.
    budget_multiplier NUMERIC(4, 2) NOT NULL CHECK (budget_multiplier > 0)
);

INSERT INTO manual_qualities (rarity, weight, budget_multiplier) VALUES
    ('common',    45.0, 1.00),
    ('uncommon',  28.0, 1.08),
    ('rare',      15.0, 1.18),
    ('epic',       7.0, 1.32),
    ('legendary',  3.5, 1.50),
    ('mythic',     1.4, 1.70),
    ('divine',     0.5, 1.90),
    ('extreme',    0.1, 2.20);

COMMENT ON TABLE manual_qualities IS
    'The last roll a refinement makes. Weights are relative; the multiplier is what the band is worth on top of harmony.';

INSERT INTO game_config (key, value, description) VALUES
    ('manual_quality_first_draw', 50,
     'Harmony at which a refinement gets its first draw at the quality ladder.'),
    ('manual_quality_per_draw', 25,
     'Further harmony per additional draw. The best draw is the one that counts.'),
    ('manual_quality_max_draws', 5,
     'Most draws one refinement may take, however high the harmony climbs.');

CREATE FUNCTION manual_quality_draws(p_harmony SMALLINT)
RETURNS INTEGER
LANGUAGE sql IMMUTABLE
AS $$
    SELECT GREATEST(1, LEAST(
        game_config_value('manual_quality_max_draws'),
        1 + floor((p_harmony - game_config_value('manual_quality_first_draw'))
                  / game_config_value('manual_quality_per_draw'))
    ))::integer;
$$;

COMMENT ON FUNCTION manual_quality_draws(SMALLINT) IS
    'How many chances at the ladder this harmony buys. Askable before the refinement, which is the point.';

CREATE FUNCTION roll_manual_quality(p_harmony SMALLINT)
RETURNS TEXT
LANGUAGE sql VOLATILE
AS $$
    SELECT drawn.rarity
    FROM generate_series(1, manual_quality_draws(p_harmony)) AS d
    CROSS JOIN LATERAL (
        SELECT mq.rarity, r.sort_order
        FROM manual_qualities mq
        JOIN rarities r ON r.code = mq.rarity
        ORDER BY -ln(random()) / mq.weight
        LIMIT 1
    ) AS drawn
    ORDER BY drawn.sort_order DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION roll_manual_quality(SMALLINT) IS
    'Draws once per chance the harmony bought and keeps the best. Harmony buys draws rather than tilting weights, so it can never become a certainty.';


-- ---------------------------------------------------------------------------
-- A manual remembers which band it landed in
-- ---------------------------------------------------------------------------
-- Defaulted rather than backfilled: every manual refined before this migration
-- was made without the roll, and 'common' is the honest description of a
-- manual that never took one.

ALTER TABLE manuals ADD COLUMN quality TEXT NOT NULL DEFAULT 'common'
    REFERENCES rarities (code) ON DELETE RESTRICT;

CREATE INDEX manuals_quality_idx ON manuals (quality);

COMMENT ON COLUMN manuals.quality IS
    'The band the final roll landed in. Already applied to the stored bonuses - this is the record of why they are what they are.';


-- ---------------------------------------------------------------------------
-- refine_forecast
-- ---------------------------------------------------------------------------
-- Everything about a refinement that is decided before the dice.

CREATE FUNCTION refine_forecast(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE (
    pages          INTEGER,
    total_power    NUMERIC,
    base_harmony   NUMERIC,
    forecast_tier  SMALLINT,
    archetype      TEXT,
    dominant       TEXT,
    distinct_paths INTEGER,
    page_types     INTEGER,
    grade_spread   INTEGER,
    avg_quality    NUMERIC,
    worst_pair     NUMERIC,
    relief_applied NUMERIC
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    skill  SMALLINT;
    relief NUMERIC;
BEGIN
    SELECT COALESCE(pr.level, 1) INTO skill
    FROM (SELECT 1) _ LEFT JOIN player_refinement pr ON pr.player_id = p_player_id;

    -- A body can stand between two Paths that will not stand each other. Only
    -- the CONFLICT is softened: a physique that also inflated agreement would
    -- make every refinement better rather than making hard ones possible.
    relief := LEAST(1, physique_stat(p_player_id, 'refine_conflict_relief'));

    RETURN QUERY
    WITH pg AS (
        SELECT mp.page_id, mp.path_code, mp.page_type, mp.tier AS page_tier,
               mp.power, mp.quality AS page_quality,
               tr.harmony_bonus, tr.pairs_with_itself
        FROM manual_pages mp
        LEFT JOIN page_traits tr ON tr.code = mp.trait
        WHERE mp.page_id = ANY (p_page_ids)
          AND mp.owner_id = p_player_id
          AND mp.consumed_at IS NULL
    ),
    agg AS (
        SELECT count(*)::integer                       AS n,
               count(DISTINCT pg.path_code)::integer   AS distinct_n,
               count(DISTINCT pg.page_type)::integer   AS type_n,
               (max(pg.page_tier) - min(pg.page_tier))::integer AS spread,
               avg(pg.page_quality)                    AS avg_q,
               COALESCE(sum(pg.harmony_bonus), 0)      AS trait_h,
               count(*) FILTER (WHERE pg.pairs_with_itself)::integer AS resonant_n,
               COALESCE(sum(pg.power), 0)              AS total_p
        FROM pg
    ),
    lead_path AS (
        SELECT pg.path_code, count(*)::integer AS dom_count
        FROM pg GROUP BY pg.path_code
        ORDER BY count(*) DESC, sum(pg.power) DESC LIMIT 1
    ),
    lead_type AS (
        SELECT pg.page_type FROM pg GROUP BY pg.page_type
        ORDER BY sum(pg.power) DESC LIMIT 1
    ),
    pairs AS (
        SELECT COALESCE(sum(CASE WHEN pair_harmony(a.p, b.p) < 0
                                 THEN pair_harmony(a.p, b.p) * (1 - relief)
                                 ELSE pair_harmony(a.p, b.p) END), 0) AS pair_sum,
               COALESCE(min(pair_harmony(a.p, b.p)), 0)               AS worst
        FROM (SELECT DISTINCT pg.path_code AS p FROM pg) a
        JOIN (SELECT DISTINCT pg.path_code AS p FROM pg) b ON a.p < b.p
    )
    SELECT
        agg.n,
        agg.total_p,
        -- The same sum 0026 wrote and 0053 added a body to, minus the last
        -- eight points, which are luck and belong to `refine()`.
        50
          + pairs.pair_sum
          + 6   * (lead_path.dom_count - 1)
          - 5   * (agg.distinct_n - 1)
          + 5   * (agg.n - agg.type_n)
          - 3.5 * agg.spread
          + (agg.avg_q - 75) * 0.35
          + skill * 0.75
          + agg.trait_h
          + CASE WHEN agg.resonant_n >= 2 THEN 12 ELSE 0 END,
        COALESCE((SELECT max(mt.tier) FROM manual_tiers mt
                  WHERE mt.bonus_budget * 100
                        <= agg.total_p / game_config_value('refinement_potential_divisor')
                 ), 1)::smallint,
        CASE WHEN agg.type_n >= 3 THEN 'hybrid'
             ELSE CASE lead_type.page_type
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
             END
        END,
        lead_path.path_code,
        agg.distinct_n,
        agg.type_n,
        agg.spread,
        agg.avg_q,
        pairs.worst,
        relief
    FROM agg, lead_path, lead_type, pairs
    WHERE agg.n > 0;
END;
$$;

COMMENT ON FUNCTION refine_forecast(BIGINT, BIGINT[]) IS
    'What a set of pages is worth before the dice. `refine()` calls this, so a preview and an outcome cannot disagree.';


-- ---------------------------------------------------------------------------
-- refine
-- ---------------------------------------------------------------------------
-- The forecast, plus eight points of luck, plus a roll at the ladder.
-- The return type gains a column, so this is a DROP and a CREATE.

DROP FUNCTION refine(BIGINT, BIGINT[]);

CREATE FUNCTION refine(p_player_id BIGINT, p_page_ids BIGINT[])
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

    keep := CASE
        WHEN final_h >= 100 THEN 1.30
        WHEN final_h >= 90  THEN 1.17
        WHEN final_h >= 75  THEN 1.02
        WHEN final_h >= 60  THEN 0.875
        WHEN final_h >= 40  THEN 0.70
        ELSE 0.50
    END;

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

COMMENT ON FUNCTION refine(BIGINT, BIGINT[]) IS
    'Pages to a manual. The forecast decides what they are worth, eight points of luck decide the harmony, and the ladder decides how much of it the manual keeps.';
