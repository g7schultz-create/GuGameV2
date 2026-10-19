-- 0034_manual_garbage_collection
--
-- A manual nobody owns and nobody wrote is nothing. Delete it.
--
-- WHY THIS IS NEEDED NOW. 0028 gave every player a per-player starter manual
-- and leaned on `created_by` CASCADE to clean it up when the player left.
-- 0033 had to turn that cascade into SET NULL, because a manual can now be
-- TRADED and the cascade would otherwise reach into a stranger's collection
-- and delete a book they earned.
--
-- Both guarantees are real and neither is negotiable:
--
--   * a manual someone owns survives its maker leaving      (trading)
--   * a manual nobody owns does not accumulate forever      (0028)
--
-- The predicate that satisfies both is ownership, not authorship: a CODELESS
-- manual - one with no stable handle, so not seeded content - is deleted when
-- its last owner lets go of it.
--
-- ORDERING MATTERS AND IS THE SUBTLE PART. trade_execute moved a manual by
-- DELETE-then-INSERT, which with this trigger means the manual is collected in
-- the gap between the two and the INSERT then fails its foreign key. The swap
-- is reordered to INSERT the taker's row first. The composite primary key
-- (player_id, manual_id) allows both rows to exist for that instant, and the
-- giver's slot still clears when their row goes.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A consumed page may outlive the manual it became
-- ---------------------------------------------------------------------------
-- `manual_pages.consumed_by` is ON DELETE SET NULL, and the whole-consumption
-- CHECK demanded consumed_by and consumed_at together - so deleting any
-- refined manual violated the CHECK on the pages that made it, and the delete
-- failed. Nothing exercised that until this trigger started deleting manuals.
--
-- The rule worth keeping is the other direction: a page that names a manual
-- must say when. A page that was spent on a manual since deleted is still a
-- spent page, and pretending it is unused would put it back in /refine.

ALTER TABLE manual_pages DROP CONSTRAINT manual_pages_consumption_is_whole;

ALTER TABLE manual_pages ADD CONSTRAINT manual_pages_consumption_is_whole CHECK (
    consumed_by IS NULL OR consumed_at IS NOT NULL
);

COMMENT ON COLUMN manual_pages.consumed_at IS
    'When refinement spent this page. Set with no consumed_by means the manual it became has since been deleted.';


-- ---------------------------------------------------------------------------
-- The collector
-- ---------------------------------------------------------------------------
-- Row-level AFTER DELETE, so it sees each manual that just lost an owner.
-- Seeded manuals (code IS NOT NULL) are content and are never collected, no
-- matter how many players stop carrying them.

CREATE FUNCTION collect_unowned_manual()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM manuals m
    WHERE m.manual_id = OLD.manual_id
      AND m.code IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM player_manuals pm WHERE pm.manual_id = m.manual_id
      );
    RETURN NULL;
END;
$$;

CREATE TRIGGER player_manuals_collects_unowned
    AFTER DELETE ON player_manuals
    FOR EACH ROW EXECUTE FUNCTION collect_unowned_manual();

COMMENT ON FUNCTION collect_unowned_manual() IS
    'Deletes a codeless manual once its last owner is gone. Ownership, not authorship, is what keeps one alive.';


-- ---------------------------------------------------------------------------
-- The swap hands over before it lets go
-- ---------------------------------------------------------------------------

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

    UPDATE trades SET status = 'complete', ended_at = now() WHERE trade_id = p_trade_id;
    DELETE FROM player_active_trade WHERE trade_id = p_trade_id;

    PERFORM apply_physique_xp(deal.proposer_id, 0);
    PERFORM apply_physique_xp(deal.partner_id, 0);
END;
$$;
