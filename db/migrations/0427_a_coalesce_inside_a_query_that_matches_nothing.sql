-- 0427_a_coalesce_inside_a_query_that_matches_nothing
--
-- `/horde` raises for anybody who has not swung at the tide on the board:
--
--     File "bot/cogs/horde.py", line 324, in board_card
--       short = int(mine["next_bar"]) - int(mine["contribution"])
--     TypeError: int() argument must be ... not 'NoneType'
--
-- `horde_contribution` is written like this:
--
--     SELECT COALESCE(c.damage_dealt + ... , 0)::bigint
--     FROM horde_contributions c
--     WHERE c.horde_id = ... AND c.player_id = ...
--
-- The COALESCE is inside the select list, so it defaults a NULL COLUMN of a
-- row that was found. It does nothing at all when the WHERE matches no rows -
-- a scalar function that selects nothing returns NULL, and no COALESCE in the
-- select list can reach that. The default has to wrap the QUERY, not the
-- expression inside it.
--
-- So every cultivator who had not yet swung at the current tide got a
-- traceback instead of the board - which is exactly the screen you open to
-- decide whether to join. A tide ended this morning and a new one rose, so the
-- answer went from "almost nobody" to "almost everybody" in one step, and
-- that is why it surfaced today rather than in the weeks this has been here.
--
-- `horde_chests_earned` and `horde_chest_bar` were checked and are fine: the
-- first is a CASE over `horde_contribution` and the second reads the tide
-- rather than the person, so neither can select nothing. The probe pins all
-- three anyway, because this is a shape that is easy to reintroduce and
-- impossible to see by reading one function.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION horde_contribution(p_horde_id bigint, p_player_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- The COALESCE wraps the whole subquery since 0427. Inside the select
    -- list it only ever defaulted a null column of a row that existed, and
    -- somebody who has not swung has no row to have a column of.
    SELECT COALESCE((
        SELECT c.damage_dealt
               + c.healing_done * game_config_value('horde_heal_weight')::bigint
               -- And the swinging itself, priced in beasts of this tide so
               -- that it means the same thing at every rank and in every
               -- region.
               + round(c.swings * game_config_value('horde_swing_worth')
                                * horde_beast_worth(p_horde_id))::bigint
        FROM horde_contributions c
        WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id
    ), 0)::bigint;
$$;

COMMENT ON FUNCTION horde_contribution(bigint, bigint) IS
    'What a cultivator has put into a tide, and zero rather than NULL for one who has put in nothing. The zero is the reason this is not a one-line function.';


-- ---------------------------------------------------------------------------
-- A stranger to the tide reads as nothing, not as nobody
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_tide BIGINT;
    v_who  BIGINT;
    v_bad  TEXT;
BEGIN
    SELECT h.horde_id INTO v_tide FROM beast_hordes h
    ORDER BY h.horde_id DESC LIMIT 1;

    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM horde_contributions c
                      WHERE c.horde_id = v_tide AND c.player_id = p.player_id)
    LIMIT 1;

    IF v_tide IS NULL OR v_who IS NULL THEN
        RAISE NOTICE 'no tide or nobody outside it to check against';
        RETURN;
    END IF;

    -- The three numbers `board_card` puts through int(). Any NULL here is a
    -- traceback on a screen somebody opened to decide whether to turn up.
    IF horde_contribution(v_tide, v_who) IS NULL THEN
        RAISE EXCEPTION 'contribution is still NULL for a stranger to the tide';
    END IF;
    IF horde_chests_earned(v_tide, v_who) IS NULL THEN
        RAISE EXCEPTION 'chests earned is NULL for a stranger to the tide';
    END IF;
    IF horde_chest_bar(v_tide, 1::smallint) IS NULL THEN
        RAISE EXCEPTION 'the first chest bar is NULL';
    END IF;

    -- And a player who has never touched ANY tide, which is the same shape a
    -- rung deeper.
    SELECT string_agg(p.discord_name, ', ') INTO v_bad
    FROM players p
    WHERE p.deleted_at IS NULL
      AND horde_contribution(v_tide, p.player_id) IS NULL;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still read as NULL on the board: %', v_bad;
    END IF;

    RAISE NOTICE
        'tide %: a cultivator who has not swung reads % rather than NULL',
        v_tide, horde_contribution(v_tide, v_who);
END;
$probe$;
