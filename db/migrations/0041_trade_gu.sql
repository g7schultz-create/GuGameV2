-- 0041_trade_gu
--
-- The fourth pile.
--
-- 0033 left the note in `trade_contents`: "Gu joins this with a fourth UNION
-- branch when they exist." They exist. A Gu is an instance with an owner, so
-- it trades exactly the way a manual does - one row per Gu, the primary key
-- making "offer it twice" a state the executor never has to defend against.
--
-- THE APERTURE FOLLOWS THE OWNER, AND NOT BECAUSE THE TRADE SAYS SO. An
-- equipped Gu that changes hands leaves a `player_gu_equipped` row saying one
-- player is wearing another player's Gu, and 0036's capacity trigger cannot
-- catch it: that trigger fires BEFORE INSERT, and this is an UPDATE somewhere
-- else entirely. So the rule lives on `player_gu` as a trigger of its own -
-- a Gu that changes hands comes out of the aperture, however it changes hands.
-- Clearing it inside `trade_execute` would have been a rule that holds only
-- for the one path that happens to go through `trade_execute`.
--
-- AND `trade_confirm` STOPS COUNTING TABLES. It refused an empty table by
-- naming all three offer tables, which means a trade with nothing on it but
-- Gu would have been refused as empty. It asks `trade_contents` now, so the
-- fifth pile is a UNION branch and nothing else.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- trade_offer_gu
-- ---------------------------------------------------------------------------

CREATE TABLE trade_offer_gu (
    trade_id BIGINT   NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side     SMALLINT NOT NULL CHECK (side IN (0, 1)),
    gu_id    BIGINT   NOT NULL REFERENCES player_gu (gu_id) ON DELETE CASCADE,

    PRIMARY KEY (trade_id, gu_id)
);

CREATE INDEX trade_offer_gu_gu_idx ON trade_offer_gu (gu_id);

CREATE TRIGGER trade_offer_gu_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_gu
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();


-- ---------------------------------------------------------------------------
-- A Gu that changes hands comes out of the aperture
-- ---------------------------------------------------------------------------

CREATE FUNCTION release_gu_on_handover()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM player_gu_equipped WHERE gu_id = NEW.gu_id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER player_gu_leaves_the_aperture_when_it_changes_hands
    AFTER UPDATE OF owner_id ON player_gu
    FOR EACH ROW
    WHEN (OLD.owner_id IS DISTINCT FROM NEW.owner_id)
    EXECUTE FUNCTION release_gu_on_handover();

COMMENT ON FUNCTION release_gu_on_handover() IS
    'An equipped Gu that changes owner would leave one player wearing another player''s Gu. 0036''s capacity trigger fires BEFORE INSERT and cannot see it.';


-- ---------------------------------------------------------------------------
-- trade_add_gu
-- ---------------------------------------------------------------------------

CREATE FUNCTION trade_add_gu(p_trade_id BIGINT, p_player_id BIGINT, p_gu_id BIGINT)
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
        SELECT 1 FROM player_gu WHERE gu_id = p_gu_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that Gu is not yours to give' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_gu (trade_id, side, gu_id)
    VALUES (p_trade_id, which, p_gu_id)
    ON CONFLICT (trade_id, gu_id) DO NOTHING;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_withdraw, with a fourth pile to sweep
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trade_withdraw(p_trade_id BIGINT, p_player_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
BEGIN
    DELETE FROM trade_offer_manuals   WHERE trade_id = p_trade_id AND side = which;
    DELETE FROM trade_offer_pages     WHERE trade_id = p_trade_id AND side = which;
    DELETE FROM trade_offer_materials WHERE trade_id = p_trade_id AND side = which;
    DELETE FROM trade_offer_gu        WHERE trade_id = p_trade_id AND side = which;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_contents
-- ---------------------------------------------------------------------------
-- Same columns, one more branch - which is all CREATE OR REPLACE VIEW allows,
-- and all this needs.

CREATE OR REPLACE VIEW trade_contents AS
SELECT o.trade_id, o.side, 'manual'::text AS kind, 1::bigint AS quantity,
       'T' || m.tier || ' ' || m.name AS label,
       m.manual_id AS ref_id, NULL::text AS ref_code
FROM trade_offer_manuals o
JOIN manuals m ON m.manual_id = o.manual_id

UNION ALL

SELECT o.trade_id, o.side, 'page', 1,
       'T' || p.tier || ' ' || pa.name || ' ' || ty.name,
       p.page_id, NULL
FROM trade_offer_pages o
JOIN manual_pages p ON p.page_id = o.page_id
JOIN paths pa ON pa.code = p.path_code
JOIN page_types ty ON ty.code = p.page_type

UNION ALL

SELECT o.trade_id, o.side, 'material', o.quantity,
       m.name, NULL, m.code
FROM trade_offer_materials o
JOIN materials m ON m.code = o.material_code

UNION ALL

SELECT o.trade_id, o.side, 'gu', 1,
       g.stars || '* ' || t.name,
       g.gu_id, t.code
FROM trade_offer_gu o
JOIN player_gu g ON g.gu_id = o.gu_id
JOIN gu_types t ON t.gu_type_id = g.gu_type_id;


-- ---------------------------------------------------------------------------
-- trade_confirm, which no longer names the piles
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trade_confirm(p_trade_id BIGINT, p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
    deal  trades%ROWTYPE;
BEGIN
    SELECT * INTO deal FROM trades WHERE trade_id = p_trade_id FOR UPDATE;
    IF deal.status <> 'open' THEN
        RAISE EXCEPTION 'that trade is closed' USING ERRCODE = 'check_violation';
    END IF;

    -- The view is the list of what a trade can hold. Asking it means the next
    -- kind of thing to become tradable does not have to remember to edit this.
    IF NOT EXISTS (SELECT 1 FROM trade_contents c WHERE c.trade_id = p_trade_id) THEN
        RAISE EXCEPTION 'there is nothing on the table' USING ERRCODE = 'check_violation';
    END IF;

    IF which = 0 THEN
        UPDATE trades SET proposer_confirmed_at = now() WHERE trade_id = p_trade_id;
    ELSE
        UPDATE trades SET partner_confirmed_at = now() WHERE trade_id = p_trade_id;
    END IF;

    SELECT * INTO deal FROM trades WHERE trade_id = p_trade_id;

    IF deal.proposer_confirmed_at IS NOT NULL AND deal.partner_confirmed_at IS NOT NULL THEN
        PERFORM trade_execute(p_trade_id);
        RETURN TRUE;
    END IF;
    RETURN FALSE;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_execute
-- ---------------------------------------------------------------------------
-- 0034's version, with Gu checked alongside everything else and moved with it.
--
-- A Gu moves by UPDATE rather than by the delete-and-insert a manual needs:
-- `player_gu` is the instance itself, not a row saying who holds a shared one,
-- so there is nothing for a collector to sweep up and nothing to hand over
-- before letting go.

CREATE OR REPLACE FUNCTION trade_execute(p_trade_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    deal   trades%ROWTYPE;
    giver  BIGINT;
    taker  BIGINT;
    row_m  RECORD;
    held   BIGINT;
BEGIN
    SELECT * INTO deal FROM trades WHERE trade_id = p_trade_id FOR UPDATE;

    IF deal.status <> 'open' THEN
        RAISE EXCEPTION 'that trade is closed' USING ERRCODE = 'check_violation';
    END IF;
    IF deal.proposer_confirmed_at IS NULL OR deal.partner_confirmed_at IS NULL THEN
        RAISE EXCEPTION 'both sides must confirm' USING ERRCODE = 'check_violation';
    END IF;

    -- ---- everything offered must still be there ---------------------------
    FOR row_m IN
        SELECT o.side, o.manual_id FROM trade_offer_manuals o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        IF NOT EXISTS (
            SELECT 1 FROM player_manuals pm
            WHERE pm.player_id = giver AND pm.manual_id = row_m.manual_id
        ) THEN
            RAISE EXCEPTION 'a manual on the table is no longer owned'
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.page_id FROM trade_offer_pages o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        IF NOT EXISTS (
            SELECT 1 FROM manual_pages mp
            WHERE mp.page_id = row_m.page_id AND mp.owner_id = giver
              AND mp.consumed_at IS NULL
        ) THEN
            RAISE EXCEPTION 'a page on the table has been used or given away'
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.material_code, o.quantity
        FROM trade_offer_materials o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        SELECT quantity INTO held FROM player_materials
        WHERE player_id = giver AND material_code = row_m.material_code
        FOR UPDATE;
        IF COALESCE(held, 0) < row_m.quantity THEN
            RAISE EXCEPTION 'the materials on the table have been spent'
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.gu_id FROM trade_offer_gu o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        IF NOT EXISTS (
            SELECT 1 FROM player_gu g
            WHERE g.gu_id = row_m.gu_id AND g.owner_id = giver
            FOR UPDATE
        ) THEN
            RAISE EXCEPTION 'a Gu on the table is no longer owned'
                USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;

    -- ---- the swap ---------------------------------------------------------
    FOR row_m IN
        SELECT o.side, o.manual_id FROM trade_offer_manuals o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        taker := CASE row_m.side WHEN 0 THEN deal.partner_id  ELSE deal.proposer_id END;

        -- Hand over BEFORE letting go: the collector runs on the giver's
        -- delete and would take an unowned manual with it.
        INSERT INTO player_manuals (player_id, manual_id)
        VALUES (taker, row_m.manual_id)
        ON CONFLICT DO NOTHING;

        DELETE FROM player_manuals
        WHERE player_id = giver AND manual_id = row_m.manual_id;
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.page_id FROM trade_offer_pages o WHERE o.trade_id = p_trade_id
    LOOP
        taker := CASE row_m.side WHEN 0 THEN deal.partner_id ELSE deal.proposer_id END;

        UPDATE manual_pages SET owner_id = taker WHERE page_id = row_m.page_id;
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.material_code, o.quantity
        FROM trade_offer_materials o WHERE o.trade_id = p_trade_id
    LOOP
        giver := CASE row_m.side WHEN 0 THEN deal.proposer_id ELSE deal.partner_id END;
        taker := CASE row_m.side WHEN 0 THEN deal.partner_id  ELSE deal.proposer_id END;

        UPDATE player_materials
        SET quantity = quantity - row_m.quantity
        WHERE player_id = giver AND material_code = row_m.material_code;

        PERFORM grant_material(taker, row_m.material_code, row_m.quantity);
    END LOOP;

    FOR row_m IN
        SELECT o.side, o.gu_id FROM trade_offer_gu o WHERE o.trade_id = p_trade_id
    LOOP
        taker := CASE row_m.side WHEN 0 THEN deal.partner_id ELSE deal.proposer_id END;

        -- The aperture is emptied by the trigger on this UPDATE, not here.
        UPDATE player_gu SET owner_id = taker WHERE gu_id = row_m.gu_id;
    END LOOP;

    UPDATE trades SET status = 'complete', ended_at = now() WHERE trade_id = p_trade_id;
    DELETE FROM player_active_trade WHERE trade_id = p_trade_id;

    -- Both bodies are re-derived: max HP reads what each of them is now
    -- carrying, and a Gu that granted it has just moved.
    PERFORM apply_physique_xp(deal.proposer_id, 0);
    PERFORM apply_physique_xp(deal.partner_id, 0);
END;
$$;
