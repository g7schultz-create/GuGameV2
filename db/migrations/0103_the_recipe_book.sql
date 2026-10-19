-- 0103_the_recipe_book
--
-- /refinegu's picker was a `LIMIT 25` over every recipe at or below the
-- player's level, which is two problems wearing one coat.
--
-- The first is that Discord allows 25 options in a select and there are 35
-- recipes, so ten of them were simply not on the screen - and the ones cut
-- were the ones sorted last, with no way to reach them and nothing saying
-- they existed.
--
-- The second is that a recipe above your level was invisible rather than
-- locked. "What do I need to be able to make?" is the question a crafting
-- screen exists to answer, and the old one answered it with silence.
--
-- So the book is a function, returning EVERY recipe from one cultivator's
-- side, with the reason each one is out of reach written down. One source
-- feeds the picker, the autocomplete and the bench, because three screens
-- computing "can I make this" three ways is three chances to disagree - and
-- the player reads the disagreement as the game lying.
--
-- THE BLOCKER IS TEXT, DELIBERATELY. It is one phrase, built where the
-- quantities already are. The alternative was three booleans and a shortfall
-- number in each caller, reassembled into a sentence in Python, twice.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION gu_recipe_book(p_player_id BIGINT)
RETURNS TABLE (
    gu_type_id     BIGINT,
    gu_code        TEXT,
    gu_name        TEXT,
    emoji          TEXT,
    rank           SMALLINT,
    rarity         TEXT,
    path_code      TEXT,
    path_name      TEXT,
    path_emoji     TEXT,
    size           SMALLINT,
    required_level SMALLINT,
    base_name      TEXT,
    base_quantity  INTEGER,
    base_held      BIGINT,
    secondary_name TEXT,
    secondary_quantity INTEGER,
    secondary_held BIGINT,
    level_ok       BOOLEAN,
    have_materials BOOLEAN,
    ready          BOOLEAN,
    blocker        TEXT
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
               profession_level(p_player_id, 'gu_refining') AS level
        FROM gu_recipe_costs c
        JOIN paths p ON p.code = c.path_code
        LEFT JOIN player_materials bm
               ON bm.player_id = p_player_id AND bm.material_code = c.base_material
        LEFT JOIN player_materials sm
               ON sm.player_id = p_player_id AND sm.material_code = c.secondary_material
    ),
    judged AS (
        SELECT s.*,
               s.level >= s.required_level AS level_ok,
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
            WHEN NOT j.level_ok
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
        END
    FROM judged j
    -- What you can start, then what only wants a trip out, then what wants a
    -- level. Within each, the cheap ones first: a book is read from the front.
    ORDER BY (j.level_ok AND j.have_materials) DESC, j.level_ok DESC,
             j.required_level, j.rank, j.gu_name;
$$;

COMMENT ON FUNCTION gu_recipe_book(BIGINT) IS
    'Every Gu recipe from one cultivator''s side: what it costs, what they hold, and in one phrase what is standing in the way. The picker, the autocomplete and the bench all read this.';
