-- 0332_fortune_reaches_the_other_three
--
-- Fortune touched `/explore` and nothing else. Forty-five kinds of Gu, a
-- destiny and a dwelling facility all fed a stat that moved one command's
-- empty-handed row and left hunting, mining and gathering alone.
--
-- It reaches all four now, and in each lane it means the thing that lane
-- already means by "rare" rather than a number bolted to the side:
--
--     gather   more candidates looked at, and the rarest is kept
--     mine     the deeper seams weigh more in the draw
--     hunt     a drop rolls better the rarer the thing being dropped
--
-- ONE CAP FOR THE WHOLE STAT. 0331 gave Fortune its own ceiling in explore so
-- an Explorer's level could not eat it; `fortune_share` is that ceiling made
-- general, and `explore_fortune` now reads it too. `explore_fortune_stat_cap`
-- from 0331 is retired into it rather than left as a second dial meaning the
-- same thing in one lane only.
--
-- WHAT EACH LANE DOES, AND WHY IT IS THAT SHAPE
--
--   GATHER already looks at `forage_draws(level)` candidates and keeps the
--   rarest, so Fortune buys more looks. They are added ON TOP of
--   `forage_max_draws` on purpose - that cap is what a LEVEL may buy, and
--   0331 was written because a cap shared with a level is how Fortune came to
--   be worth nothing. The fractional part is a chance at one more look, so a
--   half draw is half a draw over many gathers rather than nothing at all.
--
--   MINE draws a vein by weight. Fortune multiplies the weight of everything
--   below the surface by its tier, so tier 1 is untouched and the deep seams
--   climb. A tier 8 seam is 0.40% of digs in northern; at the cap it is about
--   1.4%, which is the difference between a Pseudo-Immortal expedition being
--   a rumour and being a plan.
--
--   HUNT rolls each drop against its own chance. Fortune removes a share of
--   the MISS, scaled by the grade of the thing that would have dropped, so it
--   is worth almost nothing on common material and a great deal on legendary.
--   Removing a share of the miss rather than adding to the chance also means
--   a chance can never pass 1, which the CHECK on `creature_drops` would
--   otherwise be entitled to complain about if it ever read back.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('fortune_cap', 0.75,
     'The most the Fortune stat may ever be worth in any one lane, whatever '
     'is stacked. One ceiling for the whole stat rather than one per command.'),
    ('fortune_forage_draws', 2.0,
     'Extra candidates a full measure of Fortune buys a forager, on top of '
     'whatever their level already looks at. A fractional draw is a chance at '
     'one more rather than nothing.'),
    ('fortune_mine_tier_weight', 0.5,
     'How much Fortune multiplies a vein weight per tier below the surface. '
     'Tier 1 is untouched; at the cap a tier 8 seam weighs about three and a '
     'half times what it does bare.'),
    ('fortune_hunt_weight', 0.35,
     'Share of a failed drop roll Fortune takes back, before the rarity of '
     'the thing being dropped scales it. Deliberately modest: it compounds '
     'with the grade term and the point is rare drops, not more of everything.'),
    ('fortune_rarity_pivot', 5,
     'The material grade at which Fortune gives its whole hunt effect - '
     'legendary. Commons sit at a fifth of it, so Fortune reads as luck with '
     'the rare rather than a yield stat by another name.');


-- ---------------------------------------------------------------------------
-- The stat, once, for every lane
-- ---------------------------------------------------------------------------

CREATE FUNCTION fortune_share(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(game_config_value('fortune_cap'),
                 GREATEST(0, player_stat(p_player_id, 'resource_find')));
$$;

COMMENT ON FUNCTION fortune_share(BIGINT) IS
    'The Fortune stat, clamped. Every lane that reads Fortune reads this.';


-- Explore stops carrying a second copy of the same ceiling.
CREATE OR REPLACE FUNCTION explore_fortune(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT 1 - (1 - LEAST(game_config_value('explore_fortune_cap'),
                          GREATEST(0, profession_level(p_player_id, 'exploring')
                                      * game_config_value('explore_fortune_per_level'))))
             * (1 - fortune_share(p_player_id));
$$;

DELETE FROM game_config WHERE key = 'explore_fortune_stat_cap';


-- ---------------------------------------------------------------------------
-- Gathering: more looks, the rarest kept
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '    looks := forage_draws(skill);';
    swap := concat(
'    looks := forage_draws(skill);', chr(10),
chr(10),
'    -- Fortune buys looks ON TOP of what the level may. `forage_draws` caps', chr(10),
'    -- at `forage_max_draws`, and that cap belongs to the level - folding', chr(10),
'    -- Fortune under it is exactly how Fortune came to be worth nothing to', chr(10),
'    -- every Explorer past level 38 before 0331.', chr(10),
'    looks := looks + floor(fortune_share(p_player_id)', chr(10),
'                           * game_config_value(''fortune_forage_draws''))::integer;', chr(10),
'    IF random() < (fortune_share(p_player_id)', chr(10),
'                   * game_config_value(''fortune_forage_draws'')) % 1 THEN', chr(10),
'        looks := looks + 1;', chr(10),
'    END IF;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'gather';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'gather no longer decides its draws where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- Mining: the deep seams weigh more -------------------------------
    anchor := '    ORDER BY -ln(random()) / rv.weight';
    swap := concat(
'    -- Fortune leans the draw downward: every tier below the surface has its', chr(10),
'    -- weight multiplied, so tier 1 is untouched and the rare seams climb.', chr(10),
'    ORDER BY -ln(random())', chr(10),
'             / (rv.weight * (1 + fortune_share(p_player_id)', chr(10),
'                                 * game_config_value(''fortune_mine_tier_weight'')', chr(10),
'                                 * GREATEST(0, o.tier - 1)))');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'mine';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'mine no longer draws its vein where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- Hunting: the rarer the drop, the more Fortune is worth ----------
    anchor := '            IF random() < d.chance THEN';
    swap := concat(
'            -- Fortune takes back a share of the MISS, scaled by how rare the', chr(10),
'            -- thing that would have dropped is - a fifth of the effect on a', chr(10),
'            -- common, all of it on a legendary. Taken off the miss rather', chr(10),
'            -- than added to the chance so the result can never pass 1.', chr(10),
'            IF random() < 1 - (1 - d.chance)', chr(10),
'                             * (1 - fortune_share(me.player_id)', chr(10),
'                                    * game_config_value(''fortune_hunt_weight'')', chr(10),
'                                    * LEAST(1, material_grade(d.rarity)::numeric', chr(10),
'                                       / game_config_value(''fortune_rarity_pivot''))) THEN');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'battle_conclude';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the drop roll is no longer where it was';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every lane moves, and none of them moves for somebody with no Fortune
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    cap   NUMERIC := game_config_value('fortune_cap');
    bare  NUMERIC;
    lucky NUMERIC;
BEGIN
    -- Gathering: the cap on a level's looks must not be the cap on Fortune's.
    IF floor(cap * game_config_value('fortune_forage_draws')) < 1 THEN
        RAISE EXCEPTION 'a full measure of Fortune does not buy even one look';
    END IF;

    -- Mining: a deep seam must actually climb.
    bare  := 1;
    lucky := 1 + cap * game_config_value('fortune_mine_tier_weight') * (8 - 1);
    IF lucky <= bare * 2 THEN
        RAISE EXCEPTION 'a tier 8 seam barely moves: % against %', lucky, bare;
    END IF;
    -- ...and the surface must not.
    IF 1 + cap * game_config_value('fortune_mine_tier_weight') * (1 - 1) <> 1 THEN
        RAISE EXCEPTION 'Fortune is moving the tier 1 vein as well';
    END IF;

    -- Hunting: worth much more on a legendary than on a common.
    bare  := cap * game_config_value('fortune_hunt_weight')
             * LEAST(1, 1::numeric / game_config_value('fortune_rarity_pivot'));
    lucky := cap * game_config_value('fortune_hunt_weight')
             * LEAST(1, 5::numeric / game_config_value('fortune_rarity_pivot'));
    IF lucky <= bare * 3 THEN
        RAISE EXCEPTION
            'Fortune is nearly as good on commons (%) as on legendaries (%)',
            bare, lucky;
    END IF;

    -- And a drop can never be made certain, whatever is stacked.
    IF 1 - (1 - 0.99) * (1 - lucky) >= 1 THEN
        RAISE EXCEPTION 'a drop can be forced to certainty';
    END IF;

    RAISE NOTICE
        'Fortune at the cap: % extra looks, a tier 8 seam at % times weight, legendary drops taking % percent of the miss',
        round(cap * game_config_value('fortune_forage_draws'), 2),
        round(1 + cap * game_config_value('fortune_mine_tier_weight') * 7, 2),
        round(lucky * 100);
END;
$probe$;
