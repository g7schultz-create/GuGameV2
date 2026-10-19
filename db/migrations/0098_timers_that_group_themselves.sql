-- 0098_timers_that_group_themselves
--
-- The cooldown screen gets a shape, without giving up the thing that made it
-- correct.
--
-- 0095 derived the list of timed actions from the `<action>_cooldown_minutes`
-- config keys precisely so that a new one could never be left off. A screen
-- with hand-written sections and emoji would give that straight back: the next
-- timed action would ship with no row in the display table and vanish.
--
-- So the display table is PRESENTATION ONLY and an action without a row still
-- appears - under "Other", with a plain hourglass and its own name. The list
-- stays derived and complete; the sections are decoration over the top of it.
-- Nothing can be invisible, and known things look right.
--
-- WHAT IS DELIBERATELY NOT HERE. The screen this is modelled on lists PvP,
-- battlefields, world bosses, tournaments, inheritance grounds, mentorship,
-- Dao companions, servants, split bodies and farm plots. This game has none of
-- them. A timer for a system that does not exist is worse than no timer: it is
-- a promise with a clock on it.
--
-- ACTIVE BOOSTS ARE REAL, THOUGH. `player_boosts` has held rate-changing pills
-- since 0059 and nothing has ever shown them. They are the one row on that
-- screen this game can honestly fill in.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE cooldown_display (
    action     TEXT PRIMARY KEY,
    label      TEXT NOT NULL,
    emoji      TEXT NOT NULL,
    section    TEXT NOT NULL,
    sort_order SMALLINT NOT NULL DEFAULT 0
);

COMMENT ON TABLE cooldown_display IS
    'How a timed action is drawn. Presentation only - an action with no row here still appears, so this table cannot hide anything.';

INSERT INTO cooldown_display (action, label, emoji, section, sort_order) VALUES
    ('gather',    'Gather',      '🌿', 'Gathering', 10),
    ('mine',      'Mine',        '⛏️', 'Gathering', 20),
    ('explore',   'Explore',     '🧭', 'Gathering', 30),
    ('hunt',      'Hunt',        '⚔️', 'Combat',    40),
    ('rest',      'Rest',        '💤', 'Recovery',  50),
    ('meditate',  'Meditate',    '🪷', 'Recovery',  60),
    ('daily',     'Daily purse', '💚', 'Purse',     70);


DROP FUNCTION cooldown_status(BIGINT);

CREATE FUNCTION cooldown_status(p_player_id BIGINT)
RETURNS TABLE (
    action     TEXT,
    label      TEXT,
    emoji      TEXT,
    section    TEXT,
    sort_order SMALLINT,
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

        UNION ALL

        -- The daily keeps its clock in its own table, so it is named rather
        -- than derived. It is also the one people most want to see.
        SELECT 'daily', game_config_value('daily_cooldown_hours') * 60
    ),
    clocks AS (
        SELECT t.action, t.minutes,
               CASE WHEN t.action = 'daily'
                    THEN (SELECT d.last_claimed_at
                                 + make_interval(hours =>
                                     game_config_value('daily_cooldown_hours')::int)
                          FROM player_daily d WHERE d.player_id = p_player_id)
                    ELSE (SELECT c.available_at FROM player_cooldowns c
                          WHERE c.player_id = p_player_id AND c.action = t.action)
               END AS ready_at,
               (SELECT a.tries_left FROM player_action_tries a
                WHERE a.player_id = p_player_id AND a.action = t.action) AS tries_left
        FROM timed t
    )
    SELECT
        c.action,
        -- An action nobody has styled still reads properly rather than
        -- disappearing, which is the whole point of the LEFT JOIN.
        COALESCE(d.label, initcap(replace(c.action, '_', ' '))),
        COALESCE(d.emoji, '⏳'),
        COALESCE(d.section, 'Other'),
        COALESCE(d.sort_order, 999::smallint),
        c.minutes,
        c.ready_at,
        COALESCE(c.ready_at <= now(), TRUE) OR COALESCE(c.tries_left, 0) > 0,
        c.tries_left
    FROM clocks c
    LEFT JOIN cooldown_display d ON d.action = c.action;
$$;

COMMENT ON FUNCTION cooldown_status(BIGINT) IS
    'Every timed action, whether it is ready, and how to draw it. The list is still derived from the config keys; only the styling comes from a table.';
