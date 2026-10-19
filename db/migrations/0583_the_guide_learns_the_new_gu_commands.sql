-- 0583_the_guide_learns_the_new_gu_commands
--
-- `/gu` is a GROUP now - `/gu look`, `/gu book`, `/gu dissolve` - because the
-- bot sits on Discord's hundred-command ceiling and the farm needed a slot.
-- Folding two commands into one group freed it and paid for the breakdown.
--
-- The guide still told players to type `/gu`, which is no longer a thing
-- anybody can type. `test_every_command_the_tutorial_names_exists` caught it,
-- which is the test doing exactly its job.
--
-- A GUARD MOVED AND A READER DID NOT, again, and this is the reader. The gear
-- page is the only one that named it.
--
-- The breakdown is worth a sentence of its own on that page: a jar of 253 Gu
-- with 123 spare copies had no way out that was not a trade, and that is the
-- page a player is reading when they wonder why.


UPDATE tutorial_pages
SET body = replace(
        body,
        '**/gu** — the Gu you hold and what fits in your aperture.',
        '**/gu look** — the Gu you hold and what fits in your aperture. '
        || 'Duplicates stack; **/gu dissolve** breaks a spare back down into a '
        || 'share of the materials it was refined from.')
WHERE body LIKE '%**/gu** — the Gu you hold%';


DO $probe$
DECLARE
    v_left INTEGER;
    v_has  INTEGER;
BEGIN
    -- 1. NOBODY IS TOLD TO TYPE `/gu` ANY MORE. Matched the way the test
    --    matches: the command name followed immediately by the bold close.
    SELECT count(*) INTO v_left FROM tutorial WHERE body LIKE '%/gu**%';
    IF v_left > 0 THEN
        RAISE EXCEPTION
            '% guide page(s) still tell a player to type /gu', v_left;
    END IF;

    -- 2. AND THE PAGE STILL TEACHES THE JAR. A replace that silently matched
    --    nothing would pass the check above by saying nothing at all.
    SELECT count(*) INTO v_has FROM tutorial WHERE body LIKE '%/gu look%';
    IF v_has = 0 THEN
        RAISE EXCEPTION
            'no guide page names /gu look - the replacement matched nothing';
    END IF;

    SELECT count(*) INTO v_has FROM tutorial WHERE body LIKE '%/gu dissolve%';
    IF v_has = 0 THEN
        RAISE EXCEPTION 'no guide page names /gu dissolve';
    END IF;

    RAISE NOTICE 'the guide now names /gu look and /gu dissolve';
END
$probe$;
