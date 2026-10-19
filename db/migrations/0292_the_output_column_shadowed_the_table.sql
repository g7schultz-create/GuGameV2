-- 0292_the_output_column_shadowed_the_table
--
-- `resize_world_if_due` could not run at all. It declares `encounter_id` as
-- an output column of its RETURNS TABLE, and plpgsql puts those names in
-- scope for the whole body - so
--
--     FOR r IN SELECT encounter_id FROM boss_encounters WHERE status = 'active'
--
-- is ambiguous between the output column and the table's own, and Postgres
-- refuses it rather than guessing. It failed the first time it was called.
--
-- The validation blocks in 0291 did not catch this because they exercise
-- `boss_resize_if_due` directly, which is where the interesting logic lives.
-- Nothing called the wrapper that walks the encounters, so nothing found the
-- one line in it that could not compile.
--
-- Every table column in the body is aliased now, which is the fix and also
-- the habit: an output column named after a table column is a trap that only
-- springs at runtime.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION resize_world_if_due()
RETURNS TABLE (what TEXT, encounter_id BIGINT, now_holds BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    r    RECORD;
    made BIGINT;
BEGIN
    -- One call the clock can make. Both halves are throttled in SQL, so this
    -- is a timestamp comparison on a quiet tick and a real measure every
    -- twenty minutes.
    FOR r IN SELECT b.encounter_id AS eid
             FROM boss_encounters b WHERE b.status = 'active'
    LOOP
        made := boss_resize_if_due(r.eid);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'world beast'::text, r.eid, made;
        END IF;
    END LOOP;

    FOR r IN SELECT e.encounter_id AS eid
             FROM horde_encounters e
             WHERE e.kind = 'king' AND e.status = 'alive'
    LOOP
        made := horde_king_resize_if_due(r.eid);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'king'::text, r.eid, made;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION resize_world_if_due() IS
    'Re-measures every standing world beast and King against the room. Safe to call often; it throttles itself.';


-- ---------------------------------------------------------------------------
-- It runs, which is the whole of what was wrong
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    n INTEGER;
BEGIN
    -- Calling it is the test. It returns nothing when nothing is due, and
    -- that is a pass - the failure this fixes was that it could not execute.
    SELECT count(*) INTO n FROM resize_world_if_due();
    RAISE NOTICE 'the world measured cleanly, % thing(s) moved', n;

    -- And twice, because the second call takes the throttled path through
    -- both loops rather than the resizing one.
    PERFORM resize_world_if_due();
END;
$$;
