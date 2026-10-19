-- 0569_marked_is_called_taunt
--
-- `taunt` was shown to players as 'Marked', so a technique read:
--
--     Warded 25% for 4 turns * Marked 100% for 4 turns
--
-- and nothing on the screen said what being Marked did. Taunt is the word
-- every player already has for it, and the effect's own description is
-- written in those terms anyway - 'how strongly a creature choosing whom to
-- maul is pulled toward you'.
--
-- One row. `technique_effect_summary` reads the name out of
-- `battle_effect_kinds` rather than keeping a copy, and no cog hardcodes it,
-- so this is the whole change.


UPDATE battle_effect_kinds
SET name = 'Taunt'
WHERE code = 'taunt';


DO $probe$
DECLARE
    v_name TEXT;
    v_said TEXT;
BEGIN
    SELECT name INTO v_name FROM battle_effect_kinds WHERE code = 'taunt';
    IF v_name <> 'Taunt' THEN
        RAISE EXCEPTION 'the effect is still called %', v_name;
    END IF;

    -- 2. AND THE SCREEN SAYS IT. The name is only worth changing if the thing
    --    that renders it reads the table, which is asserted against a real
    --    technique rather than against the row that was just written.
    SELECT technique_effect_summary(t.technique_id) INTO v_said
    FROM techniques t
    WHERE t.effects::text LIKE '%"taunt"%'
    ORDER BY t.technique_id LIMIT 1;

    IF v_said IS NULL THEN
        RAISE NOTICE 'no technique carries a taunt, so the summary was not read';
    ELSIF v_said NOT LIKE '%Taunt%' THEN
        RAISE EXCEPTION
            'a technique that taunts still summarises as "%"', v_said;
    ELSE
        RAISE NOTICE 'a taunting technique now reads: %', v_said;
    END IF;

    -- 3. NOTHING ELSE ANSWERS TO THE OLD NAME. A second row called 'Marked'
    --    would mean the rename only moved half of it.
    IF EXISTS (SELECT 1 FROM battle_effect_kinds WHERE name = 'Marked') THEN
        RAISE EXCEPTION 'something is still called Marked';
    END IF;
END
$probe$;
