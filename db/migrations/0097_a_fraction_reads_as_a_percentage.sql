-- 0097_a_fraction_reads_as_a_percentage
--
-- "closes 0.15 to 0.55 of your health" is not a sentence anybody wants.
--
-- Half the dials in `game_config` are fractions, and a tutorial that
-- substitutes them raw reads like a spreadsheet. The fix is not to write the
-- percentages into the prose - that is exactly the staleness 0096 was built to
-- avoid - but to let the page ask for the same value in the other form.
--
--     {rest_heal_min_pct}   -> 0.15
--     {rest_heal_min_pct%}  -> 15%
--
-- Every screen in this bot already renders a fraction as a whole percentage;
-- this is that rule reaching the one place that reads its numbers from rows.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION tutorial_text(p_body TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    dial RECORD;
    out  TEXT := p_body;
BEGIN
    FOR dial IN SELECT key, value FROM game_config LOOP
        -- The percent form first: `{key}` is a prefix of `{key%}`, so
        -- replacing the bare one first would leave a stray sign behind.
        IF position('{' || dial.key || '%}' IN out) > 0 THEN
            out := replace(out, '{' || dial.key || '%}',
                           trim_scale(round(dial.value * 100, 2))::text || '%');
        END IF;
        IF position('{' || dial.key || '}' IN out) > 0 THEN
            out := replace(out, '{' || dial.key || '}',
                           trim_scale(dial.value)::text);
        END IF;
    END LOOP;
    RETURN out;
END;
$$;

COMMENT ON FUNCTION tutorial_text(TEXT) IS
    'Substitutes live game_config values into a tutorial page. `{key}` gives the stored number, `{key%}` the same value as a whole percentage.';

UPDATE tutorial_pages
SET body = replace(replace(body,
        '{rest_heal_min_pct}', '{rest_heal_min_pct%}'),
        '{rest_heal_max_pct}', '{rest_heal_max_pct%}')
WHERE code = 'combat';

-- Meditation's share of a realm was the other one reading as a decimal.
UPDATE tutorial_pages
SET body = replace(body,
    'a share of the realm you are crossing, or of the next step on your Path',
    'between {meditate_min_pct%} and {meditate_max_pct%} of the realm you are crossing, or of the next step on your Path')
WHERE code = 'cultivation';
