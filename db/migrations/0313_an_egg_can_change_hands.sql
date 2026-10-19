-- 0313_an_egg_can_change_hands
--
-- 365 unhatched eggs are sitting in eight people's hands and not one of them
-- can move. Beasts and eggs were the only thing in the game with no route
-- between two players at all - trade carries manuals, pages, materials, Gu,
-- gear and pills, the auction carries the same six, and nothing anywhere sets
-- an egg's owner.
--
-- That bites hardest on exactly the eggs there are most of. The shelf is
-- bottom-heavy on purpose - most of those 365 are tier 3 and 4 - and a tier 3
-- that is junk to somebody holding a tier 9 is a real prize to somebody who
-- started last week. Rendering gave the shallow end A use. This gives it the
-- obvious one.
--
-- EGGS ONLY. A hatched beast carries its stage and everything ever fed into
-- it, so trading one sells a raised Elder rather than the raising of it -
-- most of the pet system's progression, in a single handover. That is a
-- separate decision and it has not been made. An egg is a sealed thing with
-- no history, which is the easy half and the half worth having.
--
-- AND ONLY UNHATCHED ONES. A row with `hatched_at` set is not an item, it is
-- the record of where a beast came from - `player_beast_shelf` joins it to
-- say what region a beast was found in. Moving one would rewrite somebody
-- else's history and hand over nothing.
--
-- The same five places as 0305, for the same reason: four of them fail
-- silently, so each gets its own assertion.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE trade_offer_eggs (
    trade_id BIGINT   NOT NULL REFERENCES trades(trade_id) ON DELETE CASCADE,
    side     SMALLINT NOT NULL,
    egg_id   BIGINT   NOT NULL REFERENCES player_beast_eggs(egg_id) ON DELETE CASCADE,
    PRIMARY KEY (trade_id, egg_id)
);

COMMENT ON TABLE trade_offer_eggs IS
    'Unhatched eggs one side has put on the table.';

CREATE INDEX trade_offer_eggs_egg_idx ON trade_offer_eggs (egg_id);

CREATE TRIGGER trade_offer_eggs_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_eggs
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();


CREATE FUNCTION trade_add_egg(
    p_trade_id BIGINT, p_player_id BIGINT, p_egg_id BIGINT
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
        SELECT 1 FROM player_beast_eggs
        WHERE egg_id = p_egg_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that egg is not yours to give'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM player_beast_eggs
        WHERE egg_id = p_egg_id AND hatched_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION
            'that egg has already hatched - the beast is what came out of it'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_eggs (trade_id, side, egg_id)
    VALUES (p_trade_id, which, p_egg_id)
    ON CONFLICT (trade_id, egg_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION trade_add_egg(BIGINT, BIGINT, BIGINT) IS
    'Puts an unhatched egg on the table. Refuses one that has already been opened.';


-- ---------------------------------------------------------------------------
-- A withdrawn side takes its eggs back
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT :=
'    DELETE FROM trade_offer_pills     WHERE trade_id = p_trade_id AND side = which;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'trade_withdraw';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trade_withdraw does not clear pills where it did';
    END IF;

    body := replace(body, anchor, anchor || chr(10) ||
'    DELETE FROM trade_offer_eggs      WHERE trade_id = p_trade_id AND side = which;');

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
    SELECT pg_get_viewdef('trade_contents'::regclass, true) INTO def;

    IF def IS NULL THEN
        RAISE EXCEPTION 'trade_contents is missing';
    END IF;
    IF def LIKE '%trade_offer_eggs%' THEN
        RAISE EXCEPTION 'trade_contents already knows about eggs';
    END IF;

    -- Lifted and appended, the way 0305 learned to after retyping six
    -- branches and falling over a reserved word in the seventh.
    EXECUTE 'CREATE OR REPLACE VIEW trade_contents AS '
        || rtrim(rtrim(def), ';')
        || ' UNION ALL
    SELECT o.trade_id, o.side, ''egg''::text, 1::bigint,
           ''T'' || e.tier || '' '' || e.rarity || '' '' || cs.name || '' egg'',
           e.egg_id, cs.code
    FROM trade_offer_eggs o
    JOIN player_beast_eggs e ON e.egg_id = o.egg_id
    JOIN creature_species cs ON cs.species_id = e.species_id';
END;
$$;


-- ---------------------------------------------------------------------------
-- And it crosses
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

    body := replace(body, anchor,
'    -- Eggs. Locked and re-checked unhatched on the way past: somebody who
    -- cracks an egg between confirming and this moment must not also hand it
    -- over, or the beast and the egg end up in different pairs of hands.
    FOR row_m IN
        SELECT o.side, o.egg_id FROM trade_offer_eggs o
        WHERE o.trade_id = p_trade_id
    LOOP
        IF row_m.side = 0 THEN
            giver := deal.proposer_id; taker := deal.partner_id;
        ELSE
            giver := deal.partner_id;  taker := deal.proposer_id;
        END IF;

        PERFORM 1 FROM player_beast_eggs
        WHERE egg_id = row_m.egg_id AND owner_id = giver
          AND hatched_at IS NULL
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                ''an egg on the table has been opened or is no longer its owner''''s''
                USING ERRCODE = ''check_violation'';
        END IF;

        UPDATE player_beast_eggs SET owner_id = taker
        WHERE egg_id = row_m.egg_id;
    END LOOP;

' || anchor);

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- All five places
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    missing TEXT := '';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'trade_add_egg') THEN
        missing := missing || ' no way to offer one';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = 'trade_offer_eggs' AND NOT t.tgisinternal
    ) THEN
        missing := missing || ' confirmations are not reset';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_withdraw')
       NOT LIKE '%trade_offer_eggs%' THEN
        missing := missing || ' a withdrawn side leaves them behind';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_views WHERE viewname = 'trade_contents'
          AND definition LIKE '%trade_offer_eggs%'
    ) THEN
        missing := missing || ' the card does not show them';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trade_execute')
       NOT LIKE '%trade_offer_eggs%' THEN
        missing := missing || ' they never actually cross';
    END IF;

    IF missing <> '' THEN
        RAISE EXCEPTION 'eggs are only half tradeable:%', missing;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- Two cultivators, one egg, and a hatched one refused
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    a     BIGINT;
    b     BIGINT;
    egg   BIGINT;
    used  BIGINT;
    deal  BIGINT;
    seen  INTEGER;
BEGIN
    SELECT e.owner_id, e.egg_id INTO a, egg
    FROM player_beast_eggs e
    JOIN players p ON p.player_id = e.owner_id
    WHERE p.deleted_at IS NULL AND p.discord_id > 0 AND e.hatched_at IS NULL
    ORDER BY e.egg_id LIMIT 1;

    SELECT player_id INTO b FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 AND player_id <> a
    ORDER BY player_id LIMIT 1;

    IF a IS NULL OR b IS NULL THEN
        RAISE NOTICE 'nobody holds an unhatched egg; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        DELETE FROM player_active_trade WHERE player_id IN (a, b);
        deal := trade_open(a, b);
        PERFORM trade_add_egg(deal, a, egg);

        SELECT count(*) INTO seen FROM trade_contents
        WHERE trade_id = deal AND kind = 'egg';
        IF seen <> 1 THEN
            RAISE EXCEPTION 'the egg is on the table and the card shows %', seen;
        END IF;

        -- An already-opened egg is refused.
        SELECT egg_id INTO used FROM player_beast_eggs
        WHERE owner_id = a AND hatched_at IS NOT NULL LIMIT 1;
        IF used IS NOT NULL THEN
            BEGIN
                PERFORM trade_add_egg(deal, a, used);
                RAISE EXCEPTION 'a hatched egg was put on the table';
            EXCEPTION
                WHEN SQLSTATE '23514' THEN NULL;
            END;
        END IF;

        PERFORM trade_confirm(deal, a);
        PERFORM trade_confirm(deal, b);

        IF (SELECT owner_id FROM player_beast_eggs WHERE egg_id = egg) <> b THEN
            RAISE EXCEPTION 'the egg did not cross the table';
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
