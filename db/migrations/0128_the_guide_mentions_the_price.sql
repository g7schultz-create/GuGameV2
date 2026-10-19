-- 0128_the_guide_mentions_the_price
--
-- The combat page said "**/learn** takes one", which was true when learning
-- was free and is now the guide quietly omitting a cost. 0126 gave a technique
-- a price in Spirit Stones and a requirement in Path attainment, and the
-- second is the one a player will not guess: they will read a locked technique
-- as "cultivate further" when what it actually wants is /focus.
--
-- The price is written as `{technique_learn_base}` rather than as the number,
-- so tuning the config key retunes the guide with it. That substitution is
-- what `tutorial_text` is for, and a page quoting a stale figure is the exact
-- failure it exists to prevent.
--
-- A targeted replace rather than a rewritten page, so the rest of what that
-- page says survives untouched - and `tutorial_pages`, not `tutorial`, which
-- is the view that performs the substitution and is not updatable.
--
-- Forward-only. Do not edit once applied.


UPDATE tutorial_pages
SET body = replace(
    body,
    '**/techniques** lists what there is, **/learn** takes one, '
    || '**/loadout** orders them.',
    '**/techniques** is the shelf: everything that exists, what each one costs '
    || 'in Spirit Stones, and which of the three gates is shut on it — your '
    || 'realm, your attainment in its Path, or your purse. A first technique '
    || 'is {technique_learn_base} stones and they get dearer a rank at a time. '
    || '**/learn** buys one and it is yours for good; **/loadout** orders '
    || 'them. A manual only lends you a technique while it is equipped.'
)
WHERE code = 'combat';


DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM tutorial_pages
        WHERE code = 'combat' AND body LIKE '%{technique_learn_base}%'
    ) THEN
        RAISE EXCEPTION 'the combat page did not contain the sentence being replaced';
    END IF;

    -- And the placeholder has to resolve, or the page ships showing braces.
    IF (SELECT body FROM tutorial WHERE code = 'combat') LIKE '%{%' THEN
        RAISE EXCEPTION 'the combat page has a placeholder game_config cannot fill';
    END IF;
END;
$$;
