-- 0173_the_shelf_offers_the_reading_too
--
-- 0172 added `study_manual`, and the gates it enforces - realm rank, the
-- attainment `technique_required_tier` asks, the stones - are exactly the
-- gates `technique_shelf` already computes for `/learn`. Writing them a
-- second time in a screen is how two places end up disagreeing about whether
-- somebody may read a book.
--
-- So the shelf answers the new question as well as the old one. Three columns
-- on the end, so nothing already reading it shifts:
--
--   manual_id    which copy would be spent
--   study_cost   what the reading costs, 0 for a basic move
--   study_ready  advanced, unknown, you hold the book, and all three gates open
--
-- `ready` still means "/learn will take it", which is never true of an
-- advanced move. `study_ready` means "/study will".
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION technique_shelf(BIGINT);

CREATE OR REPLACE FUNCTION public.technique_shelf(p_player_id bigint)
 RETURNS TABLE(technique_id bigint, code text, name text, tech_rank smallint, grade text, category text, base_power integer, typing text, path_code text, path_name text, need_tier smallint, need_tier_name text, have_tier smallint, stone_cost bigint, stones_held bigint, manual_name text, manual_held boolean, known boolean, on_loan boolean, realm_ok boolean, tier_ok boolean, stones_ok boolean, ready boolean, manual_id bigint, study_cost bigint, study_ready boolean)
 LANGUAGE sql
 STABLE
AS $function$
    WITH me AS (
        SELECT
            COALESCE((SELECT r.rank FROM player_cultivation pc
                      JOIN realms r ON r.realm_id = pc.realm_id
                      WHERE pc.player_id = p_player_id), 0)::smallint AS realm_rank,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = 'spirit_stone'), 0)::bigint AS stones
    )
    SELECT
        t.technique_id,
        t.code,
        t.name,
        t.rank,
        t.grade,
        t.category,
        t.base_power,
        typed.typing,
        dom.path_code,
        dom.path_name,
        technique_required_tier(t.rank),
        tiers.name,
        dom.have_tier,
        -- An advanced technique has no price, and 0 is how the screen knows
        -- not to quote one. It is never bought at any figure.
        CASE WHEN t.grade = 'advanced' THEN 0::bigint
             ELSE technique_stone_cost(t.rank) END,
        me.stones,
        book.manual_name,
        book.held,
        mine.player_id IS NOT NULL,
        mine.player_id IS NULL AND loan.technique_id IS NOT NULL,
        t.rank <= me.realm_rank,
        dom.have_tier >= technique_required_tier(t.rank),
        t.grade = 'advanced' OR me.stones >= technique_stone_cost(t.rank),
        -- Ready means /learn will take it. An advanced technique never is.
        t.grade = 'basic'
            AND mine.player_id IS NULL
            AND t.rank <= me.realm_rank
            AND dom.have_tier >= technique_required_tier(t.rank)
            AND me.stones >= technique_stone_cost(t.rank),
        book.manual_id,
        -- 0172. Studying is the other way to hold an advanced move: the book
        -- is spent and the slot comes back. It asks the same attainment
        -- `/learn` asks of a basic move at that rank, which wearing the book
        -- does not - so both ways of carrying a technique stay worth
        -- something.
        CASE WHEN t.grade = 'advanced'
             THEN technique_stone_cost(t.rank) ELSE 0::bigint END,
        t.grade = 'advanced'
            AND mine.player_id IS NULL
            AND book.held
            AND t.rank <= me.realm_rank
            AND dom.have_tier >= technique_required_tier(t.rank)
            AND me.stones >= technique_stone_cost(t.rank)
    FROM techniques t
    CROSS JOIN me
    JOIN attainment_tiers tiers ON tiers.tier = technique_required_tier(t.rank)
    LEFT JOIN player_techniques mine
           ON mine.player_id = p_player_id AND mine.technique_id = t.technique_id
    LEFT JOIN LATERAL (
        SELECT DISTINCT u.technique_id
        FROM player_usable_techniques u
        WHERE u.player_id = p_player_id AND u.technique_id = t.technique_id
    ) loan ON TRUE
    LEFT JOIN LATERAL (
        SELECT m.manual_id, m.name AS manual_name,
               EXISTS (SELECT 1 FROM player_manuals pm
                       WHERE pm.player_id = p_player_id
                         AND pm.manual_id = m.manual_id) AS held
        FROM manual_techniques mtq
        JOIN manuals m ON m.manual_id = mtq.manual_id
        WHERE mtq.technique_id = t.technique_id
          AND m.archetype = 'technique'
        ORDER BY EXISTS (SELECT 1 FROM player_manuals pm
                         WHERE pm.player_id = p_player_id
                           AND pm.manual_id = m.manual_id) DESC,
                 m.manual_id
        LIMIT 1
    ) book ON TRUE
    LEFT JOIN LATERAL (
        SELECT tp.path_code,
               p.name AS path_name,
               COALESCE(ppa.tier, 0)::smallint AS have_tier
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        LEFT JOIN player_path_attainment ppa
               ON ppa.player_id = p_player_id AND ppa.path_code = tp.path_code
        WHERE tp.technique_id = t.technique_id
        ORDER BY tp.weight DESC, COALESCE(ppa.tier, 0) DESC, p.sort_order
        LIMIT 1
    ) dom ON TRUE
    LEFT JOIN LATERAL (
        SELECT string_agg(p.name, ' + ' ORDER BY tp.weight DESC, p.sort_order)
                   AS typing
        FROM technique_paths tp
        JOIN paths p ON p.code = tp.path_code
        WHERE tp.technique_id = t.technique_id
    ) typed ON TRUE
    WHERE t.created_by IS NULL
    ORDER BY t.rank, t.grade DESC, t.base_power DESC, t.name;
$function$;
