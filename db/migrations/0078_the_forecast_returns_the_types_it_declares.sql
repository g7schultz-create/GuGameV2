-- 0078_the_forecast_returns_the_types_it_declares
--
-- `refine_forecast` declares NUMERIC and returned bigint.
--
-- `manual_pages.power`, `.quality`, `.tier`, `page_traits.harmony_bonus` and
-- `pair_harmony()` are every one of them smallint, so `sum()` over them is
-- bigint and `min()` is smallint - neither of which Postgres will quietly
-- widen into a declared NUMERIC output column. The function raised
-- "structure of query does not match function result type" on the first call,
-- which means `refine()` did too, which means refinement was broken outright
-- between 0077 and this.
--
-- Caught by four existing tests within a minute, which is the argument for
-- having had them.
--
-- The casts are explicit rather than achieved by multiplying something by 1.0.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION refine_forecast(p_player_id BIGINT, p_page_ids BIGINT[])
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
               COALESCE(sum(pg.harmony_bonus), 0)::numeric AS trait_h,
               count(*) FILTER (WHERE pg.pairs_with_itself)::integer AS resonant_n,
               COALESCE(sum(pg.power), 0)::numeric     AS total_p
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
                                 ELSE pair_harmony(a.p, b.p) END), 0)::numeric AS pair_sum,
               COALESCE(min(pair_harmony(a.p, b.p)), 0)::numeric      AS worst
        FROM (SELECT DISTINCT pg.path_code AS p FROM pg) a
        JOIN (SELECT DISTINCT pg.path_code AS p FROM pg) b ON a.p < b.p
    )
    SELECT
        agg.n,
        agg.total_p,
        -- The same sum 0026 wrote and 0053 added a body to, minus the last
        -- eight points, which are luck and belong to `refine()`.
        50::numeric
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
