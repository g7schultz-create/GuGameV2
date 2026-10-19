-- 0080_the_draws_have_to_be_independent
--
-- Harmony bought four draws and every one of them came back the same.
--
-- 0077 wrote the roll as a `generate_series` cross joined to a LATERAL
-- subquery that picks one band. The subquery does not REFERENCE the series -
-- it has no correlation to the outer row at all - so Postgres is free to
-- evaluate it once and reuse the answer for every row, and it does. Four draws
-- were four copies of one draw, and "the best of them" was that one.
--
-- It is invisible from the code and obvious from the data: sampling twenty
-- thousand refinements at harmony 55, 80, 105 and 130 gave 44.6 / 44.6 / 45.0
-- / 44.7 percent common. Four identical columns are not four different numbers
-- of chances.
--
-- The fix is to make each draw its own row rather than its own evaluation: the
-- series is cross joined to the WHOLE ladder, every (draw, band) pair gets its
-- own random(), DISTINCT ON picks a winner per draw, and the best of those
-- wins. There is no subquery left for the planner to hoist.
--
-- The test that catches it compares the distributions rather than the code,
-- because the code looked right.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION roll_manual_quality(p_harmony SMALLINT)
RETURNS TEXT
LANGUAGE sql VOLATILE
AS $$
    SELECT best.rarity
    FROM (
        SELECT DISTINCT ON (d.draw) d.draw, mq.rarity, r.sort_order
        FROM generate_series(1, manual_quality_draws(p_harmony)) AS d (draw)
        CROSS JOIN manual_qualities mq
        JOIN rarities r ON r.code = mq.rarity
        ORDER BY d.draw, -ln(random()) / mq.weight
    ) AS best
    ORDER BY best.sort_order DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION roll_manual_quality(SMALLINT) IS
    'Draws once per chance the harmony bought and keeps the best. Each draw is a row rather than a re-evaluation, because an uncorrelated subquery is evaluated once however many times it is joined.';
