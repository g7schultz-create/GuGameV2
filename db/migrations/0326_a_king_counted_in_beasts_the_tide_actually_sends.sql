-- 0326_a_king_counted_in_beasts_the_tide_actually_sends
--
-- The Sovereign Nine-Tail Fox that stood over the western tide on 11 Sep 2026
-- rose holding about eighty billion health and walked off thirty minutes
-- later still on thirteen and a half. clearwest and pashu0 put 2,333,396,993
-- into it between them and moved it seventeen percent.
--
-- `horde_king_rise` takes the greater of two numbers, and the wrong one won:
--
--     the room     boss_hp_pool x horde_king_effort x rank step   3,259,362,311
--     the region   avg(base_hp) x horde_world_scale x 1000       80,427,499,636
--
-- THE REGION FLOOR IS COUNTING BEASTS THAT ALMOST NEVER COME. It is meant to
-- read 'a thousand of the beasts this tide is made of', and it takes a plain
-- average over the region's roster. Western's roster, by draw weight:
--
--     rank 1, 211-341 hp, weight 10 each   98.5% of every spawn
--     Nine-Lined Tiger      18,400 hp       0.9%
--     Stone Sinew Ape      295,000 hp       0.5%
--     Sovereign Nine-Tail Fox  8.9M hp      0.1%
--
-- The plain average is 837,786. The median is 317. Three beasts that together
-- are one and a half percent of spawns carry ninety-eight percent of that
-- mean, so the floor counts a thousand beasts the tide will essentially never
-- send. 0314 and 0315 are what did it - putting rank 3 to 9 creatures into
-- the regional rosters was right for the hunt, and it quietly multiplied
-- every King's floor by somewhere between 24 and 71.
--
--     region     plain avg   draw-weighted   overstated by
--     eastern     1,034,484          21,867           47.3x
--     western       837,786          11,755           71.3x
--     southern      391,251          10,340           37.8x
--     central       152,605           6,076           25.1x
--     northern      114,361           4,704           24.3x
--
-- So the average becomes the DRAW-WEIGHTED one, which is what 'the beasts
-- this tide is made of' has always meant - `horde_spawn` picks by
-- `cr.weight`, so weighting by it is simply reading the same roster the same
-- way. No dial moves; the arithmetic starts describing the tide.
--
-- The floors land at 452 million to 2.1 billion, all at or under the
-- room-measured 3.26 billion - which is the floor doing its actual job of
-- catching a thin room rather than overruling a full one.
--
-- WHY THE RESIZE DID NOT SAVE IT. `horde_king_resize_if_due` carries no floor
-- at all - it steps toward the room measure alone, at `boss_resize_step` a
-- time. It was working: eighty billion down to thirteen and a half in thirty
-- minutes is six steps in the right direction. It ran out of King. Starting
-- from a number that needs eleven steps to become reasonable is not something
-- a resize can fix inside the life of the thing being resized.
--
-- `horde_beast_worth` reads the same plain average and feeds the chest bars.
-- It is NOT touched here: it sets what a reward costs rather than what a
-- fight holds, and making three chests between twenty-four and seventy times
-- cheaper is not a difficulty fix. Flagged, deliberately left.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'            COALESCE((SELECT avg(cs.base_hp)', chr(10),
'                      FROM creature_regions cr', chr(10),
'                      JOIN creature_species cs ON cs.species_id = cr.species_id', chr(10),
'                      WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),', chr(10),
'                     600)');

    swap := concat(
'            -- Weighted the way `horde_spawn` draws, so this is the health of', chr(10),
'            -- the beast the tide will actually send rather than of a rank 9', chr(10),
'            -- creature that turns up one spawn in a thousand. A plain', chr(10),
'            -- average over western reads 837,786 against a median of 317.', chr(10),
'            COALESCE((SELECT sum(cs.base_hp * cr.weight) / NULLIF(sum(cr.weight), 0)', chr(10),
'                      FROM creature_regions cr', chr(10),
'                      JOIN creature_species cs ON cs.species_id = cr.species_id', chr(10),
'                      WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),', chr(10),
'                     600)');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_king_rise';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the King no longer counts its floor where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The floor catches a thin room; it does not overrule a full one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad   TEXT;
    fox   BIGINT;
    room  BIGINT;
    floor_w NUMERIC;
BEGIN
    -- In every region, the draw-weighted beast must be the one the tide is
    -- made of - within an order of magnitude of the MEDIAN spawn rather than
    -- of the rarest giant in the roster.
    SELECT string_agg(t.region_code || ' (weighted ' || round(t.w)
                      || ' vs median ' || t.med || ')', ', ')
    INTO bad
    FROM (
        SELECT cr.region_code,
               sum(cs.base_hp * cr.weight) / NULLIF(sum(cr.weight), 0) AS w,
               (percentile_cont(0.5) WITHIN GROUP (ORDER BY cs.base_hp))::bigint AS med
        FROM creature_regions cr
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cs.kind = 'beast'
        GROUP BY cr.region_code
    ) t
    WHERE t.w > t.med * 100;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'the weighted beast is still a giant rather than a spawn: %', bad;
    END IF;

    -- And against the room that just fought one: the floor must no longer be
    -- the number that wins. Measured on western, where it was worst.
    SELECT species_id INTO fox FROM creature_species WHERE code = 'sovereign_ninetail_fox';

    SELECT sum(cs.base_hp * cr.weight) / NULLIF(sum(cr.weight), 0) INTO floor_w
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'western' AND cs.kind = 'beast';

    room := round(boss_hp_pool(fox)
                  * game_config_value('horde_king_effort')
                  * (1 + game_config_value('horde_king_rank_step') * 4))::bigint;

    -- horde_world_scale for a rank 5 tide with one hand: (1 + 5*0.6) * (18 + 6).
    IF room > 0 AND floor_w * 96 * game_config_value('horde_king_beasts') > room THEN
        RAISE EXCEPTION
            'the western floor is % and the room asks % - the floor still overrules',
            round(floor_w * 96 * game_config_value('horde_king_beasts')), room;
    END IF;

    RAISE NOTICE 'western floor now %, room asks % - the room decides',
        round(floor_w * 96 * game_config_value('horde_king_beasts')), room;
END;
$probe$;
