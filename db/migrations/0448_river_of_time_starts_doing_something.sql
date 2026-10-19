-- 0448_river_of_time_starts_doing_something
--
-- The Red Lotus' Inheritor root says:
--
--     River of Time - Once per day, reset the cooldown of one technique.
--
-- and does nothing whatsoever. `special_name` and `special_text` are read in
-- exactly one place in the entire codebase - `bot/character.py`, which prints
-- them - and no SQL function has ever looked at either. The only thing in the
-- game that clears a cooldown is `/dev ready`, which is owner-gated.
--
-- Worse than doing nothing: the card renders it with a diamond, beside a
-- "Cooldown reduction: +10%" that IS honestly marked unmodelled. So the one
-- line on that card presented as a working ability is the one that is not.
--
-- WHAT IT DOES NOW. Twice a day it clears the enlighten cooldown, so sylvrime
-- can sit at the anvil roughly three times a day where everybody else sits
-- once. `forge_technique_cooldown_minutes` is 1320 - twenty-two hours - so a
-- single sitting is already most of a day, and two resets is a real gift
-- rather than a rounding of one.
--
-- "A day" is the rolling window everything else here calls a day:
-- `daily_cooldown_hours`, which is 22. Not a calendar day - this game has no
-- midnight, and inventing one for a single root would be inventing a concept.
--
-- BUILT FOR ONE ROOT, IN A SHAPE THAT TAKES MORE. Twenty-three roots and
-- forty-three physiques carry a special and not one of them is wired to
-- anything, so this will be asked for again. `root_specials` is a table
-- rather than a branch: the next one is a row plus whatever it does, not a
-- rewrite of this. It is not a framework - there is no generic effect
-- language here, just "which cooldown, how often", because that is what the
-- two once-a-day root specials in the game actually ask for.
--
-- THE TEXT IS CORRECTED TOO. Saying "once per day" while granting two is the
-- same fault one notch smaller.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE root_specials (
    root_code     TEXT     PRIMARY KEY REFERENCES roots(code) ON DELETE CASCADE,
    uses_per_day  SMALLINT NOT NULL,
    resets_action TEXT     NOT NULL,
    CHECK (uses_per_day >= 1)
);

COMMENT ON TABLE root_specials IS
    'A root special that actually does something, and how often. `resets_action` is the cooldown it clears, named as `player_cooldowns.action` spells it.';

CREATE INDEX root_specials_action_idx ON root_specials (resets_action);

INSERT INTO root_specials (root_code, uses_per_day, resets_action)
VALUES ('red_lotus_inheritor', 2, 'forge_technique');


CREATE TABLE root_special_uses (
    use_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    root_code TEXT   NOT NULL REFERENCES roots(code) ON DELETE CASCADE,
    used_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX root_special_uses_who_idx ON root_special_uses (player_id, used_at DESC);
CREATE INDEX root_special_uses_root_idx ON root_special_uses (root_code);

COMMENT ON TABLE root_special_uses IS
    'Every time somebody spent their root. A log rather than a counter, so the window can be changed later without anybody''s charges being wrong in the meantime.';


-- ---------------------------------------------------------------------------
-- How many are left, and spending one
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION root_special_charges_left(p_player_id bigint)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $fn$
    -- The rolling window everything else here calls a day. A cultivator with
    -- no root, or a root that does nothing, has nothing to spend rather than
    -- an error - the screen asks this of everybody.
    SELECT GREATEST(0, COALESCE((
        SELECT rs.uses_per_day - (
            SELECT count(*) FROM root_special_uses u
            WHERE u.player_id = p_player_id
              AND u.root_code = rs.root_code
              AND u.used_at > now() - make_interval(
                  hours => game_config_value('daily_cooldown_hours')::int))
        FROM player_character pc
        JOIN root_specials rs ON rs.root_code = pc.root_code
        WHERE pc.player_id = p_player_id
    ), 0))::integer;
$fn$;

COMMENT ON FUNCTION root_special_charges_left(bigint) IS
    'What a cultivator has left of their root''s special today. Zero for anybody whose root does not have one, so a screen can ask it of everyone.';


CREATE OR REPLACE FUNCTION root_special_ready_at(p_player_id bigint)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $fn$
    -- When the oldest spent charge falls out of the window, which is when the
    -- next one arrives. NULL when they have one in hand.
    SELECT CASE WHEN root_special_charges_left(p_player_id) > 0 THEN NULL
    ELSE (
        SELECT min(u.used_at) + make_interval(
                   hours => game_config_value('daily_cooldown_hours')::int)
        FROM (
            SELECT u2.used_at FROM root_special_uses u2
            JOIN player_character pc ON pc.player_id = u2.player_id
            WHERE u2.player_id = p_player_id
              AND u2.root_code = pc.root_code
              AND u2.used_at > now() - make_interval(
                  hours => game_config_value('daily_cooldown_hours')::int)
            ORDER BY u2.used_at
            LIMIT 1
        ) u
    ) END;
$fn$;


CREATE OR REPLACE FUNCTION root_special_use(p_player_id bigint)
RETURNS TABLE(special_name text, cleared text, charges_left integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_root   TEXT;
    v_action TEXT;
    v_name   TEXT;
BEGIN
    SELECT pc.root_code, rs.resets_action, r.special_name
    INTO v_root, v_action, v_name
    FROM player_character pc
    JOIN root_specials rs ON rs.root_code = pc.root_code
    JOIN roots r ON r.code = pc.root_code
    WHERE pc.player_id = p_player_id;

    IF v_root IS NULL THEN
        RAISE EXCEPTION 'your root has nothing to spend'
            USING ERRCODE = 'check_violation';
    END IF;

    IF root_special_charges_left(p_player_id) < 1 THEN
        RAISE EXCEPTION 'you have spent % today already', v_name
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refused when there is nothing to clear, rather than spending a charge
    -- on a cooldown that was not running. Somebody pressing it early should
    -- keep their charge.
    IF NOT EXISTS (SELECT 1 FROM player_cooldowns c
                   WHERE c.player_id = p_player_id
                     AND c.action = v_action
                     AND c.available_at > now()) THEN
        RAISE EXCEPTION 'there is nothing to walk back to - that is ready now'
            USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM player_cooldowns
    WHERE player_id = p_player_id AND action = v_action;

    INSERT INTO root_special_uses (player_id, root_code)
    VALUES (p_player_id, v_root);

    RETURN QUERY SELECT v_name, v_action,
                        root_special_charges_left(p_player_id);
END;
$fn$;

COMMENT ON FUNCTION root_special_use(bigint) IS
    'Spend one use of your root''s special. Refuses when the cooldown it would clear is not running, so a charge is never spent on nothing.';


-- ---------------------------------------------------------------------------
-- And the card stops describing something that was not there
-- ---------------------------------------------------------------------------

UPDATE roots SET special_text =
    'Twice a day, step back to before you sat at the anvil - the enlighten cooldown is cleared.'
WHERE code = 'red_lotus_inheritor';


-- ---------------------------------------------------------------------------
-- It clears what it says, twice, and not a third time
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_left  INTEGER;
    v_said  TEXT;
    r       RECORD;
BEGIN
    BEGIN
        SELECT pc.player_id INTO v_who FROM player_character pc
        JOIN players p ON p.player_id = pc.player_id
        WHERE pc.root_code = 'red_lotus_inheritor' AND p.deleted_at IS NULL
        LIMIT 1;
        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Two in hand, before anything is spent.
        DELETE FROM root_special_uses WHERE player_id = v_who;
        IF root_special_charges_left(v_who) <> 2 THEN
            RAISE EXCEPTION 'the Inheritor starts with % rather than 2',
                root_special_charges_left(v_who);
        END IF;

        -- Spending it on nothing is refused, and costs nothing.
        DELETE FROM player_cooldowns
        WHERE player_id = v_who AND action = 'forge_technique';
        BEGIN
            PERFORM root_special_use(v_who);
            RAISE EXCEPTION 'a charge was spent on a cooldown that was not running';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;
        IF root_special_charges_left(v_who) <> 2 THEN
            RAISE EXCEPTION 'a refused use still cost a charge';
        END IF;

        -- Now with the anvil genuinely shut.
        PERFORM claim_cooldown(v_who, 'forge_technique',
                               game_config_value('forge_technique_cooldown_minutes'));
        IF NOT EXISTS (SELECT 1 FROM player_cooldowns
                       WHERE player_id = v_who AND action = 'forge_technique'
                         AND available_at > now()) THEN
            RAISE EXCEPTION 'the anvil did not shut, so this proves nothing';
        END IF;

        PERFORM root_special_use(v_who);
        IF EXISTS (SELECT 1 FROM player_cooldowns
                   WHERE player_id = v_who AND action = 'forge_technique'
                     AND available_at > now()) THEN
            RAISE EXCEPTION 'the river ran and the anvil is still shut';
        END IF;
        IF root_special_charges_left(v_who) <> 1 THEN
            RAISE EXCEPTION 'one use left % charges', root_special_charges_left(v_who);
        END IF;

        -- The second, and then no third.
        PERFORM claim_cooldown(v_who, 'forge_technique',
                               game_config_value('forge_technique_cooldown_minutes'));
        PERFORM root_special_use(v_who);
        IF root_special_charges_left(v_who) <> 0 THEN
            RAISE EXCEPTION 'two uses left % charges',
                root_special_charges_left(v_who);
        END IF;

        PERFORM claim_cooldown(v_who, 'forge_technique',
                               game_config_value('forge_technique_cooldown_minutes'));
        BEGIN
            PERFORM root_special_use(v_who);
            RAISE EXCEPTION 'the river ran a third time in one day';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- And it says when the next one comes.
        IF root_special_ready_at(v_who) IS NULL THEN
            RAISE EXCEPTION 'spent out, and the screen cannot say when it returns';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody else gained anything.
    SELECT count(*) INTO v_left FROM players p
    WHERE p.deleted_at IS NULL AND root_special_charges_left(p.player_id) > 0;
    RAISE NOTICE '% cultivator(s) hold a root that now does something', v_left;

    FOR r IN
        SELECT ro.name, rs.uses_per_day, rs.resets_action, ro.special_name
        FROM root_specials rs JOIN roots ro ON ro.code = rs.root_code
        ORDER BY ro.name
    LOOP
        RAISE NOTICE '  % : % clears %, % a day',
            rpad(r.name, 22), r.special_name, r.resets_action, r.uses_per_day;
    END LOOP;
END;
$probe$;
