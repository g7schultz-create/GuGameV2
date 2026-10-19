-- 0105_an_unbinding_reads_the_same_at_every_tier
--
-- 0104 floored the page count, and the result was a yield table that goes
--
--     Tier 3 -> 2 pages,  Tier 4 -> 1 page,  Tier 5 -> 1 page
--
-- which reads as a punishment for unbinding a better book. It is not: a
-- Tier 3 page carries half again the power of a Tier 2, so the VALUE returned
-- rises the whole way up. Only the count falls, and only because the tier
-- bands widen faster than the share does.
--
-- A screen can explain a number that goes up. It cannot explain one that goes
-- down while meaning up. Rounding instead of flooring gives one page at Tier 1
-- and two from Tier 2 onward, every one of them a tier below the book - which
-- is a sentence a player can hold in their head.
--
-- The economics do not move. Two Tier 9 pages refine into a Tier 5 manual,
-- which unbinds into two Tier 4 pages: still downhill, and still no EXP.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION manual_unbind_yield(p_tier SMALLINT)
RETURNS TABLE (pages INTEGER, page_tier SMALLINT, power_returned NUMERIC)
LANGUAGE sql STABLE
AS $$
    WITH worth AS (
        SELECT mt.bonus_budget * 100
               * game_config_value('refinement_potential_divisor') AS implied,
               -- Never a page as good as the book it came out of. A Tier 1
               -- manual bottoms out at Tier 1 pages rather than at nothing.
               GREATEST(1, p_tier - 1)::smallint AS back_at
        FROM manual_tiers mt WHERE mt.tier = p_tier
    ),
    band AS (
        SELECT w.implied * game_config_value('manual_unbind_share') AS returned,
               w.back_at,
               (pt.power_min + pt.power_max) / 2.0 AS per_page
        FROM worth w JOIN page_tiers pt ON pt.tier = w.back_at
    )
    -- At least one page: a manual that unbound into nothing would be a button
    -- that destroys your property and thanks you for it.
    SELECT GREATEST(1, round(b.returned / b.per_page))::integer,
           b.back_at,
           round(b.returned, 1)
    FROM band b;
$$;

COMMENT ON FUNCTION manual_unbind_yield(SMALLINT) IS
    'How many pages, and of what tier, a manual of this tier comes apart into: one at Tier 1, two above it, always a tier below the book. Derived from the page power the tier implies.';
