-- 0469_a_delve_keeps_a_tally_and_comes_round_hourly
--
-- Three small things the first delve made obvious.
--
-- AN HOUR, NOT A DAY. `delve_cooldown_minutes` was copied from the forge at
-- 1320 - twenty-two hours - which is right for a thing you do once and think
-- about, and wrong for a thing whose whole content is a sixteen-action route
-- you want to run again differently. Sixty.
--
-- AND IT KEEPS A TALLY. What a delve gives you currently arrives as a line in
-- a chat message per step and is then scrolled away; by the time you climb out
-- there is no record of what the trip was worth. `delve_haul` adds up what
-- every seam, growth, trace, hoard and beast handed over, so the screen can
-- show the whole haul at any point and the final card can say what the delve
-- was actually for.
--
-- IT IS NAMES, NOT CODES. This table exists to be read by a person. `mine`,
-- `gather` and `explore` have already granted the real material against the
-- real code by the time a delve sees the result - the haul is a receipt, not
-- an inventory, and giving it a foreign key would imply it was the latter.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 60,
    description = 'How long before a cultivator may go down again. An hour: a delve is a sixteen-action route that is worth running again differently, which is not the shape of a thing gated at a day. Was 1320, copied from the forge - see 0469.'
WHERE key = 'delve_cooldown_minutes';


CREATE TABLE delve_haul (
    delve_id BIGINT NOT NULL REFERENCES delve_runs(delve_id) ON DELETE CASCADE,
    what     TEXT NOT NULL,
    how_many BIGINT NOT NULL,
    PRIMARY KEY (delve_id, what),
    CHECK (how_many > 0)
);

COMMENT ON TABLE delve_haul IS
    'A receipt for one delve, by name rather than by code: the material itself was granted by mine, gather or explore before the delve ever saw it. This is so a cultivator can see what the trip was worth without scrolling back through every step.';


CREATE OR REPLACE FUNCTION delve_record(p_delve_id bigint, p_found jsonb)
RETURNS void
LANGUAGE sql
AS $fn$
    INSERT INTO delve_haul (delve_id, what, how_many)
    SELECT p_delve_id, e ->> 'what', (e ->> 'how_many')::bigint
    FROM jsonb_array_elements(COALESCE(p_found, '[]'::jsonb)) e
    WHERE e ->> 'what' IS NOT NULL
      AND COALESCE((e ->> 'how_many')::bigint, 0) > 0
    ON CONFLICT (delve_id, what) DO UPDATE
    SET how_many = delve_haul.how_many + EXCLUDED.how_many;
$fn$;


CREATE OR REPLACE FUNCTION delve_haul_of(p_delve_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT string_agg(h.how_many || 'x ' || h.what, chr(10)
                      ORDER BY h.how_many DESC, h.what)
    FROM delve_haul h WHERE h.delve_id = p_delve_id;
$fn$;


-- ---------------------------------------------------------------------------
-- Everything a delve hands over goes on the tally
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_step' AND pronamespace = 'public'::regnamespace;

    anchor := concat(
'    RETURN QUERY SELECT v_id, TRUE, v_kind, v_said, v_found,');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_step no longer returns its find where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    PERFORM delve_record(v_id, v_found);', chr(10),
'', chr(10),
anchor));
END;
$patch$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_strike' AND pronamespace = 'public'::regnamespace;

    anchor := '    RETURN QUERY SELECT f.fight_id,';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_strike no longer returns its blow where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    PERFORM delve_record(v_delve, v_found);', chr(10),
'', chr(10),
anchor));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The tally adds up, and the ground comes round in an hour
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p    BIGINT;
    v_id   BIGINT;
    at     RECORD;
    v_sum  BIGINT;
    v_rows INTEGER;
BEGIN
    IF game_config_value('delve_cooldown_minutes') <> 60 THEN
        RAISE EXCEPTION 'a delve still waits % minutes',
            game_config_value('delve_cooldown_minutes');
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM region_veins v
                      WHERE v.region_code = pl.region_code)
          -- Somebody not already underground. There are live delves now -
          -- people are playing this - and a probe must not reach for one of
          -- their cultivators and be refused by a rule that is working.
          AND delve_of(p.player_id) IS NULL
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);

        -- Nothing walked, nothing on the tally.
        IF delve_haul_of(v_id) IS NOT NULL THEN
            RAISE EXCEPTION 'a delve nobody has walked already has a haul';
        END IF;

        -- Two seams in a row, so the tally has to ADD rather than replace.
        SELECT r.at_x, r.at_y INTO at FROM delve_runs r WHERE r.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'seam', spent = FALSE
        WHERE t.delve_id = v_id
          AND t.x = at.at_x AND t.y IN (at.at_y - 1, at.at_y - 2);

        PERFORM delve_step(v_p, 'up');
        SELECT count(*), COALESCE(sum(h.how_many), 0) INTO v_rows, v_sum
        FROM delve_haul h WHERE h.delve_id = v_id;
        IF v_rows = 0 THEN
            RAISE EXCEPTION 'working a seam put nothing on the tally';
        END IF;

        PERFORM delve_step(v_p, 'up');
        IF (SELECT COALESCE(sum(h.how_many), 0) FROM delve_haul h
            WHERE h.delve_id = v_id) <= v_sum THEN
            RAISE EXCEPTION 'the second seam replaced the first on the tally';
        END IF;

        RAISE NOTICE 'two seams:%', chr(10) || delve_haul_of(v_id);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Both places that hand something over write it down.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_step'
        AND pronamespace = 'public'::regnamespace) NOT LIKE '%delve_record%' THEN
        RAISE EXCEPTION 'walking the ground keeps no tally';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_strike'
        AND pronamespace = 'public'::regnamespace) NOT LIKE '%delve_record%' THEN
        RAISE EXCEPTION 'killing things keeps no tally';
    END IF;
END;
$probe$;
