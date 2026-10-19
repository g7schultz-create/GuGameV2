-- 0270_gear_can_change_hands_across_a_table
--
-- /trade moves manuals, pages, materials and Gu. It does not move equipment,
-- which is the one thing in the game a player forges FOR somebody else - a
-- smith with a spare Blood Path blade and a friend who walks that Path have to
-- go through the auction house and pay the spread to hand it over.
--
-- Equipment is the same shape as a Gu here: one row, one owner, unique. So it
-- gets the Gu's treatment exactly - an offer table keyed on the piece, a check
-- that it is still yours when the trade settles, and an ownership UPDATE.
--
-- The one thing that needs no code: taking it off the body. There is already a
-- trigger `player_equipment_comes_off_when_it_changes_hands` on owner_id, put
-- there for the auction, and a trade is the same handover. It fires for free.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE trade_offer_equipment (
    trade_id     BIGINT   NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side         SMALLINT NOT NULL CHECK (side IN (0, 1)),
    equipment_id BIGINT   NOT NULL REFERENCES player_equipment (equipment_id)
                          ON DELETE CASCADE,
    PRIMARY KEY (trade_id, equipment_id)
);

CREATE INDEX trade_offer_equipment_piece_idx ON trade_offer_equipment (equipment_id);

COMMENT ON TABLE trade_offer_equipment IS
    'Forged pieces on one side of a trade. Mirrors trade_offer_gu: a piece is unique, so the row is the offer.';

-- Changing what is on the table un-confirms both sides, the same as every
-- other kind. Without this somebody could confirm, then add a piece.
CREATE TRIGGER trade_offer_equipment_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_equipment
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();


CREATE FUNCTION trade_add_equipment(
    p_trade_id BIGINT, p_player_id BIGINT, p_equipment_id BIGINT
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
        SELECT 1 FROM player_equipment
        WHERE equipment_id = p_equipment_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that piece is not yours to give'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_equipment (trade_id, side, equipment_id)
    VALUES (p_trade_id, which, p_equipment_id)
    ON CONFLICT (trade_id, equipment_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION trade_add_equipment(BIGINT, BIGINT, BIGINT) IS
    'Puts one forged piece on your side of a trade. It stays on your body until the trade settles - the handover trigger takes it off then.';


-- ---------------------------------------------------------------------------
-- Withdrawing a side takes the gear back too
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'trade_withdraw';

    old := '    DELETE FROM trade_offer_gu        WHERE trade_id = p_trade_id AND side = which;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'trade_withdraw no longer clears the Gu';
    END IF;

    src := replace(src, old, old || '
    DELETE FROM trade_offer_equipment WHERE trade_id = p_trade_id AND side = which;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- Still owned when it settles, and then handed over
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'trade_execute';

    -- ---- the check, beside the Gu's ---------------------------------------
    old := '    -- ---- the swap ---------------------------------------------------------';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'trade_execute no longer separates its checks from its swap';
    END IF;

    src := replace(src, old,
'    FOR row_m IN
        SELECT o.side, o.equipment_id FROM trade_offer_equipment o
        WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        IF NOT EXISTS (
            SELECT 1 FROM player_equipment pe
            WHERE pe.equipment_id = row_m.equipment_id AND pe.owner_id = giver
            FOR UPDATE
        ) THEN
            RAISE EXCEPTION ''a forged piece on the table is no longer owned''
                USING ERRCODE = ''check_violation'';
        END IF;
    END LOOP;

' || old);

    -- ---- the swap, beside the Gu's ----------------------------------------
    old := '    UPDATE trades SET status = ''complete'', ended_at = now() WHERE trade_id = p_trade_id;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'trade_execute no longer closes the trade the old way';
    END IF;

    src := replace(src, old,
'    FOR row_m IN
        SELECT o.side, o.equipment_id FROM trade_offer_equipment o
        WHERE o.trade_id = p_trade_id
    LOOP
        taker := CASE row_m.side WHEN 0 THEN deal.partner_id ELSE deal.proposer_id END;

        -- It comes off the giver''s body on this UPDATE, by the same trigger
        -- the auction house relies on. The physique recalculation at the end
        -- of this function is what makes that land on both of them.
        UPDATE player_equipment SET owner_id = taker
        WHERE equipment_id = row_m.equipment_id;
    END LOOP;

' || old);

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- And the table shows it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW trade_contents AS
SELECT o.trade_id, o.side, 'manual'::text AS kind, 1::bigint AS quantity,
       'T' || m.tier || ' ' || m.name AS label,
       m.manual_id AS ref_id, NULL::text AS ref_code
FROM trade_offer_manuals o
JOIN manuals m ON m.manual_id = o.manual_id
UNION ALL
SELECT o.trade_id, o.side, 'page'::text, 1,
       'T' || p.tier || ' ' || pa.name || ' ' || ty.name,
       p.page_id, NULL::text
FROM trade_offer_pages o
JOIN manual_pages p ON p.page_id = o.page_id
JOIN paths pa ON pa.code = p.path_code
JOIN page_types ty ON ty.code = p.page_type
UNION ALL
SELECT o.trade_id, o.side, 'material'::text, o.quantity,
       m.name, NULL::bigint, m.code
FROM trade_offer_materials o
JOIN materials m ON m.code = o.material_code
UNION ALL
SELECT o.trade_id, o.side, 'gu'::text, 1,
       g.stars || '* ' || t.name, g.gu_id, t.code
FROM trade_offer_gu o
JOIN player_gu g ON g.gu_id = o.gu_id
JOIN gu_types t ON t.gu_type_id = g.gu_type_id
UNION ALL
SELECT o.trade_id, o.side, 'equipment'::text, 1,
       'T' || pe.tier || ' ' || pe.name || ' (' || s.name || ')',
       pe.equipment_id, pe.slot
FROM trade_offer_equipment o
JOIN player_equipment pe ON pe.equipment_id = o.equipment_id
JOIN equipment_slots s ON s.code = pe.slot;


-- ---------------------------------------------------------------------------
-- A piece actually crosses the table
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    a     BIGINT;
    b     BIGINT;
    piece BIGINT;
    deal  BIGINT;
    shown TEXT;
BEGIN
    SELECT pe.owner_id, pe.equipment_id INTO a, piece
    FROM player_equipment pe
    JOIN players p ON p.player_id = pe.owner_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    LIMIT 1;

    SELECT p.player_id INTO b FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 AND p.player_id <> a
    LIMIT 1;

    IF a IS NULL OR b IS NULL THEN
        RAISE NOTICE 'not two cultivators with a piece between them; tests carry this';
        RETURN;
    END IF;

    BEGIN
        DELETE FROM player_active_trade WHERE player_id IN (a, b);
        deal := trade_open(a, b);

        PERFORM trade_add_equipment(deal, a, piece);

        SELECT c.label INTO shown FROM trade_contents c
        WHERE c.trade_id = deal AND c.kind = 'equipment';
        IF shown IS NULL THEN
            RAISE EXCEPTION 'the table does not show the piece on it';
        END IF;

        -- Offering it does not move it.
        IF (SELECT pe.owner_id FROM player_equipment pe
            WHERE pe.equipment_id = piece) <> a THEN
            RAISE EXCEPTION 'offering a piece handed it over early';
        END IF;

        UPDATE trades SET proposer_confirmed_at = now(),
                          partner_confirmed_at  = now()
        WHERE trade_id = deal;
        PERFORM trade_execute(deal);

        IF (SELECT pe.owner_id FROM player_equipment pe
            WHERE pe.equipment_id = piece) <> b THEN
            RAISE EXCEPTION 'the piece did not cross the table';
        END IF;

        -- And it is not still worn by the person who gave it away.
        IF EXISTS (SELECT 1 FROM player_equipped e
                   WHERE e.equipment_id = piece AND e.player_id = a) THEN
            RAISE EXCEPTION 'the giver is still wearing what they handed over';
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
