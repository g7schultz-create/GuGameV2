-- 0333_a_deeper_aperture_holds_more_casts
--
-- A technique costs a FRACTION of the pool, and everything that refills the
-- pool is a fraction of the same number:
--
--     battle_act          cost := ceil(qi_cost_pct * max_qi)
--     battle_act guard    qi   += guard_qi_restore   * max_qi
--     gauntlet            cost := ceil(qi_cost_pct * run.max_qi)
--     gauntlet on a clear qi   += horde_gauntlet_wave_qi * max_qi
--     battle_open         current_qi := max_qi
--
-- Every quantity in a fight is the same share of one number, so that number
-- cancels out of all of them. Casts before the bar runs dry is 1/qi_cost_pct
-- and nothing else. Growing the pool buys nothing.
--
-- WHICH MAKES `max_qi` A STAT THAT DOES NOTHING. It is called Battle Qi
-- Capacity, it is is_live, and its description promises
--
--     'A deeper aperture. More Qi to spend on techniques before a fight
--      runs dry.'
--
-- It is granted by 334 kinds of Gu, three physiques, a destiny and a dwelling
-- facility. On the live roster:
--
--     clearwest     stat +0.42   aperture 128,000   pool 181,760   2 casts
--     ._.visha._.   stat +0.27   aperture 128,000   pool 162,560   3 casts
--
-- Two and three are exactly what they would get carrying none of it, because
-- 1/0.42 is 2 and 1/0.30 is 3 whatever the pool is. clearwest has spent 42%
-- of an aperture on a promise the arithmetic cannot keep.
--
-- THE PERCENTAGE COST IS NOT THE MISTAKE. Pricing a technique as a share of
-- the pool is what lets one number hold across every realm without a per-
-- realm table, and `/techniques` says so on its face - 'X% of max qi'. What
-- was missing is a gap between the pool the fraction is taken OF and the pool
-- the fight is fought FROM. So the fraction is now taken of the realm's own
-- aperture, and the stat swells the pool above it:
--
--     cost  = qi_cost_pct x the realm's qi_capacity
--     pool  = the realm's qi_capacity x (1 + max_qi)
--     casts = (1 + max_qi) / qi_cost_pct
--
-- A stat of 0.42 is 42% more casts. A stat of 0 is arithmetically identical
-- to today - the aperture IS the pool when nothing swells it - so nobody who
-- carries none of it notices anything. The effect caps at 1.0, so the most
-- this can ever be is double, which is what a capacity stat should mean.
--
-- Guard keeps restoring a share of the POOL rather than the aperture, on
-- purpose: a deeper aperture should hand back more when you brace, now that
-- there is something to hand it back into.
--
-- IN-FLIGHT FIGHTS DO NOT BREAK. `battle_act` reads the aperture out of the
-- snapshot `battle_open` wrote, and a battle opened before this migration has
-- no such key - so it falls back to `max_qi` and behaves exactly as it did
-- when it started. A duel in progress is not re-priced under the duellists.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION player_qi_aperture(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- The realm's own capacity, with nothing added. What a technique's
    -- percentage is a percentage OF.
    SELECT GREATEST(1, COALESCE((SELECT r.qi_capacity
                                 FROM player_cultivation pc
                                 JOIN realms r ON r.realm_id = pc.realm_id
                                 WHERE pc.player_id = p_player_id), 1))::bigint;
$$;

COMMENT ON FUNCTION player_qi_aperture(BIGINT) IS
    'The realm aperture a technique is priced against, before any max_qi swells the pool above it.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- the snapshot carries the aperture --------------------------------
    anchor := concat(
'            jsonb_build_object(''max_hp'', body.max_hp, ''defense'', body.defense,', chr(10),
'                               ''strength'', body.strength, ''max_qi'', max_qi,');
    swap := concat(
'            jsonb_build_object(''max_hp'', body.max_hp, ''defense'', body.defense,', chr(10),
'                               ''strength'', body.strength, ''max_qi'', max_qi,', chr(10),
'                               -- What a technique is priced against. Held', chr(10),
'                               -- beside the pool rather than derived later,', chr(10),
'                               -- so a fight cannot be re-priced under the', chr(10),
'                               -- people in it.', chr(10),
'                               ''qi_aperture'', player_qi_aperture(p_player_id),');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'battle_open';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'battle_open no longer writes the snapshot where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- and the cost is taken of it --------------------------------------
    anchor := '        cost := ceil(tech.qi_cost_pct * (me.snapshot ->> ''max_qi'')::bigint);';
    swap := concat(
'        -- Of the APERTURE, not the pool: the pool is what the stat swells,', chr(10),
'        -- and a cost that swelled with it left the stat worth nothing. A', chr(10),
'        -- fight opened before 0333 has no aperture in its snapshot and is', chr(10),
'        -- priced the way it was when it started.', chr(10),
'        cost := ceil(tech.qi_cost_pct', chr(10),
'                     * COALESCE((me.snapshot ->> ''qi_aperture'')::bigint,', chr(10),
'                                (me.snapshot ->> ''max_qi'')::bigint));');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'battle_act';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'battle_act no longer prices a technique where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- the gauntlet prices the same way ---------------------------------
    anchor := '        cost := ceil(tech.qi_cost_pct * run.max_qi)::bigint;';
    swap := concat(
'        -- Of the aperture, as in a duel. A run is short and a realm does not', chr(10),
'        -- move inside one, so this is read live rather than stored on the row.', chr(10),
'        cost := ceil(tech.qi_cost_pct', chr(10),
'                     * LEAST(run.max_qi, player_qi_aperture(run.player_id)))::bigint;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_gauntlet_swing';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the gauntlet no longer prices a technique where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Capacity buys casts, and only for those who carry it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r        RECORD;
    was      INTEGER;
    now_is   INTEGER;
    moved    INTEGER := 0;
    unmoved  INTEGER := 0;
BEGIN
    FOR r IN
        SELECT p.player_id, p.discord_name,
               player_stat(p.player_id, 'max_qi') AS stat,
               player_max_qi(p.player_id) AS pool,
               player_qi_aperture(p.player_id) AS aperture,
               (SELECT min(t.qi_cost_pct)
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                WHERE u.player_id = p.player_id AND t.base_power > 0) AS pct
        FROM players p
        WHERE p.deleted_at IS NULL
    LOOP
        CONTINUE WHEN r.pct IS NULL OR r.pct <= 0;

        was    := floor(r.pool / GREATEST(1, ceil(r.pct * r.pool)));
        now_is := floor(r.pool / GREATEST(1, ceil(r.pct * r.aperture)));

        -- Nobody may come out with fewer casts than they had.
        IF now_is < was THEN
            RAISE EXCEPTION
                '% lost casts: % -> %', r.discord_name, was, now_is;
        END IF;

        IF r.stat > 0 THEN
            -- And carrying the stat has to actually buy something, or this
            -- migration changed nothing and said it did.
            IF now_is <= was THEN
                RAISE EXCEPTION
                    '% carries % of Battle Qi Capacity and still gets % casts',
                    r.discord_name, r.stat, now_is;
            END IF;
            moved := moved + 1;
        ELSE
            -- Somebody with none of it must be untouched to the cast.
            IF now_is <> was THEN
                RAISE EXCEPTION
                    '% carries none and moved % -> %', r.discord_name, was, now_is;
            END IF;
            unmoved := unmoved + 1;
        END IF;
    END LOOP;

    RAISE NOTICE
        '% cultivators gained casts from capacity, % without it are unchanged',
        moved, unmoved;
END;
$probe$;
