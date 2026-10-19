-- 0179_the_heaviest_is_the_heaviest
--
-- 0178's techniques board says which of a cultivator's moves is "the
-- heaviest" and picked it with `max(t.name)` - which is the alphabetically
-- last one. clearwest came out as Ox Shoulder over Thunder Step; grafv as
-- Frost Lotus Seal.
--
-- `max()` on a text column is a real aggregate that compiles, runs, and
-- answers a question nobody asked. Nothing catches it because the answer is
-- always a technique the player really does own - just not that one.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION leaderboard(p_board TEXT, p_limit INTEGER DEFAULT 10)
RETURNS TABLE (
    place       INTEGER,
    player_id   BIGINT,
    discord_name TEXT,
    headline    TEXT,
    detail      TEXT,
    sort_value  NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    WITH alive AS (
        SELECT p.player_id, p.discord_name
        FROM players p
        WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ),
    board AS (
        SELECT a.player_id, a.discord_name,
               r.name AS headline,
               to_char(pc.cultivation, 'FM9,999,999,999') || ' of '
                 || to_char(cultivation_ceiling(a.player_id), 'FM9,999,999,999') AS detail,
               (r.rank * 1e12 + pc.cultivation)::numeric AS sort_value
        FROM alive a
        JOIN player_cultivation pc ON pc.player_id = a.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE p_board = 'cultivation'

        UNION ALL

        SELECT a.player_id, a.discord_name,
               to_char(sum(s.damage), 'FM9,999,999,999') || ' damage',
               sum(s.strikes) || ' strike(s) across '
                 || count(DISTINCT s.encounter_id) || ' beast(s)',
               sum(s.damage)::numeric
        FROM alive a
        JOIN boss_strikes s ON s.player_id = a.player_id
        WHERE p_board = 'boss'
        GROUP BY a.player_id, a.discord_name

        UNION ALL

        SELECT a.player_id, a.discord_name,
               'level ' || craft.total AS headline,
               COALESCE(craft.spread, 'nothing learned yet') AS detail,
               craft.total::numeric
        FROM alive a
        CROSS JOIN LATERAL (
            SELECT COALESCE(sum(x.level), 0) AS total,
                   string_agg(x.label || ' ' || x.level, ' • '
                              ORDER BY x.level DESC) AS spread
            FROM (
                SELECT pr.name AS label, pp.level
                FROM player_professions pp
                JOIN professions pr ON pr.code = pp.profession
                WHERE pp.player_id = a.player_id AND pp.level > 1
                UNION ALL
                SELECT 'Refiner', prf.level
                FROM player_refinement prf
                WHERE prf.player_id = a.player_id AND prf.level > 1
            ) x
        ) craft
        WHERE p_board = 'crafting' AND craft.total > 0

        UNION ALL

        SELECT a.player_id, a.discord_name,
               to_char(COALESCE(stones.quantity, 0), 'FM9,999,999,999') || ' stones',
               to_char(jade_held(a.player_id), 'FM9,999,999,999') || ' Spirit Jade',
               (COALESCE(stones.quantity, 0) + jade_held(a.player_id) * 10)::numeric
        FROM alive a
        LEFT JOIN player_materials stones
               ON stones.player_id = a.player_id
              AND stones.material_code = 'spirit_stone'
        WHERE p_board = 'wealth'

        UNION ALL

        -- Heaviest by what it hits for. `max(t.name)` sorted the alphabet.
        SELECT a.player_id, a.discord_name,
               count(DISTINCT u.technique_id) || ' technique(s)',
               (array_agg(t.name ORDER BY t.base_power DESC, t.name))[1]
                 || ' at ' || to_char(max(t.base_power), 'FM9,999,999') || ' power',
               count(DISTINCT u.technique_id)::numeric
        FROM alive a
        JOIN player_usable_techniques u ON u.player_id = a.player_id
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE p_board = 'techniques'
        GROUP BY a.player_id, a.discord_name
    )
    SELECT (row_number() OVER (ORDER BY b.sort_value DESC, b.discord_name))::integer,
           b.player_id, b.discord_name, b.headline, b.detail, b.sort_value
    FROM board b
    ORDER BY b.sort_value DESC, b.discord_name
    LIMIT GREATEST(1, p_limit);
$$;


DO $$
DECLARE
    wrong TEXT;
BEGIN
    -- The named move has to be the one with the most power behind it, for
    -- everybody the board can show.
    SELECT string_agg(l.discord_name || ': board says "' || l.detail
                      || '", strongest is ' || truth.name, ', ')
    INTO wrong
    FROM leaderboard('techniques', 500) l
    CROSS JOIN LATERAL (
        SELECT t.name, t.base_power
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = l.player_id
        ORDER BY t.base_power DESC, t.name
        LIMIT 1
    ) truth
    WHERE l.detail NOT LIKE truth.name || '%';

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'the techniques board names the wrong move: %', wrong;
    END IF;
END;
$$;
