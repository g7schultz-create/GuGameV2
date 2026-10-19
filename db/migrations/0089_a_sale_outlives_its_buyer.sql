-- 0089_a_sale_outlives_its_buyer
--
-- 0088 wrote a constraint that made deleting a customer impossible.
--
--   buyer_id BIGINT REFERENCES players (player_id) ON DELETE SET NULL
--   CHECK ((status = 'sold') = (buyer_id IS NOT NULL))
--
-- Those two lines cannot both hold. Deleting a player sets `buyer_id` to NULL
-- on every listing they ever bought, and the CHECK then rejects the update -
-- so the delete fails and the account cannot be removed at all. Found by the
-- test teardown, which removes its player and took a hundred and sixty-three
-- tests down with it.
--
-- The biconditional was the wrong shape. What is actually true is one
-- direction: a buyer is only ever recorded against a SOLD listing. The
-- converse - that a sold listing always names its buyer - is a claim about
-- the buyer still existing, and a sale does not stop having happened because
-- somebody left.
--
-- The seller side needs no change. `seller_id` cascades, and in normal play
-- nothing hard-deletes a player anyway: `players.deleted_at` is a soft delete
-- and leaves every listing standing.
--
-- Forward-only. Do not edit once applied.

ALTER TABLE auction_listings DROP CONSTRAINT auction_buyer_only_when_sold;

ALTER TABLE auction_listings ADD CONSTRAINT auction_buyer_only_when_sold
    CHECK (buyer_id IS NULL OR status = 'sold');

COMMENT ON COLUMN auction_listings.buyer_id IS
    'Who bought it, while they still exist. NULL on an open listing, and NULL again if the buyer deletes their account - the sale still happened.';
