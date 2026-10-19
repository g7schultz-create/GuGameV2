-- 0033_trading
--
-- Two players, two piles, one swap.
--
-- THE RULE THAT SHAPES EVERYTHING: changing what you are offering CLEARS BOTH
-- CONFIRMATIONS. Every trade scam ever run is a variation on confirming a deal
-- and then swapping the goods, and no amount of care in the bot can prevent it
-- if the database will let an offer move under a confirmation. So the reset is
-- a trigger on the offer tables - it fires for the bot, for a future web UI,
-- for psql, and for anything else that ever writes here.
--
-- FOUR OFFER TABLES, NOT ONE POLYMORPHIC ONE. 0023 made this call already and
-- for the same reason: a polymorphic parent cannot carry a real foreign key,
-- and every foreign key in this schema is declared. A manual, a page and a
-- material are owned in three different shapes - a join row, an instance with
-- an owner column, and a quantity - so one table pretending otherwise would
-- only move the difference into the executor.
--
-- GU. The design has Gu as equippable instances with a Path, tradable like
-- anything else. They do not exist yet - no table, no rows - so there is
-- nothing here to trade. When they land they take a `trade_offer_gu` shaped
-- exactly like `trade_offer_pages` and one more block in trade_execute. That
-- is honest about the work rather than pretending a column covers it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A manual outlives its refiner
-- ---------------------------------------------------------------------------
-- `manuals.created_by` CASCADEd, which was right while a refined manual could
-- only ever sit in its maker's hands. The moment one can be TRADED, that
-- cascade reaches into a stranger's collection and deletes a book they earned
-- because somebody else closed their account.
--
-- SET NULL instead, and the whole-refinement CHECK stops demanding a refiner.
-- A refined manual whose maker is gone is still a refined manual: it has a
-- harmony and a date, and `/manual` already renders the maker only when there
-- is one.

ALTER TABLE manuals DROP CONSTRAINT manuals_created_by_fkey;

ALTER TABLE manuals
    ADD CONSTRAINT manuals_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES players (player_id) ON DELETE SET NULL;

ALTER TABLE manuals DROP CONSTRAINT manuals_refinement_is_whole;

ALTER TABLE manuals ADD CONSTRAINT manuals_refinement_is_whole CHECK (
    (harmony IS NULL AND refined_at IS NULL)
    OR
    (harmony IS NOT NULL AND refined_at IS NOT NULL)
);

-- With created_by nullable-by-deletion, "created_by IS NULL" no longer means
-- "seeded content anyone may find" - an orphaned refined manual would answer
-- to it too, and start dropping off corpses. `code IS NOT NULL` is the precise
-- predicate and always was: seeded content is the content with a stable handle.
CREATE OR REPLACE FUNCTION roll_manual_drop(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    creature_rank SMALLINT;
    found         BIGINT;
BEGIN
    IF random() >= game_config_value('manual_drop_chance') THEN
        RETURN NULL;
    END IF;

    SELECT rank INTO creature_rank FROM creature_species WHERE species_id = p_species_id;

    SELECT m.manual_id INTO found
    FROM manuals m
    WHERE m.code IS NOT NULL
      AND m.required_rank <= GREATEST(creature_rank, 1)
      AND NOT EXISTS (
          SELECT 1 FROM player_manuals pm
          WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
      )
    ORDER BY random()
    LIMIT 1;

    IF found IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, found)
    ON CONFLICT DO NOTHING;

    RETURN found;
END;
$$;


-- ---------------------------------------------------------------------------
-- trades
-- ---------------------------------------------------------------------------
-- RESTRICT on both players for the same reason battle_combatants uses it: a
-- trade is history involving somebody else, and closing an account must not
-- rewrite what the other party can prove happened.

CREATE TABLE trades (
    trade_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    proposer_id BIGINT NOT NULL REFERENCES players (player_id) ON DELETE RESTRICT,
    partner_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE RESTRICT,

    status      TEXT NOT NULL DEFAULT 'open'
                CHECK (status IN ('open', 'complete', 'cancelled', 'expired')),

    -- Both must be set for the swap to run, and any change to either pile
    -- clears both. See the trigger below.
    proposer_confirmed_at TIMESTAMPTZ,
    partner_confirmed_at  TIMESTAMPTZ,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at    TIMESTAMPTZ,

    CONSTRAINT trades_two_different_people CHECK (proposer_id <> partner_id),
    CONSTRAINT trades_ended_matches_status
        CHECK ((status = 'open') = (ended_at IS NULL))
);

CREATE INDEX trades_proposer_idx ON trades (proposer_id);
CREATE INDEX trades_partner_idx  ON trades (partner_id);
CREATE INDEX trades_open_idx     ON trades (created_at) WHERE status = 'open';

COMMENT ON TABLE trades IS
    'A two-sided swap. Both confirmations must stand at once, and any change to either pile clears them.';


-- ---------------------------------------------------------------------------
-- player_active_trade
-- ---------------------------------------------------------------------------
-- One trade at a time, as a claim table - the same shape player_active_battle
-- uses. Without it a player could promise the same manual to two people, and
-- whichever swap ran second would find it gone.

CREATE TABLE player_active_trade (
    player_id  BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,
    trade_id   BIGINT NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side       SMALLINT NOT NULL CHECK (side IN (0, 1)),
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (trade_id, side)
);

CREATE INDEX player_active_trade_trade_idx ON player_active_trade (trade_id);


-- ---------------------------------------------------------------------------
-- The three piles
-- ---------------------------------------------------------------------------
-- Side 0 is the proposer, side 1 the partner, matching battles.
--
-- The primary keys are doing real work: a manual or a page can appear in a
-- trade exactly once, on one side, so "offer it to myself" and "offer it
-- twice" are not states the executor has to defend against.

CREATE TABLE trade_offer_manuals (
    trade_id  BIGINT   NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side      SMALLINT NOT NULL CHECK (side IN (0, 1)),
    manual_id BIGINT   NOT NULL REFERENCES manuals (manual_id) ON DELETE CASCADE,

    PRIMARY KEY (trade_id, manual_id)
);

CREATE INDEX trade_offer_manuals_manual_idx ON trade_offer_manuals (manual_id);

CREATE TABLE trade_offer_pages (
    trade_id BIGINT   NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side     SMALLINT NOT NULL CHECK (side IN (0, 1)),
    page_id  BIGINT   NOT NULL REFERENCES manual_pages (page_id) ON DELETE CASCADE,

    PRIMARY KEY (trade_id, page_id)
);

CREATE INDEX trade_offer_pages_page_idx ON trade_offer_pages (page_id);

CREATE TABLE trade_offer_materials (
    trade_id      BIGINT   NOT NULL REFERENCES trades (trade_id) ON DELETE CASCADE,
    side          SMALLINT NOT NULL CHECK (side IN (0, 1)),
    material_code TEXT     NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    quantity      BIGINT   NOT NULL CHECK (quantity > 0),

    -- Both sides may offer the same material; each keeps its own line.
    PRIMARY KEY (trade_id, side, material_code)
);

CREATE INDEX trade_offer_materials_material_idx ON trade_offer_materials (material_code);

COMMENT ON TABLE trade_offer_materials IS
    'Stacked goods, so a quantity. Manuals and pages are instances and get a row each.';


-- ---------------------------------------------------------------------------
-- Changing the pile clears the handshake
-- ---------------------------------------------------------------------------
-- The one rule that cannot live in the bot. Confirm, then quietly swap the
-- Tier 7 manual for a Tier 1 - this is the trigger that makes that a
-- re-confirmation instead of a robbery.

CREATE FUNCTION trade_offer_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE trades
    SET proposer_confirmed_at = NULL,
        partner_confirmed_at  = NULL
    WHERE trade_id = COALESCE(NEW.trade_id, OLD.trade_id)
      AND status = 'open';
    RETURN NULL;
END;
$$;

CREATE TRIGGER trade_offer_manuals_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_manuals
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();

CREATE TRIGGER trade_offer_pages_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_pages
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();

CREATE TRIGGER trade_offer_materials_resets_confirmations
    AFTER INSERT OR UPDATE OR DELETE ON trade_offer_materials
    FOR EACH ROW EXECUTE FUNCTION trade_offer_changed();


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('trade_expiry_minutes', 30,
     'An abandoned trade holds both claims. This is when it stops.');


-- ---------------------------------------------------------------------------
-- trade_side
-- ---------------------------------------------------------------------------
-- Which pile is this player's, and an exception if the answer is "neither".

CREATE FUNCTION trade_side(p_trade_id BIGINT, p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    which SMALLINT;
BEGIN
    SELECT CASE WHEN t.proposer_id = p_player_id THEN 0
                WHEN t.partner_id  = p_player_id THEN 1 END
    INTO which
    FROM trades t WHERE t.trade_id = p_trade_id;

    IF which IS NULL THEN
        RAISE EXCEPTION 'that is not your trade' USING ERRCODE = 'check_violation';
    END IF;
    RETURN which;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_open
-- ---------------------------------------------------------------------------
-- Stale trades are cleared here rather than by a scheduled job: the only
-- moment anybody cares that an abandoned trade is holding a claim is when they
-- try to start a new one.

CREATE FUNCTION trade_open(p_proposer BIGINT, p_partner BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    stale  BIGINT;
    new_id BIGINT;
BEGIN
    IF p_proposer = p_partner THEN
        RAISE EXCEPTION 'you cannot trade with yourself' USING ERRCODE = 'check_violation';
    END IF;

    FOR stale IN
        SELECT pat.trade_id
        FROM player_active_trade pat
        JOIN trades t ON t.trade_id = pat.trade_id
        WHERE pat.player_id IN (p_proposer, p_partner)
          AND t.created_at < now()
              - make_interval(mins => game_config_value('trade_expiry_minutes')::int)
    LOOP
        UPDATE trades SET status = 'expired', ended_at = now() WHERE trade_id = stale;
        DELETE FROM player_active_trade WHERE trade_id = stale;
    END LOOP;

    IF EXISTS (SELECT 1 FROM player_active_trade WHERE player_id = p_proposer) THEN
        RAISE EXCEPTION 'you are already in a trade' USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM player_active_trade WHERE player_id = p_partner) THEN
        RAISE EXCEPTION 'they are already in a trade' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trades (proposer_id, partner_id)
    VALUES (p_proposer, p_partner)
    RETURNING trade_id INTO new_id;

    INSERT INTO player_active_trade (player_id, trade_id, side)
    VALUES (p_proposer, new_id, 0), (p_partner, new_id, 1);

    RETURN new_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- Putting things on the table
-- ---------------------------------------------------------------------------
-- Ownership is checked here AND again at execution. Here so the offer screen
-- can refuse immediately with a sentence a player understands; again at
-- execution because minutes pass in between, and in those minutes a page can
-- be refined away or a material spent.

CREATE FUNCTION trade_add_manual(p_trade_id BIGINT, p_player_id BIGINT, p_manual_id BIGINT)
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
        SELECT 1 FROM player_manuals
        WHERE player_id = p_player_id AND manual_id = p_manual_id
    ) THEN
        RAISE EXCEPTION 'you do not own that manual' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_manuals (trade_id, side, manual_id)
    VALUES (p_trade_id, which, p_manual_id)
    ON CONFLICT (trade_id, manual_id) DO NOTHING;
END;
$$;

CREATE FUNCTION trade_add_page(p_trade_id BIGINT, p_player_id BIGINT, p_page_id BIGINT)
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
        SELECT 1 FROM manual_pages
        WHERE page_id = p_page_id AND owner_id = p_player_id AND consumed_at IS NULL
    ) THEN
        RAISE EXCEPTION 'that page is not yours to give' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_pages (trade_id, side, page_id)
    VALUES (p_trade_id, which, p_page_id)
    ON CONFLICT (trade_id, page_id) DO NOTHING;
END;
$$;

-- Set rather than add: a quantity is a number the player is choosing, and
-- "offer 5" twice meaning 10 is a way to give away more than you meant to.
-- Zero takes the line off the table.
CREATE FUNCTION trade_set_material(
    p_trade_id BIGINT, p_player_id BIGINT, p_code TEXT, p_quantity BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
    held  BIGINT;
BEGIN
    IF (SELECT status FROM trades WHERE trade_id = p_trade_id) <> 'open' THEN
        RAISE EXCEPTION 'that trade is closed' USING ERRCODE = 'check_violation';
    END IF;

    IF p_quantity <= 0 THEN
        DELETE FROM trade_offer_materials
        WHERE trade_id = p_trade_id AND side = which AND material_code = p_code;
        RETURN;
    END IF;

    SELECT quantity INTO held FROM player_materials
    WHERE player_id = p_player_id AND material_code = p_code;

    IF COALESCE(held, 0) < p_quantity THEN
        RAISE EXCEPTION 'you hold % of that, not %', COALESCE(held, 0), p_quantity
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trade_offer_materials (trade_id, side, material_code, quantity)
    VALUES (p_trade_id, which, p_code, p_quantity)
    ON CONFLICT (trade_id, side, material_code)
    DO UPDATE SET quantity = EXCLUDED.quantity;
END;
$$;

CREATE FUNCTION trade_withdraw(p_trade_id BIGINT, p_player_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    which SMALLINT := trade_side(p_trade_id, p_player_id);
BEGIN
    DELETE FROM trade_offer_manuals   WHERE trade_id = p_trade_id AND side = which;
    DELETE FROM trade_offer_pages     WHERE trade_id = p_trade_id AND side = which;
    DELETE FROM trade_offer_materials WHERE trade_id = p_trade_id AND side = which;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_execute
-- ---------------------------------------------------------------------------
-- The swap, in one transaction, with both piles re-checked under lock.
--
-- Manuals move by delete-and-insert on player_manuals rather than an UPDATE of
-- its primary key, which also lets player_manual_slots CASCADE the giver's
-- slot clear. Stats are recomputed for both sides afterwards, because HP,
-- defense and strength are a function of what you are carrying.

CREATE FUNCTION trade_execute(p_trade_id BIGINT)
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

        DELETE FROM player_manuals
        WHERE player_id = giver AND manual_id = row_m.manual_id;

        INSERT INTO player_manuals (player_id, manual_id)
        VALUES (taker, row_m.manual_id)
        ON CONFLICT DO NOTHING;
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

    -- A manual that changed hands changes both bodies.
    PERFORM apply_physique_xp(deal.proposer_id, 0);
    PERFORM apply_physique_xp(deal.partner_id, 0);
END;
$$;

COMMENT ON FUNCTION trade_execute(BIGINT) IS
    'The swap. Re-checks every offered item under lock, because minutes pass between confirming and executing.';


-- ---------------------------------------------------------------------------
-- trade_confirm / trade_cancel
-- ---------------------------------------------------------------------------

CREATE FUNCTION trade_confirm(p_trade_id BIGINT, p_player_id BIGINT)
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

    IF NOT EXISTS (SELECT 1 FROM trade_offer_manuals   WHERE trade_id = p_trade_id)
       AND NOT EXISTS (SELECT 1 FROM trade_offer_pages WHERE trade_id = p_trade_id)
       AND NOT EXISTS (SELECT 1 FROM trade_offer_materials WHERE trade_id = p_trade_id)
    THEN
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

COMMENT ON FUNCTION trade_confirm(BIGINT, BIGINT) IS
    'Confirms one side, and runs the swap when that makes two. Returns whether the trade completed.';

CREATE FUNCTION trade_cancel(p_trade_id BIGINT, p_player_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM trade_side(p_trade_id, p_player_id);

    UPDATE trades SET status = 'cancelled', ended_at = now()
    WHERE trade_id = p_trade_id AND status = 'open';

    DELETE FROM player_active_trade WHERE trade_id = p_trade_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- trade_contents
-- ---------------------------------------------------------------------------
-- Both piles as text, for the card. One row per line, ordered so the two sides
-- read the same way every time - a trade screen that reshuffles between
-- refreshes is a trade screen nobody can check.

CREATE VIEW trade_contents AS
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
JOIN materials m ON m.code = o.material_code;

COMMENT ON VIEW trade_contents IS
    'Both piles, one row per line. Gu joins this with a fourth UNION branch when they exist.';
