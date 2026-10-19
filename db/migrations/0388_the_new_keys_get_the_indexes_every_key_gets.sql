-- 0388_the_new_keys_get_the_indexes_every_key_gets
--
-- 0386 added two foreign keys and no index behind either:
--
--     player_tribulations.rank -> tribulations.rank
--     tribulations.species_id  -> creature_species.species_id
--
-- `test_every_foreign_key_column_is_indexed` caught both, which is what it is
-- for. The composite on (player_id, rank, status) does not cover `rank` on its
-- own - a leading column is the only one an index answers for - so a delete
-- from `tribulations` would sequentially scan every attempt anybody has made.
--
-- Small tables today. The rule is not about today.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX player_tribulations_rank_idx ON player_tribulations (rank);
CREATE INDEX tribulations_species_idx ON tribulations (species_id);


DO $probe$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(c.conrelid::regclass || '.' || c.conname, ', ') INTO bad
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid::regclass::text IN ('player_tribulations', 'tribulations')
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                = c.conkey::smallint[]
      );
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these keys still have nothing behind them: %', bad;
    END IF;
END;
$probe$;
