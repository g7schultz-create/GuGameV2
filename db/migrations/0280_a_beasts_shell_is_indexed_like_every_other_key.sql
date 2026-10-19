-- 0280_a_beasts_shell_is_indexed_like_every_other_key
--
-- `test_every_foreign_key_column_is_indexed` is a standing rule in this
-- schema and 0276 broke it: `player_beasts.rarity` references `rarities` and
-- had nothing behind it. Every other foreign key on the table got one and
-- this one was simply missed.
--
-- It is not a hot path today - a menagerie is small and nothing joins beasts
-- to rarities in bulk - but the rule exists so that stays true by default
-- rather than by luck, and so a `DELETE FROM rarities` never has to scan
-- every beast anybody has hatched.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX player_beasts_rarity_idx ON player_beasts (rarity);


DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE c.contype = 'f' AND t.relname = 'player_beasts'
          AND NOT EXISTS (
              SELECT 1 FROM pg_index i
              WHERE i.indrelid = c.conrelid
                AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                    OPERATOR(pg_catalog.@>) c.conkey
          )
    ) THEN
        RAISE EXCEPTION 'a foreign key on player_beasts is still unindexed';
    END IF;
END;
$$;
