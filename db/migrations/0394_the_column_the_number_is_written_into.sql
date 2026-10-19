-- 0394_the_column_the_number_is_written_into
--
-- 0392 widened the damage path and stopped there. While that migration was
-- being written, two cultivators went and forged:
--
--     Borrowed Flame       pashu0        1,852,204,646   86.3% of INT_MAX
--     Gu Immortal's Fist   m_i_y_u_k_i   1,041,865,114   48.5%
--
-- `techniques.base_power` is INTEGER, and `forge_take` and `destiny_take` both
-- write into it through `LEAST(2000000000::numeric, ...)::integer` - the same
-- two-billion type guard 0392 identified and the same reasoning that migration
-- gave for lifting it. 0392 changed where the number is COMPUTED and left both
-- places it is STORED exactly as they were.
--
-- So pashu0's next forge is clamped. Not overflowed - the guard holds - but a
-- grade that earns 2.6 billion is filed as 2.0 and the difference is gone. He
-- is one realm from it mattering on every forge he makes.
--
-- HOW IT SURFACED, WHICH IS WORTH RECORDING. Not from a screen and not from a
-- player. `test_the_pool_measures_what_lands_rather_than_what_is_written`
-- sizes its probe at twenty times the loudest technique in the database, and
-- documents the choice as "arbitrary but self-maintaining: whatever anyone
-- forges tomorrow, this still dwarfs it". Twenty times 1.85 billion does not
-- fit in the column that number came out of, so the test broke on its own
-- success. A ceiling nobody could see was found by the one thing in the
-- codebase that multiplies by the largest number anybody has.
--
-- The clamp goes to the same 1e15 that 0392 chose, for the same reason: a
-- guard against something absurd upstream is worth keeping, and INT_MAX is not
-- that guard.
--
-- Nothing already stored moves. Both live techniques are under two billion and
-- were never clamped; this is about the next one.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE techniques ALTER COLUMN base_power TYPE BIGINT;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- the daily forge and the page forge share this one -----------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'forge_take';

    IF body IS NULL THEN
        RAISE EXCEPTION 'forge_take is missing';
    END IF;

    anchor := concat(
'    power := LEAST(2000000000::numeric, round(', chr(10),
'        game_config_value(''technique_forge_power_base'')', chr(10),
'        * player_power_multiple(f.player_id) * f.power_grade))::bigint;');
    swap := concat(
'    power := LEAST(1000000000000000::numeric, round(', chr(10),
'        game_config_value(''technique_forge_power_base'')', chr(10),
'        * player_power_multiple(f.player_id) * f.power_grade))::bigint;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer clamps its power where it did';
    END IF;
    body := replace(body, anchor, swap);

    anchor := '        titled, 9, ''attack'', power::integer,';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer narrows its power on the way in';
    END IF;
    EXECUTE replace(body, anchor, '        titled, 9, ''attack'', power,');

    -- ---- and the one a destiny hands out -----------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'destiny_take';

    IF body IS NULL THEN
        RAISE EXCEPTION 'destiny_take is missing';
    END IF;

    anchor := concat(
'                LEAST(2000000000::numeric, round(', chr(10),
'                    game_config_value(''technique_forge_power_base'')', chr(10),
'                    * player_power_multiple(p_player_id)', chr(10),
'                    * gift.power_grade))::integer,');
    swap := concat(
'                LEAST(1000000000000000::numeric, round(', chr(10),
'                    game_config_value(''technique_forge_power_base'')', chr(10),
'                    * player_power_multiple(p_player_id)', chr(10),
'                    * gift.power_grade))::bigint,');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'destiny_take no longer clamps its power where it did';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing in the chain is narrower than what reaches it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_reach NUMERIC;
    v_who   BIGINT;
    v_name  TEXT;
BEGIN
    -- Every column a technique's power passes through, end to end.
    SELECT string_agg(c.table_name || '.' || c.column_name || ' (' || c.data_type || ')',
                      ', ') INTO v_bad
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND (c.table_name, c.column_name) IN (
            ('techniques', 'base_power'),
            ('battle_actions', 'base_power'))
      AND c.data_type <> 'bigint';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still hold a technique''s power in an integer: %', v_bad;
    END IF;

    -- And neither writer narrows it on the way in any more.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('forge_take', 'destiny_take')
      AND p.prosrc LIKE '%2000000000%';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still clamp at two billion: %', v_bad;
    END IF;

    -- THE POINT: the deepest cultivator's best possible forge now fits where
    -- it is filed. This is the number that was about to be quietly shortened.
    SELECT p.player_id, p.discord_name INTO v_who, v_name
    FROM players p WHERE p.deleted_at IS NULL
    ORDER BY player_power_multiple(p.player_id) DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody to measure';
        RETURN;
    END IF;

    v_reach := game_config_value('technique_forge_power_base')
               * player_power_multiple(v_who)
               * (SELECT max(grade_max) FROM enlighten_qualities);

    IF v_reach > 1000000000000000::numeric THEN
        RAISE EXCEPTION
            '% can already forge %, which the new clamp would cut', v_name, v_reach;
    END IF;

    RAISE NOTICE
        '%''s best possible forge is % - it fits, and the old ceiling was %',
        v_name, round(v_reach), 2147483647::bigint;

    -- The two that exist are untouched by any of this.
    FOR v_reach IN
        SELECT t.base_power FROM techniques t WHERE t.created_by IS NOT NULL
        ORDER BY t.base_power DESC LIMIT 2
    LOOP
        IF v_reach >= 2000000000 THEN
            RAISE EXCEPTION 'a stored technique was already at the old clamp';
        END IF;
    END LOOP;
END;
$probe$;
