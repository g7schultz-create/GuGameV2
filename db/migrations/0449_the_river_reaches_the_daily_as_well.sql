-- 0449_the_river_reaches_the_daily_as_well
--
-- River of Time also walks back the daily purse, so sylvrime takes it twice a
-- day where everybody else takes it once.
--
-- WHICH MEANS THE ALLOWANCE IS PER CLOCK, not one pool spent on either. Two
-- resets of the anvil and one of the purse:
--
--     forge_technique  2  ->  three sittings a day instead of one
--     daily            1  ->  two purses a day instead of one
--
-- One shared pool of two would have meant "reset enlighten twice" and "take
-- the daily twice" could not both be true on the same day, and both were
-- asked for. So `root_specials` gains the action in its key and the uses are
-- counted per action.
--
-- THE DAILY KEEPS ITS CLOCK SOMEWHERE ELSE, which is the only real work here.
-- Everything in `player_cooldowns` is reset by deleting a row; the daily is
-- gated on `player_daily.last_claimed_at + daily_cooldown_hours`, so it is
-- reset by winding that stamp back rather than by clearing it. Wound back BY
-- THE WAIT and not to NULL, on purpose - `claim_daily` decides whether a run
-- continues from the same stamp:
--
--     carried := it.last_claimed_at + grace > now()
--
-- and `daily_streak_grace_hours` is 48. A stamp moved back 22 hours is still
-- inside the grace, so the streak carries. NULL would have quietly broken a
-- run somebody had kept for weeks, which is a strange thing for a gift to do.
--
-- THE STREAK WILL RUN AHEAD, and that is accepted rather than engineered
-- around. A second purse in one day advances the run, so sylvrime's streak
-- counts half-days. It matters for about three days: `daily_jade_for_streak`
-- is base 8 plus 2 a day against a maximum of 20, so it is pinned from a
-- streak of six onward and the rest is a vanity number. Not worth teaching
-- `claim_daily` where its caller came from.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- An allowance per clock rather than one pool
-- ---------------------------------------------------------------------------

ALTER TABLE root_specials DROP CONSTRAINT root_specials_pkey;
ALTER TABLE root_specials ADD PRIMARY KEY (root_code, resets_action);

INSERT INTO root_specials (root_code, uses_per_day, resets_action)
VALUES ('red_lotus_inheritor', 1, 'daily')
ON CONFLICT (root_code, resets_action) DO UPDATE
SET uses_per_day = EXCLUDED.uses_per_day;

-- The log has to say WHICH clock a charge was spent on, or one pool is all
-- there is however the table above is keyed.
ALTER TABLE root_special_uses
    ADD COLUMN resets_action TEXT NOT NULL DEFAULT 'forge_technique';

ALTER TABLE root_special_uses ALTER COLUMN resets_action DROP DEFAULT;

CREATE INDEX root_special_uses_action_idx
    ON root_special_uses (player_id, resets_action, used_at DESC);

COMMENT ON COLUMN root_special_uses.resets_action IS
    'Which clock this charge was spent on. Defaulted to forge_technique when the column arrived in 0449, because every use logged before then was the anvil - it was the only thing the river could reach.';


-- ---------------------------------------------------------------------------
-- Counted, and spent, per clock
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS root_special_charges_left(bigint);
DROP FUNCTION IF EXISTS root_special_ready_at(bigint);
DROP FUNCTION IF EXISTS root_special_use(bigint);


CREATE OR REPLACE FUNCTION root_special_charges_left(
    p_player_id bigint, p_action text)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $fn$
    SELECT GREATEST(0, COALESCE((
        SELECT rs.uses_per_day - (
            SELECT count(*) FROM root_special_uses u
            WHERE u.player_id = p_player_id
              AND u.root_code = rs.root_code
              AND u.resets_action = rs.resets_action
              AND u.used_at > now() - make_interval(
                  hours => game_config_value('daily_cooldown_hours')::int))
        FROM player_character pc
        JOIN root_specials rs ON rs.root_code = pc.root_code
        WHERE pc.player_id = p_player_id AND rs.resets_action = p_action
    ), 0))::integer;
$fn$;

COMMENT ON FUNCTION root_special_charges_left(bigint, text) IS
    'What a cultivator has left of their root''s special against one clock. Zero for anybody whose root does not touch that clock, so a screen can ask it of everyone.';


CREATE OR REPLACE FUNCTION root_special_ready_at(
    p_player_id bigint, p_action text)
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
AS $fn$
    SELECT CASE
        WHEN root_special_charges_left(p_player_id, p_action) > 0 THEN NULL
        ELSE (
            SELECT min(u.used_at) + make_interval(
                       hours => game_config_value('daily_cooldown_hours')::int)
            FROM root_special_uses u
            WHERE u.player_id = p_player_id
              AND u.resets_action = p_action
              AND u.used_at > now() - make_interval(
                  hours => game_config_value('daily_cooldown_hours')::int)
        )
    END;
$fn$;


CREATE OR REPLACE FUNCTION root_special_use(p_player_id bigint, p_action text)
RETURNS TABLE(special_name text, cleared text, charges_left integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_root TEXT;
    v_name TEXT;
    v_wait INTERVAL := make_interval(
        hours => game_config_value('daily_cooldown_hours')::int);
BEGIN
    SELECT pc.root_code, r.special_name INTO v_root, v_name
    FROM player_character pc
    JOIN root_specials rs ON rs.root_code = pc.root_code
    JOIN roots r ON r.code = pc.root_code
    WHERE pc.player_id = p_player_id AND rs.resets_action = p_action;

    IF v_root IS NULL THEN
        RAISE EXCEPTION 'your root has nothing to spend on that'
            USING ERRCODE = 'check_violation';
    END IF;

    IF root_special_charges_left(p_player_id, p_action) < 1 THEN
        RAISE EXCEPTION 'you have spent % on that today already', v_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_action = 'daily' THEN
        -- The daily keeps its clock in its own table. Wound BACK by the wait
        -- rather than cleared: `claim_daily` reads the same stamp to decide
        -- whether a run continues, and 22 hours is well inside the 48 of
        -- grace, so a streak somebody has kept for weeks survives this.
        IF NOT EXISTS (
            SELECT 1 FROM player_daily d
            WHERE d.player_id = p_player_id
              AND d.last_claimed_at IS NOT NULL
              AND d.last_claimed_at + v_wait > now()
        ) THEN
            RAISE EXCEPTION 'there is nothing to walk back to - that is ready now'
                USING ERRCODE = 'check_violation';
        END IF;

        UPDATE player_daily
        SET last_claimed_at = now() - v_wait
        WHERE player_id = p_player_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM player_cooldowns c
                       WHERE c.player_id = p_player_id
                         AND c.action = p_action
                         AND c.available_at > now()) THEN
            RAISE EXCEPTION 'there is nothing to walk back to - that is ready now'
                USING ERRCODE = 'check_violation';
        END IF;

        DELETE FROM player_cooldowns
        WHERE player_id = p_player_id AND action = p_action;
    END IF;

    INSERT INTO root_special_uses (player_id, root_code, resets_action)
    VALUES (p_player_id, v_root, p_action);

    RETURN QUERY SELECT v_name, p_action,
                        root_special_charges_left(p_player_id, p_action);
END;
$fn$;

COMMENT ON FUNCTION root_special_use(bigint, text) IS
    'Spend one use of your root''s special against one clock. Refuses when that clock is not running, so a charge is never spent on nothing.';


UPDATE roots SET special_text =
    'Twice a day, step back to before you sat at the anvil. Once a day, back to before you took the purse.'
WHERE code = 'red_lotus_inheritor';


-- ---------------------------------------------------------------------------
-- Both clocks, each with its own allowance, and the run kept
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who    BIGINT;
    v_streak INTEGER;
    v_before TIMESTAMPTZ;
    r        RECORD;
BEGIN
    BEGIN
        SELECT pc.player_id INTO v_who FROM player_character pc
        JOIN players p ON p.player_id = pc.player_id
        WHERE pc.root_code = 'red_lotus_inheritor' AND p.deleted_at IS NULL
        LIMIT 1;
        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM root_special_uses WHERE player_id = v_who;

        -- Two pools, not one. Spending the anvil must not touch the purse.
        IF root_special_charges_left(v_who, 'forge_technique') <> 2
           OR root_special_charges_left(v_who, 'daily') <> 1 THEN
            RAISE EXCEPTION 'the allowances start at % and %',
                root_special_charges_left(v_who, 'forge_technique'),
                root_special_charges_left(v_who, 'daily');
        END IF;

        PERFORM claim_cooldown(v_who, 'forge_technique', 1320);
        PERFORM root_special_use(v_who, 'forge_technique');
        IF root_special_charges_left(v_who, 'daily') <> 1 THEN
            RAISE EXCEPTION
                'spending the anvil took the purse with it - one pool, not two';
        END IF;

        -- The purse. Taken, walked back, and the run kept.
        INSERT INTO player_daily (player_id, streak, longest_streak, claims,
                                  last_claimed_at)
        VALUES (v_who, 9, 9, 9, now())
        ON CONFLICT (player_id) DO UPDATE
            SET streak = 9, longest_streak = 9, last_claimed_at = now();

        SELECT d.streak, d.last_claimed_at INTO v_streak, v_before
        FROM player_daily d WHERE d.player_id = v_who;

        PERFORM root_special_use(v_who, 'daily');

        IF (SELECT d.streak FROM player_daily d WHERE d.player_id = v_who)
           <> v_streak THEN
            RAISE EXCEPTION 'walking the purse back moved the run';
        END IF;
        IF (SELECT d.last_claimed_at + make_interval(
                       hours => game_config_value('daily_cooldown_hours')::int)
            FROM player_daily d WHERE d.player_id = v_who) > now() THEN
            RAISE EXCEPTION 'the purse is still shut after being walked back';
        END IF;
        -- And still inside the grace, so the next claim carries the run.
        IF (SELECT d.last_claimed_at + make_interval(
                       hours => game_config_value('daily_streak_grace_hours')::int)
            FROM player_daily d WHERE d.player_id = v_who) <= now() THEN
            RAISE EXCEPTION
                'the purse was walked back past the grace and the run is lost';
        END IF;

        -- No second purse today.
        UPDATE player_daily SET last_claimed_at = now() WHERE player_id = v_who;
        BEGIN
            PERFORM root_special_use(v_who, 'daily');
            RAISE EXCEPTION 'the purse was walked back twice in one day';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- But the anvil still has its second.
        IF root_special_charges_left(v_who, 'forge_technique') <> 1 THEN
            RAISE EXCEPTION 'the purse ate the anvil''s remaining charge';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT ro.name, rs.resets_action, rs.uses_per_day
        FROM root_specials rs JOIN roots ro ON ro.code = rs.root_code
        ORDER BY ro.name, rs.resets_action
    LOOP
        RAISE NOTICE '% : % a day against %',
            rpad(r.name, 22), r.uses_per_day, r.resets_action;
    END LOOP;
END;
$probe$;
