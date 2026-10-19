-- 0501_a_king_is_measured_against_its_own_tide
--
-- 0500 reverted the wrong fix and said the question was the user's. Having
-- then found what actually moved, it is not - it is a plain bug and this is
-- the right fix.
--
-- WHAT HAPPENED. `horde_king_pool` takes the GREATEST of three terms and the
-- first of them is a region average:
--
--     avg(base_hp of the region's beasts) * horde_world_scale * king_beasts
--
-- Nothing in that mentions a player. An elite spawn, meanwhile, is
-- `horde_body_pool` = GREATEST(region floor, boss_hp_pool * effort * elite),
-- and `boss_hp_pool` reads `player_blow_multiple`. So when 0496 let the
-- realm-scaled lid reach combat and the blow multiple rose two and a half to
-- four and a half times, THE MINIONS QUADRUPLED AND THE KING DID NOT:
--
--     the King carries 36,383 against an elite spawn's 40,346,529
--
-- The King's own line and burst terms did move with the room, but the region
-- average was winning the GREATEST, so the King stood still while its tide
-- grew around it. That is not a balance question. A King keyed to a constant
-- in a game where everything else is sized against the party was going to
-- drift the first time anything moved, and it did.
--
-- THE FIX IS TO MEASURE IT AGAINST THE THING IT LEADS. A King should be a
-- finale relative to its own tide, so it is priced in elites:
--
--     horde_king_elites * horde_body_pool(horde, species, elite := TRUE)
--
-- which inherits BOTH halves of a beast's sizing - the region floor for a
-- quiet server and the room-sized body for a busy one - and therefore tracks
-- the room automatically, forever, without naming a player itself. The
-- region-average term is dropped: `horde_body_pool` already carries the
-- region floor, so keeping a second, staler copy of the same idea was the
-- whole fault. One definition, not two.
--
-- The line and burst terms stay exactly as they were. They are already
-- player-sized and they are what makes a gathered line matter.
--
-- 2.5 elites, as a config value. The standing test asks for at least two;
-- 2.5 leaves the invariant room to breathe without making the King a wall.
--
-- WHAT IS STILL OPEN, and 0500 was right about this part: an elite's region
-- floor can sit above what a quiet room can land, so on a genuinely empty
-- server the whole tide - minions and King alike - can be out of reach. That
-- is the deliberate floor from 0240/0291 and removing it is the user's call.
-- This change makes the King proportionate to its tide; it does not claim to
-- make a tide in an empty region winnable.
--
-- Forward-only. Do not edit once applied.

INSERT INTO game_config (key, value) VALUES ('horde_king_elites', 2.5)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


CREATE OR REPLACE FUNCTION horde_king_pool(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE AS $fn$
    SELECT GREATEST(
        -- A finale relative to its own tide, priced in the elites it comes in
        -- behind. This replaces the region average 0326 built and 0377
        -- capped: `horde_body_pool` already holds the region floor AND the
        -- room-sized body, so this term tracks the party without naming one -
        -- which is exactly what the old term failed to do when 0496 moved
        -- the blow multiple and left the King standing still.
        ceiling(game_config_value('horde_king_elites')
                * horde_body_pool(p_horde_id, p_species_id, TRUE)),

        -- What the line can put into it: everyone who swung at this tide,
        -- asked for as many turns as the burst rule lets them land. 0329.
        round(COALESCE((
            SELECT sum(horde_walker_burst(c.player_id, p_species_id))
            FROM horde_contributions c WHERE c.horde_id = p_horde_id
        ), 0)
        * game_config_value('horde_king_burst')
        * game_config_value('horde_king_bursts_expected')
        * game_config_value('horde_king_effort')),

        -- And never less than one cultivator's whole burst with room to
        -- spare. A sum over an empty line is zero, and a finale nobody had
        -- to gather for is not a finale.
        round(COALESCE((
            SELECT max(horde_walker_burst(p.player_id, p_species_id))
            FROM players p
            WHERE p.deleted_at IS NULL
              AND (p.last_seen_at >= now() - make_interval(
                       mins => game_config_value('boss_presence_minutes')::integer)
                   OR EXISTS (SELECT 1 FROM horde_contributions c
                              WHERE c.horde_id = p_horde_id
                                AND c.player_id = p.player_id))
        ), 0)
        * game_config_value('horde_king_burst')
        * game_config_value('horde_king_burst_margin'))
    )::BIGINT
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$fn$;


-- ---------------------------------------------------------------------------
-- Bigger than its minions, everywhere, by construction
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_ratio NUMERIC;
    v_worst NUMERIC;
    v_n     INTEGER := 0;
    r       RECORD;
BEGIN
    -- The invariant the standing test asks for, checked across every live
    -- horde and every beast that can show up in it rather than on one sample.
    v_worst := NULL;
    FOR r IN
        SELECT h.horde_id, cs.species_id
        FROM beast_hordes h
        JOIN creature_regions cr ON cr.region_code = h.region_code
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cs.kind = 'beast'
        LIMIT 150
    LOOP
        v_n := v_n + 1;
        v_ratio := horde_king_pool(r.horde_id, r.species_id)::NUMERIC
                   / GREATEST(1, horde_body_pool(r.horde_id, r.species_id, TRUE));
        IF v_worst IS NULL OR v_ratio < v_worst THEN
            v_worst := v_ratio;
        END IF;
        IF v_ratio < 2 THEN
            v_bad := 'horde ' || r.horde_id || ' species ' || r.species_id
                     || ' ratio ' || round(v_ratio, 3);
            EXIT;
        END IF;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'no live horde to check the King against';
    END IF;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a King is still under twice an elite of its own tide: %', v_bad;
    END IF;

    -- And the stale region term is gone rather than merely outvoted.
    IF pg_get_functiondef('horde_king_pool(bigint,bigint)'::regprocedure)
       LIKE '%horde_king_beasts%' THEN
        RAISE EXCEPTION 'the region-average term is still in the King pool';
    END IF;
    IF pg_get_functiondef('horde_king_pool(bigint,bigint)'::regprocedure)
       NOT LIKE '%horde_walker_burst%' THEN
        RAISE EXCEPTION 'the player-sized terms were lost';
    END IF;

    RAISE NOTICE
        'checked % horde-species pairs; the thinnest King is %x an elite',
        v_n, round(v_worst, 2);
END;
$probe$;
