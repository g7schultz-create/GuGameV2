-- 0563_a_suppressed_move_says_so
--
-- 0562 made Suppression work in every creature lane. It did not make it
-- VISIBLE in any of them, and it turns out it never was anywhere:
--
--     grep -rn "suppressed" bot/     ->  nothing
--
-- `battle_act` has written `'suppressed', hushed` into its action detail since
-- the effect existed, and no screen has ever read it. So for as long as
-- Suppression has been in the game, the only thing a cultivator carrying it
-- has seen is a creature that sometimes does nothing, with no word anywhere
-- saying they were the reason.
--
-- That is worse now rather than better: a raider in a dungeon watching the
-- room skip a turn has no way to tell their worms from the room's mood.
--
-- So the dungeon says it. The roll moves out of the argument list and into a
-- variable, which is what lets the round log mention it at all - an inline
-- `* suppression_bite(target)` applies the effect and then forgets it
-- happened.
--
-- A suppressed blow replaces the strike line rather than joining it. Nothing
-- landed, there is no damage to report, and a 'struck for 0' line beside a
-- 'suppressed' line would be the same event told twice.
--
-- The other three lanes (`delve_act`, `horde_gauntlet_swing`, `strike_boss`)
-- keep the inline multiplier for now. They have no per-blow log to put a line
-- in - the delve prints a tally and the gauntlet a wave - so saying it there
-- is a screen change rather than a schema one.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round'
      AND pronamespace = 'public'::regnamespace;

    -- A variable to hold the roll, so it can be both applied and reported.
    IF position('    took    RECORD;' IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round does not declare what it used to';
    END IF;
    patched := replace(src, '    took    RECORD;',
'    took    RECORD;
    hushed  BOOLEAN;   -- 0563. Rolled once, so the log can say it happened.');

    -- Rolled before the blow is handed over, rather than inside the call.
    IF position('        SELECT * INTO took FROM player_take(' IN patched) = 0 THEN
        RAISE EXCEPTION 'the room does not hand its blow to player_take';
    END IF;
    patched := replace(patched,
'        SELECT * INTO took FROM player_take(
            -- SUPPRESSION REACHES THE ROOM (0562). It was read only by
            -- `battle_act`, so a raider carrying it was paying aperture for
            -- nothing in every dungeon they had ever entered.
            target, hit.final_damage * suppression_bite(target),',
'        -- SUPPRESSION REACHES THE ROOM (0562), and says so (0563). Rolled
        -- into a variable rather than inline, because an inline multiplier
        -- applies the effect and then forgets it happened - which is how the
        -- only lane that did roll it never managed to mention it.
        hushed := suppression_hushes(target);

        SELECT * INTO took FROM player_take(
            target, CASE WHEN hushed THEN 0 ELSE hit.final_damage END,');

    -- And the line itself, in place of the strike it prevented.
    IF position('        lines := lines || jsonb_build_object(
            ''who'', foe.name, ''kind'', ''boss'',' IN patched) = 0 THEN
        RAISE EXCEPTION 'the room does not log its blow where it did';
    END IF;
    patched := replace(patched,
'        lines := lines || jsonb_build_object(
            ''who'', foe.name, ''kind'', ''boss'',',
'        -- A suppressed blow REPLACES the strike line. Nothing landed, so a
        -- "struck for 0" beside a "suppressed" would be one event told twice.
        IF hushed THEN
            lines := lines || jsonb_build_object(
                ''kind'', ''suppressed'',
                ''who'', foe.name,
                ''foe_no'', foe.foe_no,
                ''target'', (SELECT p.discord_name FROM players p
                           WHERE p.player_id = target));
            CONTINUE;
        END IF;

        lines := lines || jsonb_build_object(
            ''who'', foe.name, ''kind'', ''boss'',');

    IF patched = src THEN
        RAISE EXCEPTION 'the dungeon_resolve_round patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    src    TEXT;
    v_a    BIGINT;
    v_dg   SMALLINT;
    v_run  BIGINT;
    v_tech BIGINT;
    v_log  JSONB;
    i      INTEGER;
    v_said INTEGER := 0;
    v_sup  NUMERIC;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round'
      AND pronamespace = 'public'::regnamespace;

    -- 1. THE ROLL IS STILL THERE, and now only once per blow.
    IF position('hushed := suppression_hushes(target)' IN src) = 0 THEN
        RAISE EXCEPTION 'the room stopped rolling suppression';
    END IF;
    IF position('suppression_bite(target)' IN src) > 0 THEN
        RAISE EXCEPTION
            'the inline multiplier survived beside the variable - that is two '
            'rolls for one blow';
    END IF;

    -- 2. AND IT CAN BE SEEN. A line nobody writes is the bug being fixed.
    IF position('''kind'', ''suppressed''' IN src) = 0 THEN
        RAISE EXCEPTION 'the room still suppresses a blow without saying so';
    END IF;

    -- 3. PLAYED, not read. Somebody who actually carries the effect, in a real
    --    room, must produce the line.
    SELECT p.player_id, player_stat(p.player_id, 'suppression')
    INTO v_a, v_sup
    FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id > 0
      AND player_stat(p.player_id, 'suppression') > 0.3
    ORDER BY player_stat(p.player_id, 'suppression') DESC LIMIT 1;

    IF v_a IS NULL THEN
        RAISE NOTICE
            'nobody carries enough suppression to see a line, so it was not played';
    ELSE
        BEGIN
            SELECT dungeon_id INTO v_dg FROM dungeons
            WHERE realm_rank <= player_standing(v_a)
            ORDER BY realm_rank DESC LIMIT 1;

            PERFORM grant_material(v_a, 'dungeon_key', 9);
            PERFORM grant_material(v_a, 'spirit_stone', 900000000000);
            PERFORM grant_jade(v_a, 4000, 'probe');
            DELETE FROM dungeon_raiders WHERE player_id = v_a;
            UPDATE player_physique SET current_hp = max_hp WHERE player_id = v_a;

            v_run := dungeon_open(v_a, v_dg, 'insane');
            PERFORM dungeon_begin(v_run, v_a);
            SELECT technique_id INTO v_tech FROM player_usable_techniques
            WHERE player_id = v_a LIMIT 1;

            FOR i IN 1..25 LOOP
                EXIT WHEN (SELECT status FROM dungeon_runs WHERE run_id = v_run)
                          <> 'fighting';
                BEGIN
                    PERFORM dungeon_choose(v_run, v_a, v_tech);
                EXCEPTION WHEN check_violation THEN EXIT;
                END;
                SELECT d.log INTO v_log FROM dungeon_resolve_round(v_run) d;
                IF v_log::text LIKE '%suppressed%' THEN
                    v_said := v_said + 1;
                END IF;
            END LOOP;

            IF v_said = 0 THEN
                -- `%` for the value; `%%` is a literal per cent sign and
                -- consumes no argument, which is what took this migration
                -- down on its first run.
                RAISE EXCEPTION
                    'twenty-five rounds at % per cent suppression and the log '
                    'never said so once', round(v_sup * 100);
            END IF;
            RAISE NOTICE
                'suppression at % said so in % of the rounds played',
                round(v_sup, 3), v_said;

            RAISE EXCEPTION 'probe-ok';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
        END;
    END IF;
END
$probe$;
