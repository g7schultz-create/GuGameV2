-- 0477_press_becomes_dodge
--
-- Two renamings, both of them player-facing only.
--
-- `Press` becomes `Dodge`. The stance already read as slipping something and
-- making it pay: it answers `It comes in low` - the move whose telegraph says
-- the thing has stopped caring what you do about it - and pays half again your
-- damage for it. Read wrong it costs nearly double, which is exactly what
-- dodging into a blow should cost. The old name described the arithmetic;
-- this one describes what is happening.
--
-- And what answers `Something is building` is a HEAVY ATTACK rather than "a
-- real blow" or "Strike hard". It is a different thing from the ordinary
-- Strike button and was named too close to it.
--
-- THE CODES DO NOT MOVE. `press` and `strike` stay as they are in
-- `delve_stances`, `delve_beast_moves.answered_by` and the cog's own tables.
-- A display name is what a player reads; a code is what three tables join on,
-- and renaming those to chase a word costs more than it buys. The blurbs are
-- rewritten so the two do not drift apart in meaning even though they now
-- differ in spelling.
--
-- Forward-only. Do not edit once applied.


UPDATE delve_stances
SET name = 'Dodge',
    blurb = 'You slip it and make it pay for the opening. Half again your damage - and if you have read it wrong you have dodged straight into it, for nearly double.'
WHERE code = 'press';

UPDATE delve_stances
SET blurb = 'Your blow, and nothing clever. Enough of them is what answers something building.'
WHERE code = 'strike';


-- ---------------------------------------------------------------------------
-- The names changed and nothing joined on them
-- ---------------------------------------------------------------------------

DO $probe$
BEGIN
    IF (SELECT name FROM delve_stances WHERE code = 'press') <> 'Dodge' THEN
        RAISE EXCEPTION 'the stance is still called %',
            (SELECT name FROM delve_stances WHERE code = 'press');
    END IF;

    -- Every move still has a stance to answer it. If a rename had touched a
    -- code instead of a name, this is where the telegraph would start lying.
    IF EXISTS (SELECT 1 FROM delve_beast_moves m
               WHERE m.answered_by NOT IN ('none', 'strike')
                 AND NOT EXISTS (SELECT 1 FROM delve_stances s
                                 WHERE s.code = m.answered_by)) THEN
        RAISE EXCEPTION 'a move now names an answer nobody can give';
    END IF;

    -- And the four stances are still four.
    IF (SELECT count(*) FROM delve_stances) <> 4 THEN
        RAISE EXCEPTION 'there are now % stances', (SELECT count(*) FROM delve_stances);
    END IF;

    RAISE NOTICE 'the stances read: %',
        (SELECT string_agg(name, ', ' ORDER BY code) FROM delve_stances);
END;
$probe$;
