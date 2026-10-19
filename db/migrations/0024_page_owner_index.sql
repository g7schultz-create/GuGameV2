-- 0024_page_owner_index
--
-- 0023 indexed `manual_pages.owner_id` only partially:
--
--     CREATE INDEX manual_pages_owner_idx ON manual_pages (owner_id)
--         WHERE consumed_at IS NULL;
--
-- which serves the query it was written for - "the pages this player is still
-- holding" - and does NOT serve the foreign key. A partial index cannot,
-- because deleting a player has to find every row referencing them, consumed
-- pages included, and the planner cannot use an index that excludes half the
-- table for that.
--
-- The schema's rule is that every foreign key gets an index, and
-- test_every_foreign_key_column_is_indexed caught this. Replacing the partial
-- index with a composite on (owner_id, consumed_at) satisfies both: the
-- leading column covers the FK, and the second column still makes the
-- unconsumed-pages lookup a range scan rather than a filter.
--
-- One index instead of two, which is also why this replaces rather than adds.
--
-- Forward-only. Do not edit once applied.

DROP INDEX manual_pages_owner_idx;

CREATE INDEX manual_pages_owner_idx ON manual_pages (owner_id, consumed_at);

COMMENT ON INDEX manual_pages_owner_idx IS
    'Serves the owner FK on its leading column and the "still holding" lookup on both. A partial index would do only the second.';
