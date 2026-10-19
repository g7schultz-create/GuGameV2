-- 0061_player_skills
--
-- One place to ask what a cultivator has learned.
--
-- THERE ARE THREE CRAFTS AND TWO TABLES. 0038 built `professions` as sparse
-- rows so a second craft would be an INSERT, and deliberately left manual
-- refinement in `player_refinement` where 0026 put it: folding it in meant
-- rewriting `refine()`, which works, to buy nothing that day.
--
-- That day has arrived, and it still does not buy a rewrite. A screen that
-- listed two of a player's three crafts would be lying by omission, so the
-- seam is closed here instead - in a view, which costs nothing and breaks
-- nothing. `refine()` never learns about this and never has to.
--
-- THE ARITHMETIC LIVES HERE. "How much is left" is
-- `level * exp_per_level - exp`, which follows from every level formula in
-- the game being `1 + floor(exp / per_level)`. Putting it in the view means
-- the screen does no sums, and a profession with a curve instead of a line
-- later changes one place.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- skills
-- ---------------------------------------------------------------------------
-- The catalog, with the odd one out folded in so it can be listed beside the
-- others. A profession nobody has started still appears - a screen that hides
-- what you have not begun cannot tell you what there is to begin.

CREATE VIEW skills AS
SELECT p.code, p.name, p.exp_per_level, p.description, 20 AS sort_order
FROM professions p
UNION ALL
SELECT 'refinement', 'Refiner',
       game_config_value('refinement_exp_per_level'),
       'Combines manual pages into a manual. Level decides how many pages fit in one refinement.',
       10;

COMMENT ON VIEW skills IS
    'Every craft, including the one that predates the professions table. The seam is closed here rather than by moving a working system.';


-- ---------------------------------------------------------------------------
-- player_skills
-- ---------------------------------------------------------------------------

CREATE VIEW player_skills AS
SELECT
    pp.player_id,
    p.code            AS skill,
    p.name,
    p.exp_per_level,
    pp.exp,
    pp.level,
    pp.successes,
    pp.failures,
    (pp.level * p.exp_per_level - pp.exp)::bigint       AS to_next,
    (pp.exp - (pp.level - 1) * p.exp_per_level)::bigint AS into_level,
    -- What this level is currently worth. A CASE rather than a column,
    -- because it is a sentence about the level and not a property of the
    -- craft - and every one of these is a function that already exists.
    CASE p.code
        WHEN 'gu_refining' THEN
            gu_refine_aux_slots(pp.level) || ' auxiliary materials on the bench'
        WHEN 'alchemy' THEN
            alchemy_herb_slots(pp.level) || ' herbs in the cauldron'
        ELSE NULL
    END AS buys
FROM player_professions pp
JOIN professions p ON p.code = pp.profession

UNION ALL

SELECT
    pr.player_id,
    'refinement',
    'Refiner',
    per.v,
    pr.exp,
    pr.level,
    pr.refined,
    pr.failures,
    (pr.level * per.v - pr.exp)::bigint,
    (pr.exp - (pr.level - 1) * per.v)::bigint,
    refinement_max_pages(pr.level) || ' pages in one refinement'
FROM player_refinement pr
CROSS JOIN LATERAL (SELECT game_config_value('refinement_exp_per_level') AS v) per;

COMMENT ON VIEW player_skills IS
    'What a cultivator has learned, across both tables that hold it, with the distance to the next level already worked out.';
