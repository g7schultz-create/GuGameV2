-- 0458_the_map_is_dark_until_you_stand_on_it
--
-- 0455 laid the whole map out in the open on the argument that a route you can
-- see is a choice and a route you cannot is a dice roll. The call went the
-- other way: a Trial map is dark, and a tile shows what it was only once the
-- party has stood on it.
--
--     before            after, four steps in
--     🟦🐉🟦💠🟦         ⬛⬛⬛⬛⬛
--     🔥💠🔥🟦🟦         ⬛⬛⬛⬛⬛
--     👹🟦🟦🟦🟦         ⬛⬛⬛⬛⬛
--     🟦🔥🟦🟦🟦         ⬛⬜⬛⬛⬛
--     🟦💠🟦🔥🟦         ⬛🧍⬛⬛⬛
--     💠🟦🧍🔥🟦         ⬛🟦🟦⬛⬛
--
-- WHAT THE STEP BUDGET NOW MEANS. In the open, thirteen steps bought a route:
-- you could see two caches and decide whether they were worth the detour. In
-- the dark they buy search. The pressure is the same shape - every step spent
-- is a step not spent on the dragon - but the thing being risked is that you
-- find nothing rather than that you chose wrong.
--
-- AND THE WARDEN IS NO LONGER OPTIONAL IN THE WAY IT WAS. It is nearly double
-- the Trial and 0455 kept it off the party's straight line so that meeting it
-- was always a decision. You cannot decide against something you cannot see,
-- so a blind party can now walk into it and lose the run to a tile it never
-- had an opinion about. That is a real consequence of this change and it is
-- left standing rather than quietly softened - but it is worth knowing, and
-- the cheapest fixes if it plays badly are to drop the warden count to zero or
-- to let it be felt from one tile away.
--
-- THE TRAIL IS THE MAP. Because a tile is only ever revealed by being stood
-- on, everything revealed is also already spent or was open ground: what the
-- grid shows is where the party has been. That is the one thing a lost party
-- actually needs, and it is why the spent tile keeps its own glyph rather than
-- going dark again behind them.
--
-- EXISTING MAPS KEEP THEIR SIGHT. The backfill marks every tile of every map
-- that already exists as seen, so nothing half-walked goes dark underneath the
-- party standing on it. There are none today; the rule is that a live run must
-- survive a migration, not that one happened to be absent.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE trial_map_tiles
    ADD COLUMN seen BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN trial_map_tiles.seen IS
    'Whether the party has stood here. A tile tells you nothing until it has - see 0458 - so this is what separates the map from the territory.';

-- Every map that already exists was walked in the open. It keeps that.
UPDATE trial_map_tiles SET seen = TRUE;


-- ---------------------------------------------------------------------------
-- The ground underfoot is lit, and nothing else is
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_map_open' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'trial_map_open is missing';
    END IF;

    anchor := concat(
'    -- The body the party is carrying, which from here is the only one that', chr(10),
'    -- counts until the map lets them out.');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_map_open no longer seats the party where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- The ground the party is standing on is the only ground it knows.', chr(10),
'    UPDATE trial_map_tiles t SET seen = TRUE', chr(10),
'    WHERE t.map_id = v_map AND t.x = v_sx AND t.y = v_h - 1;', chr(10),
'', chr(10),
anchor));
END;
$patch$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_map_move' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'trial_map_move is missing';
    END IF;

    -- Arrival, and nowhere else. A tile is lit by being stood on, so the one
    -- place that can light it is the one place the party arrives.
    anchor := concat(
'    UPDATE trial_maps m', chr(10),
'    SET at_x = v_nx, at_y = v_ny, steps_left = GREATEST(0, m.steps_left - 1)', chr(10),
'    WHERE m.map_id = v_map;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_map_move no longer arrives where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
anchor, chr(10),
'', chr(10),
'    -- And now the party can see where it is. 0458.', chr(10),
'    UPDATE trial_map_tiles t SET seen = TRUE', chr(10),
'    WHERE t.map_id = v_map AND t.x = v_nx AND t.y = v_ny;'));
END;
$patch$;


CREATE OR REPLACE FUNCTION trial_map_render(p_map_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT string_agg(row_text, chr(10) ORDER BY y)
    FROM (
        SELECT t.y,
               string_agg(
                   CASE WHEN t.x = m.at_x AND t.y = m.at_y THEN '🧍'
                        WHEN NOT t.seen THEN '⬛'
                        WHEN t.spent THEN '⬜'
                        ELSE k.emoji END,
                   '' ORDER BY t.x) AS row_text
        FROM trial_map_tiles t
        JOIN trial_maps m ON m.map_id = t.map_id
        JOIN trial_map_kinds k ON k.kind = t.kind
        WHERE t.map_id = p_map_id
        GROUP BY t.y, m.at_x, m.at_y
    ) rows;
$fn$;

COMMENT ON FUNCTION trial_map_render(bigint) IS
    'The map as the party sees it, which since 0458 is only where it has been. Dark where it has not walked, blank where it has taken what was there, and the trail is the whole of what the grid is for.';


-- ---------------------------------------------------------------------------
-- A map tells you nothing you have not walked
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_map   BIGINT;
    v_grid  TEXT;
    v_dark  INTEGER;
    v_seen  INTEGER;
    v_w     INTEGER;
    v_h     INTEGER;
    r       RECORD;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_lead IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;
        PERFORM trial_party_seal(v_lead);

        v_map := trial_map_open(v_lead);
        SELECT m.width, m.height INTO v_w, v_h FROM trial_maps m
        WHERE m.map_id = v_map;

        -- Exactly one tile is lit, and it is the one underfoot.
        SELECT count(*) INTO v_seen FROM trial_map_tiles t
        WHERE t.map_id = v_map AND t.seen;
        IF v_seen <> 1 THEN
            RAISE EXCEPTION
                'the party can already see % tiles of a map it has not walked',
                v_seen;
        END IF;
        IF NOT (SELECT t.seen FROM trial_map_tiles t
                JOIN trial_maps m ON m.map_id = t.map_id
                WHERE t.map_id = v_map AND t.x = m.at_x AND t.y = m.at_y) THEN
            RAISE EXCEPTION 'the party cannot see the ground it stands on';
        END IF;

        v_grid := trial_map_render(v_map);
        RAISE NOTICE 'walked in:%', chr(10) || v_grid;

        -- Nothing in that grid names a cache, a beast, a warden or the gate.
        IF v_grid LIKE '%💠%' OR v_grid LIKE '%🔥%'
           OR v_grid LIKE '%👹%' OR v_grid LIKE '%🐉%' THEN
            RAISE EXCEPTION 'the dark map is still showing what is on it';
        END IF;

        v_dark := (length(v_grid) - length(replace(v_grid, '⬛', '')))
                  / length('⬛');
        IF v_dark <> v_w * v_h - 1 THEN
            RAISE EXCEPTION
                'the map shows % dark tiles of the % it should', v_dark,
                v_w * v_h - 1;
        END IF;

        -- Then one step, and that tile and no other has been lit.
        PERFORM trial_map_move(v_lead, 'up');
        SELECT count(*) INTO v_seen FROM trial_map_tiles t
        WHERE t.map_id = v_map AND t.seen;
        IF v_seen <> 2 THEN
            RAISE EXCEPTION 'a single step lit % tiles', v_seen;
        END IF;

        RAISE NOTICE 'one step on:%', chr(10) || trial_map_render(v_map);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing already laid out went dark under somebody.
    IF EXISTS (SELECT 1 FROM trial_map_tiles t
               JOIN trial_maps m ON m.map_id = t.map_id
               WHERE m.status <> 'done' AND NOT t.seen
                 AND t.x = m.at_x AND t.y = m.at_y) THEN
        RAISE EXCEPTION 'a party is standing on ground it can no longer see';
    END IF;
END;
$probe$;
