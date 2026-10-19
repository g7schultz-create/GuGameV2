-- 0440_two_new_keys_without_an_index_behind_them
--
-- 0437 gave `player_equipment` a `quality` and left `rarity` with the index
-- that was built for it under its old name - and this codebase has a test that
-- refuses an unindexed foreign key:
--
--     test_every_foreign_key_column_is_indexed
--       player_equipment_quality_fkey1
--       player_equipment_rarity_fkey
--
-- The rarity one is the more surprising of the two. `player_equipment_quality_idx`
-- was built in an earlier migration and RENAMING the column does not rename the
-- index, so the index still exists and still covers the right column - it is
-- simply named after a column that now means something else, and the test looks
-- for an index whose name matches the constraint. Renaming it is the honest fix:
-- an index called `_quality_idx` sitting on `rarity` is the sort of thing that
-- gets dropped by somebody tidying up.
--
-- Forward-only. Do not edit once applied.


ALTER INDEX player_equipment_quality_idx RENAME TO player_equipment_rarity_idx;

CREATE INDEX player_equipment_quality_idx ON player_equipment (quality);


DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    -- The invariant the test checks, asserted here so the migration cannot
    -- land half of it.
    SELECT string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ')
    INTO v_bad
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) AS k (attnum) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid = 'player_equipment'::regclass
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND a.attnum = i.indkey[0]
      );
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these gear keys have no index leading on them: %', v_bad;
    END IF;

    -- And the renamed one really did keep its column rather than being
    -- rebuilt on the wrong one.
    IF NOT EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class ic ON ic.oid = i.indexrelid
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
        WHERE ic.relname = 'player_equipment_rarity_idx' AND a.attname = 'rarity'
    ) THEN
        RAISE EXCEPTION 'the renamed index does not lead on rarity';
    END IF;
END;
$probe$;
