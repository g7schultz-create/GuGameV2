-- 0572_a_rogue_carries_the_notes_too
--
-- Ancient Venerable Notes off a rogue cultivator, as asked - and it turns out
-- the schema was already asking for the same thing.
--
-- `test_every_material_says_where_it_comes_from` failed the moment 0570 added
-- the material:
--
--     'A recipe naming something the world does not drop is a recipe nobody
--      can fill.'
--
-- The notes DO drop - from exploring and from the deepest rooms - but both of
-- those are code paths inside a function, and `material_sources` reads tables:
-- `region_materials`, `region_veins`, `creature_drops`. So as far as anything
-- that can be asked was concerned, the notes came from nowhere.
--
-- This is the same hole essence sat in, and it was closed the same way. The
-- test says so itself:
--
--     'Essence used to be carved out of the rule above. 0334 built the
--      immortal ladder and deliberately left the fuel undroppable... 0359 is
--      that day: rogue immortals walk both heavens carrying their own realm's
--      essence, so the ordinary rule covers essence now.'
--
-- A rogue immortal is somebody who walked this ladder and came off it. That
-- they are carrying a dead Venerable's working notes is the most natural thing
-- in the world, and it makes the item findable by a reader rather than only by
-- somebody who happens to run the right function.
--
-- WHICH ROGUES: the ones standing above the realm ladder. A Dewberry rogue has
-- no business holding the notes of somebody who crossed out of the realms
-- entirely, and gating it high keeps the notes where the people who can read
-- them are hunting.


-- `creature_drops` carries a trigger that admits beast parts, and essence as
-- a named exception gated on the creature being an immortal. The notes are a
-- third thing a deep cultivator carries, so they are named the same way rather
-- than by loosening the rule to "anything an immortal holds" - which would
-- open the drop table to all 279 gathering materials.
DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'check_drop_is_beast_material'
      AND pronamespace = 'public'::regnamespace;

    IF position('    IF kind_of = ''essence'' THEN' IN src) = 0 THEN
        RAISE EXCEPTION 'the drop guard does not name essence where it did';
    END IF;

    patched := replace(src,
        '    IF kind_of = ''essence'' THEN',
        '    -- Essence, and the notes a dead Venerable left behind. Both are
    -- carried rather than cut off a corpse, and both are gated the same way
    -- below: only somebody who climbed the ladder is holding one.
    IF kind_of = ''essence''
       OR NEW.material_code = ''ancient_venerable_notes'' THEN');

    IF patched = src THEN
        RAISE EXCEPTION 'the drop guard patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, 'ancient_venerable_notes', 0.12, 1, 1
FROM creature_species cs
WHERE cs.kind = 'rogue'
  -- The deepest rogues in the world. `immortal_rank` runs past the realm
  -- ladder for these, which is how a rogue is placed at all.
  AND cs.immortal_rank >= (SELECT max(r.rank) - 2 FROM realms r)
  AND NOT EXISTS (
      SELECT 1 FROM creature_drops d
      WHERE d.species_id = cs.species_id
        AND d.material_code = 'ancient_venerable_notes');


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_lo   SMALLINT;
    v_src  INTEGER;
BEGIN
    -- 1. SOMEBODY CARRIES THEM, and it is a rogue.
    SELECT count(*) INTO v_n
    FROM creature_drops d JOIN creature_species cs ON cs.species_id = d.species_id
    WHERE d.material_code = 'ancient_venerable_notes';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'no creature in the world carries the notes';
    END IF;

    IF EXISTS (
        SELECT 1 FROM creature_drops d
        JOIN creature_species cs ON cs.species_id = d.species_id
        WHERE d.material_code = 'ancient_venerable_notes' AND cs.kind <> 'rogue'
    ) THEN
        RAISE EXCEPTION 'something that is not a rogue is carrying the notes';
    END IF;

    -- 2. AND ONLY THE DEEP ONES. A shallow rogue holding a Venerable's working
    --    papers is the wrong picture and the wrong place.
    SELECT min(cs.immortal_rank) INTO v_lo
    FROM creature_drops d JOIN creature_species cs ON cs.species_id = d.species_id
    WHERE d.material_code = 'ancient_venerable_notes';

    IF v_lo < (SELECT max(r.rank) - 2 FROM realms r) THEN
        RAISE EXCEPTION
            'a rank % rogue is carrying them, and the floor is %',
            v_lo, (SELECT max(r.rank) - 2 FROM realms r);
    END IF;

    RAISE NOTICE
        '% rogue(s) carry the notes, the shallowest at immortal rank %',
        v_n, v_lo;

    -- 3. AND THE WORLD CAN NOW SAY WHERE THEY COME FROM, which is the guard
    --    that caught this - `material_sources` reads tables, and until now the
    --    only two ways to get them lived inside functions.
    SELECT count(*) INTO v_src FROM material_sources('ancient_venerable_notes');
    IF v_src = 0 THEN
        RAISE EXCEPTION
            'the notes still come from nowhere that can be asked';
    END IF;
    RAISE NOTICE '`material_sources` now names % place(s) to find them', v_src;
END
$probe$;
