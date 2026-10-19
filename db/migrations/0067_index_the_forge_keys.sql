-- 0067_index_the_forge_keys
--
-- Four foreign keys 0065 left without an index on the referencing side.
--
-- Postgres indexes the referenced side of a foreign key and never the
-- referencing side, so a delete on the parent scans the child whole. This
-- schema has held "every FK is indexed" as a rule since 0001 and there is a
-- test that asks the catalog rather than the author - which is how these four
-- were found, about ninety seconds after they were written.
--
-- Three of them are second columns of a composite primary key, which is the
-- easy one to miss: `player_equipped (player_id, slot)` indexes player_id
-- because it leads the key, and indexes `slot` not at all.
--
-- Forward-only. Do not edit once applied.

CREATE INDEX forge_reactions_path_b_idx   ON forge_reactions (path_b);
CREATE INDEX player_equipment_path_idx    ON player_equipment (path_code);
CREATE INDEX player_equipment_tier_idx    ON player_equipment (tier);
CREATE INDEX player_equipped_slot_idx     ON player_equipped (slot);
