-- 0160_both_hands_on_the_table
--
-- 0159 settled a wager where it was issued, which meant anybody could put
-- another cultivator's Jade at risk without being asked. That was flagged when
-- it went in and it is being taken back out: a wager now needs BOTH people to
-- say yes.
--
-- Two acceptances, not one. The old flow before 0159 had the challenger
-- consenting by typing the command and the opponent pressing a button - which
-- is two people agreeing, but it is not two people accepting, and a mistyped
-- mention was a wager. Now each side presses, and nothing happens until both
-- have.
--
-- THE STAKE IS ESCROWED PER SIDE, AS EACH ACCEPTS. Half-agreed is a real state
-- that can sit for ten minutes, so whoever has said yes has their Jade held
-- from that moment - they cannot spend it and then win with money they no
-- longer have. Whoever has not said yes has parted with nothing. A decline or
-- a lapse hands back exactly what was taken, from whoever it was taken from.
--
-- `wager_now` goes. Leaving a function that settles without asking, next to a
-- flow that exists to ask, is leaving the gate open beside the fence.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION wager_now(BIGINT, BIGINT, BIGINT);


ALTER TABLE wagers
    ADD COLUMN challenger_ok TIMESTAMPTZ,
    ADD COLUMN opponent_ok   TIMESTAMPTZ,
    -- A settled wager is one both sides accepted. Stated as a constraint
    -- because it is the whole point of this migration.
    ADD CONSTRAINT wager_settled_needs_both
        CHECK (status <> 'settled'
               OR (challenger_ok IS NOT NULL AND opponent_ok IS NOT NULL));

COMMENT ON COLUMN wagers.challenger_ok IS
    'When the challenger accepted, and therefore when their stake was escrowed. NULL means they have not yet - and have parted with nothing.';

-- Rows settled under 0159 were never accepted by anybody. Backfilled to their
-- settlement time so the constraint above describes history as well as it
-- describes what happens next.
UPDATE wagers
SET challenger_ok = COALESCE(challenger_ok, settled_at),
    opponent_ok   = COALESCE(opponent_ok, settled_at)
WHERE status = 'settled';

-- One standing wager per pair again, so a pile of half-agreed offers cannot
-- escrow somebody's whole purse.
CREATE UNIQUE INDEX wagers_one_pending_per_pair
    ON wagers (challenger_id, opponent_id) WHERE status = 'pending';
CREATE INDEX wagers_pending_idx ON wagers (expires_at) WHERE status = 'pending';


-- ---------------------------------------------------------------------------
-- Lapsing
-- ---------------------------------------------------------------------------

CREATE FUNCTION expire_wagers()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER := 0;
    dead RECORD;
BEGIN
    FOR dead IN
        SELECT wager_id, challenger_id, opponent_id, stake,
               challenger_ok, opponent_ok
        FROM wagers
        WHERE status = 'pending' AND expires_at <= now()
        FOR UPDATE
    LOOP
        -- Back to whoever actually paid, which is whoever accepted.
        IF dead.challenger_ok IS NOT NULL THEN
            PERFORM grant_jade(dead.challenger_id, dead.stake, 'wager_expired');
        END IF;
        IF dead.opponent_ok IS NOT NULL THEN
            PERFORM grant_jade(dead.opponent_id, dead.stake, 'wager_expired');
        END IF;

        UPDATE wagers SET status = 'expired', settled_at = now()
        WHERE wager_id = dead.wager_id;
        gone := gone + 1;
    END LOOP;
    RETURN gone;
END;
$$;

COMMENT ON FUNCTION expire_wagers() IS
    'Lapses half-agreed wagers and hands back exactly what was escrowed, to whoever it was escrowed from.';


CREATE FUNCTION offer_wager(
    p_challenger_id BIGINT, p_opponent_id BIGINT, p_stake BIGINT
) RETURNS TABLE (
    wager_id   BIGINT,
    stake      BIGINT,
    expires_at TIMESTAMPTZ
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

    -- Nothing is taken here. Offering is not accepting - that is the whole
    -- distinction this migration exists to draw.
    IF jade_held(p_challenger_id) < p_stake THEN
        RAISE EXCEPTION 'you hold % Spirit Jade and staked %',
            jade_held(p_challenger_id), p_stake
            USING ERRCODE = 'check_violation';
    END IF;

    ends := now() + make_interval(
        mins => game_config_value('wager_expiry_minutes')::int);

    INSERT INTO wagers (challenger_id, opponent_id, stake, expires_at)
    VALUES (p_challenger_id, p_opponent_id, p_stake, ends)
    RETURNING wagers.wager_id INTO made;

    RETURN QUERY SELECT made, p_stake, ends;
END;
$$;

COMMENT ON FUNCTION offer_wager(BIGINT, BIGINT, BIGINT) IS
    'Puts a wager on the table. Takes nothing: both sides accept separately, and each pays as they do.';


CREATE FUNCTION accept_wager(p_wager_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (
    wager_id        BIGINT,
    stake           BIGINT,
    pot             BIGINT,
    challenger_id   BIGINT,
    opponent_id     BIGINT,
    settled         BOOLEAN,
    waiting_on      BIGINT,
    challenger_roll SMALLINT,
    opponent_roll   SMALLINT,
    winner_id       BIGINT,
    tied            BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    it    RECORD;
    mine  SMALLINT;
    yours SMALLINT;
    won   BIGINT;
    ok_c  TIMESTAMPTZ;
    ok_o  TIMESTAMPTZ;
BEGIN
    SELECT * INTO it FROM wagers w
    WHERE w.wager_id = p_wager_id AND w.status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that wager is not standing any more'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_player_id NOT IN (it.challenger_id, it.opponent_id) THEN
        RAISE EXCEPTION 'that wager is not yours to answer'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.expires_at <= now() THEN
        PERFORM expire_wagers();
        RAISE EXCEPTION 'that wager lapsed before you answered it'
            USING ERRCODE = 'check_violation';
    END IF;

    ok_c := it.challenger_ok;
    ok_o := it.opponent_ok;

    IF p_player_id = it.challenger_id THEN
        IF ok_c IS NOT NULL THEN
            RAISE EXCEPTION 'you have already accepted this one'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, it.stake, 'wager_accepted');
        ok_c := now();
    ELSE
        IF ok_o IS NOT NULL THEN
            RAISE EXCEPTION 'you have already accepted this one'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, it.stake, 'wager_accepted');
        ok_o := now();
    END IF;

    -- Half agreed. The Jade of whoever has said yes is held until the other
    -- answers or the clock runs out.
    IF ok_c IS NULL OR ok_o IS NULL THEN
        UPDATE wagers SET challenger_ok = ok_c, opponent_ok = ok_o
        WHERE wagers.wager_id = p_wager_id;

        RETURN QUERY SELECT p_wager_id, it.stake, it.stake * 2,
                            it.challenger_id, it.opponent_id,
                            FALSE,
                            CASE WHEN ok_c IS NULL THEN it.challenger_id
                                 ELSE it.opponent_id END,
                            NULL::smallint, NULL::smallint, NULL::bigint,
                            NULL::boolean;
        RETURN;
    END IF;

    mine  := 1 + floor(random() * 100);
    yours := 1 + floor(random() * 100);

    won := CASE
        WHEN mine > yours THEN it.challenger_id
        WHEN yours > mine THEN it.opponent_id
        ELSE NULL
    END;

    IF won IS NULL THEN
        PERFORM grant_jade(it.challenger_id, it.stake, 'wager_tied');
        PERFORM grant_jade(it.opponent_id, it.stake, 'wager_tied');
    ELSE
        PERFORM grant_jade(won, it.stake * 2, 'wager_won');
    END IF;

    UPDATE wagers
    SET status = 'settled', settled_at = now(),
        challenger_ok = ok_c, opponent_ok = ok_o,
        challenger_roll = mine, opponent_roll = yours, winner_id = won
    WHERE wagers.wager_id = p_wager_id;

    RETURN QUERY SELECT p_wager_id, it.stake, it.stake * 2,
                        it.challenger_id, it.opponent_id,
                        TRUE, NULL::bigint, mine, yours, won, won IS NULL;
END;
$$;

COMMENT ON FUNCTION accept_wager(BIGINT, BIGINT) IS
    'One side saying yes, and escrowing their half as they do. The dice are thrown only when both have.';


CREATE FUNCTION decline_wager(p_wager_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (stake BIGINT, refunded BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    it   RECORD;
    back BIGINT := 0;
BEGIN
    SELECT * INTO it FROM wagers w
    WHERE w.wager_id = p_wager_id AND w.status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that wager is not standing any more'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_player_id NOT IN (it.challenger_id, it.opponent_id) THEN
        RAISE EXCEPTION 'that wager is not yours to answer'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.challenger_ok IS NOT NULL THEN
        PERFORM grant_jade(it.challenger_id, it.stake, 'wager_declined');
        back := back + it.stake;
    END IF;
    IF it.opponent_ok IS NOT NULL THEN
        PERFORM grant_jade(it.opponent_id, it.stake, 'wager_declined');
        back := back + it.stake;
    END IF;

    UPDATE wagers SET status = 'declined', settled_at = now()
    WHERE wagers.wager_id = p_wager_id;

    RETURN QUERY SELECT it.stake, back;
END;
$$;


DO $$
DECLARE
    a     BIGINT;
    b     BIGINT;
    made  RECORD;
    step  RECORD;
    total BIGINT;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999162, 'consent probe a') RETURNING player_id INTO a;
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999163, 'consent probe b') RETURNING player_id INTO b;
    PERFORM grant_jade(a, 200, 'probe');
    PERFORM grant_jade(b, 200, 'probe');
    total := jade_held(a) + jade_held(b);

    -- Offering takes nothing.
    SELECT * INTO made FROM offer_wager(a, b, 10);
    IF jade_held(a) + jade_held(b) <> total THEN
        RAISE EXCEPTION 'offering took Jade before anybody accepted';
    END IF;

    -- One acceptance escrows one half and settles nothing.
    SELECT * INTO step FROM accept_wager(made.wager_id, a);
    IF step.settled THEN
        RAISE EXCEPTION 'one acceptance settled the wager';
    END IF;
    IF step.waiting_on <> b THEN
        RAISE EXCEPTION 'the wager is waiting on the wrong person';
    END IF;
    IF jade_held(a) <> total - jade_held(b) - 10 THEN
        RAISE EXCEPTION 'accepting did not escrow that side''s stake';
    END IF;

    -- The same side cannot accept twice.
    BEGIN
        PERFORM accept_wager(made.wager_id, a);
        RAISE EXCEPTION 'one person accepted twice';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- The second settles it, and the pair is no poorer for the whole thing.
    SELECT * INTO step FROM accept_wager(made.wager_id, b);
    IF NOT step.settled THEN
        RAISE EXCEPTION 'two acceptances did not settle it';
    END IF;
    IF step.challenger_roll IS NULL OR step.opponent_roll IS NULL THEN
        RAISE EXCEPTION 'a settled wager kept no dice';
    END IF;
    IF jade_held(a) + jade_held(b) <> total THEN
        RAISE EXCEPTION 'a settled wager was not zero sum';
    END IF;

    -- A decline after one acceptance hands that one back and takes nothing.
    SELECT * INTO made FROM offer_wager(a, b, 7);
    PERFORM accept_wager(made.wager_id, a);
    PERFORM decline_wager(made.wager_id, b);
    IF jade_held(a) + jade_held(b) <> total THEN
        RAISE EXCEPTION 'declining a half-agreed wager kept somebody''s stake';
    END IF;

    -- And so does lapsing.
    SELECT * INTO made FROM offer_wager(a, b, 9);
    PERFORM accept_wager(made.wager_id, b);
    UPDATE wagers SET expires_at = now() - interval '1 minute'
    WHERE wager_id = made.wager_id;
    PERFORM expire_wagers();
    IF jade_held(a) + jade_held(b) <> total THEN
        RAISE EXCEPTION 'a lapsed half-agreed wager kept somebody''s stake';
    END IF;

    DELETE FROM wagers WHERE challenger_id IN (a, b) OR opponent_id IN (a, b);
    DELETE FROM jade_ledger WHERE player_id IN (a, b);
    DELETE FROM player_materials WHERE player_id IN (a, b);
    DELETE FROM players WHERE player_id IN (a, b);
END;
$$;
