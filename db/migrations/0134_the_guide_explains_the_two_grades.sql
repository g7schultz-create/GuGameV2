-- 0134_the_guide_explains_the_two_grades
--
-- 0128 taught the combat page that a technique has a price. 0129 to 0131 made
-- half of them unbuyable at any price, which is a bigger thing for the guide
-- to be silent about: a player reading "/learn buys one" and then finding
-- Heaven-Defying Edge refused has been told something untrue by the only
-- screen whose job is to explain.
--
-- Two sentences on the split, and one on where an advanced manual comes from,
-- because a reward nobody knows how to pursue is a reward nobody pursues.
--
-- Forward-only. Do not edit once applied.


UPDATE tutorial_pages
SET body = replace(
    body,
    '**/learn** buys one and it is yours for good; **/loadout** orders '
    || 'them. A manual only lends you a technique while it is equipped.',
    '**/learn** buys a **basic** technique and it is yours for good; '
    || '**/loadout** orders them.'
    || E'\n\n'
    || 'An **advanced** technique is not for sale at any price. It lives in a '
    || 'technique manual, and it works only while that manual is one of your '
    || 'two equipped — you carry it rather than own it. They are about twice '
    || 'the power of a basic technique at the same rank, which is what the '
    || 'slot is being spent on. Two ways to get one: off an elite, a boss or a '
    || 'world beast, or out of an attack refinement that comes back above '
    || '{technique_manual_harmony} harmony.'
)
WHERE code = 'combat';


-- The crafting page is where a refiner reads about harmony, so it is where
-- the second route belongs as well.
UPDATE tutorial_pages
SET body = body || E'\n\n'
    || 'An **attack** refinement that comes back above {technique_manual_harmony} '
    || 'harmony is not a stat manual at all — it is a **technique manual**, '
    || 'carrying an advanced technique that cannot be bought. Which move '
    || 'depends on the dominant Path and the tier the pages bought.'
WHERE code = 'crafting'
  AND body NOT LIKE '%technique manual%';


DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tutorial_pages
        WHERE code = 'combat' AND body LIKE '%advanced%'
    ) THEN
        RAISE EXCEPTION 'the combat page did not contain the sentence being replaced';
    END IF;

    IF (SELECT body FROM tutorial WHERE code = 'combat') LIKE '%{%' THEN
        RAISE EXCEPTION 'the combat page has a placeholder game_config cannot fill';
    END IF;

    IF (SELECT body FROM tutorial WHERE code = 'crafting') LIKE '%{%' THEN
        RAISE EXCEPTION 'the crafting page has a placeholder game_config cannot fill';
    END IF;
END;
$$;
