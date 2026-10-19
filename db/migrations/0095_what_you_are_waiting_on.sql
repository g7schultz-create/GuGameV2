-- 0095_what_you_are_waiting_on
--
-- Real waits on rest and meditation, and one screen that says what is ready.
--
-- SEVEN PERCENT OF A REALM EVERY THIRTY SECONDS crossed a realm in under
-- twenty minutes, which 0094 flagged and this fixes: an hour for a meditation,
-- five minutes for a rest. The magnitudes were what the design asked for; the
-- wait is what makes them mean something.
--
-- THE LIST OF COOLDOWNS IS DERIVED, NOT TYPED. Nothing in this schema has ever
-- recorded which actions HAVE a cooldown - it is implicit in whichever command
-- happens to call `claim_cooldown`. A hand-written list on a screen would be a
-- list somebody has to remember to add to, and the first thing to ship without
-- one would simply be invisible.
--
-- So the source of truth is `game_config` itself: a key named
-- `<action>_cooldown_minutes` IS the declaration that the action has a
-- cooldown, and the screen reads the key names. A new timed action appears on
-- it the moment its config row exists, which is the same migration that
-- creates the action.
--
-- AN OPEN SET COUNTS AS READY. `/gather`, `/mine` and `/explore` buy five
-- tries with one claim, so the cooldown can be running while the player still
-- has swings in hand. A screen that said "gather in 4 minutes" to somebody
-- holding three tries would be wrong in the way that matters most.
--
-- THE DAILY KEEPS ITS OWN CLOCK, in `player_daily` rather than
-- `player_cooldowns`, so it is unioned in by name. It is the one a player most
-- wants to see and would be the strangest omission.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 5,
    description = 'Wait between rests.'
WHERE key = 'rest_cooldown_minutes';

UPDATE game_config SET value = 60,
    description = 'Wait between meditations. This is the dial that decides what a meditation is worth, not the percentage.'
WHERE key = 'meditate_cooldown_minutes';


CREATE FUNCTION cooldown_status(p_player_id BIGINT)
RETURNS TABLE (
    action     TEXT,
    minutes    NUMERIC,
    ready_at   TIMESTAMPTZ,
    ready      BOOLEAN,
    tries_left SMALLINT
)
LANGUAGE sql STABLE
AS $$
    WITH timed AS (
        SELECT replace(g.key, '_cooldown_minutes', '') AS action, g.value AS minutes
        FROM game_config g
        WHERE g.key LIKE '%\_cooldown\_minutes'
    )
    SELECT
        t.action,
        t.minutes,
        c.available_at,
        -- Ready if the clock has run out, or if there are swings left in an
        -- open set: a claim buys five of those and the clock starts on the
        -- first one.
        COALESCE(c.available_at <= now(), TRUE) OR COALESCE(a.tries_left, 0) > 0,
        a.tries_left
    FROM timed t
    LEFT JOIN player_cooldowns c
           ON c.player_id = p_player_id AND c.action = t.action
    LEFT JOIN player_action_tries a
           ON a.player_id = p_player_id AND a.action = t.action

    UNION ALL

    -- The daily keeps its clock in its own table, so it is named here rather
    -- than derived. It is also the one a player most wants to see.
    SELECT 'daily',
           game_config_value('daily_cooldown_hours') * 60,
           d.last_claimed_at
               + make_interval(hours => game_config_value('daily_cooldown_hours')::int),
           COALESCE(
               d.last_claimed_at
                   + make_interval(hours => game_config_value('daily_cooldown_hours')::int)
                   <= now(),
               TRUE),
           NULL::smallint
    FROM (SELECT 1) _
    LEFT JOIN player_daily d ON d.player_id = p_player_id;
$$;

COMMENT ON FUNCTION cooldown_status(BIGINT) IS
    'Every timed action and whether it is ready. The list comes from the `<action>_cooldown_minutes` config keys, so a new timed action appears here in the migration that creates it rather than in one somebody has to remember.';
