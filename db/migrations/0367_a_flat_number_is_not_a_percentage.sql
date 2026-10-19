-- 0367_a_flat_number_is_not_a_percentage
--
-- Iron Bone Immortal Gu reads 'Body 1500%' on the /gu screen. It grants
-- fifteen points of Body. Every screen that lists a Gu's effects multiplies
-- the magnitude by a hundred and staples a per cent sign on, which was correct
-- for every effect in the game until 0355 added three that are not fractions:
-- Body, Hide and Sinew are POINTS added to a base of 120, 20 and 30 before the
-- realm multiplies them.
--
-- So '1500%' is not a rounding problem or a cosmetic one. It is a different
-- quantity, printed in a unit it was never in, and it reads as though one worm
-- is worth fifteen times a cultivator's entire body.
--
-- 0356 already fixed this for /stats by carrying `is_base` through
-- `player_stat_sheet` so the screen could tell them apart. Four other places
-- render effects and none of them were told:
--
--   * /gu, the list of what is in the aperture - the screenshot
--   * /gupedia, the catalogue entry
--   * the Gu refining bench preview
--   * `gu_recipe_book`, the one-line summary in the recipe list
--
-- ONE FORMATTER RATHER THAN FOUR FIXES. Each of those sites had its own copy of
-- `round(100 * magnitude) || '%'`, which is exactly how a fifth site would get
-- it wrong next month. `effect_amount` is now the single place that decides how
-- a magnitude is written down, and it asks `gu_effects.is_base` rather than
-- assuming.
--
-- It also removes a footgun on the way out: a literal per cent sign inside a
-- parameterised psycopg query is a placeholder marker and has to be doubled,
-- which three of those four call sites were doing by hand and the destiny cog
-- has a comment apologising for. A function call contains no per cent at all.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION effect_amount(p_effect TEXT, p_magnitude NUMERIC)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    -- A base stat is a count of points and a percentage is a fraction. The
    -- only thing that knows which is the effect itself.
    SELECT CASE
        WHEN f.is_base THEN '+' || round(p_magnitude)::text
        ELSE round(100 * p_magnitude)::text || '%'
    END
    FROM gu_effects f WHERE f.code = p_effect;
$$;

COMMENT ON FUNCTION effect_amount(TEXT, NUMERIC) IS
    'How a magnitude is written down: +15 for a base stat, 32% for a fraction. The single place that decides, so a new screen cannot print points as a percentage.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '               (SELECT string_agg(ef.emoji || '' '' || round(100 * te.magnitude) || ''%'',';
    swap   := '               (SELECT string_agg(ef.emoji || '' '' || effect_amount(ef.code, te.magnitude),';

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'gu_recipe_book';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'gu_recipe_book no longer writes an effect where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Points read as points, fractions read as fractions
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    said TEXT;
    bad  TEXT;
BEGIN
    -- The worm from the screenshot, said out loud.
    said := effect_amount('base_hp', 15);
    IF said <> '+15' THEN
        RAISE EXCEPTION 'fifteen points of Body reads as %', said;
    END IF;

    said := effect_amount('attack_power', 0.32);
    IF said <> '32%' THEN
        RAISE EXCEPTION 'a third of attack power reads as %', said;
    END IF;

    -- No base stat anywhere in the catalogue comes out with a per cent on it,
    -- and no fraction comes out without one. Driven over every effect a Gu
    -- actually carries rather than over the two spot checks above.
    SELECT string_agg(DISTINCT g.name || ' ' || f.name || ' = '
                      || effect_amount(f.code, te.magnitude), ', ')
    INTO bad
    FROM gu_type_effects te
    JOIN gu_effects f ON f.code = te.effect_code
    JOIN gu_types g ON g.gu_type_id = te.gu_type_id
    WHERE (f.is_base AND effect_amount(f.code, te.magnitude) LIKE '%!%%' ESCAPE '!')
       OR (NOT f.is_base AND effect_amount(f.code, te.magnitude) NOT LIKE '%!%%' ESCAPE '!');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'written in the wrong unit: %', left(bad, 300);
    END IF;

    -- And the recipe list really goes through it now.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'gu_recipe_book')
       ~ '100 \* te\.magnitude' THEN
        RAISE EXCEPTION 'gu_recipe_book still multiplies a magnitude itself';
    END IF;

    SELECT string_agg(f.name || ' ' || effect_amount(f.code, 15), ', ') INTO said
    FROM gu_effects f WHERE f.is_base;
    RAISE NOTICE 'fifteen of each base stat now reads: %', said;
END;
$probe$;
