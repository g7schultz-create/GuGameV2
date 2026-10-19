-- 0429_the_three_timers_get_names_and_a_section
--
-- 0428 made Boss Strike, Horde King and the forge read their real clocks.
-- None of the three has ever had a row in `cooldown_display`, which is why
-- they were sitting under "Other" with the fallback hourglass while Gather,
-- Mine and Hunt had emoji and sections. The screen was styling six of nine.
--
-- That fallback is deliberate and good - `cooldown_status` LEFT JOINs the
-- display table precisely so an unstyled action still appears rather than
-- vanishing, which is the whole reason nothing ships invisible. It is a
-- safety net, not a destination, and three things have been sitting in it.
--
-- The forge also needs its row for a second reason: 0428 renamed its config
-- key to agree with the action it claims, so the derived label went from
-- "Technique Forge" to "Forge Technique" - correct, and worse to read. A
-- display row settles what it is called independently of what the key is
-- spelled, which is what that table is for.
--
-- Forward-only. Do not edit once applied.


INSERT INTO cooldown_display (action, label, emoji, section, sort_order) VALUES
    ('boss_strike',     'World boss strike', '🐲', 'Combat',   41),
    ('horde_king',      'Horde King strike', '👑', 'Combat',   42),
    ('forge_technique', 'Technique forge',   '⚒️', 'Crafting', 80);


-- ---------------------------------------------------------------------------
-- Nothing is left in the net that was only ever meant to catch it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- Every action the screen derives now has a name somebody chose. A new
    -- one will land in "Other" as designed, and this will say so.
    SELECT string_agg(c.action, ', ') INTO v_bad
    FROM (SELECT DISTINCT action FROM cooldown_status(
              (SELECT player_id FROM players
               WHERE deleted_at IS NULL ORDER BY player_id LIMIT 1))) c
    WHERE NOT EXISTS (SELECT 1 FROM cooldown_display d WHERE d.action = c.action);

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still fall back to Other: %', v_bad;
    END IF;

    FOR r IN
        SELECT c.section, c.emoji, c.label, c.sort_order
        FROM cooldown_status((SELECT player_id FROM players
                              WHERE deleted_at IS NULL ORDER BY player_id LIMIT 1)) c
        ORDER BY c.sort_order, c.label
    LOOP
        RAISE NOTICE '% % % (%)',
            rpad(r.section, 10), r.emoji, rpad(r.label, 20), r.sort_order;
    END LOOP;
END;
$probe$;
