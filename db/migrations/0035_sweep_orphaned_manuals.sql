-- 0035_sweep_orphaned_manuals
--
-- 0034's collector fires on DELETE, so it cleans up from here forward. It says
-- nothing about the manuals that were already orphaned: books whose maker's
-- account went away while `created_by` was still the thing keeping them alive.
--
-- Same predicate as the trigger, applied once to what is already here. Seeded
-- content has a code and is never touched.
--
-- Forward-only. Do not edit once applied.

DELETE FROM manuals m
WHERE m.code IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM player_manuals pm WHERE pm.manual_id = m.manual_id
  );
