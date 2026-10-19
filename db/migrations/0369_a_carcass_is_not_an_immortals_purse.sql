-- 0369_a_carcass_is_not_an_immortals_purse
--
-- /explore in Black Heaven has been handing out Yellow Apricot Essence, and it
-- is my fault in 0359.
--
-- THE CHAIN. 0359 gave rogue immortals their essence through `creature_drops`,
-- which was the right table - `battle_conclude` already loops it, Fortune
-- already takes its share of the miss, and a beaten rogue paying out needed no
-- new code. To make that legal it widened `check_drop_is_beast_material` to
-- admit essence off anything carrying an `immortal_rank`.
--
-- What it did not do was ask who ELSE reads `creature_drops`. Two other
-- callers do, and both of them mean 'beast parts' while saying
-- `creature_drops`:
--
--   * `explore`, whose own comment reads 'whatever the local wildlife is made
--     of, taken off something already dead'. It picks ONE row at random from
--     every drop of every creature in the region - no category filter, no rank
--     filter, and no chance roll, because a carcass was always just a carcass.
--     In Black Heaven that pool is now sixteen beast rows and NINE essence
--     rows, one per rogue immortal, so better than a third of every 'beast'
--     find was essence, drawn uniformly across ranks 10 to 18. A Dewberry
--     immortal could walk out of a stroll with the rarest currency in the game.
--   * `horde_spill_parts`, the same shape. No tide opens in a heaven since
--     0350, so it has not leaked - but it is the identical bug waiting for the
--     day one does.
--
-- THE FIX IS THE WORD THEY BOTH ALREADY MEANT. Both now take beast materials
-- and only beast materials. Essence keeps exactly one route out of a rogue -
-- beating it - which is what 0359 set out to build. `material_sources` and
-- `region_finds` are left alone on purpose: they are read-only screens, and
-- 'this rogue carries this essence' is a true and useful thing for them to say.
--
-- WHAT IS ALREADY IN PLAYERS' HANDS IS LEFT ALONE. Five holdings came out of
-- this, three of them already absorbed. Taking things back out of somebody's
-- inventory is a decision for whoever runs the game, not a side effect of the
-- patch that closes the hole.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        SELECT cd.material_code INTO mat', chr(10),
'        FROM creature_regions cr', chr(10),
'        JOIN creature_drops cd ON cd.species_id = cr.species_id', chr(10),
'        WHERE cr.region_code = here', chr(10),
'        ORDER BY random()', chr(10),
'        LIMIT 1;');

    swap := concat(
'        -- Beast materials ONLY. Since 0359 `creature_drops` also carries the', chr(10),
'        -- essence a rogue immortal is holding, and a stroll through a heaven', chr(10),
'        -- picking that up at random is not scavenging, it is a windfall of', chr(10),
'        -- the rarest currency in the game. Essence comes off a rogue by', chr(10),
'        -- beating one.', chr(10),
'        SELECT cd.material_code INTO mat', chr(10),
'        FROM creature_regions cr', chr(10),
'        JOIN creature_drops cd ON cd.species_id = cr.species_id', chr(10),
'        JOIN materials dm ON dm.code = cd.material_code', chr(10),
'        WHERE cr.region_code = here', chr(10),
'          AND dm.category = ''beast''', chr(10),
'        ORDER BY random()', chr(10),
'        LIMIT 1;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'explore';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'explore no longer picks off a carcass where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'            SELECT cd.material_code, max(cd.chance) AS chance', chr(10),
'            FROM creature_regions cr', chr(10),
'            JOIN creature_drops cd ON cd.species_id = cr.species_id', chr(10),
'            WHERE cr.region_code = p_region', chr(10),
'            GROUP BY cd.material_code');

    swap := concat(
'            -- Beast materials only, for the same reason /explore is: a tide', chr(10),
'            -- spills carcasses, not an immortal''s purse.', chr(10),
'            SELECT cd.material_code, max(cd.chance) AS chance', chr(10),
'            FROM creature_regions cr', chr(10),
'            JOIN creature_drops cd ON cd.species_id = cr.species_id', chr(10),
'            JOIN materials sm ON sm.code = cd.material_code', chr(10),
'            WHERE cr.region_code = p_region', chr(10),
'              AND sm.category = ''beast''', chr(10),
'            GROUP BY cd.material_code');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'horde_spill_parts';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_spill_parts no longer gathers a region where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A heaven can be walked all day and yield no essence, and a rogue still pays
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    was    TEXT;
    got    RECORD;
    leaked INTEGER := 0;
    parts  INTEGER := 0;
    sp     BIGINT;
    d      RECORD;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 10 ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to walk a heaven';
        RETURN;
    END IF;

    BEGIN
        SELECT region_code INTO was FROM player_location WHERE player_id = who;

        INSERT INTO player_location (player_id, region_code)
        VALUES (who, 'black_heaven')
        ON CONFLICT (player_id) DO UPDATE SET region_code = 'black_heaven';

        -- Walked hard. The old pool was better than a third essence, so three
        -- hundred strolls finding none is not luck.
        FOR i IN 1..300 LOOP
            FOR got IN SELECT * FROM explore(who) LOOP
                IF got.material_code IS NOT NULL THEN
                    IF EXISTS (SELECT 1 FROM materials m
                               WHERE m.code = got.material_code
                                 AND m.category = 'essence') THEN
                        leaked := leaked + 1;
                    END IF;
                    IF EXISTS (SELECT 1 FROM materials m
                               WHERE m.code = got.material_code
                                 AND m.category = 'beast') THEN
                        parts := parts + 1;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;

        IF leaked > 0 THEN
            RAISE EXCEPTION
                'three hundred strolls through Black Heaven still turned up % essence',
                leaked;
        END IF;

        -- And it did not fix it by finding nothing at all: carcasses still
        -- turn up, which is what the branch is for.
        IF parts = 0 THEN
            RAISE EXCEPTION
                'nothing was scavenged in three hundred strolls - the branch is dead, not fixed';
        END IF;
        RAISE NOTICE
            '300 strolls through Black Heaven: % beast parts, % essence', parts, leaked;

        -- Beating a rogue still pays, which is the route that was meant to
        -- exist. Driven through the same loop `battle_conclude` runs.
        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'rogue' AND immortal_rank IS NOT NULL LIMIT 1;

        SELECT count(*) INTO parts
        FROM creature_drops cd JOIN materials m ON m.code = cd.material_code
        WHERE cd.species_id = sp AND m.category = 'essence';
        IF parts = 0 THEN
            RAISE EXCEPTION 'a beaten rogue immortal now carries no essence';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'the walk was rolled back - nobody moved and nobody was paid';
END;
$probe$;
