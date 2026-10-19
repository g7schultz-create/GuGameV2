-- 0396_the_last_four_realms_stop_being_the_same_climb
--
-- m_i_y_u_k_i reached Green Grape Immortal - realm 15 of 18 - this afternoon,
-- having been at Jade Plum a few hours earlier. pashu0 is 78 per cent of the
-- way to 15 behind them. The top of the ladder is arriving far too early, and
-- the reason is structural rather than a number being too small.
--
-- EVERY WAY UP IS PROPORTIONAL TO THE STAGE IT IS CLIMBING.
--
--   meditate           1 to 7 per cent OF THE NEXT STAGE, once an hour
--   absorb_essence     the essence and the requirement both triple per realm,
--                      so a realm costs exactly 110 essence of its own rank -
--                      at Dewberry, at Yellow Apricot, and at every rung between
--   the passive floor  0382 set it at a flat thirty days per stage BY DESIGN,
--                      because a rank-squared curve meant nothing up here
--
-- Which has a consequence worth stating plainly, because it is the reason the
-- obvious fix is not one: RAISING `cultivation_required` FOR 15 TO 18 WOULD DO
-- NOTHING AT ALL. Every source above would scale with it and the climb would
-- take exactly as long as it does now. The requirement is not what is short.
-- The ladder is flat, and it is flat in all three currencies at once.
--
-- SO THE DRAG GOES ON THE INCOME, AND IT IS ONE NUMBER. `realm_climb_drag`
-- divides all three - the meditation, the essence and the floor - so the four
-- deepest realms cost more of everything rather than more of one thing that
-- players then route around. One dial, applied in three places, and the probe
-- checks all three moved together.
--
--     drag(rank) = 1                                  below realm 15
--                = realm_drag_per_rank ^ (rank - 14)  at 15 and above
--
-- At 2.5: realm 15 costs two and a half times what it did, 16 six times, 17
-- fifteen, 18 thirty-nine. Nothing at realm 14 or below changes by a hair,
-- which matters - four of the six immortals in this game are at realm 10 and
-- this is not aimed at them.
--
-- WHAT THAT IS IN DAYS. Meditating every waking hour, say fourteen sits a day
-- at four per cent, is about 0.56 of a stage a day, so a realm is a touch over
-- seven days today. After this:
--
--     realm 15      18 days      realm 17     110 days
--     realm 16      45 days      realm 18     275 days
--
-- Close to a year and a half of dedicated play for the last four realms, from
-- about a month now. Yellow Apricot should be something one cultivator reaches
-- and the server talks about, not the fourth realm somebody passes through on
-- a Tuesday.
--
-- Essence keeps its shape too: a realm that took 110 of its own essence now
-- takes 275 at Green Grape and 4,290 at Yellow Apricot. Since a rogue immortal
-- carries two to five and a blessed land condenses two a day, the top realm
-- stops being reachable by essence alone, which is the point.
--
-- This is a dial, not a wall. One value in `game_config` moves all of it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('realm_drag_from_rank', 15,
     'The first realm that costs more than its own size to climb. Below this the ladder is flat by design and nothing about it changes.'),
    ('realm_drag_per_rank', 2.5,
     'How much harder each realm at or above realm_drag_from_rank is than the one below, compounding. Divides the meditation, the essence and the passive floor alike, so the four deepest realms cost more of everything rather than more of one thing players then route around.');


CREATE FUNCTION realm_climb_drag(p_rank SMALLINT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    -- Everything that grants cultivation up here is a share of the stage it is
    -- climbing, so the ladder is flat unless something divides the income.
    -- This is that something, and it is the only one - three call sites, one
    -- definition, so the routes cannot be tuned apart by accident.
    SELECT GREATEST(1.0, power(
        game_config_value('realm_drag_per_rank'),
        GREATEST(0, COALESCE(p_rank, 1)
                    - game_config_value('realm_drag_from_rank') + 1)));
$$;

COMMENT ON FUNCTION realm_climb_drag(SMALLINT) IS
    'How much harder a realm is to climb than its own size suggests. 1.0 below realm_drag_from_rank, compounding above it. Divides every route up: meditation, essence and the passive floor.';


-- ---------------------------------------------------------------------------
-- The three routes, each divided by the same number
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- sitting with it --------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'meditate';
    IF body IS NULL THEN
        RAISE EXCEPTION 'meditate is missing';
    END IF;

    anchor := '        gift   := GREATEST(1, round(span * share));';
    swap := concat(
'        -- Divided by the drag on the realm being climbed. Without this a', chr(10),
'        -- sit is worth a share of whatever stage it faces, so Yellow Apricot', chr(10),
'        -- takes exactly as many sits as Dewberry.', chr(10),
'        gift   := GREATEST(1, round(span * share', chr(10),
'                  / realm_climb_drag((SELECT r2.rank FROM realms r2', chr(10),
'                                      WHERE r2.realm_id = cult.realm_id))));');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'meditate no longer sizes its gift where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- drinking it ------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'absorb_essence';
    IF body IS NULL THEN
        RAISE EXCEPTION 'absorb_essence is missing';
    END IF;

    -- The continuation indent is BUILT rather than typed: it lines up under
    -- the expression, not on a round number, and counting it by eye is how
    -- this migration failed its own assertion the first time.
    anchor := concat(
'    worth := p_quantity::numeric * ess.unit_value', chr(10),
repeat(' ', 13), '* game_config_value(''essence_cultivation_rate'');');
    swap := concat(
'    -- Against the drag on the realm DOING the drinking, not the rank of the', chr(10),
'    -- essence: the question is how hard this climb is, and a Dewberry', chr(10),
'    -- essence drunk at Yellow Apricot is being spent on a Yellow Apricot', chr(10),
'    -- stage.', chr(10),
'    worth := p_quantity::numeric * ess.unit_value', chr(10),
repeat(' ', 13), '* game_config_value(''essence_cultivation_rate'')', chr(10),
repeat(' ', 13), '/ realm_climb_drag((SELECT r2.rank FROM realms r2', chr(10),
repeat(' ', 32), 'WHERE r2.realm_id = standing));');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'absorb_essence no longer values its essence where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- and sitting still ------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'cultivation_per_hour';
    IF body IS NULL THEN
        RAISE EXCEPTION 'cultivation_per_hour is missing';
    END IF;

    anchor := concat(
'             THEN r.cultivation_required', chr(10),
'                  / GREATEST(1, game_config_value(', chr(10),
'                        ''immortal_passive_days_per_stage'') * 24)');
    swap := concat(
'             THEN r.cultivation_required', chr(10),
'                  / GREATEST(1, game_config_value(', chr(10),
'                        ''immortal_passive_days_per_stage'') * 24)', chr(10),
'                  / realm_climb_drag(r.rank)');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'cultivation_per_hour no longer floors an immortal where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- All three routes moved, and only for the realms that were meant to
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r       RECORD;
    v_from  SMALLINT := game_config_value('realm_drag_from_rank')::smallint;
    v_prev  NUMERIC := 0;
BEGIN
    -- The curve itself: flat below, compounding above, never less than one.
    FOR r IN SELECT g.rank FROM generate_series(1, 18) AS g(rank) LOOP
        IF r.rank < v_from AND realm_climb_drag(r.rank::smallint) <> 1.0 THEN
            RAISE EXCEPTION
                'realm % is below the line and its climb changed', r.rank;
        END IF;
        IF r.rank >= v_from
           AND realm_climb_drag(r.rank::smallint) <= v_prev THEN
            RAISE EXCEPTION 'realm % is no harder than the one below it', r.rank;
        END IF;
        v_prev := GREATEST(v_prev, realm_climb_drag(r.rank::smallint));
    END LOOP;

    -- All three routes have to read it, or the one that does not becomes the
    -- only route anybody takes.
    IF (SELECT count(*) FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('meditate', 'absorb_essence', 'cultivation_per_hour')
          AND p.prosrc LIKE '%realm_climb_drag%') <> 3 THEN
        RAISE EXCEPTION
            'a way up the ladder does not know about the drag, and will be the only one used';
    END IF;

    -- Nobody below the line had their rate touched. Four of the six immortals
    -- in this game are at realm 10 and this is not aimed at them.
    FOR r IN
        SELECT p.discord_name, rr.rank,
               round(cultivation_per_hour(p.player_id)) AS rate,
               round(rr.cultivation_required
                     / NULLIF(cultivation_per_hour(p.player_id), 0) / 24, 1) AS days
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms rr ON rr.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND rr.rank >= 10
        ORDER BY rr.rank DESC
    LOOP
        RAISE NOTICE '% (realm %) : % an hour, % days a stage%',
            rpad(r.discord_name, 14), r.rank, r.rate, r.days,
            CASE WHEN r.rank >= v_from THEN ' - dragged' ELSE '' END;
    END LOOP;

    -- And what the whole climb now costs in essence, which is the number that
    -- should stop Yellow Apricot being reachable by drinking alone.
    FOR r IN
        SELECT rr.rank, min(rr.name) AS realm,
               round(sum(rr.cultivation_required
                         - COALESCE((SELECT max(r2.cultivation_required) FROM realms r2
                                     WHERE r2.realm_id = rr.realm_id - 1), 0))
                     / (e.unit_value
                        * game_config_value('essence_cultivation_rate')
                        / realm_climb_drag(rr.rank))) AS essence_for_the_realm
        FROM realms rr JOIN immortal_essences e ON e.rank = rr.rank
        WHERE rr.rank >= 14 GROUP BY rr.rank, e.unit_value ORDER BY rr.rank
    LOOP
        RAISE NOTICE '  % : % essence for the whole realm',
            rpad(r.realm, 34), r.essence_for_the_realm;
    END LOOP;
END;
$probe$;
