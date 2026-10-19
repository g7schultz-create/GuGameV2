-- 0361_the_forge_tables_index_what_they_point_at
--
-- 0360 left three foreign key columns without an index, and the schema suite
-- caught all three. The rule is older than this feature: an unindexed FK makes
-- every DELETE on the parent a sequential scan of the child, so deleting one
-- player would scan every forge ever opened.
--
-- `technique_forges.technique_id` was already covered - its partial index is
-- exactly `WHERE technique_id IS NOT NULL`, which is the one predicate the
-- check accepts as equivalent to a full index for this purpose. The other
-- three were not:
--
--   * technique_forges.player_id - the only index on it is partial on
--     `finished_at IS NULL`, which serves the one-open-forge rule and does
--     nothing for a cascade.
--   * technique_forges.manual_id - no index at all.
--   * forge_choices.taken - no index at all.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX technique_forges_player_idx ON technique_forges (player_id);
CREATE INDEX technique_forges_manual_idx ON technique_forges (manual_id);
CREATE INDEX forge_choices_taken_idx ON forge_choices (taken);


-- ---------------------------------------------------------------------------
-- Nothing in this feature points at a parent it cannot be cascaded from
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad TEXT;
BEGIN
    -- The same rule the suite applies, narrowed to the tables this feature
    -- added, so the migration proves its own fix rather than deferring to a
    -- test run that happens afterwards.
    SELECT string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ')
    INTO bad
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid::regclass::text IN
          ('technique_forges', 'forge_choices')
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

    RAISE NOTICE 'every forge foreign key is indexed';
END;
$probe$;
