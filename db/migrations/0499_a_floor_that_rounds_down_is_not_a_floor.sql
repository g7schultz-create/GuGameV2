-- 0499_a_floor_that_rounds_down_is_not_a_floor
--
-- Two faults in the horde's sizing, both uncovered by 0496 moving damage and
-- both older than it. They are the two places where a player-independent term
-- meets a player-scaled one, which is exactly where this kind of thing lives.
--
-- ONE: THE BODY FLOOR ROUNDS THE WRONG WAY.
--
--     GREATEST(1, round(cs.base_hp * horde_world_scale(...) * elite))
--
-- `round` goes down as happily as up, so a floor of 79027.2 becomes 79027 and
-- the beast comes out below the floor it was supposed to honour. One tenth of
-- a point, and the standing test for it is written as `>=` against the
-- unrounded value, so it is a real failure rather than a pedantic one. A floor
-- is `ceiling`. The upper term keeps `round`, because that one is an estimate
-- rather than a promise.
--
-- TWO: THE KING'S SEA TERM IS UNBOUNDED WHEN NOBODY GATHERED.
--
-- `horde_king_pool` takes the GREATEST of three things: the sea it came in
-- behind, what the line can put in, and one cultivator's burst. 0377 capped
-- the sea term with `horde_king_line_reach` and wrote the reason down - "a
-- King nobody can kill is a wall with a timer". But that cap returns NULL
-- when no line gathered, `LEAST` ignores NULLs, and so in exactly the case
-- where the room is weakest the sea term stands with no cap at all.
--
-- Measured: a King in a quiet region holds 316,104,683 against a room that
-- can land 13,425 across every burst it gets in the half hour the King
-- stands. Twenty-three thousand times out of reach, with a timer.
--
-- 0377's intent was right and its fallback was the problem. When no line
-- gathered, the cap now falls back to the PRESENT roster's reach - the same
-- set of cultivators the third term already asks about - so the sea term is
-- always bounded by somebody's ability to finish it. It returns NULL only
-- when there is nobody at all, where the floor stands alone as 0377 intended.
--
-- NEITHER OF THESE IS ABOUT CRITICALS. 0496 raised what the room can land by
-- two and a half to four and a half times, which moved both of these over the
-- line where the standing tests notice them. The tests were right and had
-- been nearly right for a while.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A floor is a ceiling
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('horde_body_pool(bigint,bigint,boolean)'::regprocedure);

    anchor := '        GREATEST(1, round(cs.base_hp';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the floor term in horde_body_pool is not there exactly once';
    END IF;

    -- ceiling, not round: a floor that rounds down is not a floor.
    src := replace(src, anchor, '        GREATEST(1, ceiling(cs.base_hp');
    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And a cap that still caps when nobody turned up
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_king_line_reach(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- What the line that gathered could put into it, times the reach.
    --
    -- When nobody gathered this used to return NULL and LEAST would ignore
    -- it, which left the sea term in `horde_king_pool` uncapped in precisely
    -- the case where the room was weakest - a King twenty-three thousand
    -- times out of reach, with a timer. So the fallback is the PRESENT
    -- roster's reach instead: the same cultivators the pool's third term
    -- already asks about. NULL survives only when there is nobody at all,
    -- where 0377 wanted the floor to stand alone.
    SELECT CASE
        WHEN gathered.reach > 0 THEN gathered.reach
        WHEN present.reach  > 0 THEN present.reach
        ELSE NULL
    END
    FROM (
        SELECT COALESCE(sum(horde_walker_burst(c.player_id, p_species_id)), 0)
               * game_config_value('horde_king_burst')
               * game_config_value('horde_king_bursts_expected')
               * game_config_value('horde_king_effort')
               * game_config_value('horde_king_reach') AS reach
        FROM horde_contributions c WHERE c.horde_id = p_horde_id
    ) gathered
    CROSS JOIN (
        SELECT COALESCE(sum(horde_walker_burst(p.player_id, p_species_id)), 0)
               * game_config_value('horde_king_burst')
               * game_config_value('horde_king_bursts_expected')
               * game_config_value('horde_king_effort')
               * game_config_value('horde_king_reach') AS reach
        FROM players p
        WHERE p.deleted_at IS NULL
          AND p.last_seen_at >= now() - make_interval(
                  mins => game_config_value('boss_presence_minutes')::integer)
    ) present;
$fn$;


-- ---------------------------------------------------------------------------
-- The floor holds and the King is reachable
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_floor  NUMERIC;
    v_pool   BIGINT;
    v_sp     BIGINT;
    v_scale  NUMERIC;
    v_bad    TEXT;
    r        RECORD;
BEGIN
    IF pg_get_functiondef('horde_body_pool(bigint,bigint,boolean)'::regprocedure)
       NOT LIKE '%ceiling(cs.base_hp%' THEN
        RAISE EXCEPTION 'the body floor still rounds';
    END IF;

    -- The floor is honoured for every live horde and species, elite or not,
    -- which is what the standing test asks and what rounding broke.
    FOR r IN
        SELECT h.horde_id, cs.species_id, cs.base_hp, e.elite
        FROM beast_hordes h
        CROSS JOIN (VALUES (TRUE), (FALSE)) AS e(elite)
        JOIN creature_regions cr ON cr.region_code = h.region_code
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cs.kind = 'beast'
        LIMIT 200
    LOOP
        v_scale := horde_world_scale(r.horde_id);
        v_floor := r.base_hp * v_scale
                   * CASE WHEN r.elite THEN game_config_value('horde_elite_hp') ELSE 1 END;
        v_pool  := horde_body_pool(r.horde_id, r.species_id, r.elite);
        IF v_pool < v_floor THEN
            v_bad := 'horde ' || r.horde_id || ' species ' || r.species_id
                     || ': floor ' || v_floor || ' but pool ' || v_pool;
            EXIT;
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the floor is still broken - %', v_bad;
    END IF;

    -- And the cap answers for a roster with nobody gathered, rather than NULL.
    SELECT cs.species_id INTO v_sp FROM creature_species cs
    WHERE cs.kind = 'beast' ORDER BY cs.base_hp DESC LIMIT 1;

    -- A horde with no contributions at all, which is the case 0377 left
    -- uncapped. Asked of an id that has no line rather than by inserting one,
    -- because `beast_hordes` wants more columns than this probe cares about
    -- and the empty-line behaviour is the whole point.
    IF horde_king_line_reach(-1::BIGINT, v_sp) IS NULL
       AND EXISTS (SELECT 1 FROM players p
                   WHERE p.deleted_at IS NULL
                     AND p.last_seen_at >= now() - make_interval(
                             mins => game_config_value('boss_presence_minutes')::integer)) THEN
        RAISE EXCEPTION
            'with a present roster and no line gathered, the cap is still NULL';
    END IF;

    -- The NULL branch - genuinely nobody present, where 0377 wanted the floor
    -- to stand alone - is NOT asserted here. It needs an empty roster, and
    -- `horde_walker_burst` answers with a positive number even for a species
    -- id that does not exist, so there is no way to construct the case
    -- against a live database without emptying it. The branch is three lines
    -- of CASE and is left to the test suite with a synthetic roster.

    RAISE NOTICE 'the body floor is a floor, and the King cap answers without a line';
END;
$probe$;
