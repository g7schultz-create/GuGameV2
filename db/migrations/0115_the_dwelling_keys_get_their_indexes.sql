-- 0115_the_dwelling_keys_get_their_indexes
--
-- 0111 and 0112 added five foreign keys and indexed two of them.
-- `test_every_foreign_key_column_is_indexed` names the other three, which is
-- exactly the job that test was written to do: an unindexed foreign key turns
-- every delete on the parent into a sequential scan of the child, and it does
-- it silently, on a table that is small right now and will not always be.
--
-- Forward-only. Do not edit once applied.


-- Read on every facility screen, and scanned whenever an effect is retired.
CREATE INDEX dwelling_facilities_effect_idx ON dwelling_facilities (effect_code);

-- Read when working out which facilities a dwelling of a given stage allows.
CREATE INDEX dwelling_facilities_min_stage_idx ON dwelling_facilities (min_stage);

-- The stage a rung demands, scanned if a realm is ever renumbered.
CREATE INDEX dwelling_stages_realm_idx ON dwelling_stages (realm_required);
