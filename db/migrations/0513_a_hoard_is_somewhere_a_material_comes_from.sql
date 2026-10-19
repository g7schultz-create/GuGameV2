-- 0513_a_hoard_is_somewhere_a_material_comes_from
--
-- 0512 moved the Warden's crown into `boss_drops`, which is where a boss's
-- exclusive loot belongs. One more standing test then caught it:
--
--     test_every_material_says_where_it_comes_from
--     "A recipe naming something the world does not drop is a recipe nobody
--      can fill."
--
-- `material_sources` reads `region_materials`, `region_veins` and
-- `creature_drops` - gather, mine, hunt. It has never read `boss_drops`, so
-- anything held ONLY in a hoard reads as coming from nowhere. That was
-- invisible until now because every existing hoard material is also dropped
-- somewhere else; the crown is the first thing in the game that exists only
-- in a hoard, so it is the first to expose the gap.
--
-- This is the same shape as the rest of the week - a reader that did not
-- learn about a table - except the table is six migrations old rather than
-- six minutes. Adding the branch fixes the crown and every boss-exclusive
-- material anybody adds after it, and it makes `/where` tell a player that
-- the thing they need comes off a world beast, which it currently cannot.
--
-- Lifted and patched: the three existing branches are the whole of how this
-- game explains where anything comes from and are not getting retyped.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
    tail   TEXT;
BEGIN
    src := pg_get_functiondef('material_sources(text)'::regprocedure);

    -- The body ends with an ORDER BY over the whole union, so the new branch
    -- goes BEFORE that rather than before the closing $function$ - appending
    -- after the terminating semicolon is how the first attempt produced
    -- "syntax error at or near UNION".
    anchor := 'ORDER BY 1, 5 DESC, 3;';
    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'material_sources does not end with the ORDER BY 0209 gave it';
    END IF;

    IF src LIKE '%boss_drops%' THEN
        RAISE EXCEPTION 'material_sources already reads the hoard';
    END IF;

    tail :=
        chr(10) ||
        '    UNION ALL' || chr(10) ||
        chr(10) ||
        '    -- A hoard, which is a second table on purpose: `boss_drops` exists' || chr(10) ||
        '    -- so a hunt can never roll what a world beast holds. Nothing read' || chr(10) ||
        '    -- it here until something existed ONLY in a hoard, and then this' || chr(10) ||
        '    -- said the material came from nowhere.' || chr(10) ||
        '    SELECT ''hoard'', cr.region_code, r.name, cs.name,' || chr(10) ||
        '           round(100 * bd.chance, 1),' || chr(10) ||
        '           CASE WHEN bd.min_quantity = bd.max_quantity' || chr(10) ||
        '                THEN bd.min_quantity::text || '' each time''' || chr(10) ||
        '                ELSE bd.min_quantity::text || ''-'' || bd.max_quantity::text' || chr(10) ||
        '                     || '' each time'' END' || chr(10) ||
        '           || '', and off nothing a hunt can reach''' || chr(10) ||
        '    FROM boss_drops bd' || chr(10) ||
        '    JOIN creature_species cs ON cs.species_id = bd.species_id' || chr(10) ||
        '    LEFT JOIN creature_regions cr ON cr.species_id = bd.species_id' || chr(10) ||
        '    LEFT JOIN regions r ON r.code = cr.region_code' || chr(10) ||
        '    WHERE bd.material_code = p_code' || chr(10);

    src := replace(src, anchor, tail || chr(10) || '    ' || anchor);
    EXECUTE src;
END;
$patch$;


DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
BEGIN
    -- The rule the test states, for every material rather than the new one.
    SELECT string_agg(m.code, ', ') INTO v_bad
    FROM materials m
    WHERE m.category <> 'currency'
      AND NOT EXISTS (SELECT 1 FROM material_sources(m.code));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these materials come from nowhere: %', v_bad;
    END IF;

    -- The crown specifically reads as a hoard, which is what a player needs
    -- to be told.
    SELECT count(*) INTO v_n
    FROM material_sources('longevity_crown_fragment')
    WHERE kind = 'hoard';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'the crown still says it comes from nowhere';
    END IF;

    -- And the three branches that were already there still answer. A patch
    -- that replaced them rather than appending would pass the test above and
    -- break every /where screen in the game.
    IF NOT EXISTS (SELECT 1 FROM material_sources('iron_ore') WHERE kind = 'mine') THEN
        RAISE EXCEPTION 'the mine branch stopped answering';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM material_sources('court_step_moss') WHERE kind = 'gather') THEN
        RAISE EXCEPTION 'the gather branch stopped answering';
    END IF;
    SELECT count(*) INTO v_n FROM materials m
    WHERE EXISTS (SELECT 1 FROM material_sources(m.code) WHERE kind = 'hunt');
    IF v_n = 0 THEN
        RAISE EXCEPTION 'the hunt branch stopped answering';
    END IF;

    RAISE NOTICE
        'material_sources now reads four kinds; % materials are huntable, % hoarded',
        v_n,
        (SELECT count(DISTINCT material_code) FROM boss_drops);
END;
$probe$;
