-- 0337_black_heaven_and_the_door_that_keeps_mortals_out
--
-- A sixth region, and the first one that is not reached by walking further.
-- Black Heaven is pitch dark, full of primeval soul beasts, and closed to
-- anybody who has not finished the mortal ladder.
--
-- THE GATE IS A COLUMN, NOT A SPECIAL CASE. `regions.min_rank` is the rank a
-- cultivator must hold to set foot there, and it defaults to 1 - so the five
-- mortal regions are untouched by a column they now carry. Black Heaven asks
-- for 10. White Heaven, the blessed lands and wherever else stands outside
-- the mortal world will each be one row and no new code.
--
-- IT IS ENFORCED IN `begin_travel`, which is the one place a journey starts.
-- Putting it on the screen instead would be a lock on the door handle and not
-- on the door: the travel picker is a view, views time out and get re-used,
-- and a refusal that only exists in Python is a refusal that a second client
-- walks straight past.
--
-- THE ROUTES ARE TWELVE HOURS FROM EVERYWHERE. The five mortal regions sit
-- two to six hours apart because they are all one continent. Black Heaven is
-- not on it, so the distance from any of them is the same distance - the
-- crossing itself, rather than the ground covered before it. `travel_hours`
-- raises on a missing route rather than assuming one, so every pair has to be
-- written down or the picker breaks the moment somebody opens it.
--
-- WHAT IS NOT HERE YET. The forty materials, the fifteen beasts, the region
-- boss and the hundred and sixty-six Gu that belong in this place are the
-- migrations after this one. This one is the map and the door.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE regions
    ADD COLUMN min_rank SMALLINT NOT NULL DEFAULT 1;

ALTER TABLE regions ADD CONSTRAINT regions_min_rank_check
    CHECK (min_rank >= 1 AND min_rank <= 18);

COMMENT ON COLUMN regions.min_rank IS
    'The cultivation rank needed to travel here. 1 for the mortal world; 10 and up for the heavens.';


INSERT INTO regions (code, name, danger_level, description, emoji, sort_order, min_rank)
VALUES (
    'black_heaven', 'Black Heaven', 6,
    'A realm of pitch black darkness filled with primeval soul beasts. '
    'Demonic cultivators keep what order there is, and Spectral Soul''s '
    'legacy lies somewhere under it.',
    '🌑', 60, 10
);


-- `travel_hours` reads the pair as (LEAST, GREATEST), and 'black_heaven'
-- sorts before all five, so it is always the origin.
INSERT INTO region_routes (origin, destination, travel_hours)
SELECT 'black_heaven', r.code, 12.00
FROM regions r WHERE r.code <> 'black_heaven';


-- ---------------------------------------------------------------------------
-- The door
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    IF here.region_code = p_destination THEN', chr(10),
'        RAISE EXCEPTION ''already in %'', p_destination', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;');

    swap := concat(
anchor, chr(10),
chr(10),
'    -- Some places are not reached by walking further. Enforced here rather', chr(10),
'    -- than on the screen that offers them, because a journey can only start', chr(10),
'    -- in this function and a view cannot be trusted to be the only caller.', chr(10),
'    DECLARE', chr(10),
'        gate     SMALLINT;', chr(10),
'        standing SMALLINT;', chr(10),
'        needs    TEXT;', chr(10),
'    BEGIN', chr(10),
'        SELECT r.min_rank INTO gate FROM regions r WHERE r.code = p_destination;', chr(10),
'        IF gate IS NULL THEN', chr(10),
'            RAISE EXCEPTION ''there is no region called %'', p_destination', chr(10),
'                USING ERRCODE = ''check_violation'';', chr(10),
'        END IF;', chr(10),
chr(10),
'        IF gate > 1 THEN', chr(10),
'            SELECT rr.rank INTO standing', chr(10),
'            FROM player_cultivation pc', chr(10),
'            JOIN realms rr ON rr.realm_id = pc.realm_id', chr(10),
'            WHERE pc.player_id = p_player_id;', chr(10),
chr(10),
'            IF COALESCE(standing, 1) < gate THEN', chr(10),
'                SELECT min(rr.name) INTO needs', chr(10),
'                FROM realms rr WHERE rr.rank = gate;', chr(10),
'                RAISE EXCEPTION', chr(10),
'                    ''% is closed to you - it takes a cultivator of % to cross'',', chr(10),
'                    (SELECT r.name FROM regions r WHERE r.code = p_destination),', chr(10),
'                    COALESCE(needs, ''a higher realm'')', chr(10),
'                    USING ERRCODE = ''check_violation'';', chr(10),
'            END IF;', chr(10),
'        END IF;', chr(10),
'    END;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'begin_travel';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'begin_travel no longer refuses a journey where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Reachable from everywhere, and only by those who may
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    missing TEXT;
    mortal  BIGINT;
    saw     TEXT;
BEGIN
    -- Every pair has a route, or the travel screen raises the moment it is
    -- opened by somebody standing in the wrong place.
    SELECT string_agg(a.code || '/' || b.code, ', ') INTO missing
    FROM regions a CROSS JOIN regions b
    WHERE a.code < b.code
      AND NOT EXISTS (SELECT 1 FROM region_routes rr
                      WHERE rr.origin = a.code AND rr.destination = b.code);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'no route between: %', missing;
    END IF;

    -- A mortal is turned away...
    SELECT pc.player_id INTO mortal
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    JOIN players p ON p.player_id = pc.player_id
    WHERE r.rank < 10 AND p.deleted_at IS NULL
    LIMIT 1;

    IF mortal IS NOT NULL THEN
        BEGIN
            PERFORM begin_travel(mortal, 'black_heaven');
            RAISE EXCEPTION 'a mortal walked into Black Heaven';
        EXCEPTION WHEN check_violation THEN
            saw := SQLERRM;
        END;
        IF saw NOT LIKE '%closed to you%' THEN
            RAISE EXCEPTION 'the refusal was not the gate: %', saw;
        END IF;
        RAISE NOTICE 'a mortal is told: %', saw;
    END IF;

    -- ...and the mortal world is still open to everybody.
    IF EXISTS (SELECT 1 FROM regions WHERE code <> 'black_heaven' AND min_rank > 1) THEN
        RAISE EXCEPTION 'a mortal region grew a gate';
    END IF;
END;
$probe$;
