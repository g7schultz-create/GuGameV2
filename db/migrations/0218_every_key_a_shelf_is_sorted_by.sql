-- 0218_every_key_a_shelf_is_sorted_by
--
-- `player_beast_eggs` shipped with indexes on owner and species and none on
-- the other two foreign keys. The rule this project holds - every foreign key
-- column is indexed - exists because an unindexed one turns a DELETE on the
-- parent into a sequential scan of the child, and `regions` and `rarities` are
-- both small tables that anything might one day tidy.
--
-- It is also not academic here: the egg shelf sorts by rarity, and every
-- screen that shows an egg reads its grade.
--
-- Caught by the test rather than by me, which is the test doing its job.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX player_beast_eggs_rarity_idx   ON player_beast_eggs (rarity);
CREATE INDEX player_beast_eggs_found_in_idx ON player_beast_eggs (found_in);


DO $$
DECLARE
    n INTEGER;
BEGIN
    -- The whole rule, not just the two rows above: a follow-up that fixed one
    -- table and left the next one broken would be worse than none.
    SELECT count(*) INTO n
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace ns ON ns.oid = t.relnamespace
    WHERE c.contype = 'f' AND ns.nspname = 'public'
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                = c.conkey::smallint[]
      );

    IF n > 0 THEN
        RAISE EXCEPTION '% foreign keys still have no index behind them', n;
    END IF;
END;
$$;
