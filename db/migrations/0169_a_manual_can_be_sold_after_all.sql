-- 0169_a_manual_can_be_sold_after_all
--
-- 0088 named this as the one deliberate gap:
--
--     MANUALS ARE NOT SELLABLE YET, and that is the one deliberate gap. Every
--     other item is owned through a column - `owner_id` on the row itself -
--     while a manual is owned through a join table AND can sit in an equipped
--     slot.
--
-- Both halves of that turn out to be solved elsewhere already. `trade_execute`
-- has moved manuals between players since the trade was written, and the way
-- it does it is the whole trick: INSERT for the taker, then DELETE for the
-- giver, in that order, because `collect_unowned_manual` fires on the delete
-- and would take a manual nobody owns with it. And the equipped slot needs no
-- handling at all - `player_manual_slots` is keyed (player_id, manual_id)
-- against `player_manuals` ON DELETE CASCADE, so letting go of a manual
-- unequips it by construction.
--
-- One real restriction follows from the house owning what is listed. A manual
-- is held in `player_manuals`, whose key is (player_id, manual_id), so the
-- house can hold one copy of a given manual at a time - which means two
-- cultivators who both own Crimson Moth Requiem cannot both have it listed at
-- once. The partial unique index says so rather than letting the second
-- listing quietly destroy the first seller's copy.
--
-- And a buyer who already owns the manual is refused before any Jade moves,
-- for the same reason: the INSERT would do nothing, the DELETE would take the
-- house's copy, and somebody would have paid for a row that cannot exist.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE auction_listings
    ADD COLUMN manual_id BIGINT REFERENCES manuals (manual_id) ON DELETE CASCADE;

ALTER TABLE auction_listings
    DROP CONSTRAINT auction_holds_one_thing;

ALTER TABLE auction_listings
    ADD CONSTRAINT auction_holds_one_thing CHECK (
        (material_code IS NOT NULL)::integer
        + (gu_id IS NOT NULL)::integer
        + (equipment_id IS NOT NULL)::integer
        + (pill_id IS NOT NULL)::integer
        + (page_id IS NOT NULL)::integer
        + (manual_id IS NOT NULL)::integer = 1
    );

CREATE INDEX auction_manual_idx ON auction_listings (manual_id);

CREATE UNIQUE INDEX auction_one_open_listing_per_manual
    ON auction_listings (manual_id)
    WHERE status = 'open' AND manual_id IS NOT NULL;


CREATE FUNCTION auction_list_manual(
    p_seller_id BIGINT,
    p_manual_id BIGINT,
    p_price     BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    PERFORM auction_open_slot(p_seller_id);

    IF NOT EXISTS (
        SELECT 1 FROM player_manuals pm
        WHERE pm.player_id = p_seller_id AND pm.manual_id = p_manual_id
    ) THEN
        RAISE EXCEPTION 'that is not yours to sell'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM player_manuals pm
        WHERE pm.player_id = auction_house() AND pm.manual_id = p_manual_id
    ) THEN
        RAISE EXCEPTION 'one of those is already on the auction house floor'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Hand over BEFORE letting go, exactly as `trade_execute` does: the
    -- collector trigger runs on the seller's delete and would take an unowned
    -- manual with it. The delete also cascades the equipped slot away, so a
    -- worn manual comes off on the way out without this having to say so.
    INSERT INTO player_manuals (player_id, manual_id)
    VALUES (auction_house(), p_manual_id);

    DELETE FROM player_manuals
    WHERE player_id = p_seller_id AND manual_id = p_manual_id;

    INSERT INTO auction_listings (seller_id, price, manual_id)
    VALUES (p_seller_id, p_price, p_manual_id)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;


CREATE OR REPLACE FUNCTION auction_release(p_listing_id BIGINT, p_to BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    it auction_listings%ROWTYPE;
BEGIN
    SELECT * INTO it FROM auction_listings WHERE listing_id = p_listing_id;

    IF it.material_code IS NOT NULL THEN
        PERFORM spend_material(auction_house(), it.material_code, it.quantity);
        PERFORM grant_material(p_to, it.material_code, it.quantity);
    ELSIF it.gu_id IS NOT NULL THEN
        UPDATE player_gu SET owner_id = p_to WHERE gu_id = it.gu_id;
    ELSIF it.equipment_id IS NOT NULL THEN
        UPDATE player_equipment SET owner_id = p_to WHERE equipment_id = it.equipment_id;
    ELSIF it.pill_id IS NOT NULL THEN
        UPDATE player_pills SET owner_id = p_to WHERE pill_id = it.pill_id;
    ELSIF it.page_id IS NOT NULL THEN
        UPDATE manual_pages SET owner_id = p_to WHERE page_id = it.page_id;
    ELSIF it.manual_id IS NOT NULL THEN
        INSERT INTO player_manuals (player_id, manual_id)
        VALUES (p_to, it.manual_id)
        ON CONFLICT DO NOTHING;

        DELETE FROM player_manuals
        WHERE player_id = auction_house() AND manual_id = it.manual_id;
    ELSE
        -- The failure this branch exists to prevent: a kind added to the
        -- table and forgotten here would take the buyer's Jade and hand back
        -- nothing at all, silently, with the listing marked sold.
        RAISE EXCEPTION 'listing % holds nothing this knows how to hand over',
            p_listing_id;
    END IF;
END;
$$;


CREATE OR REPLACE FUNCTION auction_buy(p_buyer_id BIGINT, p_listing_id BIGINT)
RETURNS TABLE (price BIGINT, seller_id BIGINT, jade_left BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    it auction_listings%ROWTYPE;
BEGIN
    -- Locked first: two buyers pressing at once must not both get it.
    SELECT * INTO it FROM auction_listings
    WHERE listing_id = p_listing_id FOR UPDATE;

    IF NOT FOUND OR it.status <> 'open' THEN
        RAISE EXCEPTION 'that listing is gone' USING ERRCODE = 'check_violation';
    END IF;
    IF it.seller_id = p_buyer_id THEN
        RAISE EXCEPTION 'that is your own listing' USING ERRCODE = 'check_violation';
    END IF;

    -- A manual is held one to a cultivator, so buying a second copy of one
    -- you already carry cannot be recorded - and would take the Jade anyway
    -- if it were not refused here, before the money moves.
    IF it.manual_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM player_manuals pm
        WHERE pm.player_id = p_buyer_id AND pm.manual_id = it.manual_id
    ) THEN
        RAISE EXCEPTION 'you are already carrying that manual'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The money moves between players and is NOT written to the ledger: a
    -- sale changes who holds it, not how much exists.
    PERFORM spend_material(p_buyer_id, 'spirit_jade', it.price);
    PERFORM grant_material(it.seller_id, 'spirit_jade', it.price);

    PERFORM auction_release(p_listing_id, p_buyer_id);

    UPDATE auction_listings
    SET status = 'sold', buyer_id = p_buyer_id, ended_at = now()
    WHERE listing_id = p_listing_id;

    RETURN QUERY SELECT it.price, it.seller_id, jade_held(p_buyer_id);
END;
$$;


-- Listed, bought and handed over for real, on two throwaway cultivators
-- inside a subtransaction that is rolled back. A manual that can be listed
-- but not collected would be the worst possible version of this.

DO $$
DECLARE
    book   BIGINT;
    seller BIGINT;
    buyer  BIGINT;
    listed BIGINT;
BEGIN
    SELECT manual_id INTO book FROM manuals ORDER BY manual_id LIMIT 1;
    IF book IS NULL THEN
        RAISE NOTICE 'no manual to probe with; tests carry it';
        RETURN;
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-9001, 'Probe Seller') RETURNING player_id INTO seller;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-9002, 'Probe Buyer') RETURNING player_id INTO buyer;

        INSERT INTO player_manuals (player_id, manual_id) VALUES (seller, book);
        -- `auction_open_slot` charges a listing fee in Jade, so a seller with
        -- an empty purse cannot list at all.
        PERFORM grant_material(seller, 'spirit_jade', 500);
        PERFORM grant_material(buyer, 'spirit_jade', 500);

        listed := auction_list_manual(seller, book, 10);

        IF EXISTS (SELECT 1 FROM player_manuals
                   WHERE player_id = seller AND manual_id = book) THEN
            RAISE EXCEPTION 'the seller still holds a listed manual';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM player_manuals
                       WHERE player_id = auction_house() AND manual_id = book) THEN
            RAISE EXCEPTION 'the house does not hold what was listed';
        END IF;

        PERFORM auction_buy(buyer, listed);

        IF NOT EXISTS (SELECT 1 FROM player_manuals
                       WHERE player_id = buyer AND manual_id = book) THEN
            RAISE EXCEPTION 'the buyer paid and got nothing';
        END IF;
        IF EXISTS (SELECT 1 FROM player_manuals
                   WHERE player_id = auction_house() AND manual_id = book) THEN
            RAISE EXCEPTION 'the house kept a copy of what it sold';
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
