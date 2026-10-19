-- 0475_the_deep_places_hold_things_worth_meeting
--
-- 0474 made a carcass worth butchering. What it could not fix is WHICH
-- carcass, because `delve_meet` draws a species by the region's own weight
-- and the tables behind those species are nothing like each other:
--
--     Stone Sinew Ape   6 entries, worth 16.65 units a roll
--     Herb Thief        1 entry,   worth  0.35
--
-- Forty-seven times apart. A delve that puts a Herb Thief in your way is
-- asking for a fight, a quarter of your health and four rounds in exchange
-- for three Beast Blood, and the only honest answer to that fight is to back
-- away from it.
--
-- THE BESTIARY IS NOT THE PROBLEM TO SOLVE HERE. A Herb Thief having a thin
-- table is correct - it is a herb thief. What is wrong is a DELVE putting one
-- in front of somebody, because the deep places are supposed to hold the
-- things worth meeting.
--
-- SO THE DRAW IS WEIGHTED BY WHAT THE THING CARRIES, on top of the region's
-- own weight. A thin-table creature becomes rare down here rather than
-- impossible - the variety is worth keeping, and a delve that only ever
-- produced the richest beast in the region would be its own kind of flat.
--
-- A creature with no table at all is now skipped outright. There are none in
-- any region today; the join would simply have handed over an empty carcass.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION delve_table_worth(p_species_id bigint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- What one roll of this creature's table is worth, in units. The same
    -- reckoning the measurements in 0474 were made with.
    SELECT COALESCE(sum(cd.chance * (cd.min_quantity + cd.max_quantity) / 2.0), 0)
    FROM creature_drops cd WHERE cd.species_id = p_species_id;
$fn$;

COMMENT ON FUNCTION delve_table_worth(bigint) IS
    'What one roll of a creature''s drop table is worth. Used to weight what a delve puts in somebody''s way, so the deep places hold things worth the fight they cost.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_meet' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_meet is missing';
    END IF;

    anchor := concat(
'    SELECT cr.species_id INTO v_spec', chr(10),
'    FROM creature_regions cr', chr(10),
'    WHERE cr.region_code = d.region_code', chr(10),
'    ORDER BY -ln(random()) / GREATEST(0.0001, cr.weight)', chr(10),
'    LIMIT 1;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_meet no longer draws its creature where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- 0475: the region''''s own weight, leaned toward what the thing is', chr(10),
'    -- carrying. A delve asks for a fight and should offer something worth', chr(10),
'    -- having for it; a thin-table creature stays possible and becomes rare.', chr(10),
'    SELECT cr.species_id INTO v_spec', chr(10),
'    FROM creature_regions cr', chr(10),
'    WHERE cr.region_code = d.region_code', chr(10),
'      AND delve_table_worth(cr.species_id) > 0', chr(10),
'    ORDER BY -ln(random())', chr(10),
'             / GREATEST(0.0001, cr.weight * delve_table_worth(cr.species_id))', chr(10),
'    LIMIT 1;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- What a delve puts in your way is worth the fight
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_region TEXT;
    v_poor   NUMERIC;
    v_rich   NUMERIC;
    v_drawn  NUMERIC := 0;
    v_flat   NUMERIC := 0;
    v_spec   BIGINT;
    i        INTEGER;
BEGIN
    SELECT cr.region_code INTO v_region
    FROM creature_regions cr
    GROUP BY cr.region_code
    HAVING count(*) > 4
    ORDER BY cr.region_code LIMIT 1;
    IF v_region IS NULL THEN
        RAISE EXCEPTION 'probe-ok';
    END IF;

    SELECT min(delve_table_worth(cr.species_id)),
           max(delve_table_worth(cr.species_id))
    INTO v_poor, v_rich
    FROM creature_regions cr WHERE cr.region_code = v_region;

    -- The weighted draw, against the flat one it replaced.
    FOR i IN 1..300 LOOP
        SELECT cr.species_id INTO v_spec
        FROM creature_regions cr
        WHERE cr.region_code = v_region
          AND delve_table_worth(cr.species_id) > 0
        ORDER BY -ln(random())
                 / GREATEST(0.0001, cr.weight * delve_table_worth(cr.species_id))
        LIMIT 1;
        v_drawn := v_drawn + delve_table_worth(v_spec);

        SELECT cr.species_id INTO v_spec
        FROM creature_regions cr
        WHERE cr.region_code = v_region
        ORDER BY -ln(random()) / GREATEST(0.0001, cr.weight)
        LIMIT 1;
        v_flat := v_flat + delve_table_worth(v_spec);
    END LOOP;

    RAISE NOTICE
        'in % the tables run % to %; the weighted draw averages % against % flat',
        v_region, round(v_poor, 2), round(v_rich, 2),
        round(v_drawn / 300, 2), round(v_flat / 300, 2);

    IF v_drawn <= v_flat THEN
        RAISE EXCEPTION
            'the weighted draw (%) is no richer than the flat one (%)',
            round(v_drawn / 300, 2), round(v_flat / 300, 2);
    END IF;

    -- The thin ones are still reachable. A delve that only ever produced the
    -- richest beast in a region would be its own kind of flat.
    IF (SELECT count(DISTINCT cr.species_id) FROM creature_regions cr
        WHERE cr.region_code = v_region
          AND delve_table_worth(cr.species_id) > 0) < 2 THEN
        RAISE EXCEPTION 'there is only one thing left to meet in %', v_region;
    END IF;

    -- And a creature carrying nothing is never put in anybody's way.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_meet'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%delve_table_worth(cr.species_id) > 0%' THEN
        RAISE EXCEPTION 'a delve can still offer an empty carcass';
    END IF;
END;
$probe$;
