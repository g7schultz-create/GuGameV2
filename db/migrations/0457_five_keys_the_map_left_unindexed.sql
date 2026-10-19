-- 0457_five_keys_the_map_left_unindexed
--
-- 0455 added five tables and five foreign keys, and indexed none of them.
-- `test_every_foreign_key_column_is_indexed` caught it, which is the fourth
-- time that test has caught exactly this and the reason it exists: an
-- unindexed referencing column turns every DELETE on the parent into a
-- sequential scan of the child, and the parents here are `players`,
-- `materials` and `creature_species` - three of the most-deleted-from tables
-- in the game.
--
--     trial_cache_spoils (material_code)   -> materials
--     trial_map_bodies   (player_id)       -> players
--     trial_map_tiles    (kind)            -> trial_map_kinds
--     trial_maps         (species_id)      -> creature_species
--     trial_runs         (tile_kind)       -> trial_map_kinds
--
-- The two pointing at `trial_map_kinds` matter least - it holds five rows and
-- nothing ever deletes from it - but they are indexed anyway rather than
-- argued about, because a rule with exceptions in it stops being checkable.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX trial_cache_spoils_material_idx
    ON trial_cache_spoils (material_code);

CREATE INDEX trial_map_bodies_player_idx
    ON trial_map_bodies (player_id);

CREATE INDEX trial_map_tiles_kind_idx
    ON trial_map_tiles (kind);

CREATE INDEX trial_maps_species_idx
    ON trial_maps (species_id);

CREATE INDEX trial_runs_tile_kind_idx
    ON trial_runs (tile_kind);


-- ---------------------------------------------------------------------------
-- Nothing in the Trial references without an index
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    SELECT string_agg(bad.what, ', ') INTO v_bad
    FROM (
        SELECT c.conrelid::regclass::text || '.' || a.attname AS what
        FROM pg_constraint c
        CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k (att, ord)
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.att
        WHERE c.contype = 'f'
          AND c.conrelid::regclass::text LIKE 'trial%'
          AND NOT EXISTS (
              SELECT 1 FROM pg_index i
              WHERE i.indrelid = c.conrelid
                AND (i.indkey::smallint[])[0:array_length(c.conkey, 1) - 1]
                    = c.conkey)
        GROUP BY c.oid, c.conrelid, a.attname
    ) bad;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'still unindexed: %', v_bad;
    END IF;
END;
$probe$;
