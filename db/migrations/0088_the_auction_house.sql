-- 0088_the_auction_house
--
-- Fixed-price listings, priced in Spirit Jade and nothing else.
--
-- ESCROW IS THE WHOLE PROBLEM, and the answer is a player.
--
-- A listing has to take custody the moment it is posted, or somebody lists a
-- sword, hands it over in `/trade`, and the auction sells a sword they no
-- longer own. The tempting fix is a `listed` flag plus a guard on every path
-- that consumes an item - equipping, wearing, taking, refining, trading - and
-- that is eight places to remember, where forgetting one duplicates goods.
--
-- So the house is a `players` row with discord_id 0, and listing something
-- TRANSFERS OWNERSHIP TO IT. Every ownership check in the game then works
-- unchanged, because the item genuinely is not yours any more: `/gear` cannot
-- see it, `take_pill` refuses it, `trade_add_gu` refuses it, and none of them
-- needed a line changed. 0041's `release_gu_on_handover` trigger even empties
-- the aperture for free, because it fires on any owner change and never cared
-- why.
--
-- ONE TABLE, NOT SIX. `trades` needs a child table per kind because a trade
-- holds many piles. A fixed-price listing holds exactly ONE thing, so it is
-- one row with one nullable column per kind and a CHECK that exactly one is
-- filled. The shape follows the cardinality rather than the precedent.
--
-- MANUALS ARE NOT SELLABLE YET, and that is the one deliberate gap. Every
-- other item is owned through a column - `owner_id` on the row itself - while
-- a manual is owned through a join table AND can sit in an equipped slot.
-- Pages are sellable, which is the more interesting market anyway: a refiner
-- who wants pages can buy them.
--
-- JADE ONLY. There is no currency column on a listing because there is no
-- other currency. If a second one ever arrives, that is when the column is
-- worth having.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The house
-- ---------------------------------------------------------------------------
-- A real player row, because half a player would need every ownership check
-- in the game to learn about it. discord_id 0 is not a snowflake anybody can
-- hold, so nothing can ever log in as the house.

INSERT INTO players (discord_id, discord_name) VALUES (0, 'The Auction House');

CREATE FUNCTION auction_house()
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT player_id FROM players WHERE discord_id = 0;
$$;

COMMENT ON FUNCTION auction_house() IS
    'The player that holds everything in escrow. Ownership transfer is the escrow, so every existing owner check enforces it for free.';


-- ---------------------------------------------------------------------------
-- Equipment leaves the body when it changes hands
-- ---------------------------------------------------------------------------
-- 0041 wrote this for Gu and equipment did not exist yet. Without it, listing
-- a worn sword would leave the seller wearing the house's sword.

CREATE FUNCTION release_equipment_on_handover()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM player_equipped WHERE equipment_id = NEW.equipment_id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER player_equipment_comes_off_when_it_changes_hands
    AFTER UPDATE OF owner_id ON player_equipment
    FOR EACH ROW
    WHEN (OLD.owner_id IS DISTINCT FROM NEW.owner_id)
    EXECUTE FUNCTION release_equipment_on_handover();

COMMENT ON FUNCTION release_equipment_on_handover() IS
    'A worn piece that changes owner would leave one player wearing another player''s armour. The same hole 0041 closed for Gu.';


-- ---------------------------------------------------------------------------
-- auction_listings
-- ---------------------------------------------------------------------------

CREATE TABLE auction_listings (
    listing_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    seller_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    price      BIGINT NOT NULL CHECK (price > 0),

    status     TEXT   NOT NULL DEFAULT 'open'
               CHECK (status IN ('open', 'sold', 'cancelled')),
    buyer_id   BIGINT REFERENCES players (player_id) ON DELETE SET NULL,

    listed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ,

    -- Exactly one of these. A listing holds one thing; that is what separates
    -- it from a trade and why it is one table rather than six.
    material_code TEXT   REFERENCES materials (code) ON DELETE RESTRICT,
    quantity      BIGINT CHECK (quantity IS NULL OR quantity > 0),
    gu_id         BIGINT REFERENCES player_gu (gu_id) ON DELETE CASCADE,
    equipment_id  BIGINT REFERENCES player_equipment (equipment_id) ON DELETE CASCADE,
    pill_id       BIGINT REFERENCES player_pills (pill_id) ON DELETE CASCADE,
    page_id       BIGINT REFERENCES manual_pages (page_id) ON DELETE CASCADE,

    CONSTRAINT auction_holds_one_thing CHECK (
        (material_code IS NOT NULL)::int + (gu_id IS NOT NULL)::int
        + (equipment_id IS NOT NULL)::int + (pill_id IS NOT NULL)::int
        + (page_id IS NOT NULL)::int = 1
    ),
    CONSTRAINT auction_quantity_belongs_to_materials CHECK (
        (material_code IS NULL) = (quantity IS NULL)
    ),
    CONSTRAINT auction_ended_matches_status CHECK (
        (status = 'open') = (ended_at IS NULL)
    ),
    CONSTRAINT auction_buyer_only_when_sold CHECK (
        (status = 'sold') = (buyer_id IS NOT NULL)
    ),
    CONSTRAINT auction_nobody_buys_their_own CHECK (buyer_id IS DISTINCT FROM seller_id)
);

CREATE INDEX auction_open_idx     ON auction_listings (listed_at) WHERE status = 'open';
CREATE INDEX auction_seller_idx   ON auction_listings (seller_id);
CREATE INDEX auction_buyer_idx    ON auction_listings (buyer_id);
CREATE INDEX auction_material_idx ON auction_listings (material_code);
CREATE INDEX auction_gu_idx       ON auction_listings (gu_id);
CREATE INDEX auction_equip_idx    ON auction_listings (equipment_id);
CREATE INDEX auction_pill_idx     ON auction_listings (pill_id);
CREATE INDEX auction_page_idx     ON auction_listings (page_id);

-- Escrow already makes a second listing impossible - you cannot list what the
-- house owns - but the rule is worth stating where it cannot be argued with.
CREATE UNIQUE INDEX auction_one_open_listing_per_gu
    ON auction_listings (gu_id) WHERE status = 'open' AND gu_id IS NOT NULL;
CREATE UNIQUE INDEX auction_one_open_listing_per_piece
    ON auction_listings (equipment_id) WHERE status = 'open' AND equipment_id IS NOT NULL;
CREATE UNIQUE INDEX auction_one_open_listing_per_batch
    ON auction_listings (pill_id) WHERE status = 'open' AND pill_id IS NOT NULL;
CREATE UNIQUE INDEX auction_one_open_listing_per_page
    ON auction_listings (page_id) WHERE status = 'open' AND page_id IS NOT NULL;

COMMENT ON TABLE auction_listings IS
    'One thing, one price, in Spirit Jade. The house owns whatever is listed, which is what makes the escrow real rather than a flag.';

INSERT INTO game_config (key, value, description) VALUES
    ('auction_listing_fee', 1,
     'Spirit Jade to post a listing. Not refunded on cancellation - it is the sink, and it is what stops the board filling with hopeful nonsense.'),
    ('auction_max_open', 10,
     'Open listings one seller may hold at once.');


-- ---------------------------------------------------------------------------
-- Listing
-- ---------------------------------------------------------------------------
-- One function per kind rather than one with five nullable arguments: each
-- kind has a different thing to check before it hands the item over, and a
-- single entry point would be five validations wearing a trench coat.

CREATE FUNCTION auction_open_slot(p_seller_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    open_now INTEGER;
BEGIN
    SELECT count(*) INTO open_now FROM auction_listings
    WHERE seller_id = p_seller_id AND status = 'open';

    IF open_now >= game_config_value('auction_max_open') THEN
        RAISE EXCEPTION 'you already have % listings up, which is the most', open_now
            USING ERRCODE = 'check_violation';
    END IF;

    PERFORM spend_jade(p_seller_id, game_config_value('auction_listing_fee')::bigint,
                       'auction_fee');
END;
$$;

CREATE FUNCTION auction_list_material(
    p_seller_id BIGINT, p_code TEXT, p_quantity BIGINT, p_price BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    IF p_code = 'spirit_jade' THEN
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

CREATE FUNCTION auction_list_gu(p_seller_id BIGINT, p_gu_id BIGINT, p_price BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    PERFORM auction_open_slot(p_seller_id);

    -- The aperture is emptied by 0041's trigger on this UPDATE, not here.
    UPDATE player_gu SET owner_id = auction_house()
    WHERE gu_id = p_gu_id AND owner_id = p_seller_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to sell' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO auction_listings (seller_id, price, gu_id)
    VALUES (p_seller_id, p_price, p_gu_id)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;

CREATE FUNCTION auction_list_equipment(
    p_seller_id BIGINT, p_equipment_id BIGINT, p_price BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    PERFORM auction_open_slot(p_seller_id);

    UPDATE player_equipment SET owner_id = auction_house()
    WHERE equipment_id = p_equipment_id AND owner_id = p_seller_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to sell' USING ERRCODE = 'check_violation';
    END IF;

    -- It came off the body on that UPDATE, so the stored stats are stale.
    PERFORM apply_physique_xp(p_seller_id, 0);

    INSERT INTO auction_listings (seller_id, price, equipment_id)
    VALUES (p_seller_id, p_price, p_equipment_id)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;

CREATE FUNCTION auction_list_pill(p_seller_id BIGINT, p_pill_id BIGINT, p_price BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    PERFORM auction_open_slot(p_seller_id);

    UPDATE player_pills SET owner_id = auction_house()
    WHERE pill_id = p_pill_id AND owner_id = p_seller_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to sell' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO auction_listings (seller_id, price, pill_id)
    VALUES (p_seller_id, p_price, p_pill_id)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;

CREATE FUNCTION auction_list_page(p_seller_id BIGINT, p_page_id BIGINT, p_price BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    PERFORM auction_open_slot(p_seller_id);

    UPDATE manual_pages SET owner_id = auction_house()
    WHERE page_id = p_page_id AND owner_id = p_seller_id AND consumed_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to sell' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO auction_listings (seller_id, price, page_id)
    VALUES (p_seller_id, p_price, p_page_id)
    RETURNING listing_id INTO made;
    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- Handing it over
-- ---------------------------------------------------------------------------
-- One function, because taking the thing OUT of the house is the same act
-- whoever it goes to - the buyer on a sale, the seller on a cancellation.

CREATE FUNCTION auction_release(p_listing_id BIGINT, p_to BIGINT)
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
    END IF;
END;
$$;

CREATE FUNCTION auction_buy(p_buyer_id BIGINT, p_listing_id BIGINT)
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

CREATE FUNCTION auction_cancel(p_seller_id BIGINT, p_listing_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    it auction_listings%ROWTYPE;
BEGIN
    SELECT * INTO it FROM auction_listings
    WHERE listing_id = p_listing_id FOR UPDATE;

    IF NOT FOUND OR it.status <> 'open' THEN
        RAISE EXCEPTION 'that listing is gone' USING ERRCODE = 'check_violation';
    END IF;
    IF it.seller_id <> p_seller_id THEN
        RAISE EXCEPTION 'that is not your listing' USING ERRCODE = 'check_violation';
    END IF;

    -- The fee is not returned. It is the sink, and a refunded fee is no sink.
    PERFORM auction_release(p_listing_id, p_seller_id);

    UPDATE auction_listings SET status = 'cancelled', ended_at = now()
    WHERE listing_id = p_listing_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- The board
-- ---------------------------------------------------------------------------
-- What each listing IS, resolved once, so no screen has to know that a
-- listing holds one of five different things.

CREATE VIEW auction_board AS
SELECT
    l.listing_id, l.seller_id, l.price, l.status, l.listed_at,
    s.discord_name AS seller_name,
    CASE
        WHEN l.material_code IS NOT NULL THEN 'material'
        WHEN l.gu_id        IS NOT NULL THEN 'gu'
        WHEN l.equipment_id IS NOT NULL THEN 'equipment'
        WHEN l.pill_id      IS NOT NULL THEN 'pill'
        ELSE 'page'
    END AS kind,
    COALESCE(
        m.name || ' ' || chr(215) || l.quantity,
        gt.name || ' ' || repeat(chr(9733), g.stars),
        eq.name,
        pl.name || ' ' || chr(215) || pl.quantity,
        'Tier ' || pg.tier || ' ' || pp.name || ' page'
    ) AS label,
    COALESCE(m.emoji, gt.emoji, es.emoji, pk.emoji, chr(128220)) AS emoji,
    COALESCE(m.rarity, gt.rarity, eq.quality, 'common')          AS rarity,
    l.quantity, l.material_code, l.gu_id, l.equipment_id, l.pill_id, l.page_id
FROM auction_listings l
JOIN players s ON s.player_id = l.seller_id
LEFT JOIN materials m        ON m.code = l.material_code
LEFT JOIN player_gu g        ON g.gu_id = l.gu_id
LEFT JOIN gu_types gt        ON gt.gu_type_id = g.gu_type_id
LEFT JOIN player_equipment eq ON eq.equipment_id = l.equipment_id
LEFT JOIN equipment_slots es ON es.code = eq.slot
LEFT JOIN player_pills pl    ON pl.pill_id = l.pill_id
LEFT JOIN pill_kinds pk      ON pk.code = pl.kind
LEFT JOIN manual_pages pg    ON pg.page_id = l.page_id
LEFT JOIN paths pp           ON pp.code = pg.path_code;

COMMENT ON VIEW auction_board IS
    'A listing as a line: what it is, what it costs, who is selling it. The five kinds are resolved here so no screen has to.';
