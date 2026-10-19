-- 0491_two_keys_the_carry_tally_left_bare
--
-- `test_every_foreign_key_column_is_indexed` caught both of the foreign keys
-- 0487 and 0488 added. A standing invariant doing exactly its job - this is
-- the sixth time that test has caught a migration of mine.
--
--     player_gu_carried.gu_type_id    PK is (player_id, gu_type_id), so the
--                                     second column leads nothing
--     player_gu_equipped.gu_type_id   added by 0488, indexed by nothing
--
-- The second one is not only a foreign key. `gu_carried_seconds` asks
-- `player_gu_equipped` for the open stints of one kind of worm:
--
--     WHERE e.player_id = ... AND e.gu_type_id = ...
--
-- and that table's only index is its primary key on gu_id. So the function at
-- the centre of the Gu axis of every Dao was doing a sequential scan, on a
-- path I created in 0488 when I moved the lookup off player_gu to stop the
-- banking trigger reading a dead row. Fixing one thing and leaving its reader
-- slower is the same shape as the faults it was fixing.
--
-- (gu_type_id, player_id) rather than the other way round: it leads with the
-- foreign key column, which is what the invariant wants, and equality on both
-- columns uses it either way, which is what the function wants.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX player_gu_carried_kind_idx
    ON player_gu_carried (gu_type_id);

CREATE INDEX player_gu_equipped_kind_idx
    ON player_gu_equipped (gu_type_id, player_id);


DO $probe$
DECLARE
    v_bare TEXT;
    v_plan TEXT;
    v_line TEXT;
BEGIN
    -- Every foreign key on the two tables this work added now leads an index,
    -- asked the same way the test asks it.
    SELECT string_agg(c.conrelid::regclass::text || '.' || a.attname, ', ')
    INTO v_bare
    FROM pg_constraint c
    JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, pos) ON k.pos = 1
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f'
      AND c.conrelid IN ('player_gu_carried'::regclass, 'player_gu_equipped'::regclass)
      AND array_length(c.conkey, 1) = 1
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid
            AND i.indkey[0] = k.attnum
            AND i.indpred IS NULL);
    IF v_bare IS NOT NULL THEN
        RAISE EXCEPTION 'still unindexed: %', v_bare;
    END IF;

    -- And the read the Gu aspect depends on uses one rather than scanning.
    -- Forced off sequential scans so the plan is about the index existing and
    -- not about a table that is currently small enough not to care.
    -- Collected row by row: EXECUTE ... INTO takes only the first line of a
    -- plan, which is 'Aggregate' and says nothing about how the scan was done.
    SET LOCAL enable_seqscan = off;
    v_plan := '';
    FOR v_line IN
        EXECUTE 'EXPLAIN (COSTS OFF) SELECT sum(1) FROM player_gu_equipped e '
                'WHERE e.player_id = 1 AND e.gu_type_id = 1'
    LOOP
        v_plan := v_plan || v_line || ' / ';
    END LOOP;
    IF v_plan NOT LIKE '%player_gu_equipped_kind_idx%' THEN
        RAISE EXCEPTION 'the open-stint read does not reach for the new index: %', v_plan;
    END IF;

    RAISE NOTICE 'both carry-tally keys indexed, and the open-stint read uses one';
END;
$probe$;
