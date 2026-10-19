-- 0305_a_pill_can_change_hands_across_a_table
--
-- Manuals, pages, materials, Gu and gear can all be put on the table. Pills
-- could not, which is the odd one out twice over: a pill is the one thing in
-- this game somebody brews specifically for somebody else, and it has been
-- sellable at auction since auctions existed. You could sell a friend a pill
-- through the house and pay the fee; you could not simply hand it to them.
--
-- THE WHOLE STACK MOVES, because that is what `auction_list_pill` does - it
-- changes `owner_id` and nothing else. Pills carry tier, kind, Path,
-- magnitude, harmony and potency per row, so splitting a stack means minting
-- a second row and deciding which of those travel. The auction declined to
-- invent that and so does this: one row, one owner, whole.
--
-- EVERY PIECE OF THE PATTERN IS COPIED DELIBERATELY:
--
--   the offer table    shaped like trade_offer_equipment
--   the reset trigger  because an offer that changes AFTER both sides have
--                      confirmed is the whole of how a trade gets stolen
--   the withdraw       or a withdrawn side leaves its pills behind and the
--                      trade hands over something nobody offered
--   trade_contents     or the pill is on the table and invisible on the card
--   trade_execute      or the pill is promised and never delivered
--
-- Four of those five are the kind of omission that does not error. It just
-- quietly hands somebody the wrong thing, which is why each one gets its own
-- assertion at the bottom rather than a glance at the diff.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE trade_offer_pills (
    trade_id BIGINT   NOT NULL REFERENCES trades(trade_id) ON DELETE CASCADE,
    side     SMALLINT NOT NULL,
    pill_id  BIGINT   NOT NULL REFERENCES player_pills(pill_id) ON DELETE CASCADE,
    PRIMARY KEY (trade_id, pill_id)
);

COMMENT ON TABLE trade_offer_pills IS
    'Pills one side has put on the table. Whole stacks, the way the auction moves them.';

-- The primary key leads with trade_id, so the pill_id foreign key needs its
-- own - the house rule, and the same one 0300 was caught by.
CREATE INDEX trade_offer_pills_pill_idx ON trade_offer_pills (pill_id);

CREATE TRIGGER trade_offer_pills_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_pills
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();


CREATE FUNCTION trade_add_pill(
    p_trade_id BIGINT, p_player_id BIGINT, p_pill_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
BEGIN
    IF (SELECT status FROM trades WHERE trade_id = p_trade_id) <> 'open' THEN
        RAISE EXCEPTION 'that trade is closed' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM player_pills
        WHERE pill_id = p_pill_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that pill is not yours to give'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_pills (trade_id, side, pill_id)
    VALUES (p_trade_id, which, p_pill_id)
    ON CONFLICT (trade_id, pill_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION trade_add_pill(BIGINT, BIGINT, BIGINT) IS
    'Puts a pill stack on the table. Whole stacks only, as the auction does.';


-- ---------------------------------------------------------------------------
-- A withdrawn side takes its pills back with it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    DELETE FROM trade_offer_equipment WHERE trade_id = p_trade_id AND side = which;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'trade_withdraw';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trade_withdraw does not clear gear where it did';
    END IF;

    body := replace(body, anchor, anchor || chr(10) ||
'    DELETE FROM trade_offer_pills     WHERE trade_id = p_trade_id AND side = which;');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The card shows it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    def TEXT;
BEGIN
    -- Lifted and appended rather than retyped. The first draft wrote all six
    -- branches out by hand and fell over on `e.rank`, which is a reserved
    -- word in a SELECT list - a good reminder that retyping five working
    -- branches to add a sixth is five chances to break something that was
    -- already right.
    SELECT pg_get_viewdef('trade_contents'::regclass, true) INTO def;

    IF def IS NULL THEN
        RAISE EXCEPTION 'trade_contents is missing';
    END IF;
    IF def LIKE '%trade_offer_pills%' THEN
        RAISE EXCEPTION 'trade_contents already knows about pills';
    END IF;

    EXECUTE 'CREATE OR REPLACE VIEW trade_contents AS '
        || rtrim(rtrim(def), ';')
        || ' UNION ALL
    -- The quantity is the stack''s own, so a card that says 3x is telling
    -- the truth about what crosses the table rather than counting rows.
    SELECT o.trade_id, o.side, ''pill''::text, pp.quantity,
           ''T'' || pp.tier || '' '' || pp.name, pp.pill_id, pp.kind
    FROM trade_offer_pills o
    JOIN player_pills pp ON pp.pill_id = o.pill_id';
END;
$$;


-- ---------------------------------------------------------------------------
-- And it actually crosses
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    UPDATE trades SET status = ''complete'', ended_at = now() WHERE trade_id = p_trade_id;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'trade_execute';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the closing of trade_execute is not where it was';
    END IF;

    -- Placed immediately before the trade is closed out, so it runs after
    -- every other kind has moved and before anything is marked complete.
    body := replace(body, anchor,
'    -- Pills, whole stacks, the way the auction moves them. Locked on the
    -- way past like everything else here: a stack that went somewhere else
    -- between the confirmation and this moment must not be handed over.
    FOR row_m IN
        SELECT o.side, o.pill_id FROM trade_offer_pills o
        WHERE o.trade_id = p_trade_id
    LOOP
        IF row_m.side = 0 THEN
            giver := deal.proposer_id; taker := deal.partner_id;
        ELSE
            giver := deal.partner_id;  taker := deal.proposer_id;
        END IF;

        PERFORM 1 FROM player_pills
        WHERE pill_id = row_m.pill_id AND owner_id = giver
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION ''a pill on the table is no longer its owner''''s''
                USING ERRCODE = ''check_violation'';
        END IF;

        UPDATE player_pills SET owner_id = taker WHERE pill_id = row_m.pill_id;
    END LOOP;

' || anchor);

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- All five places, because four of them fail silently
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    missing TEXT := '';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'trade_add_pill') THEN
        missing := missing || ' no way to offer one';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'trade_offer_pills' AND NOT t.tgisinternal
    ) THEN
        missing := missing || ' confirmations are not reset';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_withdraw')
       NOT LIKE '%trade_offer_pills%' THEN
        missing := missing || ' a withdrawn side leaves them behind';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_views WHERE viewname = 'trade_contents'
          AND definition LIKE '%trade_offer_pills%'
    ) THEN
        missing := missing || ' the card does not show them';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_execute')
       NOT LIKE '%trade_offer_pills%' THEN
        missing := missing || ' they never actually cross';
    END IF;

    IF missing <> '' THEN
        RAISE EXCEPTION 'pills are only half tradeable:%', missing;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- Two cultivators, one pill, and it ends up on the other side
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    a      BIGINT;
    b      BIGINT;
    pill   BIGINT;
    deal   BIGINT;
    seen   INTEGER;
BEGIN
    SELECT pp.owner_id, pp.pill_id INTO a, pill
    FROM player_pills pp
    JOIN players p ON p.player_id = pp.owner_id
    WHERE p.deleted_at IS NULL AND p.discord_id > 0
    ORDER BY pp.pill_id LIMIT 1;

    SELECT player_id INTO b FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 AND player_id <> a
    ORDER BY player_id LIMIT 1;

    IF a IS NULL OR b IS NULL THEN
        RAISE NOTICE 'nobody holds a pill to trade; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        DELETE FROM player_active_trade WHERE player_id IN (a, b);
        deal := trade_open(a, b);
        PERFORM trade_add_pill(deal, a, pill);

        SELECT count(*) INTO seen FROM trade_contents
        WHERE trade_id = deal AND kind = 'pill';
        IF seen <> 1 THEN
            RAISE EXCEPTION 'the pill is on the table and the card shows %', seen;
        END IF;

        -- Offering something resets confirmations, so confirm AFTER offering.
        PERFORM trade_confirm(deal, a);
        PERFORM trade_confirm(deal, b);

        IF (SELECT owner_id FROM player_pills WHERE pill_id = pill) <> b THEN
            RAISE EXCEPTION 'the pill did not cross the table';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
