-- 0577_the_new_tables_index_their_keys
--
-- `test_every_foreign_key_column_is_indexed` caught two columns 0574 and 0575
-- left bare:
--
--     market_bought.player_id    -> players
--     player_garden.material_code -> materials
--
-- Both are the half of a foreign key that nobody thinks about. `player_garden`
-- is indexed on (player_id, ready_at) because that is how a garden is read,
-- and `market_bought` has a composite primary key with player_id LAST - which
-- is no use to the lookup Postgres does when a player row is deleted or a
-- material is touched.
--
-- It is the deletion that matters. Both are ON DELETE CASCADE, and an
-- unindexed referencing column turns one deleted player into a sequential scan
-- of every row in the table.


CREATE INDEX market_bought_player_idx ON market_bought (player_id);
CREATE INDEX player_garden_material_idx ON player_garden (material_code);


DO $probe$
DECLARE
    v_bare TEXT;
BEGIN
    -- SCOPED TO THE TWO TABLES THIS MIGRATION IS ABOUT. The first version of
    -- this probe re-derived the global rule and got it wrong - it flagged four
    -- pre-existing columns (`player_loadout.technique_id`,
    -- `player_bestiary_paths.species_id`, `battle_actions.actor_no` and
    -- `.target_no`) that `test_every_foreign_key_column_is_indexed` accepts,
    -- because its notion of "covered" is wider than leading-column-of-an-index.
    --
    -- Policing the whole schema is that test's job and it already does it.
    -- What belongs here is whether the two tables added last night are clean.
    SELECT string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ')
    INTO v_bare
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) AS k(attnum) ON TRUE
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid IN ('market_bought'::regclass, 'player_garden'::regclass)
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND i.indkey[0] = k.attnum
      );

    IF v_bare IS NOT NULL THEN
        RAISE EXCEPTION
            'these foreign key columns are still unindexed: %', v_bare;
    END IF;
END
$probe$;
