-- 0142_the_beast_gets_its_missing_indexes
--
-- `boss_encounters.region_code` and `boss_encounters.slayer_id` both carry a
-- foreign key and neither had an index behind it. That is not a hypothetical:
-- an unindexed FK makes every DELETE on the referenced table scan this one, so
-- retiring a region or closing a player's account would seq-scan every
-- encounter that has ever stood.
--
-- Caught by `test_every_foreign_key_column_is_indexed`, which is the test that
-- has caught this three times now - 0110 and 0115 were the same omission in
-- the same shape. Worth saying plainly: writing a table in this schema means
-- writing an index for every REFERENCES in it, and the suite will find the one
-- that was forgotten rather than the deploy finding it.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX boss_encounters_region_idx ON boss_encounters (region_code);
CREATE INDEX boss_encounters_slayer_idx ON boss_encounters (slayer_id)
    WHERE slayer_id IS NOT NULL;


DO $$
DECLARE
    bare TEXT;
BEGIN
    SELECT c.conname INTO bare
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    WHERE c.contype = 'f'
      AND t.relname LIKE 'boss_%'
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                @> c.conkey[1:1]
      )
    LIMIT 1;

    IF bare IS NOT NULL THEN
        RAISE EXCEPTION 'the boss tables still have an unindexed foreign key: %', bare;
    END IF;
END;
$$;
