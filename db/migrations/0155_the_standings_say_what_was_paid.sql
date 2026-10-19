-- 0155_the_standings_say_what_was_paid
--
-- 0154 pays the whole field and writes down what each of them got. The screen
-- that shows the result reads `tournament_standings`, which was written before
-- any of that existed and still reports only who beat whom.
--
-- A card that says "you came fourth" and not "you came fourth and here is your
-- thirty-one stones" is the reason nobody would notice the change.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION tournament_standings(BIGINT);

CREATE FUNCTION tournament_standings(p_tournament_id BIGINT)
RETURNS TABLE (
    place        INTEGER,
    player_id    BIGINT,
    discord_name TEXT,
    current_hp   BIGINT,
    max_hp       BIGINT,
    dealt        BIGINT,
    taken        BIGINT,
    felled       INTEGER,
    fell_round   INTEGER,
    stones_paid  BIGINT,
    jade_paid    BIGINT
)
LANGUAGE sql STABLE
AS $$
    SELECT te.place, te.player_id, p.discord_name, te.current_hp, te.max_hp,
           te.dealt, te.taken, te.felled, te.fell_round,
           te.stones_paid, te.jade_paid
    FROM tournament_entrants te
    JOIN players p ON p.player_id = te.player_id
    WHERE te.tournament_id = p_tournament_id
    ORDER BY te.place NULLS LAST, te.dealt DESC;
$$;

COMMENT ON FUNCTION tournament_standings(BIGINT) IS
    'How a free-for-all fell out, and what the ring paid each entrant for it.';
