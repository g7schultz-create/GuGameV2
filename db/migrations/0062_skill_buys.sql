-- 0062_skill_buys
--
-- "What does this level get me" has to be answerable for a level you have not
-- reached, and for a craft you have never touched.
--
-- 0061 put that sentence in a CASE inside `player_skills`, which only has rows
-- for crafts a player has actually begun - so the one line a beginner most
-- needs, the one telling them what the Alchemist profession is even for, came
-- back NULL for everybody who had not already brewed something.
--
-- It is a function now. The view calls it, the screen calls it for the crafts
-- with no row yet, and it is written once rather than once per caller - which
-- is the whole reason it was wrong the first time.
--
-- Forward-only. Do not edit once applied.

CREATE FUNCTION skill_buys(p_skill TEXT, p_level SMALLINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE p_skill
        WHEN 'gu_refining' THEN
            gu_refine_aux_slots(p_level) || ' auxiliary materials on the bench'
        WHEN 'alchemy' THEN
            alchemy_herb_slots(p_level) || ' herbs in the cauldron'
        WHEN 'refinement' THEN
            refinement_max_pages(p_level) || ' pages in one refinement'
    END;
$$;

COMMENT ON FUNCTION skill_buys(TEXT, SMALLINT) IS
    'What a level of a craft is currently worth, askable for a level nobody has reached yet.';

CREATE OR REPLACE VIEW player_skills AS
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
    skill_buys(p.code, pp.level)                        AS buys
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
    skill_buys('refinement', pr.level)
FROM player_refinement pr
CROSS JOIN LATERAL (SELECT game_config_value('refinement_exp_per_level') AS v) per;
