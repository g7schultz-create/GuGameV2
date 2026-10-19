-- 0410_the_wall_belongs_inside_the_loop_that_climbs
--
-- 0409 put its rule at the door of `feed_beast`: if the next rung takes
-- essence, what you are holding had better be essence. That check is asked
-- ONCE, against the stage the beast is standing on when the meal starts.
--
-- `beast_grow` then adds the whole meal to the pool and climbs in a loop, one
-- rung per pass, for as long as the pool can pay - and it has never known nor
-- cared what it was fed. So the door was asked about an adult, and the loop
-- walked that adult past Elder and up the immortal ladder on the same pile of
-- iron ore:
--
--     feed_beast(adult, 'iron_ore', 100000)
--       -> ended at Green Grape Immortal, 66,520 still banked
--
-- Rank fifteen, for ore, because the beast was not yet an elder at the moment
-- somebody asked. 0409 cleared the pools that already existed and wrote a rule
-- about what may be eaten, and then handed the ladder away through the loop
-- underneath it. The rule was right; it was standing in the wrong place.
--
-- So `beast_grow` learns what it is being fed, and the wall moves inside the
-- loop where the climbing actually happens. The door check in `feed_beast`
-- stays - it is what produces a sentence a player can read, rather than a
-- meal that silently does less than they expected.
--
-- WHAT HAPPENS TO THE LEFTOVER. It is discarded, and this is deliberate. A
-- pool is spent by whatever comes next, so ore left banked at the foot of the
-- immortal ladder is ore waiting for essence to spend it - which is the same
-- hole 0409 had to clear by hand for the elders that already existed. Before
-- 0409 that overflow was dead anyway: Elder was the end of the ladder and
-- `beast_grow` exited on a NULL `want` without touching the pool. So nothing
-- is taken here that was worth anything a week ago.
--
-- `beast_grow` gains a third argument rather than a second function, and it
-- defaults to FALSE - so `feed_beast_pill` and `feed_beast_beast`, which have
-- no business carrying anything past Elder, are safe without being edited.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION beast_grow(bigint, numeric);

CREATE FUNCTION beast_grow(
    p_beast_id     bigint,
    p_nourishment  numeric,
    p_is_essence   boolean DEFAULT FALSE
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    want  NUMERIC;
    grown TEXT := NULL;
BEGIN
    IF p_nourishment <= 0 THEN
        RETURN NULL;
    END IF;

    UPDATE player_beasts SET fed = fed + p_nourishment WHERE beast_id = p_beast_id;

    -- A generous meal may carry it through more than one stage, so this is a
    -- loop rather than one comparison.
    LOOP
        want := beast_feed_needed(p_beast_id);
        EXIT WHEN want IS NULL;                    -- the end of the ladder

        -- The wall, which since 0410 stands here rather than only at the door.
        -- Asked once outside the loop it was answered about the stage the
        -- beast started on, and a large enough meal simply walked past it.
        IF beast_needs_essence(p_beast_id) AND NOT p_is_essence THEN
            -- And the leftover goes. A pool is spent by whatever comes next,
            -- so ore banked at the foot of the immortal ladder is ore waiting
            -- for essence to spend it.
            UPDATE player_beasts SET fed = 0 WHERE beast_id = p_beast_id;
            EXIT;
        END IF;

        EXIT WHEN (SELECT fed FROM player_beasts WHERE beast_id = p_beast_id) < want;

        UPDATE player_beasts b
        SET stage = (SELECT n.code FROM beast_stages n
                     JOIN beast_stages h ON h.code = b.stage
                     WHERE n.sort_order = h.sort_order + 1),
            fed = b.fed - want
        WHERE b.beast_id = p_beast_id
        RETURNING b.stage INTO grown;
    END LOOP;

    -- The new body is the whole point of the stage.
    IF grown IS NOT NULL THEN
        UPDATE player_beasts SET hp = NULL WHERE beast_id = p_beast_id;
    END IF;

    RETURN grown;
END;
$$;

COMMENT ON FUNCTION beast_grow(bigint, numeric, boolean) IS
    'Adds a meal to a beast and climbs as many rungs as it pays for. Refuses to cross an immortal rung on anything but essence, and drops what is left at that wall so the pool cannot be spent later by something it did not come from.';


-- ---------------------------------------------------------------------------
-- The one caller that may say yes
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'feed_beast';
    IF body IS NULL THEN
        RAISE EXCEPTION 'feed_beast is missing';
    END IF;

    anchor := '    grown := beast_grow(p_beast_id, worth * p_quantity);';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'feed_beast no longer grows its beast where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- Since 0410 the loop is told what it is eating, because the door check', chr(10),
'    -- above can only speak for the rung the beast was standing on.', chr(10),
'    grown := beast_grow(p_beast_id, worth * p_quantity,', chr(10),
'                        beast_food_is_essence(p_material_code));'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A mountain of ore stops at Elder, whatever it was standing on when it began
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_owner BIGINT;
    v_beast BIGINT;
    v_stage TEXT;
    v_fed   NUMERIC;
    v_want  NUMERIC;
    v_grew  TEXT;
BEGIN
    -- Only `feed_beast` may pass TRUE. The other two must not have learned to.
    IF EXISTS (
        SELECT 1 FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND proname IN ('feed_beast_pill', 'feed_beast_beast')
          AND prosrc LIKE '%beast_grow(%TRUE%'
    ) THEN
        RAISE EXCEPTION 'a route that should never cross the wall can';
    END IF;

    BEGIN
        SELECT b.beast_id, b.owner_id INTO v_beast, v_owner
        FROM player_beasts b WHERE b.stage = 'baby' ORDER BY b.tier LIMIT 1;
        IF v_beast IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Start it low, so the door check is asked about a beast that is
        -- nowhere near Elder - which is exactly how 0409 was walked past.
        UPDATE player_beasts SET stage = 'adult', fed = 0 WHERE beast_id = v_beast;

        PERFORM grant_material(v_owner, 'iron_ore', 1000000);
        PERFORM feed_beast(v_owner, v_beast, 'iron_ore', 1000000);

        SELECT b.stage, b.fed INTO v_stage, v_fed
        FROM player_beasts b WHERE b.beast_id = v_beast;

        IF v_stage <> 'elder' THEN
            RAISE EXCEPTION 'a million ore carried an adult to %', v_stage;
        END IF;
        IF v_fed <> 0 THEN
            RAISE EXCEPTION
                'ore is still banked at the foot of the ladder: %', v_fed;
        END IF;

        -- And essence still works from there.
        v_want := beast_feed_needed(v_beast);
        PERFORM grant_material(v_owner, 'dewberry_essence', ceil(v_want)::bigint);
        SELECT grew_to INTO v_grew
        FROM feed_beast(v_owner, v_beast, 'dewberry_essence', ceil(v_want)::integer);
        IF v_grew IS DISTINCT FROM 'dewberry' THEN
            RAISE EXCEPTION 'essence took it to % rather than Dewberry',
                COALESCE(v_grew, 'nowhere');
        END IF;

        RAISE NOTICE
            'a million ore stopped at Elder with nothing banked; % essence crossed',
            ceil(v_want);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'the wall is inside the loop that climbs';
END;
$probe$;
