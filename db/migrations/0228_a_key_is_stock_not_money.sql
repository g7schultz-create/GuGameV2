-- 0228_a_key_is_stock_not_money
--
-- A Dungeon Key cannot be put on the auction house, and nothing ever decided
-- that.
--
-- 0204's own note says the opposite out loud: "THE KEY IS A MATERIAL, which is
-- the whole reason it can be traded", and the key's description says somebody
-- makes them faster than the dungeons can be emptied, "which is why they change
-- hands so often". `trade_set_material` moves them between two cultivators
-- today. The public market is the one place they will not move.
--
-- It was never a rule. The key was registered in `currency_materials` so the
-- furnace and the cauldron would refuse to melt it, and given
-- `materials.category = 'currency'` so it would sit in the purse rather than on
-- an inventory shelf. Both of those are right and both stay. The auction picker
-- then read `category <> 'currency'` as if it meant "not money" - a proxy for a
-- rule nobody had written - and the key was swept up by it.
--
-- WHAT THE RULE ACTUALLY IS: you cannot list the thing the house pays in.
-- Listings are bought with Spirit Jade, so a jade listing is jade for jade and
-- means nothing. That is the whole of it. Spirit Stones are money too and are
-- listable, correctly - a stone listing is stones for jade, which is an
-- exchange between two cultivators and exactly what a market is for.
--
-- So the currency gets named once. `auction_currency()` is what the buyer
-- spends, `auction_list_material` refuses that and nothing else, and the picker
-- asks the same function instead of guessing from a category. The key becomes
-- stock, which is what 0204 said it was.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION auction_currency()
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT 'spirit_jade'::text;
$$;

COMMENT ON FUNCTION auction_currency() IS
    'The material a buyer spends. The one thing that cannot be listed, because a listing priced in it would be itself for itself - every other material, money or not, is stock.';


-- The refusal was a literal. Now it is the rule.
CREATE OR REPLACE FUNCTION auction_list_material(
    p_seller_id BIGINT, p_code TEXT, p_quantity BIGINT, p_price BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    IF p_code = auction_currency() THEN
        RAISE EXCEPTION 'you cannot sell money for money'
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM auction_open_slot(p_seller_id);

    -- The materials leave the seller and arrive at the house, which is the
    -- escrow: there is nothing left in the inventory to sell twice.
    PERFORM spend_material(p_seller_id, p_code, p_quantity);
    PERFORM grant_material(auction_house(), p_code, p_quantity);

    INSERT INTO auction_listings (seller_id, price, material_code, quantity)
    VALUES (p_seller_id, p_price, p_code, p_quantity)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;


-- The key stays unmeltable and stays in the purse. Only its note was written
-- as though those two facts implied a third.
UPDATE currency_materials
SET note = 'Opens a dungeon. The furnace and the cauldron refuse it, and it '
           'sits in the purse rather than on a shelf - but it is stock on the '
           'auction house, not money. Only what the house pays in is barred.'
WHERE material_code = 'dungeon_key';


DO $$
DECLARE
    seller BIGINT;
    listed BIGINT;
    said   TEXT;
BEGIN
    -- Somebody with a free slot: the cap is per seller and a live game has
    -- people sitting on a full board.
    SELECT p.player_id INTO seller FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND (SELECT count(*) FROM auction_listings a
           WHERE a.seller_id = p.player_id AND a.status = 'open')
          < game_config_value('auction_max_open')
    LIMIT 1;
    IF seller IS NULL THEN
        RAISE NOTICE 'nobody with a free slot; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- Listing costs a jade fee, so the seller needs one before they can
        -- prove anything about what may be listed.
        PERFORM grant_material(seller, auction_currency(),
                               game_config_value('auction_listing_fee')::bigint * 4);

        -- A key is stock.
        PERFORM grant_material(seller, 'dungeon_key', 1);
        listed := auction_list_material(seller, 'dungeon_key', 1, 250);
        IF listed IS NULL THEN
            RAISE EXCEPTION 'a key could not be listed';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM auction_listings a
                       WHERE a.listing_id = listed
                         AND a.material_code = 'dungeon_key'
                         AND a.status = 'open') THEN
            RAISE EXCEPTION 'the key listing did not open';
        END IF;

        -- The escrow still holds: the key is the house's, not the seller's.
        IF NOT EXISTS (SELECT 1 FROM player_materials pm
                       WHERE pm.player_id = auction_house()
                         AND pm.material_code = 'dungeon_key'
                         AND pm.quantity > 0) THEN
            RAISE EXCEPTION 'the house is not holding the key it took';
        END IF;

        -- And the one thing that is still barred is still barred.
        BEGIN
            PERFORM auction_list_material(seller, auction_currency(), 1, 9);
            RAISE EXCEPTION 'the house took a listing priced in what it pays in';
        EXCEPTION
            WHEN check_violation THEN
                GET STACKED DIAGNOSTICS said = MESSAGE_TEXT;
                IF said NOT LIKE '%money for money%' THEN
                    RAISE;
                END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
