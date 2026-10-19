-- 0107_a_craft_says_how_far_it_has_left
--
-- 0106 made the climbs two to three times longer. A long climb that does not
-- say how long is worse than a short one: a Miner at level 30 can see "veins
-- down to tier 5" and has no way to learn whether the next tier is one level
-- away or thirty-six, or whether there is a next tier at all.
--
-- That was survivable when a ladder finished at 24 and everybody blew past it
-- in an afternoon. It is not survivable now, and two cultivators sitting at
-- mining 103 and foraging 93 are the evidence: nothing ever told them they
-- had finished.
--
-- Which ladder belongs to which craft is a table rather than a CASE, because
-- Blacksmith has two of them - depth and anvil width - and the next thing
-- that changes for a Blacksmith is whichever of the two comes first.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE skill_ladders (
    skill  TEXT NOT NULL,
    ladder TEXT NOT NULL,
    PRIMARY KEY (skill, ladder)
);

COMMENT ON TABLE skill_ladders IS
    'Which rungs belong to which craft. A craft may have more than one ladder, and then the next rung is the nearest of them.';

INSERT INTO skill_ladders (skill, ladder) VALUES
    ('mining',        'mining_tier'),
    ('foraging',      'forage_draws'),
    ('alchemy',       'alchemy_herbs'),
    ('blacksmithing', 'forge_tier'),
    ('blacksmithing', 'forge_parts'),
    ('gu_refining',   'gu_refine_aux'),
    ('refinement',    'refinement_pages');


CREATE FUNCTION skill_next_step(p_skill TEXT, p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        -- Explorer has no rungs: its fortune rises every single level until
        -- the cap, so the next level is always the next step - right up to
        -- the one where it stops.
        WHEN p_skill = 'exploring' THEN
            CASE WHEN p_level < ceil(game_config_value('explore_fortune_cap')
                                     / game_config_value('explore_fortune_per_level'))
                 THEN (p_level + 1)::smallint
                 ELSE NULL
            END
        ELSE (
            SELECT min(ladder_next_at(sl.ladder, p_level))
            FROM skill_ladders sl WHERE sl.skill = p_skill
        )
    END;
$$;

COMMENT ON FUNCTION skill_next_step(TEXT, SMALLINT) IS
    'The next level at which anything about this craft changes, or NULL when it is finished. What a screen needs to stop a long climb feeling like an empty one.';
