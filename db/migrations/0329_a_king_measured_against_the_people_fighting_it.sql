-- 0329_a_king_measured_against_the_people_fighting_it
--
-- Tide 8082, northern, rank 5. The sea was emptied completely - 910 of 910,
-- nothing lost - and the King escaped on 62% of its health.
--
--     Thunder Horn Bull                     6,646,239,922
--     m_i_y_u_k_i.                          1,656,601,138   burst spent
--     pashu0                                  819,089,791   burst spent
--     sylvrime                                 10,342,154   burst spent
--     delivered                             2,486,033,083
--
-- All three were stood off on cooldown when it walked. That is not a room
-- that gave up; it is a room that had nothing left to give.
--
-- THE KING IS SIZED AGAINST THE WRONG PEOPLE. `boss_hp_pool` counts everybody
-- whose `last_seen_at` falls inside `boss_presence_minutes` - being online,
-- not being in the fight. Measured against that same roster now:
--
--     m_i_y_u_k_i.   300,439,199 a turn   NOT counted   fought it hardest
--     clearwest      195,256,898 a turn   counted       never touched the tide
--     ._.visha._.     95,227,543 a turn   counted       never touched the tide
--     grafv           12,809,849 a turn   counted       never touched the tide
--
-- The single hardest hitter in the game was left out of the measure of a
-- beast he then did two thirds of the damage to, and three people who were
-- merely logged in were counted in his place. Presence is not participation,
-- and for the King it is not even close to it.
--
-- AND ITS OWN RULE THROTTLES WHAT A FIGHTER CAN DELIVER. The King is met in
-- bursts: `horde_king_burst` strikes and then `horde_king_cooldown_minutes`
-- of standing off, inside the `horde_king_minutes` it is there at all. Sizing
-- it from `boss_swings_expected` - a dial written for a world beast that
-- stands for forty-eight hours - asked each fighter for 13.9 turns. The rule
-- allowed, and the room landed, 5.2.
--
-- So the King is now measured against the people who actually turned up to
-- THIS tide, and asks them for what its own burst rule permits:
--
--     the fighters   everyone in horde_contributions, whatever they hit for
--     the ask        horde_king_burst x horde_king_bursts_expected turns
--     the dial       horde_king_effort, now 0.55
--
-- Five strikes twice over at 0.55 is 5.5 turns a fighter, against the 5.2
-- that room actually landed. Replayed on 8082 the King comes out at
-- 2,636,309,110 and they finish on 94% - one more burst, or one more person,
-- and it is dead. That is the fight it was supposed to be.
--
-- THE RANK STEP GOES. `horde_king_rank_step` raised the King 15% a rank
-- because 0290 had just taken the region's scale away from it and something
-- had to carry the weight. It is double-counting now: a tide's rank IS the
-- average realm of the roster, and a roster's realm is what drives the damage
-- the pool is built from. Strength is already in the measure once.
--
-- The draw-weighted region floor from 0326 stays underneath, so a King never
-- comes out smaller than the sea it walked in behind.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_bursts_expected', 2,
     'How many of its own bursts the King expects each fighter to land before '
     'it leaves. It is met in horde_king_burst strikes at a time with '
     'horde_king_cooldown_minutes between, inside horde_king_minutes - so two '
     'means coming back once, which is what a room actually does. Sizing it '
     'from boss_swings_expected asked for fourteen turns and its own rule '
     'delivered five.');

UPDATE game_config
SET value = 0.55,
    description = 'What share of its fighters full effort a King carries. '
                  'With horde_king_burst and horde_king_bursts_expected this '
                  'is 5.5 turns a fighter, set against the 5.2 the room on '
                  'tide 8082 actually landed before it walked off on 62%.'
WHERE key = 'horde_king_effort';


-- ---------------------------------------------------------------------------
-- What the people who turned up can put into it
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_king_pool(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        -- The sea it came in behind, counted in the beasts that sea actually
        -- sends. 0326.
        GREATEST(1000, round(
            COALESCE((SELECT sum(cs.base_hp * cr.weight)
                             / NULLIF(sum(cr.weight), 0)
                      FROM creature_regions cr
                      JOIN creature_species cs ON cs.species_id = cr.species_id
                      WHERE cr.region_code = h.region_code AND cs.kind = 'beast'),
                     600)
            * horde_world_scale(p_horde_id)
            * game_config_value('horde_king_beasts'))),
        -- And what the line can put into it: everyone who swung at this tide,
        -- asked for as many turns as the burst rule lets them land. Not
        -- everyone who happened to be online - that roster left out the man
        -- who did two thirds of the damage.
        round(COALESCE((
            SELECT sum(horde_walker_burst(c.player_id, p_species_id))
            FROM horde_contributions c WHERE c.horde_id = p_horde_id
        ), 0)
        * game_config_value('horde_king_burst')
        * game_config_value('horde_king_bursts_expected')
        * game_config_value('horde_king_effort'))
    )::bigint
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_king_pool(BIGINT, BIGINT) IS
    'What a King carries, measured against the people who actually fought the tide it came in behind.';


-- ---------------------------------------------------------------------------
-- Both sites read it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    pool := GREATEST(', chr(10),
'        GREATEST(1000, round(', chr(10),
'            -- Weighted the way `horde_spawn` draws, so this is the health of', chr(10),
'            -- the beast the tide will actually send rather than of a rank 9', chr(10),
'            -- creature that turns up one spawn in a thousand. A plain', chr(10),
'            -- average over western reads 837,786 against a median of 317.', chr(10),
'            COALESCE((SELECT sum(cs.base_hp * cr.weight) / NULLIF(sum(cr.weight), 0)', chr(10),
'                      FROM creature_regions cr', chr(10),
'                      JOIN creature_species cs ON cs.species_id = cr.species_id', chr(10),
'                      WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),', chr(10),
'                     600)', chr(10),
'            * horde_world_scale(p_horde_id)', chr(10),
'            * game_config_value(''horde_king_beasts''))),', chr(10),
'        round(boss_hp_pool(who)', chr(10),
'              * game_config_value(''horde_king_effort'')', chr(10),
'              * (1 + game_config_value(''horde_king_rank_step'')', chr(10),
'                     * GREATEST(0, COALESCE(tide.rank, 1) - 1)))', chr(10),
'    )::bigint;');
    swap := '    pool := horde_king_pool(p_horde_id, who);';

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_king_rise';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the King no longer sizes itself where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    anchor := concat(
'    want := GREATEST(1, round(', chr(10),
'        boss_hp_pool(live.species_id, ARRAY(', chr(10),
'            SELECT c.player_id FROM horde_contributions c', chr(10),
'            WHERE c.horde_id = live.horde_id AND c.king_damage > 0))', chr(10),
'        * game_config_value(''horde_king_effort'')', chr(10),
'        * (1 + game_config_value(''horde_king_rank_step'')', chr(10),
'               * GREATEST(0, COALESCE(', chr(10),
'                     (SELECT h.rank FROM beast_hordes h', chr(10),
'                      WHERE h.horde_id = live.horde_id), 1) - 1))))::bigint;');
    swap := '    want := horde_king_pool(live.horde_id, live.species_id);';

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'horde_king_resize_if_due';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the King no longer resizes itself where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Replayed against the tide that could not finish
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bull    BIGINT;
    per     NUMERIC;
    would   NUMERIC;
    got     CONSTANT NUMERIC := 2486033083;   -- what that room actually landed
    was     CONSTANT NUMERIC := 6646239922;   -- what it was asked for
BEGIN
    SELECT species_id INTO bull FROM creature_species WHERE code = 'thunder_horn_bull';

    SELECT sum(horde_walker_burst(c.player_id, bull)) INTO per
    FROM horde_contributions c WHERE c.horde_id = 8082;

    IF per IS NULL OR per = 0 THEN
        RAISE NOTICE 'tide 8082 is gone - the arithmetic stands on its own';
        RETURN;
    END IF;

    would := per * game_config_value('horde_king_burst')
                 * game_config_value('horde_king_bursts_expected')
                 * game_config_value('horde_king_effort');

    IF would >= was THEN
        RAISE EXCEPTION 'the King did not come down at all: % against %', would, was;
    END IF;

    -- It must be a fight, not a formality: near enough that the room gets
    -- there, far enough that it is not handed to them.
    IF got >= would THEN
        RAISE EXCEPTION
            'that room would now kill it outright (% delivered against %)',
            got, would;
    END IF;
    IF got < would * 0.75 THEN
        RAISE EXCEPTION
            'still out of reach: % delivered against % - only %%% of the way',
            got, round(would), round(100 * got / would);
    END IF;

    RAISE NOTICE
        'King % -> %, and that room finishes on % percent of it',
        was, round(would), round(100 * got / would);
END;
$probe$;
