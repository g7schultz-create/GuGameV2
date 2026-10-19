-- 0212_a_book_you_can_actually_leaf_through
--
-- `gu_recipe_book` was written against 35 recipes. It now answers with 2,869,
-- and the screen it feeds pages 25 at a time - so "Every recipe" is 115 pages
-- of names with no way to say which stretch of the ladder you are shopping on.
--
-- The rank is the axis that was missing, and it belongs on the screen rather
-- than in this function: filtering is the caller's job and the rows are all
-- here already.
--
-- WHAT IS MISSING FROM THE ROWS is what the Gu would actually DO. The book has
-- always said what a recipe costs and what is in the way, and never said what
-- you get - which is the one thing that decides whether the price is worth
-- paying. You had to open a recipe to find out, and with 2,869 of them that is
-- not a browse, it is a lottery.
--
-- So the book gains an `effects` column: the same words `/gu` and `/gupedia`
-- use, compact enough to sit on the end of a line, biggest first. One place
-- computes it, and the bench screen keeps its own longer form.
--
-- A returned column cannot be added in place, so the function is dropped and
-- recreated. Nothing else reads it.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION gu_recipe_book(BIGINT);

CREATE FUNCTION gu_recipe_book(p_player_id BIGINT)
RETURNS TABLE (
    gu_type_id BIGINT, gu_code TEXT, gu_name TEXT, emoji TEXT, rank SMALLINT,
    rarity TEXT, path_code TEXT, path_name TEXT, path_emoji TEXT, size SMALLINT,
    required_level SMALLINT, base_name TEXT, base_quantity INTEGER,
    base_held BIGINT, secondary_name TEXT, secondary_quantity INTEGER,
    secondary_held BIGINT, level_ok BOOLEAN, have_materials BOOLEAN,
    ready BOOLEAN, blocker TEXT, effects TEXT
)
LANGUAGE sql STABLE
AS $$
    WITH standing AS (
        SELECT c.*,
               p.name AS path_name, p.emoji AS path_emoji,
               material_name(c.base_material) AS base_name,
               material_name(c.secondary_material) AS secondary_name,
               COALESCE(bm.quantity, 0) AS base_held,
               COALESCE(sm.quantity, 0) AS secondary_held,
               profession_level(p_player_id, 'gu_refining') AS level,
               game_config_value('gu_max_refinable_rank') AS ceiling,
               -- Emoji and per cent only. A line in a list has room for what
               -- it does, not for what it is called; the bench screen spells
               -- the names out when you open one.
               (SELECT string_agg(ef.emoji || ' ' || round(100 * te.magnitude) || '%',
                                  ' + ' ORDER BY te.magnitude DESC)
                FROM gu_type_effects te
                JOIN gu_effects ef ON ef.code = te.effect_code
                WHERE te.gu_type_id = c.gu_type_id) AS effects
        FROM gu_recipe_costs c
        JOIN paths p ON p.code = c.path_code
        LEFT JOIN player_materials bm
               ON bm.player_id = p_player_id AND bm.material_code = c.base_material
        LEFT JOIN player_materials sm
               ON sm.player_id = p_player_id AND sm.material_code = c.secondary_material
    ),
    judged AS (
        SELECT s.*,
               -- "The bench will take this", which is the world and the
               -- refiner together. The screen draws three states off this and
               -- they have to be the three states that are real.
               (s.level >= s.required_level AND s.rank <= s.ceiling) AS level_ok,
               (s.base_held >= s.base_quantity
                AND s.secondary_held >= s.secondary_quantity) AS have_materials
        FROM standing s
    )
    SELECT
        j.gu_type_id, j.gu_code, j.gu_name, j.emoji, j.rank, j.rarity,
        j.path_code, j.path_name, j.path_emoji, j.size, j.required_level,
        j.base_name, j.base_quantity, j.base_held,
        j.secondary_name, j.secondary_quantity, j.secondary_held,
        j.level_ok, j.have_materials,
        (j.level_ok AND j.have_materials),
        CASE
            -- The shut door before the personal one, for the same reason
            -- refine_gu checks them in that order.
            WHEN j.rank > j.ceiling
                THEN 'rank ' || j.rank || ', and the bench stops at rank '
                     || j.ceiling
            WHEN j.level < j.required_level
                THEN 'Gu Refiner level ' || j.required_level
            WHEN j.have_materials THEN NULL
            -- The larger shortfall first: it is the one that decides whether
            -- the trip out is worth making.
            ELSE (
                SELECT string_agg(short, ', ' ORDER BY missing DESC)
                FROM (
                    SELECT j.base_quantity - j.base_held AS missing,
                           (j.base_quantity - j.base_held) || ' more '
                           || j.base_name AS short
                    WHERE j.base_held < j.base_quantity
                    UNION ALL
                    SELECT j.secondary_quantity - j.secondary_held,
                           (j.secondary_quantity - j.secondary_held) || ' more '
                           || j.secondary_name
                    WHERE j.secondary_held < j.secondary_quantity
                ) shortfall
            )
        END,
        j.effects
    FROM judged j
    -- What you can start, then what only wants a trip out, then what wants a
    -- level. Within each, the cheap ones first: a book is read from the front.
    ORDER BY (j.level_ok AND j.have_materials) DESC, j.level_ok DESC,
             j.required_level, j.rank, j.gu_name;
$$;


DO $$
DECLARE
    who BIGINT;
    n   BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody to read the book; the tests carry it';
        RETURN;
    END IF;

    -- Every recipe says what it makes. 0209 gave every Gu an effect and a
    -- test holds that; this is the same rule seen from the screen's side,
    -- where a blank would read as "this Gu does nothing".
    SELECT count(*) INTO n FROM gu_recipe_book(who) b
    WHERE b.effects IS NULL OR b.effects = '';
    IF n > 0 THEN
        RAISE EXCEPTION '% recipes would be drawn as making nothing', n;
    END IF;

    -- And the book still covers the whole catalogue, which is what makes the
    -- rank filter on the screen worth having.
    SELECT count(*) INTO n FROM gu_recipe_book(who);
    IF n <> (SELECT count(*) FROM gu_types) THEN
        RAISE EXCEPTION 'the book lists % of % Gu', n, (SELECT count(*) FROM gu_types);
    END IF;

    IF (SELECT count(DISTINCT b.rank) FROM gu_recipe_book(who) b) <> 9 THEN
        RAISE EXCEPTION 'the book does not reach every rank';
    END IF;
END;
$$;
