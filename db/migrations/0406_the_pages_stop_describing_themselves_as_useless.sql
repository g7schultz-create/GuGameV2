-- 0406_the_pages_stop_describing_themselves_as_useless
--
-- 0405 gave all four dead page kinds a job. Their descriptions still say they
-- have none, and `is_live` is still false - which is not cosmetic: the page
-- catalogue reads that flag to decide whether to print a kind in italics as
-- "not yet implemented", so a player who equips a Speed page is told by the
-- game that it does nothing while it quietly adds to their defence.
--
-- A flag nobody updated is how the last four kinds ended up being described
-- accurately for two hundred migrations and then inaccurately for one.
--
-- Forward-only. Do not edit once applied.


UPDATE page_types SET is_live = TRUE, description =
    'Defence. This world has no turn order to spend speed on, so a quick '
    'cultivator is simply a hard one to hurt - it joins the same pile a '
    'manual''s Defense pages feed.'
WHERE code = 'speed';

UPDATE page_types SET is_live = TRUE, description =
    'Harmony at every bench. A Gu refined, a pill brewed and a manual pressed '
    'all come out better, and a thing that would have failed sometimes forms.'
WHERE code = 'refinement';

UPDATE page_types SET is_live = TRUE, description =
    'What a mouthful of immortal essence and a cultivation pill are worth. '
    'Stacks with Essence pages, which do the same thing.'
WHERE code = 'breakthrough';

UPDATE page_types SET is_live = TRUE, description =
    'What a mouthful of immortal essence and a cultivation pill are worth. '
    'Stacks with Breakthrough pages, which do the same thing.'
WHERE code = 'essence';


-- ---------------------------------------------------------------------------
-- Nothing calls itself dead that is not, and nothing alive says so quietly
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    -- Every page kind that something reads must say it is live. The reverse -
    -- a live flag on a kind nothing reads - is the shape this migration is
    -- fixing, so it is worth checking both directions.
    SELECT string_agg(pt.code, ', ') INTO v_bad
    FROM page_types pt
    WHERE NOT pt.is_live
      AND EXISTS (
          SELECT 1 FROM pg_proc p
          WHERE p.pronamespace = 'public'::regnamespace
            AND p.proname NOT IN ('manual_total_bonus', 'manual_stat')
            AND p.prosrc LIKE '%' || pt.manual_column || '%'
      );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these kinds do something and still claim not to: %', v_bad;
    END IF;

    SELECT string_agg(pt.code, ', ') INTO v_bad
    FROM page_types pt
    WHERE pt.is_live
      AND NOT EXISTS (
          SELECT 1 FROM pg_proc p
          WHERE p.pronamespace = 'public'::regnamespace
            AND p.proname NOT IN ('manual_total_bonus', 'manual_stat')
            AND p.prosrc LIKE '%' || pt.manual_column || '%'
      );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these kinds claim to do something and nothing reads them: %', v_bad;
    END IF;

    -- And no description still calls itself unimplemented.
    SELECT string_agg(pt.code, ', ') INTO v_bad
    FROM page_types pt
    WHERE pt.description ~* 'no .* (system|skill) exists|nothing spends|currently advance';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these still describe themselves as a placeholder: %', v_bad;
    END IF;

    RAISE NOTICE
        'all % page kinds do something and say what', (SELECT count(*) FROM page_types);
END;
$probe$;
