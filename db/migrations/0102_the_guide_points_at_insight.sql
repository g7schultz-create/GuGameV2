-- 0102_the_guide_points_at_insight
--
-- 0101 made attainment resistance real and gave it a screen. The guide's Paths
-- page still describes attainment as "it multiplies damage", which was the
-- whole of it until now, and names no command for reading your own.
--
-- Forward-only. Do not edit once applied.


UPDATE tutorial_pages
SET body = replace(
    body,
    'It rises from focused cultivation and from meditation, and it multiplies '
    || 'damage from techniques of that Path.',
    'It rises from focused cultivation, from meditation, and from fighting '
    || 'things that use it. A tier raises damage from techniques of that Path '
    || 'and, from Grandmaster, turns aside part of any blow led with it. '
    || '**/insight** shows where you stand in every Path and what each one is '
    || 'currently paying you; **/tiers** is the ladder itself.'
)
WHERE code = 'paths';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tutorial_pages
        WHERE code = 'paths' AND body LIKE '%/insight%'
    ) THEN
        RAISE EXCEPTION 'the paths page was not rewritten - the anchor moved';
    END IF;
END;
$$;
