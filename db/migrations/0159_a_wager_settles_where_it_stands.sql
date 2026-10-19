-- 0159_a_wager_settles_where_it_stands
--
-- A wager between two people was an offer: the challenger's stake was escrowed
-- and it sat there until the other one pressed a button, lapsed after ten
-- minutes, or was waved off. Both rolls and the payout already happened in one
-- statement on accept - the waiting was the whole of the delay.
--
-- Now it resolves where it is issued. Both stakes are taken, both dice are
-- thrown, the pot is paid, all in the same call.
--
-- WHAT THIS GIVES UP, PLAINLY: consent. Anybody can now put another
-- cultivator's Jade at risk without being asked. On a server of friends with a
-- twenty-five Jade ceiling that is a trade worth making and it is what was
-- asked for - but it is a real change and not a detail, so it is written down
-- here rather than discovered later. An opt-out is a small table away if it
-- ever stops being funny.
--
-- BOTH PURSES ARE CHECKED BEFORE EITHER IS TOUCHED. Without that, a challenge
-- against somebody who cannot cover it takes the challenger's stake and then
-- fails - the half-completed transaction that escrow existed to prevent. The
-- ordering is what replaces it.
--
-- The pending machinery goes with it. `offer_wager`, `accept_wager`,
-- `decline_wager` and `expire_wagers` have nothing left to do, and leaving
-- four working functions nobody calls is how a schema starts lying about what
-- it does.
--
-- Forward-only. Do not edit once applied.


-- The one challenge standing right now has somebody's Jade in it. It can never
-- be accepted after this, so it goes home first.
DO $$
DECLARE
    stuck RECORD;
BEGIN
    FOR stuck IN
        SELECT wager_id, challenger_id, stake FROM wagers WHERE status = 'pending'
    LOOP
        PERFORM grant_jade(stuck.challenger_id, stuck.stake, 'wager_flow_retired');
        UPDATE wagers SET status = 'expired', settled_at = now()
        WHERE wager_id = stuck.wager_id;
        RAISE NOTICE 'refunded % Jade from a challenge that can no longer be taken',
            stuck.stake;
    END LOOP;
END;
$$;


DROP FUNCTION accept_wager(BIGINT, BIGINT);
DROP FUNCTION decline_wager(BIGINT, BIGINT);
DROP FUNCTION offer_wager(BIGINT, BIGINT, BIGINT);
DROP FUNCTION expire_wagers();

-- Nothing is pending any more, so the index that enforced one at a time has
-- nothing to enforce.
DROP INDEX wagers_one_pending_per_pair;
DROP INDEX wagers_pending_idx;

COMMENT ON COLUMN wagers.status IS
    'Always ''settled'' from 0159 on. The other three are history: wagers used to be offers that could lapse or be waved off.';


CREATE FUNCTION wager_now(
    p_challenger_id BIGINT, p_opponent_id BIGINT, p_stake BIGINT
)
RETURNS TABLE (
    wager_id        BIGINT,
    stake           BIGINT,
    pot             BIGINT,
    challenger_roll SMALLINT,
    opponent_roll   SMALLINT,
    winner_id       BIGINT,
    tied            BOOLEAN,
    challenger_left BIGINT,
    opponent_left   BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    lo    BIGINT := game_config_value('gamble_min_stake')::bigint;
    hi    BIGINT := game_config_value('gamble_max_stake')::bigint;
    mine  SMALLINT;
    yours SMALLINT;
    won   BIGINT;
    made  BIGINT;
BEGIN
    IF p_challenger_id = p_opponent_id THEN
        RAISE EXCEPTION 'you cannot stake against yourself'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_stake < lo OR p_stake > hi THEN
        RAISE EXCEPTION 'a wager is between % and % Spirit Jade', lo, hi
            USING ERRCODE = 'check_violation';
    END IF;

    -- Both purses, before either is touched. `spend_jade` would refuse the
    -- second one on its own, but by then the first is gone - and there is no
    -- escrow left to unwind it from.
    IF jade_held(p_challenger_id) < p_stake THEN
        RAISE EXCEPTION 'you hold % Spirit Jade and staked %',
            jade_held(p_challenger_id), p_stake
            USING ERRCODE = 'check_violation';
    END IF;

    IF jade_held(p_opponent_id) < p_stake THEN
        RAISE EXCEPTION 'they hold % Spirit Jade and cannot cover %',
            jade_held(p_opponent_id), p_stake
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM spend_jade(p_challenger_id, p_stake, 'wager_staked');
    PERFORM spend_jade(p_opponent_id, p_stake, 'wager_staked');

    mine  := 1 + floor(random() * 100);
    yours := 1 + floor(random() * 100);

    won := CASE
        WHEN mine > yours THEN p_challenger_id
        WHEN yours > mine THEN p_opponent_id
        ELSE NULL
    END;

    IF won IS NULL THEN
        PERFORM grant_jade(p_challenger_id, p_stake, 'wager_tied');
        PERFORM grant_jade(p_opponent_id, p_stake, 'wager_tied');
    ELSE
        PERFORM grant_jade(won, p_stake * 2, 'wager_won');
    END IF;

    INSERT INTO wagers
        (challenger_id, opponent_id, stake, status, challenger_roll,
         opponent_roll, winner_id, expires_at, settled_at)
    VALUES (p_challenger_id, p_opponent_id, p_stake, 'settled', mine, yours,
            won, now(), now())
    RETURNING wagers.wager_id INTO made;

    RETURN QUERY SELECT made, p_stake, p_stake * 2, mine, yours, won,
                        won IS NULL,
                        jade_held(p_challenger_id), jade_held(p_opponent_id);
END;
$$;

COMMENT ON FUNCTION wager_now(BIGINT, BIGINT, BIGINT) IS
    'One wager, settled where it stands: both stakes taken, both dice thrown, the pot paid. Checks both purses before touching either.';


DO $$
DECLARE
    a      BIGINT;
    b      BIGINT;
    poor   BIGINT;
    got    RECORD;
    before_total BIGINT;
    ties   INTEGER := 0;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999159, 'wager probe a') RETURNING player_id INTO a;
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999160, 'wager probe b') RETURNING player_id INTO b;
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999161, 'wager probe skint') RETURNING player_id INTO poor;

    PERFORM grant_jade(a, 300, 'probe');
    PERFORM grant_jade(b, 300, 'probe');
    PERFORM grant_jade(poor, 1, 'probe');
    before_total := jade_held(a) + jade_held(b);

    FOR i IN 1..40 LOOP
        SELECT * INTO got FROM wager_now(a, b, 5);
        IF got.challenger_roll IS NULL OR got.opponent_roll IS NULL THEN
            RAISE EXCEPTION 'a wager settled without both dice';
        END IF;
        IF got.tied THEN
            ties := ties + 1;
            IF got.winner_id IS NOT NULL THEN
                RAISE EXCEPTION 'a tie named a winner';
            END IF;
        ELSIF got.winner_id IS NULL THEN
            RAISE EXCEPTION 'a decided wager named nobody';
        END IF;
    END LOOP;

    IF jade_held(a) + jade_held(b) <> before_total THEN
        RAISE EXCEPTION 'forty wagers moved the pair from % to %',
            before_total, jade_held(a) + jade_held(b);
    END IF;

    -- An opponent who cannot cover it costs the challenger nothing.
    BEGIN
        PERFORM wager_now(a, poor, 20);
        RAISE EXCEPTION 'a wager nobody could cover was taken';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;
    IF jade_held(poor) <> 1 THEN
        RAISE EXCEPTION 'a refused wager took the poor one''s Jade';
    END IF;

    DELETE FROM wagers WHERE challenger_id IN (a, b, poor)
                          OR opponent_id IN (a, b, poor);
    DELETE FROM jade_ledger WHERE player_id IN (a, b, poor);
    DELETE FROM player_materials WHERE player_id IN (a, b, poor);
    DELETE FROM players WHERE player_id IN (a, b, poor);
END;
$$;
