-- 0426_a_servant_can_change_hands
--
-- Everything else on the table can be traded: manuals, pages, materials, Gu,
-- equipment, pills and unhatched eggs. Servants arrive by a jade wheel at
-- 0.124 per cent for the top tier, duplicates are the only way to raise a
-- star, and there was no way to move one between two cultivators - so a
-- second Fang Yuan in the wrong hands was worth nothing to anybody, and the
-- one person who wanted him could only roll for him.
--
-- The eighth kind on the table, built to the shape the other seven already
-- use: an offer table, an `add` that refuses what cannot be given, a branch in
-- `trade_contents` so the screen names it, a line in `trade_withdraw` so
-- pulling out takes it back, and a loop in `trade_execute` that re-checks
-- ownership under FOR UPDATE before moving anything.
--
-- WHAT CANNOT BE PUT ON THE TABLE, and both refusals already have precedents:
--
--   * one who ATTENDS you. `trade_execute` would move them while a row in
--     `player_servant_attending` still pointed at them, and the stat would go
--     on being felt by somebody who no longer owns them. The forge refuses to
--     trade worn equipment for the same reason and in the same words.
--   * one who is OUT WORKING. They are carrying hours that belong to the
--     person who sent them, and `servant_settle` pays those hours to whoever
--     owns the row when it next runs. Call them home - which settles them -
--     and then give them away.
--
-- WHAT TRAVELS WITH THEM. Stars, realm, cultivation and their standing orders
-- all hang off `player_servant_id`, so they move because the row moves and
-- nothing has to copy them.
--
-- AND WHAT HAPPENS WHEN A DEEP SERVANT LANDS IN SHALLOW HANDS. Nothing
-- breaks, and it is worth writing down rather than guarding: a servant may
-- outrank their owner after a trade, because `servant_climb` only refuses to
-- RAISE one past their master. They keep the realm they were fed to and stop
-- growing until their new owner catches up, and `servant_feed` says so in the
-- sentence it already has. Clamping them down would destroy somebody's pills
-- to enforce a rule that only ever governed climbing.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE trade_offer_servants (
    trade_id          BIGINT NOT NULL REFERENCES trades(trade_id) ON DELETE CASCADE,
    side              SMALLINT NOT NULL CHECK (side IN (0, 1)),
    player_servant_id BIGINT NOT NULL
        REFERENCES player_servants(player_servant_id) ON DELETE CASCADE,
    PRIMARY KEY (trade_id, player_servant_id)
);

CREATE INDEX trade_offer_servants_servant_idx
    ON trade_offer_servants (player_servant_id);

COMMENT ON TABLE trade_offer_servants IS
    'Servants currently on a trade table. The same shape as the other seven offer tables, because it is the same idea.';


-- ---------------------------------------------------------------------------
-- Putting one on the table
-- ---------------------------------------------------------------------------

CREATE FUNCTION trade_add_servant(p_trade_id bigint, p_player_id bigint,
                                  p_player_servant_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
    it    RECORD;
BEGIN
    IF (SELECT status FROM trades WHERE trade_id = p_trade_id) <> 'open' THEN
        RAISE EXCEPTION 'that trade is closed' USING ERRCODE = 'check_violation';
    END IF;

    SELECT ps.farming, s.name INTO it
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that servant is not yours to give'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_servant_attending a
               WHERE a.player_servant_id = p_player_servant_id) THEN
        RAISE EXCEPTION
            '% attends you - send them away before giving them to somebody else',
            it.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.farming THEN
        RAISE EXCEPTION
            '% is out working and carrying hours that are yours - call them home first',
            it.name
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_servants (trade_id, side, player_servant_id)
    VALUES (p_trade_id, which, p_player_servant_id)
    ON CONFLICT (trade_id, player_servant_id) DO NOTHING;
END;
$$;


-- ---------------------------------------------------------------------------
-- The screen names it, withdrawing takes it back, and the deal moves it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    v_def  TEXT;
    body   TEXT;
    anchor TEXT;
BEGIN
    -- ---- the screen -------------------------------------------------------
    -- Appended to the definition Postgres hands back rather than retyped. The
    -- view is seven UNION branches long and copying six of them to add a
    -- seventh is how the copy and the original come to disagree.
    v_def := rtrim(rtrim(pg_get_viewdef('trade_contents'::regclass, true)), ';');

    EXECUTE 'CREATE OR REPLACE VIEW trade_contents AS ' || v_def || '
UNION ALL
 SELECT o.trade_id,
    o.side,
    ''servant''::text AS kind,
    1::bigint AS quantity,
    ((((''T''::text || s.tier) || '' ''::text) || s.name) || '' ''::text)
        || ps.stars || ''*''::text AS label,
    ps.player_servant_id AS ref_id,
    NULL::text AS ref_code
   FROM trade_offer_servants o
     JOIN player_servants ps ON ps.player_servant_id = o.player_servant_id
     JOIN servants s ON s.servant_code = ps.servant_code';

    -- ---- pulling out ------------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trade_withdraw' AND pronamespace = 'public'::regnamespace;

    anchor := '    DELETE FROM trade_offer_eggs      WHERE trade_id = p_trade_id AND side = which;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trade_withdraw no longer clears its eggs where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
anchor, chr(10),
'    DELETE FROM trade_offer_servants  WHERE trade_id = p_trade_id AND side = which;'));

    -- ---- and the deal itself ----------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trade_execute' AND pronamespace = 'public'::regnamespace;

    anchor := '    UPDATE trades SET status = ''complete'', ended_at = now() WHERE trade_id = p_trade_id;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trade_execute no longer closes the deal where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- Servants, added in 0426. Re-checked under FOR UPDATE like everything', chr(10),
'    -- else here: somebody who sends a servant out to work, or calls them to', chr(10),
'    -- attend, between confirming and this moment must not also hand them', chr(10),
'    -- over - the hours and the passive would follow the wrong person.', chr(10),
'    FOR row_m IN', chr(10),
'        SELECT o.side, o.player_servant_id FROM trade_offer_servants o', chr(10),
'        WHERE o.trade_id = p_trade_id', chr(10),
'    LOOP', chr(10),
'        IF row_m.side = 0 THEN', chr(10),
'            giver := deal.proposer_id; taker := deal.partner_id;', chr(10),
'        ELSE', chr(10),
'            giver := deal.partner_id;  taker := deal.proposer_id;', chr(10),
'        END IF;', chr(10),
'', chr(10),
'        PERFORM 1 FROM player_servants ps', chr(10),
'        WHERE ps.player_servant_id = row_m.player_servant_id', chr(10),
'          AND ps.player_id = giver', chr(10),
'          AND NOT ps.farming', chr(10),
'          AND NOT EXISTS (SELECT 1 FROM player_servant_attending a', chr(10),
'                          WHERE a.player_servant_id = ps.player_servant_id)', chr(10),
'        FOR UPDATE;', chr(10),
'', chr(10),
'        IF NOT FOUND THEN', chr(10),
'            RAISE EXCEPTION', chr(10),
'                ''a servant on the table has been sent to work, called to attend, or is no longer theirs''', chr(10),
'                USING ERRCODE = ''check_violation'';', chr(10),
'        END IF;', chr(10),
'', chr(10),
'        UPDATE player_servants SET player_id = taker', chr(10),
'        WHERE player_servant_id = row_m.player_servant_id;', chr(10),
'    END LOOP;', chr(10),
'', chr(10),
anchor));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A servant changes hands, and the ones who cannot do not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a     BIGINT;
    v_b     BIGINT;
    v_trade BIGINT;
    v_id    BIGINT;
    v_stars SMALLINT;
BEGIN
    -- Every route in and out has to know about the new table, or a servant
    -- gets stranded on a cancelled trade.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_withdraw'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%trade_offer_servants%' THEN
        RAISE EXCEPTION 'withdrawing from a trade leaves servants on the table';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_execute'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%trade_offer_servants%' THEN
        RAISE EXCEPTION 'a completed trade does not move its servants';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_views WHERE viewname = 'trade_contents'
                   AND definition LIKE '%trade_offer_servants%') THEN
        RAISE EXCEPTION 'the trade screen cannot see a servant on the table';
    END IF;

    BEGIN
        SELECT player_id INTO v_a FROM players
        WHERE deleted_at IS NULL ORDER BY player_id LIMIT 1;
        SELECT player_id INTO v_b FROM players
        WHERE deleted_at IS NULL AND player_id <> v_a ORDER BY player_id LIMIT 1;
        IF v_b IS NULL THEN
            RAISE EXCEPTION 'probe-ok';        -- nobody to trade with
        END IF;

        INSERT INTO player_servants (player_id, servant_code, realm_id, stars)
        SELECT v_a, s.servant_code, (SELECT min(realm_id) FROM realms), 3
        FROM servants s ORDER BY s.servant_code LIMIT 1
        RETURNING player_servant_id INTO v_id;

        DELETE FROM player_active_trade WHERE player_id IN (v_a, v_b);
        v_trade := trade_open(v_a, v_b);

        -- One who attends may not be given away.
        PERFORM servant_attend(v_a, v_id);
        BEGIN
            PERFORM trade_add_servant(v_trade, v_a, v_id);
            RAISE EXCEPTION 'an attending servant was put on the table';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;
        PERFORM servant_dismiss(v_a, v_id);

        -- Nor one who is out working.
        UPDATE player_servants SET farming = TRUE WHERE player_servant_id = v_id;
        BEGIN
            PERFORM trade_add_servant(v_trade, v_a, v_id);
            RAISE EXCEPTION 'a working servant was put on the table';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;
        UPDATE player_servants SET farming = FALSE WHERE player_servant_id = v_id;

        -- Idle and unattached, they can be given.
        PERFORM trade_add_servant(v_trade, v_a, v_id);
        IF NOT EXISTS (SELECT 1 FROM trade_contents
                       WHERE trade_id = v_trade AND kind = 'servant') THEN
            RAISE EXCEPTION 'the table does not show the servant on it';
        END IF;

        PERFORM trade_confirm(v_trade, v_a);
        PERFORM trade_confirm(v_trade, v_b);

        SELECT player_id, stars INTO v_b, v_stars
        FROM player_servants WHERE player_servant_id = v_id;

        IF v_b <> (SELECT partner_id FROM trades WHERE trade_id = v_trade) THEN
            RAISE EXCEPTION 'the servant did not change hands';
        END IF;
        IF v_stars <> 3 THEN
            RAISE EXCEPTION 'the servant arrived at % stars rather than 3',
                v_stars;
        END IF;

        RAISE NOTICE 'a three-star servant changed hands with its stars intact';
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
