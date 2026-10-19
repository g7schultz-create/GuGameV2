-- 0412_an_ordinary_fight_runs_until_somebody_wins_it
--
-- `battle_act` ends any fight that reaches `battle_turn_cap` in a draw:
--
--     ELSIF fight.turn_number + 1 > game_config_value('battle_turn_cap') THEN
--         ends_as := 'drawn';
--
-- Fifty turns, and it has fired three times in 8,669 fights. Those three are
-- the whole of what this changes: a hunt that was going to be won on turn 52
-- was taken away from whoever was winning it, and the longest fight anybody
-- has actually completed ran 48 - so the wall sits just past where the real
-- ones end, which is the worst place for a wall to sit. It is not stopping
-- runaway fights; it is stopping the few honest long ones.
--
-- Nothing loops forever without it either, because nothing here loops at all.
-- A fight advances one turn per button press by a person who is waiting for
-- the answer. There is no server-side tick to run away, and a raider who has
-- had enough already has two doors out - the 'flee' action inside this very
-- function, and `battle_abandon` from outside it.
--
-- WHAT KEEPS ITS CLOCK, which is the reason this is a condition rather than a
-- deletion. A tribulation is the clock. `tribulation_hp_share` is set to 0.65
-- of the realm's dungeon boss precisely so that the question is whether you
-- can break it in time, and `battle_conclude` settles a tribulation on every
-- ending it has, with the comment saying why:
--
--     A flight and an expiry are failures as surely as a death: looking at
--     heaven and walking away is the same information and costs the same wait.
--
-- Take the cap off a tribulation and the only way left to fail one is to die
-- to it, which turns a gate into a formality. So the cap stays wherever the
-- fight is a test of speed, and goes wherever it was only ever a timeout.
--
-- The condition is written `fight.kind <> 'pve'` rather than `= 'tribulation'`
-- on purpose. Capped is the safe side of this fence: a kind added later gets
-- the ceiling by default and has to ask to be let out, rather than being
-- uncapped by an omission nobody notices.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET description =
    'Turns before a fight that is going nowhere is called a draw. Since 0412 this binds every kind of battle EXCEPT ''pve'': an ordinary hunt runs until somebody wins it, and a tribulation keeps its clock because the clock is what a tribulation asks.'
WHERE key = 'battle_turn_cap';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'battle_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    anchor := concat(
'    ELSIF fight.turn_number + 1 > game_config_value(''battle_turn_cap'') THEN', chr(10),
'        ends_as := ''drawn'';');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'battle_act no longer calls its draw where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- An ordinary fight has no ceiling since 0412. Everything else keeps', chr(10),
'    -- one, tribulations above all: theirs is not a timeout, it is the', chr(10),
'    -- question being asked. `<> ''pve''` rather than `= ''tribulation''` so a', chr(10),
'    -- kind added later is capped until somebody decides otherwise.', chr(10),
'    ELSIF fight.kind <> ''pve''', chr(10),
'          AND fight.turn_number + 1 > game_config_value(''battle_turn_cap'') THEN', chr(10),
'        ends_as := ''drawn'';'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The hunt runs on; the trial still has to be beaten in time
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_src TEXT;
    r     RECORD;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc
    WHERE proname = 'battle_act' AND pronamespace = 'public'::regnamespace;

    -- The cap is still read - this migration narrows it, it does not delete it.
    IF v_src NOT LIKE '%battle_turn_cap%' THEN
        RAISE EXCEPTION 'the turn cap was removed outright rather than narrowed';
    END IF;
    IF v_src NOT LIKE '%fight.kind <> ''pve''%' THEN
        RAISE EXCEPTION 'the draw is not conditioned on the kind of fight';
    END IF;

    -- And the two must be the same branch, not the cap in one place and a
    -- loose kind check in another.
    IF position('fight.kind <> ''pve''' in v_src)
       > position('battle_turn_cap' in v_src) THEN
        RAISE EXCEPTION 'the kind check does not guard the cap it was meant to';
    END IF;

    -- Nothing that is a test of speed has quietly lost its ceiling.
    FOR r IN
        SELECT b.kind, count(*) AS fights, max(b.turn_number) AS longest,
               count(*) FILTER (WHERE b.status = 'expired') AS ran_out
        FROM battles b GROUP BY b.kind ORDER BY b.kind
    LOOP
        RAISE NOTICE '% : % fights, longest % turns, % ran out of them',
            rpad(r.kind, 12), r.fights, r.longest, r.ran_out;
    END LOOP;

    RAISE NOTICE
        'a tribulation still has % turns to break what it is looking at',
        game_config_value('battle_turn_cap');
END;
$probe$;
