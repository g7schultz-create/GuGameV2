-- 0376_the_focus_column_indexes_what_it_points_at
--
-- 0373 added `technique_forges.focus` pointing at `paths` and gave it no
-- index, and the schema suite caught it - the same rule that caught three of
-- these on the forge tables in 0361. An unindexed foreign key turns every
-- DELETE on the parent into a sequential scan of the child, so retiring a Path
-- would scan every forge ever opened.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX technique_forges_focus_idx
    ON technique_forges (focus) WHERE focus IS NOT NULL;


DO $probe$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ')
    INTO bad
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid::regclass::text IN
          ('technique_forges', 'forge_choices', 'path_effect_bias',
           'destiny_techniques', 'enlighten_qualities')
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                = c.conkey
            AND (i.indpred IS NULL
                 OR pg_get_expr(i.indpred, i.indrelid)
                    = '(' || a.attname || ' IS NOT NULL)'));
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'still unindexed: %', bad;
    END IF;

    RAISE NOTICE 'every key the enlightenment tables point with is indexed';
END;
$probe$;
