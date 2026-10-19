-- 0150_a_wager_between_two_cultivators
--
-- The other half of the table: staking Jade against another person rather than
-- against the house.
--
-- ZERO SUM, AND THAT IS THE POINT. The house game in 0149 needed a four per
-- cent edge because an opponent with infinite Jade is otherwise a faucet. Two
-- cultivators are not: what one loses the other wins, the currency's total is
-- untouched, and no rake is taken. A cut here would be a sink pretending to be
-- a game between friends.
--
-- THE STAKE IS ESCROWED AT THE CHALLENGE. Both halves have to be somewhere the
-- owner cannot spend them, or the loser settles up by simply not having it any
-- more - which is the failure `auction_listings` escrows goods to avoid. The
-- challenger's Jade is taken when they offer; the opponent's when they accept;
-- the pot is paid out in the same statement that decides it.
--
-- A DECLINED OR EXPIRED WAGER REFUNDS IN FULL. This is not the refinement
-- table - nothing was risked until both sides agreed, so nothing is kept.
--
-- TIES RETURN BOTH STAKES. A d100 ties one time in a hundred and there is no
-- house here to break it in favour of.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('wager_expiry_minutes', 10,
     'How long a challenge stands before it lapses and both stakes go home.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


CREATE TABLE wagers (
    wager_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    challenger_id BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    opponent_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    stake        BIGINT NOT NULL CHECK (stake > 0),

    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'settled', 'declined', 'expired')),

    challenger_roll SMALLINT CHECK (challenger_roll BETWEEN 1 AND 100),
    opponent_roll   SMALLINT CHECK (opponent_roll BETWEEN 1 AND 100),
    -- NULL on a tie, which is why this cannot simply be inferred from status.
    winner_id    BIGINT REFERENCES players (player_id) ON DELETE SET NULL,

    offered_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL,
    settled_at   TIMESTAMPTZ,

    CONSTRAINT wager_needs_two_people CHECK (challenger_id <> opponent_id),
    CONSTRAINT wager_settled_is_whole
        CHECK ((status = 'settled')
               = (challenger_roll IS NOT NULL AND opponent_roll IS NOT NULL)),
    CONSTRAINT wager_ended_matches_status
        CHECK ((status = 'pending') = (settled_at IS NULL))
);

-- One open challenge each way at a time, so a pile of pending offers cannot
-- escrow somebody's whole purse.
CREATE UNIQUE INDEX wagers_one_pending_per_pair
    ON wagers (challenger_id, opponent_id) WHERE status = 'pending';

CREATE INDEX wagers_challenger_idx ON wagers (challenger_id, offered_at DESC);
CREATE INDEX wagers_opponent_idx ON wagers (opponent_id, offered_at DESC);
CREATE INDEX wagers_winner_idx ON wagers (winner_id) WHERE winner_id IS NOT NULL;
CREATE INDEX wagers_pending_idx ON wagers (expires_at) WHERE status = 'pending';

COMMENT ON TABLE wagers IS
    'A stake between two cultivators. The challenger''s Jade is escrowed from the moment it is offered; the opponent''s from the moment it is accepted.';


-- ---------------------------------------------------------------------------
-- Lapsing, without a scheduler
-- ---------------------------------------------------------------------------
-- Same trick as the world beast: the screens that would show a challenge sweep
-- the stale ones first. A wager nobody is looking at can sit there.

CREATE FUNCTION expire_wagers()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER := 0;
    dead RECORD;
BEGIN
    FOR dead IN
        SELECT wager_id, challenger_id, stake FROM wagers
        WHERE status = 'pending' AND expires_at <= now()
        FOR UPDATE
    LOOP
        PERFORM grant_jade(dead.challenger_id, dead.stake, 'wager_expired');
        UPDATE wagers SET status = 'expired', settled_at = now()
        WHERE wager_id = dead.wager_id;
        gone := gone + 1;
    END LOOP;
    RETURN gone;
END;
$$;

COMMENT ON FUNCTION expire_wagers() IS
    'Lapses challenges nobody answered and hands the escrowed stakes back. Called by the screens rather than by a scheduler.';


CREATE FUNCTION offer_wager(
    p_challenger_id BIGINT, p_opponent_id BIGINT, p_stake BIGINT
) RETURNS TABLE (
    wager_id   BIGINT,
    stake      BIGINT,
    expires_at TIMESTAMPTZ,
    jade_left  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    lo   BIGINT := game_config_value('gamble_min_stake')::bigint;
    hi   BIGINT := game_config_value('gamble_max_stake')::bigint;
    made BIGINT;
    ends TIMESTAMPTZ;
BEGIN
    PERFORM expire_wagers();

    IF p_challenger_id = p_opponent_id THEN
        RAISE EXCEPTION 'you cannot stake against yourself'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_stake < lo OR p_stake > hi THEN
        RAISE EXCEPTION 'a wager is between % and % Spirit Jade', lo, hi
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM wagers w
               WHERE w.status = 'pending'
                 AND w.challenger_id = p_challenger_id
                 AND w.opponent_id = p_opponent_id) THEN
        RAISE EXCEPTION 'you already have a wager standing with them'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Escrowed now. It refuses rather than going negative, so a challenge
    -- nobody could honour is never made.
    PERFORM spend_jade(p_challenger_id, p_stake, 'wager_offered');

    ends := now() + make_interval(
        mins => game_config_value('wager_expiry_minutes')::int);

    INSERT INTO wagers (challenger_id, opponent_id, stake, expires_at)
    VALUES (p_challenger_id, p_opponent_id, p_stake, ends)
    RETURNING wagers.wager_id INTO made;

    RETURN QUERY SELECT made, p_stake, ends, jade_held(p_challenger_id);
END;
$$;

COMMENT ON FUNCTION offer_wager(BIGINT, BIGINT, BIGINT) IS
    'Offers a stake to one cultivator and escrows the challenger''s half of it.';


CREATE FUNCTION decline_wager(p_wager_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (stake BIGINT, refunded_to BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    it RECORD;
BEGIN
    SELECT * INTO it FROM wagers w
    WHERE w.wager_id = p_wager_id AND w.status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that wager is not standing any more'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Either side may call it off. Nothing was risked until both agreed.
    IF p_player_id NOT IN (it.challenger_id, it.opponent_id) THEN
        RAISE EXCEPTION 'that wager is not yours to answer'
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM grant_jade(it.challenger_id, it.stake, 'wager_declined');
    UPDATE wagers SET status = 'declined', settled_at = now()
    WHERE wager_id = p_wager_id;

    RETURN QUERY SELECT it.stake, it.challenger_id;
END;
$$;


CREATE FUNCTION accept_wager(p_wager_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (
    wager_id        BIGINT,
    stake           BIGINT,
    pot             BIGINT,
    challenger_id   BIGINT,
    opponent_id     BIGINT,
    challenger_roll SMALLINT,
    opponent_roll   SMALLINT,
    winner_id       BIGINT,
    tied            BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    it   RECORD;
    mine SMALLINT;
    them SMALLINT;
    won  BIGINT;
BEGIN
    SELECT * INTO it FROM wagers w
    WHERE w.wager_id = p_wager_id AND w.status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that wager is not standing any more'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.opponent_id <> p_player_id THEN
        RAISE EXCEPTION 'that wager was not offered to you'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.expires_at <= now() THEN
        PERFORM expire_wagers();
        RAISE EXCEPTION 'that wager lapsed before you answered it'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The opponent's half, escrowed by being spent. If they cannot cover it
    -- this raises and the challenger's stake stays where it is, which is what
    -- keeps a wager either wholly on or wholly off.
    PERFORM spend_jade(p_player_id, it.stake, 'wager_accepted');

    them := 1 + floor(random() * 100);
    mine := 1 + floor(random() * 100);

    won := CASE
        WHEN them > mine THEN it.challenger_id
        WHEN mine > them THEN it.opponent_id
        ELSE NULL
    END;

    IF won IS NULL THEN
        -- A tie takes nothing from anybody. There is no house here to break it
        -- in favour of, and inventing one would be a rake by another name.
        PERFORM grant_jade(it.challenger_id, it.stake, 'wager_tied');
        PERFORM grant_jade(it.opponent_id, it.stake, 'wager_tied');
    ELSE
        PERFORM grant_jade(won, it.stake * 2, 'wager_won');
    END IF;

    UPDATE wagers
    SET status = 'settled', settled_at = now(),
        challenger_roll = them, opponent_roll = mine, winner_id = won
    WHERE wagers.wager_id = p_wager_id;

    RETURN QUERY SELECT p_wager_id, it.stake, it.stake * 2,
                        it.challenger_id, it.opponent_id,
                        them, mine, won, won IS NULL;
END;
$$;

COMMENT ON FUNCTION accept_wager(BIGINT, BIGINT) IS
    'Takes the opponent''s half, rolls both sides and settles in one statement. A tie hands both stakes back.';


-- ---------------------------------------------------------------------------
-- Nothing may be created or destroyed here
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    a     BIGINT;
    b     BIGINT;
    made  RECORD;
    done  RECORD;
    before_total BIGINT;
    after_total  BIGINT;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999150, 'migration 0150 probe a') RETURNING player_id INTO a;
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999151, 'migration 0150 probe b') RETURNING player_id INTO b;

    PERFORM grant_jade(a, 100, 'probe');
    PERFORM grant_jade(b, 100, 'probe');
    before_total := jade_held(a) + jade_held(b);

    -- Twenty settled wagers: the pair's total Jade must be untouched by all of
    -- them, which is the whole claim this half of the feature makes.
    FOR i IN 1..20 LOOP
        SELECT * INTO made FROM offer_wager(a, b, 5);
        SELECT * INTO done FROM accept_wager(made.wager_id, b);

        IF done.tied THEN
            IF done.winner_id IS NOT NULL THEN
                RAISE EXCEPTION 'a tie named a winner';
            END IF;
        ELSIF done.winner_id IS NULL THEN
            RAISE EXCEPTION 'a decided wager named nobody';
        END IF;
    END LOOP;

    after_total := jade_held(a) + jade_held(b);
    IF after_total <> before_total THEN
        RAISE EXCEPTION
            'twenty wagers moved the pair from % Jade to %; this must be zero sum',
            before_total, after_total;
    END IF;

    -- A declined wager gives the escrow back whole.
    SELECT * INTO made FROM offer_wager(a, b, 7);
    IF jade_held(a) <> after_total - jade_held(b) - 7 THEN
        RAISE EXCEPTION 'offering did not escrow the stake';
    END IF;
    PERFORM decline_wager(made.wager_id, b);
    IF jade_held(a) + jade_held(b) <> before_total THEN
        RAISE EXCEPTION 'declining did not hand the stake back';
    END IF;

    -- And an expired one does too.
    SELECT * INTO made FROM offer_wager(a, b, 9);
    UPDATE wagers SET expires_at = now() - interval '1 minute'
    WHERE wager_id = made.wager_id;
    PERFORM expire_wagers();
    IF jade_held(a) + jade_held(b) <> before_total THEN
        RAISE EXCEPTION 'a lapsed wager kept somebody''s stake';
    END IF;

    DELETE FROM wagers WHERE challenger_id IN (a, b) OR opponent_id IN (a, b);
    DELETE FROM jade_ledger WHERE player_id IN (a, b);
    DELETE FROM player_materials WHERE player_id IN (a, b);
    DELETE FROM players WHERE player_id IN (a, b);
END;
$$;
