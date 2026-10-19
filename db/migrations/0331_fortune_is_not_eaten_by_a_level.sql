-- 0331_fortune_is_not_eaten_by_a_level
--
-- `explore_fortune` put an Explorer's level and their Fortune stat into one
-- sum and then clamped the sum:
--
--     LEAST(explore_fortune_cap, level * explore_fortune_per_level
--                              + player_stat('resource_find'))
--
-- At 0.02 a level the cap of 0.75 is reached at level 38. Every active
-- Explorer on this server is far past that:
--
--     clearwest      level 604   from level 12.080   Fortune 0.7964   all wasted
--     m_i_y_u_k_i.   level 468   from level  9.360   Fortune 0.0200   all wasted
--     ._.visha._.    level 192   from level  3.840   Fortune 0.1500   all wasted
--     pashu0         level  91   from level  1.820
--     grafv          level  40   from level  0.800
--
-- The level term alone overshoots the cap twelve times over, so the stat was
-- added to a number already past the ceiling and thrown away by the LEAST.
-- Fortune did nothing whatsoever for anybody above level 38 - which is
-- everyone who explores. Forty-five kinds of Gu, a destiny and a dwelling
-- facility all feed a stat that could not move the outcome.
--
-- THE TWO NOW MULTIPLY INSTEAD OF ADDING. Each removes a share of the
-- empty-handed result that is LEFT after the other:
--
--     nothing_left = (1 - from_level) * (1 - from_fortune)
--
-- which the function returns as `1 - nothing_left`, so `explore` is untouched
-- - it still multiplies the 'nothing' weight by (1 - luck) and renormalises
-- the other three into the space freed.
--
-- Three things fall out of that shape, and all three are wanted:
--
--   FORTUNE ALWAYS PAYS. There is no ceiling it can be hidden under, because
--   it is never added to the level term in the first place. Stacking it on a
--   level 604 Explorer still cuts what is left.
--
--   NOBODY LOSES ANYTHING. With no Fortune at all the second factor is 1 and
--   the answer is exactly the old one - 0.40 at level 20, 0.75 at level 38
--   and above. This migration cannot make any current explorer worse off.
--
--   EMPTY-HANDED NEVER REACHES ZERO. Both factors stay strictly positive, so
--   the product does too. That matters more than it reads: `explore` divides
--   by the weight, and a 'nothing' weight driven to zero or below would not
--   make searching perfect, it would make the draw undefined.
--
-- The level keeps its own ceiling at `explore_fortune_cap`, which is what
-- `skill_buys` and `skill_next_step` describe when they say what a level of
-- Exploring buys - so those screens stay true without being touched. The
-- stat gets a ceiling of its own so the product stays bounded: at both caps
-- the empty-handed result is cut by 93.75%, from 18% of searches to 1.35%.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('explore_fortune_stat_cap', 0.75,
     'The most of the empty-handed outcome the Fortune stat may remove on its '
     'own, before the Explorer level takes its share of what is left. Its own '
     'ceiling rather than one shared with the level, which is what made '
     'Fortune worthless to every Explorer past level 38.');

UPDATE game_config
SET description = 'The most of the empty-handed outcome an Explorer LEVEL may '
                  'remove. Fortune is no longer added into this before the '
                  'clamp - it takes a share of what the level leaves - so '
                  'this is the level own ceiling and is what skill_buys '
                  'quotes as what a level of Exploring buys.'
WHERE key = 'explore_fortune_cap';


CREATE OR REPLACE FUNCTION explore_fortune(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- What the level takes, and then what Fortune takes of the remainder.
    -- Returned as one number so `explore` keeps multiplying the 'nothing'
    -- weight by (1 - this) exactly as it did.
    SELECT 1 - (1 - LEAST(game_config_value('explore_fortune_cap'),
                          GREATEST(0, profession_level(p_player_id, 'exploring')
                                      * game_config_value('explore_fortune_per_level'))))
             * (1 - LEAST(game_config_value('explore_fortune_stat_cap'),
                          GREATEST(0, player_stat(p_player_id, 'resource_find'))));
$$;

COMMENT ON FUNCTION explore_fortune(BIGINT) IS
    'Share of the empty-handed search removed: the level takes its cut, Fortune takes a cut of what is left.';


-- ---------------------------------------------------------------------------
-- Fortune pays, nobody loses, and nothing never disappears
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    lvl_cap  NUMERIC := game_config_value('explore_fortune_cap');
    stat_cap NUMERIC := game_config_value('explore_fortune_stat_cap');
    bad      TEXT;
BEGIN
    -- The ceiling has to stay under 1, or `explore` divides by a weight of
    -- nothing and the draw stops meaning anything.
    IF 1 - (1 - lvl_cap) * (1 - stat_cap) >= 1 THEN
        RAISE EXCEPTION 'the empty-handed result can be removed entirely';
    END IF;

    -- Nobody who explores may come out of this worse than they went in. The
    -- old answer is LEAST(cap, level_term + stat); the new one is the
    -- multiplicative pair.
    SELECT string_agg(t.discord_name || ' (' || round(t.was, 4)
                      || ' -> ' || round(t.now_is, 4) || ')', ', ')
    INTO bad
    FROM (
        SELECT p.discord_name,
               LEAST(lvl_cap,
                     COALESCE(pp.level, 0) * game_config_value('explore_fortune_per_level')
                     + player_stat(p.player_id, 'resource_find')) AS was,
               explore_fortune(p.player_id) AS now_is
        FROM players p
        LEFT JOIN player_professions pp
          ON pp.player_id = p.player_id AND pp.profession = 'exploring'
        WHERE p.deleted_at IS NULL
    ) t
    WHERE t.now_is < t.was - 0.0001;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these explorers came out worse: %', bad;
    END IF;

    -- And somebody who actually carries Fortune must now be better off than
    -- the level alone would make them.
    SELECT string_agg(t.discord_name, ', ') INTO bad
    FROM (
        SELECT p.discord_name,
               player_stat(p.player_id, 'resource_find') AS fortune,
               explore_fortune(p.player_id) AS now_is,
               LEAST(lvl_cap, COALESCE(pp.level, 0)
                              * game_config_value('explore_fortune_per_level')) AS level_only
        FROM players p
        LEFT JOIN player_professions pp
          ON pp.player_id = p.player_id AND pp.profession = 'exploring'
        WHERE p.deleted_at IS NULL
    ) t
    WHERE t.fortune > 0 AND t.now_is <= t.level_only + 0.0001;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'Fortune still buys these cultivators nothing: %', bad;
    END IF;

    RAISE NOTICE 'Fortune pays on top of any level; the floor on empty-handed is % of its weight',
        round((1 - lvl_cap) * (1 - stat_cap), 4);
END;
$probe$;
