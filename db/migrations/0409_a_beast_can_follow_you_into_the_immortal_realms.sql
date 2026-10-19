-- 0409_a_beast_can_follow_you_into_the_immortal_realms
--
-- A beast's ladder ends at Elder. Twenty-one of the thirty-four hatched beasts
-- on the server are already standing on it with nothing left to eat, and the
-- error they get says so plainly: 'an elder has nothing left to grow into'.
-- Meanwhile their owners went on climbing, and a pet that stopped at Elder
-- while its cultivator crossed into the immortal realms is a pet that quietly
-- stopped mattering.
--
-- So the ladder gets nine more rungs, one for each immortal rank, named for
-- the same fruits the realms are: Dewberry through Yellow Apricot. And the
-- thing that carries a beast up them is the thing that carries its owner -
-- immortal essence.
--
-- WHAT IT COSTS. Each rung costs thirty times its rank's essence value, per
-- tier of beast. A tier 9 beast therefore needs 270 of the matching essence
-- for each rung, whichever rung it is on - the cost tracks the essence ladder
-- rather than sitting still beside it, which is the mistake 0382, 0396, 0397
-- and 0398 each had to come back and undo. Lower essence still works and
-- simply takes proportionally more of it, so a hoard of Dewberry is not
-- worthless at rank 14, merely inefficient.
--
-- WHY THIS CANNOT RUN AWAY. It cannot, and the guard was already there before
-- this migration: `player_swing` clamps a beast's contribution to
-- `pet_share_cap` - a quarter - of the blow its owner just landed, and
-- `pet_max_hp` clamps its body to `pet_hp_cap` of its owner's. Both ceilings
-- are RELATIVE to the cultivator. A beast raised past its owner is not a
-- problem to be gated; it is simply a beast that gets no use out of the
-- height. That is also why there is no check here that a beast may not out-
-- rank its owner: it would be a rule against something that already does
-- nothing. What these rungs actually buy is the room to REACH that quarter,
-- which at Elder the deepest pet on the server is nowhere near.
--
-- WHAT THE FOOD MAY BE, WHICH IS THE PART THAT WOULD HAVE BROKEN. All three
-- feeding routes - ore and parts, cultivation pills, and rendering one beast
-- into another - share a single check:
--
--     IF beast_feed_needed(p_beast_id) IS NULL THEN
--         RAISE EXCEPTION 'an elder has nothing left to grow into';
--
-- That check is the ONLY thing that was stopping them, and it stops meaning
-- anything the moment Elder has somewhere to go. Left alone, this migration
-- would have handed the immortal realms to whoever had the most iron ore. So
-- each rung now says what it eats, and all three routes are made to ask.
-- Ore, bone and pills raise a beast to Elder. Essence is the only thing that
-- carries it past.
--
-- `feed_per_tier` becomes BIGINT because Yellow Apricot essence is worth
-- 243,000,000 a unit and thirty of those is past what an integer holds.
--
-- AND THE FOOD ALREADY BANKED, which the probe below caught and which would
-- have given the whole thing away. An elder goes on ACCEPTING food it cannot
-- spend - `beast_grow` adds to `fed` first and only then looks for a rung to
-- buy - so the elders on this server are sitting on pools of it. One of them
-- holds 12,260 points, paid in ore, which is four immortal rungs bought
-- outright the instant those rungs exist. That is precisely the rule this
-- migration is making, broken by the migration making it.
--
-- So every elder's banked pool is cleared here, once. Nothing is taken that
-- could ever have been spent: above Elder there was nothing to buy, and
-- `beast_grow` exits on a NULL `want` without touching it. After this the
-- pool stays honest on its own, because `feed_beast` now refuses ore at Elder
-- and refuses essence below it - the two currencies cannot mix again.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE beast_stages ALTER COLUMN feed_per_tier TYPE BIGINT;

ALTER TABLE beast_stages
    ADD COLUMN needs_essence BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN beast_stages.needs_essence IS
    'Whether reaching this stage takes immortal essence rather than ore, bone or a pill. The three feed_beast functions all ask, because the elder check that used to stop them stopped meaning anything in 0409.';


-- ---------------------------------------------------------------------------
-- Nine rungs, named for the realms they answer
-- ---------------------------------------------------------------------------

INSERT INTO beast_stages (code, name, sort_order, power, feed_per_tier, needs_essence)
VALUES
    ('dewberry',         'Dewberry Immortal',         5,  2.40,          30, TRUE),
    ('jade_plum',        'Jade Plum Immortal',        6,  3.60,          90, TRUE),
    ('purple_mulberry',  'Purple Mulberry Immortal',  7,  5.40,         270, TRUE),
    ('golden_peach',     'Golden Peach Immortal',     8,  8.10,         810, TRUE),
    ('blood_cherry',     'Blood Cherry Immortal',     9, 12.15,        2430, TRUE),
    ('green_grape',      'Green Grape Immortal',     10, 18.23,        7290, TRUE),
    ('red_date',         'Red Date Immortal',        11, 27.34,      729000, TRUE),
    ('white_litchi',     'White Litchi Immortal',    12, 41.01,    72900000, TRUE),
    ('yellow_apricot',   'Yellow Apricot Immortal',  13, 61.51,  7290000000, TRUE);


-- Ore bought this, and ore does not buy immortal rungs. See the header.
UPDATE player_beasts SET fed = 0 WHERE stage = 'elder' AND fed > 0;


-- ---------------------------------------------------------------------------
-- A beast will eat essence, and knows when it must
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION beast_food_value(p_material_code text)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Ore by its tier, anything off a beast by its grade. Squared, the way
    -- the forge prices what goes on its anvil. Immortal essence by what the
    -- essence itself is worth, which is the same number `absorb_essence`
    -- reads - a mouthful is a mouthful whoever swallows it.
    SELECT CASE
        WHEN o.material_code  IS NOT NULL THEN o.tier::numeric ^ 2
        WHEN bp.material_code IS NOT NULL THEN material_grade(m.rarity)::numeric ^ 2
        WHEN ie.material_code IS NOT NULL THEN ie.unit_value::numeric
        ELSE 0
    END
    FROM materials m
    LEFT JOIN ores o ON o.material_code = m.code
    LEFT JOIN beast_parts bp ON bp.material_code = m.code
    LEFT JOIN immortal_essences ie ON ie.material_code = m.code
    WHERE m.code = p_material_code;
$$;


CREATE FUNCTION beast_food_is_essence(p_material_code text)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM immortal_essences ie
                   WHERE ie.material_code = p_material_code);
$$;


CREATE FUNCTION beast_needs_essence(p_beast_id bigint)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    -- Whether the NEXT rung takes essence. NULL at the end of the ladder,
    -- where the caller's own 'nothing left to grow into' answers first.
    SELECT next.needs_essence
    FROM player_beasts b
    JOIN beast_stages here ON here.code = b.stage
    JOIN beast_stages next ON next.sort_order = here.sort_order + 1
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION beast_needs_essence(bigint) IS
    'Whether this beast''s next stage is an immortal one. Asked by every feeding route, because the elder check they all shared stopped being a wall in 0409.';


-- ---------------------------------------------------------------------------
-- And the three routes stop being interchangeable
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    elder  TEXT;
BEGIN
    elder := concat(
'    IF beast_feed_needed(p_beast_id) IS NULL THEN', chr(10),
'        RAISE EXCEPTION ''an elder has nothing left to grow into''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;');

    -- ---- ore, bone and essence: the one route that may carry both ---------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'feed_beast';
    IF (length(body) - length(replace(body, elder, ''))) / length(elder) <> 1 THEN
        RAISE EXCEPTION 'feed_beast no longer holds the elder check once';
    END IF;

    anchor := concat(
'    worth := beast_food_value(p_material_code);', chr(10),
'    IF COALESCE(worth, 0) <= 0 THEN', chr(10),
'        RAISE EXCEPTION ''a beast will not eat that - ore and what comes off other beasts''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'feed_beast no longer prices its food where it did';
    END IF;

    body := replace(body, anchor, concat(
'    worth := beast_food_value(p_material_code);', chr(10),
'    IF COALESCE(worth, 0) <= 0 THEN', chr(10),
'        RAISE EXCEPTION ''a beast will not eat that - ore, what comes off other beasts, and immortal essence''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;', chr(10),
'', chr(10),
'    -- Which ladder the next rung is on. Before 0409 the elder check above', chr(10),
'    -- was the whole of this rule, and it stopped being a wall the moment', chr(10),
'    -- Elder had somewhere to go.', chr(10),
'    IF beast_needs_essence(p_beast_id)', chr(10),
'       AND NOT beast_food_is_essence(p_material_code) THEN', chr(10),
'        RAISE EXCEPTION ''ore and bone raise a beast to its elder years - past those it takes immortal essence''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;', chr(10),
'    IF NOT beast_needs_essence(p_beast_id)', chr(10),
'       AND beast_food_is_essence(p_material_code) THEN', chr(10),
'        RAISE EXCEPTION ''save the essence - this one still grows on ore and bone''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;'));

    EXECUTE body;

    -- ---- a pill will not do it -------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'feed_beast_pill';
    IF (length(body) - length(replace(body, elder, ''))) / length(elder) <> 1 THEN
        RAISE EXCEPTION 'feed_beast_pill no longer holds the elder check once';
    END IF;
    EXECUTE replace(body, elder, concat(elder, chr(10), chr(10),
'    IF beast_needs_essence(p_beast_id) THEN', chr(10),
'        RAISE EXCEPTION ''a pill will not carry a beast past its elder years - that takes immortal essence''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;'));

    -- ---- nor will another beast ------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'feed_beast_beast';
    IF (length(body) - length(replace(body, elder, ''))) / length(elder) <> 1 THEN
        RAISE EXCEPTION 'feed_beast_beast no longer holds the elder check once';
    END IF;
    EXECUTE replace(body, elder, concat(elder, chr(10), chr(10),
'    IF beast_needs_essence(p_beast_id) THEN', chr(10),
'        RAISE EXCEPTION ''another beast will not carry this one past its elder years - that takes immortal essence''', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- An elder has somewhere to go, and only one thing gets it there
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_beast BIGINT;
    v_owner BIGINT;
    v_tier  SMALLINT;
    v_stage TEXT;
    v_want  NUMERIC;
    v_got   TEXT;
    r       RECORD;
BEGIN
    IF (SELECT count(*) FROM beast_stages WHERE needs_essence) <> 9 THEN
        RAISE EXCEPTION 'the immortal rungs are not all there';
    END IF;

    -- Every rung reachable, in one unbroken run of sort_order.
    IF EXISTS (
        SELECT 1 FROM beast_stages s
        WHERE s.sort_order > 1
          AND NOT EXISTS (SELECT 1 FROM beast_stages p
                          WHERE p.sort_order = s.sort_order - 1)
    ) THEN
        RAISE EXCEPTION 'the stage ladder has a gap in it';
    END IF;

    -- A beast will now eat essence, and the larder screen finds it by this.
    IF (SELECT count(*) FROM immortal_essences ie
        WHERE beast_food_value(ie.material_code) > 0) <> 9 THEN
        RAISE EXCEPTION 'a beast still will not eat some essence';
    END IF;

    -- ---- and it actually works, on an elder that is rolled back ----------
    BEGIN
        SELECT b.beast_id, b.owner_id, b.tier INTO v_beast, v_owner, v_tier
        FROM player_beasts b WHERE b.stage = 'elder' ORDER BY b.tier DESC LIMIT 1;
        IF v_beast IS NULL THEN
            RAISE EXCEPTION 'probe-ok';       -- nothing to try it on, fine
        END IF;

        v_want := beast_feed_needed(v_beast);
        IF v_want IS NULL THEN
            RAISE EXCEPTION 'an elder still has nowhere to go';
        END IF;

        -- Ore must now bounce off it.
        BEGIN
            PERFORM grant_material(v_owner, 'iron_ore', 100000);
            PERFORM feed_beast(v_owner, v_beast, 'iron_ore', 100000);
            RAISE EXCEPTION 'iron ore carried an elder into the immortal realms';
        EXCEPTION WHEN check_violation THEN
            NULL;                              -- which is the point
        END;

        -- Essence must not.
        PERFORM grant_material(v_owner, 'dewberry_essence',
                               ceil(v_want)::bigint);
        SELECT grew_to INTO v_got
        FROM feed_beast(v_owner, v_beast, 'dewberry_essence',
                        ceil(v_want)::integer);
        IF v_got IS DISTINCT FROM 'dewberry' THEN
            RAISE EXCEPTION 'essence took the elder to % rather than Dewberry',
                COALESCE(v_got, 'nowhere');
        END IF;

        RAISE NOTICE
            'a tier % elder crossed on % Dewberry essence', v_tier, ceil(v_want);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT s.name, s.power, s.feed_per_tier,
               s.feed_per_tier * 9 AS a_tier_nine_pays
        FROM beast_stages s WHERE s.needs_essence ORDER BY s.sort_order
    LOOP
        RAISE NOTICE '% : power %, a tier 9 pays %',
            rpad(r.name, 24), r.power, r.a_tier_nine_pays;
    END LOOP;

    RAISE NOTICE '% elders now have somewhere to go',
        (SELECT count(*) FROM player_beasts WHERE stage = 'elder');
END;
$probe$;
