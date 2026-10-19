-- 0081_five_swings_to_a_cooldown
--
-- One cooldown buys five tries, and the count outlives the message.
--
-- `/gather`, `/mine` and `/explore` were one action per cooldown. They are now
-- a SEAM you work: the command opens five tries and each one is taken with a
-- button, which is a better shape for the same wait - a player watches a pile
-- build instead of pressing a command five times.
--
-- THE COUNT IS A ROW, NOT VIEW STATE. This is the whole design decision. A
-- Discord view times out in minutes, dies when the bot restarts, and cannot be
-- reached from a phone that has scrolled away - so a session living in the
-- view would mean a cooldown spent and four swings lost to a reconnect. The
-- remaining tries are a row, so `/mine` RESUMES rather than starting again,
-- and it costs no second cooldown to pick the pickaxe back up.
--
-- That is the same reasoning `player_cooldowns` was given in 0017 and
-- `last_tick_at` in 0009: nothing in this game is allowed to depend on a
-- client staying connected.
--
-- SPENT SESSIONS ARE DELETED RATHER THAN ZEROED, and `tries_left > 0` is a
-- CHECK. 0060 is the reason: a column constrained positive and then
-- decremented to zero is a crash, and the fix is to remove the row on the way
-- past rather than to loosen the constraint.
--
-- AN AMBUSH DOES NOT EAT THE REST. A rogue interrupting the third swing leaves
-- two in the table; the fight resolves and `/gather` picks them up.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- player_action_tries
-- ---------------------------------------------------------------------------
-- Sparse rows keyed by action, exactly like `player_cooldowns` beside it - a
-- fourth thing worth doing five times is an INSERT rather than a column.

CREATE TABLE player_action_tries (
    player_id  BIGINT   NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    action     TEXT     NOT NULL,

    tries_left SMALLINT NOT NULL CHECK (tries_left > 0),
    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, action)
);

COMMENT ON TABLE player_action_tries IS
    'Swings left in an open session. A row here is why a disconnect costs nothing and a cooldown is never spent twice.';

INSERT INTO game_config (key, value, description) VALUES
    ('gather_tries', 5,
     'Forages one gather cooldown buys.'),
    ('mine_tries', 5,
     'Swings one mining cooldown buys.'),
    ('explore_tries', 5,
     'Searches one explore cooldown buys.');


-- ---------------------------------------------------------------------------
-- begin_action
-- ---------------------------------------------------------------------------
-- Resume, or claim a cooldown and open a fresh set. One function, because
-- "have I already paid for this" is exactly the question three commands would
-- otherwise each answer slightly differently.

CREATE FUNCTION begin_action(
    p_player_id    BIGINT,
    p_action       TEXT,
    p_cooldown_key TEXT,
    p_tries_key    TEXT
)
RETURNS TABLE (tries_left SMALLINT, resumed BOOLEAN, ready_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    open_now SMALLINT;
    claim    RECORD;
    fresh    SMALLINT;
BEGIN
    SELECT t.tries_left INTO open_now
    FROM player_action_tries t
    WHERE t.player_id = p_player_id AND t.action = p_action
    FOR UPDATE;

    IF FOUND THEN
        RETURN QUERY SELECT open_now, TRUE, NULL::timestamptz;
        RETURN;
    END IF;

    SELECT * INTO claim
    FROM claim_cooldown(p_player_id, p_action, game_config_value(p_cooldown_key));

    IF NOT claim.claimed THEN
        RETURN QUERY SELECT 0::smallint, FALSE, claim.ready_at;
        RETURN;
    END IF;

    fresh := GREATEST(1, game_config_value(p_tries_key))::smallint;

    INSERT INTO player_action_tries (player_id, action, tries_left)
    VALUES (p_player_id, p_action, fresh);

    RETURN QUERY SELECT fresh, FALSE, NULL::timestamptz;
END;
$$;

COMMENT ON FUNCTION begin_action(BIGINT, TEXT, TEXT, TEXT) IS
    'Opens a set of tries, or hands back the one already open. The cooldown is only claimed when a set is actually opened.';


-- ---------------------------------------------------------------------------
-- spend_try
-- ---------------------------------------------------------------------------

CREATE FUNCTION spend_try(p_player_id BIGINT, p_action TEXT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    have SMALLINT;
BEGIN
    SELECT t.tries_left INTO have
    FROM player_action_tries t
    WHERE t.player_id = p_player_id AND t.action = p_action
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have no % left', p_action
            USING ERRCODE = 'check_violation';
    END IF;

    -- Removed on the way past rather than decremented to a zero the CHECK
    -- forbids. 0060 learned this the hard way on player_boosts.
    IF have <= 1 THEN
        DELETE FROM player_action_tries t
        WHERE t.player_id = p_player_id AND t.action = p_action;
        RETURN 0;
    END IF;

    UPDATE player_action_tries t SET tries_left = t.tries_left - 1
    WHERE t.player_id = p_player_id AND t.action = p_action
    RETURNING t.tries_left INTO have;

    RETURN have;
END;
$$;

COMMENT ON FUNCTION spend_try(BIGINT, TEXT) IS
    'Takes one swing off an open set and says how many are left. Refuses rather than going negative.';
