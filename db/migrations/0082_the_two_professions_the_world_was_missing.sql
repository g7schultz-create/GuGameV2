-- 0082_the_two_professions_the_world_was_missing
--
-- Mining levels. Gathering and exploring did not.
--
-- Three of the five world actions now teach something - a swing at a vein
-- raises Miner, a cauldron raises Alchemist, an anvil raises Blacksmith - and
-- the two oldest actions in the game taught nothing at all. A player who has
-- foraged four hundred times is no better at foraging than one who has never
-- bent down.
--
-- WHAT A LEVEL BUYS, because a profession that only counts is a counter:
--
--   Forager  - DRAWS. A forage samples the region's table once at level 1 and
--              up to three times later, keeping the RAREST of what it turned
--              up. Skill buys chances rather than tilted weights, which is the
--              same shape 0077 gave the refinement roll and legible for the
--              same reason: "I look twice" is a sentence. Plus a yield bonus
--              on the same additive stack Gu and manuals already feed.
--
--   Explorer - FEWER EMPTY WALKS. `explore_outcomes` has a 'nothing' row at
--              weight 18, and an Explorer's fortune scales that weight DOWN.
--              The other three outcomes renormalise into the space, so the
--              skill is worth exactly what it removes.
--
-- AND `resource_find` STOPS BEING A LIE. 0036 shipped it flagged is_live
-- FALSE - "Better finds while exploring. Nothing reads it yet." Nothing has
-- read it for forty-six migrations. `explore()` reads it now, on the same term
-- as the Explorer's own level, so a Gu or a body or a helm granting Fortune
-- finally does the thing its description claims.
--
-- BOTH FUNCTIONS GROW A RETURN COLUMN, so both are a DROP and a CREATE. They
-- report the EXP they granted rather than granting it quietly, which is the
-- rule 0045, 0058, 0072 and 0076 each arrived at separately.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The professions
-- ---------------------------------------------------------------------------

INSERT INTO professions (code, name, exp_per_level, description) VALUES
    ('foraging', 'Forager', 100,
     'Works over what grows in a region. Level decides how many candidates a forage looks at before choosing the best of them.'),
    ('exploring', 'Explorer', 110,
     'Walks a region for what was left behind. Level decides how often a search comes back empty.');

INSERT INTO game_config (key, value, description) VALUES
    ('forage_base_draws', 1,
     'Candidates a novice Forager looks at before taking the best.'),
    ('forage_levels_per_draw', 8,
     'Forager levels per additional candidate.'),
    ('forage_max_draws', 3,
     'Most candidates one forage considers, however high the level.'),
    ('foraging_yield_per_level', 0.015,
     'PLACEHOLDER - extra yield per Forager level, on the same additive stack everything else uses.'),
    ('foraging_exp_per_grade', 8,
     'PLACEHOLDER - Forager EXP per rarity grade of what was picked.'),
    ('explore_fortune_per_level', 0.02,
     'How much of the empty-handed outcome one Explorer level removes.'),
    ('explore_fortune_cap', 0.75,
     'Most of the empty-handed outcome that skill and Fortune together may remove.'),
    ('exploring_exp_per_grade', 12,
     'PLACEHOLDER - Explorer EXP per rarity grade of what a search turned up.'),
    ('exploring_exp_empty', 6,
     'PLACEHOLDER - Explorer EXP for a walk that found nothing. The ground still taught something.');

CREATE FUNCTION forage_draws(p_level SMALLINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, LEAST(
        game_config_value('forage_max_draws'),
        game_config_value('forage_base_draws')
        + floor(p_level / game_config_value('forage_levels_per_draw'))
    ))::integer;
$$;

COMMENT ON FUNCTION forage_draws(SMALLINT) IS
    'Candidates a forage of this level looks at before keeping the rarest. Askable for a level nobody has reached.';

CREATE FUNCTION explore_fortune(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('explore_fortune_cap'),
        profession_level(p_player_id, 'exploring')
            * game_config_value('explore_fortune_per_level')
        + player_stat(p_player_id, 'resource_find')
    );
$$;

COMMENT ON FUNCTION explore_fortune(BIGINT) IS
    'How much of the empty-handed outcome this cultivator removes, from skill and from anything granting Fortune.';


-- ---------------------------------------------------------------------------
-- Fortune is real now
-- ---------------------------------------------------------------------------

UPDATE gu_effects
SET is_live     = TRUE,
    description = 'Fewer empty-handed searches. Read by exploring, alongside the Explorer''s own level.',
    step        = 0.0250
WHERE code = 'resource_find';


-- ---------------------------------------------------------------------------
-- gather
-- ---------------------------------------------------------------------------

DROP FUNCTION gather(BIGINT);

CREATE FUNCTION gather(p_player_id BIGINT)
RETURNS TABLE (
    material_code TEXT,
    material_name TEXT,
    rarity        TEXT,
    quantity      BIGINT,
    held          BIGINT,
    draws         INTEGER,
    exp_gained    BIGINT,
    level_after   SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    skill   SMALLINT;
    looks   INTEGER;
    picked  TEXT;
    lo      NUMERIC := game_config_value('gather_yield_min');
    hi      NUMERIC := game_config_value('gather_yield_max');
    bonus   NUMERIC := 0;
    amount  BIGINT;
    total   BIGINT;
    gained  BIGINT;
    lvl     SMALLINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    skill := profession_level(p_player_id, 'foraging');
    looks := forage_draws(skill);

    -- Each draw is a ROW rather than a re-evaluated subquery: an uncorrelated
    -- LATERAL is evaluated once however many times it is joined, which is
    -- exactly the bug 0080 had to undo in the manual quality roll.
    SELECT best.material_code INTO picked
    FROM (
        SELECT DISTINCT ON (d.draw) d.draw, rm.material_code, r.sort_order
        FROM generate_series(1, looks) AS d (draw)
        CROSS JOIN region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN rarities r  ON r.code = m.rarity
        WHERE rm.region_code = here
        ORDER BY d.draw, -ln(random()) / rm.weight
    ) AS best
    ORDER BY best.sort_order DESC
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'nothing grows in %', here USING ERRCODE = 'check_violation';
    END IF;

    SELECT b.gathering_bonus INTO bonus
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1)))
        * (1 + COALESCE(bonus, 0)
             + player_stat(p_player_id, 'gathering_yield')
             + skill * game_config_value('foraging_yield_per_level'))
    ));
    total := grant_material(p_player_id, picked, amount);

    gained := GREATEST(5, round(
        material_grade((SELECT m.rarity FROM materials m WHERE m.code = picked))
        * game_config_value('foraging_exp_per_grade')
    ));
    lvl := grant_profession_exp(p_player_id, 'foraging', gained, TRUE);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, amount, total, looks, gained, lvl
    FROM materials m WHERE m.code = picked;
END;
$$;

COMMENT ON FUNCTION gather(BIGINT) IS
    'One forage. A Forager looks at several candidates and keeps the rarest, which is what the levels buy.';


-- ---------------------------------------------------------------------------
-- explore
-- ---------------------------------------------------------------------------

DROP FUNCTION explore(BIGINT);

CREATE FUNCTION explore(p_player_id BIGINT)
RETURNS TABLE (
    outcome       TEXT,
    outcome_name  TEXT,
    material_code TEXT,
    material_name TEXT,
    rarity        TEXT,
    quantity      BIGINT,
    held          BIGINT,
    fortune       NUMERIC,
    exp_gained    BIGINT,
    level_after   SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    luck    NUMERIC;
    pick    TEXT;
    mat     TEXT;
    amount  BIGINT;
    total   BIGINT;
    gained  BIGINT;
    lvl     SMALLINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    luck := GREATEST(0, explore_fortune(p_player_id));

    -- The empty-handed row is the only one skill touches, and the other three
    -- renormalise into the space it leaves - so an Explorer's level is worth
    -- exactly the nothing it removes and not a point more.
    SELECT o.code INTO pick
    FROM explore_outcomes o
    WHERE o.weight > 0
    ORDER BY -ln(random())
             / (o.weight * CASE WHEN o.code = 'nothing' THEN (1 - luck) ELSE 1 END)
    LIMIT 1;

    IF pick = 'spirit_stones' THEN
        mat    := 'spirit_stone';
        amount := game_config_value('explore_spirit_stone_min')
                  + floor(random() * (game_config_value('explore_spirit_stone_max')
                                      - game_config_value('explore_spirit_stone_min') + 1));

    ELSIF pick = 'gathering' THEN
        SELECT rm.material_code INTO mat
        FROM region_materials rm
        WHERE rm.region_code = here
        ORDER BY -ln(random()) / rm.weight
        LIMIT 1;
        amount := 1 + floor(random() * 2);

    ELSIF pick = 'beast' THEN
        -- Whatever the local wildlife is made of, taken off something already
        -- dead rather than something you killed.
        SELECT cd.material_code INTO mat
        FROM creature_regions cr
        JOIN creature_drops cd ON cd.species_id = cr.species_id
        WHERE cr.region_code = here
        ORDER BY random()
        LIMIT 1;
        amount := 1 + floor(random() * 2);
    END IF;

    IF mat IS NULL THEN
        gained := game_config_value('exploring_exp_empty');
        lvl := grant_profession_exp(p_player_id, 'exploring', gained, FALSE);
        RETURN QUERY SELECT 'nothing'::text,
                            (SELECT o.name FROM explore_outcomes o WHERE o.code = 'nothing'),
                            NULL::text, NULL::text, NULL::text, 0::bigint, 0::bigint,
                            luck, gained, lvl;
        RETURN;
    END IF;

    total := grant_material(p_player_id, mat, amount);

    gained := GREATEST(game_config_value('exploring_exp_empty'), round(
        material_grade((SELECT m.rarity FROM materials m WHERE m.code = mat))
        * game_config_value('exploring_exp_per_grade')
    ));
    lvl := grant_profession_exp(p_player_id, 'exploring', gained, TRUE);

    RETURN QUERY
    SELECT pick,
           (SELECT o.name FROM explore_outcomes o WHERE o.code = pick),
           m.code, m.name, m.rarity, amount, total, luck, gained, lvl
    FROM materials m WHERE m.code = mat;
END;
$$;

COMMENT ON FUNCTION explore(BIGINT) IS
    'One search. An Explorer''s level and anything granting Fortune come off the empty-handed outcome and nothing else.';


-- ---------------------------------------------------------------------------
-- skill_buys, with five crafts and two trades in it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION skill_buys(p_skill TEXT, p_level SMALLINT)
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
        WHEN 'mining' THEN
            'veins down to tier ' || mining_tier_cap(p_level)
        WHEN 'blacksmithing' THEN
            'tier ' || smith_tier_cap(p_level) || ' pieces, '
            || smith_part_slots(p_level)
            || CASE WHEN smith_part_slots(p_level) = 1
                    THEN ' beast material' ELSE ' beast materials' END
            || ' on the anvil'
        WHEN 'foraging' THEN
            forage_draws(p_level)
            || CASE WHEN forage_draws(p_level) = 1
                    THEN ' look at the ground, ' ELSE ' looks at the ground, ' END
            || 'the rarest kept'
        WHEN 'exploring' THEN
            round(LEAST(game_config_value('explore_fortune_cap'),
                        p_level * game_config_value('explore_fortune_per_level')) * 100)
            || '% fewer empty searches'
    END;
$$;
