-- 0257_the_realms_you_crossed_before_fate_was_listening
--
-- 0254 made a great realm rewrite your fate, and everybody who had already
-- crossed one got nothing. Clearwest has passed seven rank doors, Miyuki six,
-- and every one of them handed out a Destiny to a system that did not exist
-- yet. They are owed.
--
-- SO THE OFFERS ARE MADE NOW, one per crossing already behind them, each drawn
-- from the pool that realm would have drawn from - a rank 2 crossing still
-- only offers what a rank 2 crossing offers, so nobody is handed Immortal
-- Bones for a door they walked through in Qi Condensation.
--
-- BACKFILLING EXPOSED A HOLE, which is the more useful half of this migration.
-- `destiny_offer` excluded fates already TAKEN and said nothing about fates
-- sitting in another offer that had not been answered yet. One player with
-- seven pending offers would have been shown the same Destiny twice, and
-- `destiny_take` would have let them write it twice, and `destiny_stat` sums
-- what it finds - so a fate taken twice was worth double.
--
-- Nobody could have hit that before today, because nobody had two offers open
-- at once. Backfilling seven at a stroke is exactly the shape that finds it.
-- Both halves are closed: an offer will not show what another offer is already
-- showing, and a fate cannot be written twice however it was reached.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- An offer knows what the other offers are showing
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION destiny_offer(p_player_id BIGINT, p_rank SMALLINT)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $$
DECLARE
    said TEXT[];
BEGIN
    -- Already offered: the same three, forever. Rolling on read would let a
    -- cultivator walk away and come back until fate suggested what they wanted.
    SELECT pd.offered INTO said FROM player_destinies pd
    WHERE pd.player_id = p_player_id AND pd.rank = p_rank;

    IF said IS NOT NULL THEN
        RETURN said;
    END IF;

    SELECT array_agg(d.code) INTO said FROM (
        SELECT d.code FROM destinies d
        WHERE d.min_rank <= p_rank
          AND d.roll_weight > 0
          -- Nothing twice. A fate is a thing you are, not a stack - and that
          -- includes one already sitting in an offer nobody has answered.
          AND NOT EXISTS (
              SELECT 1 FROM player_destinies p
              WHERE p.player_id = p_player_id
                AND (p.code = d.code OR d.code = ANY (p.offered)))
        ORDER BY -ln(random()) / d.roll_weight
        LIMIT 3
    ) d;

    IF said IS NULL OR array_length(said, 1) < 1 THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_destinies (player_id, rank, offered)
    VALUES (p_player_id, p_rank, said)
    ON CONFLICT (player_id, rank) DO NOTHING;

    RETURN said;
END;
$$;


-- ---------------------------------------------------------------------------
-- And a fate cannot be written twice however it was reached
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION destiny_take(p_player_id BIGINT, p_rank SMALLINT, p_code TEXT)
RETURNS TABLE (name TEXT, description TEXT, grants TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    row_now player_destinies%ROWTYPE;
BEGIN
    SELECT * INTO row_now FROM player_destinies
    WHERE player_id = p_player_id AND rank = p_rank
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'fate has not offered you anything at that realm'
            USING ERRCODE = 'check_violation';
    END IF;
    IF row_now.code IS NOT NULL THEN
        RAISE EXCEPTION 'that fate is already written'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT (p_code = ANY (row_now.offered)) THEN
        RAISE EXCEPTION 'that was not one of the three put in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The backstop. `destiny_offer` will not show the same fate twice, and
    -- this refuses it anyway - `destiny_stat` sums what it finds, so a fate
    -- written twice would quietly be worth double.
    IF EXISTS (SELECT 1 FROM player_destinies pd
               WHERE pd.player_id = p_player_id AND pd.code = p_code) THEN
        RAISE EXCEPTION 'that fate is already yours'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE player_destinies
    SET code = p_code, chosen_at = now()
    WHERE player_id = p_player_id AND rank = p_rank;

    RETURN QUERY
    SELECT d.name, d.description,
           (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                              || CASE WHEN de.magnitude < 0 THEN '' ELSE '+' END
                              || round(100 * de.magnitude) || '%',
                              ', ' ORDER BY ef.sort_order)
            FROM destiny_effects de
            JOIN gu_effects ef ON ef.code = de.effect_code
            WHERE de.code = d.code)
    FROM destinies d WHERE d.code = p_code;
END;
$$;


-- ---------------------------------------------------------------------------
-- What everybody is owed
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    RECORD;
    step   INTEGER;
    made   TEXT[];
    owed   INTEGER := 0;
    people INTEGER := 0;
BEGIN
    FOR who IN
        SELECT pc.player_id, r.rank
        FROM player_cultivation pc
        JOIN players p ON p.player_id = pc.player_id
        JOIN realms r  ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND r.rank > 1
        ORDER BY pc.player_id
    LOOP
        people := people + 1;

        -- One per door already behind them, lowest first, each drawn from the
        -- pool that door would have drawn from.
        FOR step IN 2..who.rank LOOP
            made := destiny_offer(who.player_id, step::smallint);
            IF made IS NOT NULL THEN
                owed := owed + 1;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'opened % offers to % cultivators', owed, people;
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    dupes TEXT;
    thin  TEXT;
BEGIN
    -- Nobody was offered the same fate twice across their open offers.
    SELECT string_agg(DISTINCT p.discord_name, ', ') INTO dupes
    FROM player_destinies a
    JOIN player_destinies b
      ON b.player_id = a.player_id AND b.rank > a.rank
     AND b.offered && a.offered
    JOIN players p ON p.player_id = a.player_id;

    IF dupes IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators were shown a fate twice: %', dupes;
    END IF;

    -- Every offer put three in front of somebody.
    SELECT string_agg(p.discord_name || ' at rank ' || pd.rank, ', ') INTO thin
    FROM player_destinies pd
    JOIN players p ON p.player_id = pd.player_id
    WHERE array_length(pd.offered, 1) <> 3;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these offers held other than three: %', thin;
    END IF;

    -- And a fate offered at a low door is one a low door could offer.
    IF EXISTS (
        SELECT 1 FROM player_destinies pd
        CROSS JOIN LATERAL unnest(pd.offered) AS o(code)
        JOIN destinies d ON d.code = o.code
        WHERE d.min_rank > pd.rank
    ) THEN
        RAISE EXCEPTION 'a door offered a fate above its realm';
    END IF;

    -- Taking one twice is refused, whichever door it came through.
    SELECT pd.player_id INTO who FROM player_destinies pd
    WHERE pd.code IS NULL LIMIT 1;

    IF who IS NOT NULL THEN
        DECLARE
            first_rank SMALLINT;
            first_code TEXT;
        BEGIN
            SELECT pd.rank, pd.offered[1] INTO first_rank, first_code
            FROM player_destinies pd
            WHERE pd.player_id = who AND pd.code IS NULL
            ORDER BY pd.rank LIMIT 1;

            PERFORM destiny_take(who, first_rank, first_code);

            -- Put it in somebody else's offer by hand and try again.
            UPDATE player_destinies
            SET offered = array_append(offered, first_code)
            WHERE player_id = who AND code IS NULL
              AND rank = (SELECT min(rank) FROM player_destinies
                          WHERE player_id = who AND code IS NULL);

            BEGIN
                PERFORM destiny_take(who,
                    (SELECT min(rank) FROM player_destinies
                     WHERE player_id = who AND code IS NULL),
                    first_code);
                RAISE EXCEPTION 'a fate was written twice';
            EXCEPTION
                WHEN check_violation THEN NULL;
            END;

            RAISE EXCEPTION 'probe-ok';
        END;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
END;
$$;
