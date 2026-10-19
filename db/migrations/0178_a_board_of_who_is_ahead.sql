-- 0178_a_board_of_who_is_ahead
--
-- Five boards, one function. A leaderboard is a query per board, and a screen
-- that wrote five queries would be a screen that decides five times what
-- "ahead" means - and would drift from whatever the rest of the game says the
-- moment one of them changed.
--
-- So the ranking lives here and the cog is a renderer: place, who, a headline
-- and a line of detail, the same four columns whichever board is asked for.
--
-- The house account is left out of every board. It holds whatever is listed
-- and would top the wealth board with other people's Jade.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION leaderboard(p_board TEXT, p_limit INTEGER DEFAULT 10)
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
        -- The bar every cultivator is actually trying to move. Realm first,
        -- because a Core Formation cultivator with less raw cultivation is
        -- still further along than a Foundation one with more.
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

        -- Everything ever taken off a world beast, which is the only number
        -- in the game earned entirely in company.
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

        -- Every trade added up. A specialist and a generalist can both get
        -- here, which is the point of adding rather than taking the best.
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

        -- What a cultivator can actually bring to a fight: learned outright
        -- plus whatever an equipped manual is lending.
        SELECT a.player_id, a.discord_name,
               count(DISTINCT u.technique_id) || ' technique(s)',
               COALESCE(max(t.name), 'none') || ' is the heaviest',
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
    board TEXT;
    got   INTEGER;
BEGIN
    FOREACH board IN ARRAY ARRAY['cultivation', 'boss', 'crafting', 'wealth',
                                 'techniques']
    LOOP
        SELECT count(*) INTO got FROM leaderboard(board, 50);

        -- A board that answers nothing is a button that does nothing. Every
        -- one of these has to have somebody on it on a live server.
        IF got = 0 THEN
            RAISE EXCEPTION 'the % board is empty', board;
        END IF;

        -- Places start at one and do not repeat.
        IF (SELECT count(DISTINCT l.place) FROM leaderboard(board, 50) l) <> got THEN
            RAISE EXCEPTION 'the % board hands out a place twice', board;
        END IF;
        IF (SELECT min(l.place) FROM leaderboard(board, 50) l) <> 1 THEN
            RAISE EXCEPTION 'the % board does not start at first', board;
        END IF;
    END LOOP;

    -- An unknown board is empty rather than an error, so a stale button on an
    -- old message answers with nothing rather than a red box.
    IF (SELECT count(*) FROM leaderboard('nonsense', 10)) <> 0 THEN
        RAISE EXCEPTION 'an unknown board returned rows';
    END IF;

    -- The house holds what is listed and must never appear.
    IF EXISTS (
        SELECT 1 FROM leaderboard('wealth', 50) l
        JOIN players p ON p.player_id = l.player_id
        WHERE p.discord_id = 0
    ) THEN
        RAISE EXCEPTION 'the auction house is on the wealth board';
    END IF;
END;
$$;
