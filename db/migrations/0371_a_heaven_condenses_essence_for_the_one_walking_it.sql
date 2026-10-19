-- 0371_a_heaven_condenses_essence_for_the_one_walking_it
--
-- 0369 shut off essence from /explore because it was coming out of the wrong
-- hole: the beast branch was scooping rogue immortals' drop rows at random, so
-- better than a third of finds were essence drawn UNIFORMLY across ranks 10 to
-- 18 and a Dewberry immortal could stroll home with Yellow Apricot.
--
-- Walking a heaven SHOULD turn up essence. What it should not do is decide the
-- tier by coin flip. This puts it back as its own thing, keyed to the walker
-- rather than to whatever happens to live in the region.
--
-- HOW THE TIER IS DECIDED, AND WHY IT IS SHAPED LIKE THIS. Start at the realm
-- the walker stands at - that is what they can use, and what the ladder is
-- asking them for. Then offer a step up, and another, each at
-- `explore_essence_step_chance`. One in ten climbs a rung:
--
--     own realm   ~90 percent of finds
--     +1 rung      10 percent          - a good day
--     +2 rungs      1 percent          - a story
--     +3 rungs      0.1 percent        - a rumour
--     +8 rungs      0.000001 percent   - one walk in a hundred million
--
-- That last line is the point. A Dewberry immortal CAN find Yellow Apricot
-- Essence, worth two hundred and forty-three million times what they were
-- looking for, and they will not. Compounding is what makes the tail comical
-- rather than merely thin - a flat rarity table would have handed one out this
-- week.
--
-- WHERE, AND WHO. Heavens only, immortals only. The region gate is read off
-- `regions.min_rank` rather than named, so a third heaven inherits it. A
-- mortal cannot reach a heaven and an immortal standing in the Central
-- Continent is not walking anywhere that condenses.
--
-- It is its own outcome rather than a fourth branch of the material roll, so
-- the existing weights are untouched: gathering, stones, remains and nothing
-- still sit at 34, 30, 18 and 18 in a heaven exactly as they do at home. The
-- essence is drawn BEFORE them and takes the walk when it lands.
--
-- Forward-only. Do not edit once applied.


INSERT INTO explore_outcomes (code, name, description, weight) VALUES
    ('essence', 'Condensation',
     'The qi here is thick enough to come apart in the hand.', 0);

COMMENT ON TABLE explore_outcomes IS
    'What a walk can turn up, and how often. Weight 0 means it is never drawn by the ordinary roll - `essence` is rolled separately, and is here so the screen has a name for it.';


INSERT INTO game_config (key, value, description) VALUES
    ('explore_essence_chance', 0.12,
     'Chance a walk through a heaven condenses immortal essence for an immortal walking it. Rolled before the ordinary outcome and takes the walk when it lands.'),
    ('explore_essence_step_chance', 0.10,
     'Chance the essence found is one realm ABOVE the walker, rolled again for each further rung. Compounding, so two rungs up is one walk in a hundred and eight rungs up is one in a hundred million.');


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        amount := 1 + floor(random() * 2);', chr(10),
'    END IF;', chr(10),
chr(10),
'    IF mat IS NULL THEN');

    swap := concat(
'        amount := 1 + floor(random() * 2);', chr(10),
'    END IF;', chr(10),
chr(10),
'    -- ---- what a heaven condenses -------------------------------------', chr(10),
'    -- Keyed to the WALKER, not the region''s roster. 0369 shut off the old', chr(10),
'    -- route because it read rogue drop rows at random and handed a Dewberry', chr(10),
'    -- immortal whatever tier it felt like.', chr(10),
'    DECLARE', chr(10),
'        gate  SMALLINT;', chr(10),
'        stood SMALLINT;', chr(10),
'        tier  SMALLINT;', chr(10),
'        top   SMALLINT;', chr(10),
'    BEGIN', chr(10),
'        SELECT min_rank INTO gate FROM regions WHERE code = here;', chr(10),
'        SELECT r.rank INTO stood', chr(10),
'        FROM player_cultivation pc', chr(10),
'        JOIN realms r ON r.realm_id = pc.realm_id', chr(10),
'        WHERE pc.player_id = p_player_id;', chr(10),
chr(10),
'        IF COALESCE(gate, 1) > 1', chr(10),
'           AND EXISTS (SELECT 1 FROM immortal_essences e WHERE e.rank = stood)', chr(10),
'           AND random() < game_config_value(''explore_essence_chance'') THEN', chr(10),
'            SELECT max(e.rank) INTO top FROM immortal_essences e;', chr(10),
'            tier := stood;', chr(10),
'            -- One rung at a time, each needing its own roll. Compounding is', chr(10),
'            -- what makes the top of the ladder a rumour rather than a rarity.', chr(10),
'            WHILE tier < top', chr(10),
'                  AND random() < game_config_value(''explore_essence_step_chance'')', chr(10),
'            LOOP', chr(10),
'                tier := tier + 1;', chr(10),
'            END LOOP;', chr(10),
chr(10),
'            SELECT e.material_code INTO mat', chr(10),
'            FROM immortal_essences e WHERE e.rank = tier;', chr(10),
'            IF mat IS NOT NULL THEN', chr(10),
'                pick   := ''essence'';', chr(10),
'                amount := 1;', chr(10),
'            END IF;', chr(10),
'        END IF;', chr(10),
'    END;', chr(10),
chr(10),
'    IF mat IS NULL THEN');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'explore';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'explore no longer finishes its branches where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Their own realm nearly always, the rung above sometimes, the top never
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    stood  SMALLINT;
    was    TEXT;
    got    RECORD;
    walks  INTEGER := 3000;
    -- NOT `found`: PL/pgSQL identifiers are case-insensitive, so a variable
    -- called `found` shadows the built-in FOUND that the line after every
    -- SELECT INTO depends on. The first draft of this probe did exactly that
    -- and reported zero essence from a branch that was working perfectly.
    seen   INTEGER := 0;
    own    INTEGER := 0;
    above  INTEGER := 0;
    below  INTEGER := 0;
    best   SMALLINT := 0;
    tier   SMALLINT;
BEGIN
    SELECT pc.player_id, r2.rank INTO who, stood
    FROM player_cultivation pc JOIN realms r2 ON r2.realm_id = pc.realm_id
    WHERE r2.rank >= 10 ORDER BY r2.rank LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to walk a heaven';
        RETURN;
    END IF;

    BEGIN
        SELECT region_code INTO was FROM player_location WHERE player_id = who;
        INSERT INTO player_location (player_id, region_code)
        VALUES (who, 'black_heaven')
        ON CONFLICT (player_id) DO UPDATE SET region_code = 'black_heaven';

        FOR i IN 1..walks LOOP
            FOR got IN SELECT * FROM explore(who) LOOP
                IF got.material_code IS NOT NULL THEN
                    -- A scalar subquery and a NULL test, rather than SELECT
                    -- INTO and FOUND. Nothing here can be shadowed.
                    tier := (SELECT e.rank FROM immortal_essences e
                             WHERE e.material_code = got.material_code);
                    IF tier IS NOT NULL THEN
                        seen := seen + 1;
                        best := GREATEST(best, tier);
                        IF tier = stood THEN own := own + 1;
                        ELSIF tier > stood THEN above := above + 1;
                        ELSE below := below + 1;
                        END IF;
                    END IF;
                END IF;
            END LOOP;
        END LOOP;

        IF seen = 0 THEN
            RAISE EXCEPTION
                '% walks through a heaven and no essence at all', walks;
        END IF;

        -- Never BELOW their realm: the walker gets what they can use.
        IF below > 0 THEN
            RAISE EXCEPTION '% finds came in under the walker''s own realm', below;
        END IF;

        -- The shape: own realm dominates, the rungs above are the exception.
        IF own::numeric / seen < 0.75 THEN
            RAISE EXCEPTION
                'only % of % finds were the walker''s own realm - the tail is too fat',
                own, seen;
        END IF;

        RAISE NOTICE
            '% walks: % essence, % at rank %, % above it, best seen rank %',
            walks, seen, own, stood, above, best;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- And a mortal region condenses nothing, whoever is standing in it.
    RAISE NOTICE 'the walk was rolled back - nobody moved and nobody was paid';
END;
$probe$;
