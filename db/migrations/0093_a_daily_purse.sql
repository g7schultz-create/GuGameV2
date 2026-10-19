-- 0093_a_daily_purse
--
-- The faucet the economy was missing, and the only one whose rate is exact.
--
-- WHAT THE LEDGER SAYS TODAY: four Spirit Jade generated in the entire world.
-- The three faucets built so far are all ONE-OFFS or near enough - twenty-six
-- breakthroughs and sixty-two first kills across a character's whole life,
-- plus a three-percent purse - which comes to about a hundred and forty Jade
-- ever. A Legendary reroll costs ninety-five and a Divine one eight hundred.
-- The sinks were priced for an income that does not exist.
--
-- A DAILY IS THE ONE FAUCET YOU CAN ACTUALLY SET. "Approximate Jade generation
-- per active player should be measurable and controllable" is the sentence the
-- whole economy document hangs on, and every other faucet is a function of how
-- somebody plays. This one is a number times the number of people.
--
-- THE RATE IS THE DOCUMENT'S OWN. It works from "about 50 Jade per week" for
-- an active player, and every sink price in this schema was derived from the
-- ladder that number implies - 5 minor, 50 meaningful, 500 major, 5,000 a
-- fortune. So the daily is tuned to land there:
--
--     day 1   3      first week   39
--     day 2   4      settled     ~53 a week
--     day 3   5
--     day 4   6
--     day 5+  7
--
-- TWENTY-TWO HOURS, NOT TWENTY-FOUR. A hard day means the claim time creeps
-- later every day until it lands in the middle of somebody's night and the
-- streak breaks through no fault of theirs. Two hours of grace costs about
-- half a Jade a week and removes the whole problem.
--
-- AND THE STREAK FORGIVES BY ELAPSED TIME, not by calendar date. A calendar
-- day is a timezone argument this schema has no way to settle - `players` does
-- not know where anybody is - so the rule is simply that a claim within
-- forty-eight hours of the last one continues the run.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE player_daily (
    player_id       BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    streak          INTEGER NOT NULL DEFAULT 0 CHECK (streak >= 0),
    longest_streak  INTEGER NOT NULL DEFAULT 0 CHECK (longest_streak >= 0),
    claims          INTEGER NOT NULL DEFAULT 0 CHECK (claims >= 0),

    last_claimed_at TIMESTAMPTZ
);

COMMENT ON TABLE player_daily IS
    'The daily purse and the run behind it. A streak is not a cooldown, so it does not live in player_cooldowns.';

INSERT INTO game_config (key, value, description) VALUES
    ('daily_cooldown_hours', 22,
     'Wait between daily purses. Deliberately under a day so the claim time does not creep later and break a run by itself.'),
    ('daily_streak_grace_hours', 48,
     'Claim within this of the last one and the run continues. Elapsed time rather than a calendar date, because this schema does not know what timezone anybody is in.'),
    ('daily_jade_base', 3,
     'Spirit Jade on the first day of a run.'),
    ('daily_jade_streak_step', 1,
     'Further Spirit Jade per consecutive day.'),
    ('daily_jade_max', 7,
     'Most one daily purse pays, however long the run. Settles the income near the fifty a week the economy document works from.');

CREATE FUNCTION daily_jade_for_streak(p_streak INTEGER)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('daily_jade_max'),
        game_config_value('daily_jade_base')
        + game_config_value('daily_jade_streak_step') * GREATEST(0, p_streak - 1)
    )::bigint;
$$;

COMMENT ON FUNCTION daily_jade_for_streak(INTEGER) IS
    'What a run of this length pays. Askable for a day nobody has reached, so a screen can show the ladder ahead.';


-- ---------------------------------------------------------------------------
-- claim_daily
-- ---------------------------------------------------------------------------
-- Shaped like `claim_cooldown`: it reports whether it was free to take rather
-- than raising, because "not yet, come back at" is an answer and not an error.

CREATE FUNCTION claim_daily(p_player_id BIGINT)
RETURNS TABLE (
    claimed  BOOLEAN,
    jade     BIGINT,
    streak   INTEGER,
    longest  INTEGER,
    kept     BOOLEAN,
    next_at  TIMESTAMPTZ,
    held     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it      player_daily%ROWTYPE;
    wait    INTERVAL := make_interval(hours => game_config_value('daily_cooldown_hours')::int);
    grace   INTERVAL := make_interval(hours => game_config_value('daily_streak_grace_hours')::int);
    run     INTEGER;
    carried BOOLEAN;
    paid    BIGINT;
BEGIN
    SELECT * INTO it FROM player_daily WHERE player_id = p_player_id FOR UPDATE;

    IF FOUND AND it.last_claimed_at + wait > now() THEN
        RETURN QUERY SELECT FALSE, 0::bigint, it.streak, it.longest_streak, TRUE,
                            it.last_claimed_at + wait, jade_held(p_player_id);
        RETURN;
    END IF;

    -- A run continues if the last claim was recent enough; otherwise it starts
    -- again at one. `kept` is what the screen needs to say which happened.
    carried := FOUND AND it.last_claimed_at IS NOT NULL
               AND it.last_claimed_at + grace > now();
    run := CASE WHEN carried THEN it.streak + 1 ELSE 1 END;

    paid := daily_jade_for_streak(run);

    INSERT INTO player_daily
        (player_id, streak, longest_streak, claims, last_claimed_at)
    VALUES (p_player_id, run, run, 1, now())
    ON CONFLICT (player_id) DO UPDATE
        SET streak          = run,
            longest_streak  = GREATEST(player_daily.longest_streak, run),
            claims          = player_daily.claims + 1,
            last_claimed_at = now();

    PERFORM grant_jade(p_player_id, paid, 'daily');

    RETURN QUERY
    SELECT TRUE, paid, d.streak, d.longest_streak, carried,
           now() + wait, jade_held(p_player_id)
    FROM player_daily d WHERE d.player_id = p_player_id;
END;
$$;

COMMENT ON FUNCTION claim_daily(BIGINT) IS
    'The daily purse. Reports rather than raises when it is not due, the way claim_cooldown does.';
