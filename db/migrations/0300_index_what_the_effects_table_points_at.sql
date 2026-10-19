-- 0300_index_what_the_effects_table_points_at
--
-- `test_every_foreign_key_column_is_indexed` caught three unindexed foreign
-- keys on the table 0298 added. It is a house rule with a real reason behind
-- it: an unindexed referencing column makes every DELETE on the referenced
-- side scan this table to check nothing points at the row. `battle_effects`
-- points at `players`, `techniques` and `battle_effect_kinds`, so without
-- these, deleting one cultivator or one technique would sequentially scan
-- every live effect in the game.
--
-- 0298 did add an index - `(scope, scope_id, player_id, effect_code)` - which
-- is the right one for the lookup `effect_value` makes on every blow. It does
-- not help any of the three constraints, because a composite index only
-- serves a prefix of its columns and that one leads with `scope`. Being
-- useful for the hot read and useless for the foreign keys is exactly the
-- case the rule exists to catch, and I would not have noticed it by looking.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX battle_effects_player_idx     ON battle_effects (player_id);
CREATE INDEX battle_effects_kind_idx       ON battle_effects (effect_code);
CREATE INDEX battle_effects_technique_idx  ON battle_effects (from_technique)
    WHERE from_technique IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Every foreign key on the new table is served by an index leading with it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bare TEXT;
BEGIN
    SELECT string_agg(c.conname, ' ') INTO bare
    FROM pg_constraint c
    JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid::regclass::text LIKE 'battle_effect%'
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND i.indkey[0] = a.attnum      -- leading column, not merely present
      );

    IF bare IS NOT NULL THEN
        RAISE EXCEPTION 'still unindexed: %', bare;
    END IF;
END;
$$;
