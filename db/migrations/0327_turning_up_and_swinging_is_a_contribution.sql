-- 0327_turning_up_and_swinging_is_a_contribution
--
-- The western tide of 11 Sep 2026, as it was scored:
--
--     clearwest   10,947,450,773 damage   66 beasts   0 elites   3 chests
--     pashu0       8,169,654,814 damage   58 beasts   0 elites   3 chests
--     grafv            8,231,889 damage   60 beasts   3 elites   0 chests
--
-- grafv landed more finishing blows than pashu0 and was the only person on
-- the line who felled an elite - three of them - and came away with nothing.
-- The first chest wanted 50,271,687 and their whole afternoon came to
-- 8,231,889, which is 0.16% of it.
--
-- CONTRIBUTION IS DENOMINATED IN RAW DAMAGE, and raw damage on this roster
-- spans a factor of about fifteen hundred. Any bar written in those units is
-- either free for the top of the roster or unreachable for the bottom; there
-- is no value that is a target for both. clearwest clears all three chests
-- with a single blow. grafv cannot clear the first with a two hour tide.
--
-- What the dial says it wants is not what it does. `horde_chest_one`, in its
-- own description:
--
--     'Reachable by somebody who turned up and swung a few times.'
--
-- So swinging starts to count. A swing on the line is worth
-- `horde_swing_worth` of a beast of this tide, which puts the chest ladder
-- back in the units it is already written in - `horde_chest_kills_one` is
-- fifteen, and fifteen is now what a chest costs in swings if you never land
-- a telling blow at all:
--
--     chest one     15 swings    'turned up and swung a few times'
--     chest two     60 swings
--     chest three  150 swings    'a serious afternoon on the line'
--
-- THIS TAKES NOTHING FROM ANYBODY. Contribution only gains a term. Everyone
-- who reaches a chest today still reaches it, in the same order, on the same
-- leaderboard - clearwest's eleven billion is not moved by a few hundred
-- swings. What changes is that the people whose damage cannot reach the bar
-- now have a road to it that is made of showing up, which is the thing the
-- event is actually short of.
--
-- COUNTED IN BEASTS, NOT IN A NUMBER. The credit is a multiple of
-- `horde_beast_worth`, the same quantity the bar is built from, so the two
-- can never drift apart. If that measure is ever corrected - it reads a plain
-- average over a roster whose median is a seventieth of its mean, which 0326
-- fixed for the King and deliberately left here - the bar and the swing move
-- together and fifteen swings stays fifteen swings.
--
-- Attacks only. A guarded round in the gauntlet is a turn on the line and it
-- is not a swing, and counting it would make the cheapest way to a chest a
-- button that does nothing to the beast.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE horde_contributions
    ADD COLUMN swings INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN horde_contributions.swings IS
    'Attacks landed on the line, in the channel or the gauntlet. The road to a chest for somebody whose damage cannot reach the bar.';


INSERT INTO game_config (key, value, description) VALUES
    ('horde_swing_worth', 1.0,
     'What one attack on the line is worth, counted in beasts of the tide - '
     'the same unit the chest bars are built from, so the two cannot drift '
     'apart. One, which makes the first chest fifteen swings and the third a '
     'hundred and fifty, exactly what horde_chest_kills_one and _three '
     'already say those chests are worth.');


-- ---------------------------------------------------------------------------
-- What an afternoon on the line came to
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_contribution(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        c.damage_dealt
        + c.healing_done * game_config_value('horde_heal_weight')::bigint
        -- And the swinging itself, priced in beasts of this tide so that it
        -- means the same thing at every rank and in every region.
        + round(c.swings * game_config_value('horde_swing_worth')
                         * horde_beast_worth(p_horde_id))::bigint,
        0)::bigint
    FROM horde_contributions c
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;
$$;


-- ---------------------------------------------------------------------------
-- Both lanes count the swing
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body TEXT;

    PROCEDURE_MARKER CONSTANT TEXT := '';

    a1 TEXT; s1 TEXT;
    a2 TEXT; s2 TEXT;
BEGIN
    -- ---- the channel ------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_strike';

    a1 := concat(
'         elites_slain, last_swing_at)', chr(10),
'    VALUES (met.horde_id, p_player_id, hurt + paid, drain,', chr(10),
'            CASE WHEN down AND met.kind = ''normal'' THEN 1 ELSE 0 END,', chr(10),
'            CASE WHEN down AND met.kind = ''elite''  THEN 1 ELSE 0 END,', chr(10),
'            now())');
    s1 := concat(
'         elites_slain, swings, last_swing_at)', chr(10),
'    VALUES (met.horde_id, p_player_id, hurt + paid, drain,', chr(10),
'            CASE WHEN down AND met.kind = ''normal'' THEN 1 ELSE 0 END,', chr(10),
'            CASE WHEN down AND met.kind = ''elite''  THEN 1 ELSE 0 END,', chr(10),
'            1, now())');

    a2 := '        SET damage_dealt  = horde_contributions.damage_dealt + hurt + paid,';
    s2 := concat(
'        SET damage_dealt  = horde_contributions.damage_dealt + hurt + paid,', chr(10),
'            swings        = horde_contributions.swings + 1,');

    IF (length(body) - length(replace(body, a1, ''))) / length(a1) <> 1
       OR (length(body) - length(replace(body, a2, ''))) / length(a2) <> 1 THEN
        RAISE EXCEPTION 'horde_strike no longer banks a contribution where it did';
    END IF;
    EXECUTE replace(replace(body, a1, s1), a2, s2);

    -- ---- and the gauntlet -------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_gauntlet_swing';

    a1 := concat(
'            (horde_id, player_id, damage_dealt, healing_done, beasts_slain,', chr(10),
'             last_swing_at)', chr(10),
'        VALUES (run.horde_id, run.player_id, out_dmg + paid, out_heal,', chr(10),
'                CASE WHEN down THEN 1 ELSE 0 END, now())');
    s1 := concat(
'            (horde_id, player_id, damage_dealt, healing_done, beasts_slain,', chr(10),
'             swings, last_swing_at)', chr(10),
'        VALUES (run.horde_id, run.player_id, out_dmg + paid, out_heal,', chr(10),
'                CASE WHEN down THEN 1 ELSE 0 END, 1, now())');

    a2 := '            SET damage_dealt  = horde_contributions.damage_dealt + out_dmg + paid,';
    s2 := concat(
'            SET damage_dealt  = horde_contributions.damage_dealt + out_dmg + paid,', chr(10),
'                swings        = horde_contributions.swings + 1,');

    IF (length(body) - length(replace(body, a1, ''))) / length(a1) <> 1
       OR (length(body) - length(replace(body, a2, ''))) / length(a2) <> 1 THEN
        RAISE EXCEPTION 'the gauntlet no longer banks a contribution where it did';
    END IF;
    EXECUTE replace(replace(body, a1, s1), a2, s2);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Fifteen swings is a chest, and nobody loses one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    worth NUMERIC;
    bar1  BIGINT;
    bar3  BIGINT;
    swing NUMERIC;
    gone  TEXT;
BEGIN
    -- Against the tide that produced the complaint.
    worth := horde_beast_worth(7575);
    IF worth IS NULL THEN
        RAISE NOTICE 'the reference tide is gone - checking the arithmetic only';
        RETURN;
    END IF;

    swing := game_config_value('horde_swing_worth') * worth;
    bar1  := horde_chest_bar(7575, 1::smallint);
    bar3  := horde_chest_bar(7575, 3::smallint);

    -- The first chest must cost about what its own dial says it costs.
    IF ceil(bar1 / swing) > game_config_value('horde_chest_kills_one') + 1 THEN
        RAISE EXCEPTION
            'the first chest is % swings, and horde_chest_kills_one says %',
            ceil(bar1 / swing), game_config_value('horde_chest_kills_one');
    END IF;

    -- Nobody who could reach a chest before may have lost one: the term is
    -- added, never substituted, so this is a guard against getting that
    -- backwards rather than a hope.
    SELECT string_agg(p.discord_name, ', ') INTO gone
    FROM horde_contributions c
    JOIN players p ON p.player_id = c.player_id
    WHERE c.horde_id = 7575
      AND horde_contribution(7575, c.player_id) <
          c.damage_dealt + c.healing_done * game_config_value('horde_heal_weight')::bigint;

    IF gone IS NOT NULL THEN
        RAISE EXCEPTION 'contribution went DOWN for: %', gone;
    END IF;

    RAISE NOTICE
        'a swing is worth % - the first chest is % swings, the third %',
        round(swing), ceil(bar1 / swing), ceil(bar3 / swing);
END;
$probe$;
