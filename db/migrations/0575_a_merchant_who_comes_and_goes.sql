-- 0575_a_merchant_who_comes_and_goes
--
-- There is nowhere to SPEND a spirit stone. `sell_to_broker` takes things off
-- a cultivator and `auction_buy` buys from other players, so the only way a
-- stone leaves the economy is a dwelling, a dungeon door or a forge - and the
-- deepest cultivators are sitting on a quadrillion of them.
--
-- So a merchant with a cart: body herbs, essence, Gu and beast eggs, priced in
-- stones, and a different cart every hour.
--
-- THE HOUR IS THE STOCK, not a timer. `date_trunc('hour', now())` is the key -
-- the shelf for 14:00 is built the first time anybody looks during 14:00 and
-- is the same shelf for everybody who looks after them, so two cultivators in
-- the same hour see the same cart and neither can reroll it by refreshing. At
-- 15:00 the key changes and the next look builds the next cart.
--
-- Nothing ticks, as nowhere else in this game does.
--
-- WHAT IT COSTS. `broker_price_material` prices by rarity alone and tops out
-- around three stones, which is what the merchant PAYS, not what he asks. A
-- cart priced like that would be free. The ask is built off tier^2 the way
-- everything else that has had to be priced against this economy is, times a
-- markup - so a tier 13 herb is 169 times a tier 1 one and the deep shelf is
-- where the stones actually go.
--
-- WHAT HE CARRIES: six slots, drawn from four kinds of thing. The draw is
-- seeded by the hour so it is stable within it, and weighted so herbs are
-- common and a beast egg is a thing you come back for.


CREATE TABLE market_stall (
    stocked_for TIMESTAMPTZ NOT NULL,
    slot_no     SMALLINT    NOT NULL CHECK (slot_no >= 1),
    kind        TEXT        NOT NULL
                CHECK (kind IN ('material', 'essence', 'gu', 'egg')),
    code        TEXT        NOT NULL,
    quantity    BIGINT      NOT NULL CHECK (quantity > 0),
    price       BIGINT      NOT NULL CHECK (price > 0),
    PRIMARY KEY (stocked_for, slot_no)
);

COMMENT ON TABLE market_stall IS
    'What the merchant has out this hour. Keyed by the hour itself, so the cart is built once by whoever looks first and is the same cart for everybody else who looks before it turns - a shelf nobody can reroll by asking twice. 0575.';


CREATE TABLE market_bought (
    stocked_for TIMESTAMPTZ NOT NULL,
    slot_no     SMALLINT    NOT NULL,
    player_id   BIGINT      NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    bought_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (stocked_for, slot_no, player_id)
);

COMMENT ON TABLE market_bought IS
    'Who has already taken which slot this hour. One of each per cultivator per hour - the cart is a chance, not a shop to empty.';


INSERT INTO game_config (key, value, description) VALUES
    ('market_slots', 6,
     'How many things the merchant has out at once.'),
    ('market_markup', 900,
     'Multiplier on a thing''s tier^2 to reach what the merchant asks for it. The broker''s own prices top out near three stones - that is what he PAYS - and a cart priced at that would be free against what cultivators hold.'),
    ('market_gu_markup', 30000,
     'The same, for a Gu - priced off its rank rather than a tier, and dearer because a worm is not a herb.'),
    ('market_egg_markup', 90000,
     'The same, for a beast egg.');


-- ---------------------------------------------------------------------------
-- Building the cart
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION market_stock_for(p_hour TIMESTAMPTZ)
RETURNS VOID
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_slots INTEGER := game_config_value('market_slots')::int;
    i       INTEGER;
    v_kind  TEXT;
    v_code  TEXT;
    v_qty   BIGINT;
    v_price BIGINT;
    v_tier  SMALLINT;
BEGIN
    -- Whoever looks first builds it. Everybody after that reads the same cart,
    -- which is the whole point of keying on the hour rather than on the look.
    IF EXISTS (SELECT 1 FROM market_stall s WHERE s.stocked_for = p_hour) THEN
        RETURN;
    END IF;

    FOR i IN 1..v_slots LOOP
        -- Herbs are the bread of the cart; a worm or an egg is why you come
        -- back. The exponential race, the same draw everything else uses.
        SELECT k.kind INTO v_kind
        FROM (VALUES ('material', 55.0), ('essence', 20.0),
                     ('gu', 18.0), ('egg', 7.0)) AS k(kind, weight)
        ORDER BY -ln(random()) / k.weight
        LIMIT 1;

        v_code  := NULL;
        v_price := NULL;

        IF v_kind = 'material' THEN
            SELECT m.code, m.tier INTO v_code, v_tier
            FROM materials m
            WHERE m.tier IS NOT NULL
            ORDER BY random() LIMIT 1;
            v_qty   := 20 + floor(random() * 80);
            v_price := GREATEST(1, round(power(v_tier, 2)
                       * game_config_value('market_markup') * v_qty));

        ELSIF v_kind = 'essence' THEN
            SELECT e.material_code, e.rank INTO v_code, v_tier
            FROM immortal_essences e ORDER BY random() LIMIT 1;
            v_qty   := 1 + floor(random() * 3);
            v_price := GREATEST(1, round(power(v_tier, 2)
                       * game_config_value('market_markup') * 40 * v_qty));

        ELSIF v_kind = 'gu' THEN
            -- Nothing the world would not drop anyway: the merchant deals, he
            -- does not smuggle the apex out of the Vault.
            SELECT t.code, t.rank INTO v_code, v_tier
            FROM gu_types t
            WHERE t.rank <= game_config_value('gu_max_droppable_rank')
            ORDER BY random() LIMIT 1;
            v_qty   := 1;
            v_price := GREATEST(1, round(power(v_tier, 2)
                       * game_config_value('market_gu_markup')));

        ELSE
            SELECT cs.code, LEAST(9, GREATEST(1, cs.rank)) INTO v_code, v_tier
            FROM creature_species cs
            WHERE cs.kind IN ('beast', 'elite')
            ORDER BY random() LIMIT 1;
            v_qty   := 1;
            v_price := GREATEST(1, round(power(v_tier, 2)
                       * game_config_value('market_egg_markup')));
        END IF;

        CONTINUE WHEN v_code IS NULL;

        INSERT INTO market_stall (stocked_for, slot_no, kind, code, quantity, price)
        VALUES (p_hour, i, v_kind, v_code, v_qty, v_price)
        ON CONFLICT DO NOTHING;
    END LOOP;
END;
$fn$;


CREATE OR REPLACE FUNCTION market_today(p_player_id BIGINT)
RETURNS TABLE (slot_no SMALLINT, kind TEXT, code TEXT, label TEXT,
               quantity BIGINT, price BIGINT, taken BOOLEAN,
               turns_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_hour TIMESTAMPTZ := date_trunc('hour', now());
BEGIN
    PERFORM market_stock_for(v_hour);

    RETURN QUERY
    SELECT s.slot_no, s.kind, s.code,
           CASE s.kind
               WHEN 'material' THEN material_name(s.code)
               WHEN 'essence'  THEN material_name(s.code)
               WHEN 'gu'       THEN (SELECT t.name FROM gu_types t
                                     WHERE t.code = s.code)
               ELSE (SELECT cs.name FROM creature_species cs
                     WHERE cs.code = s.code)
           END,
           s.quantity, s.price,
           EXISTS (SELECT 1 FROM market_bought b
                   WHERE b.stocked_for = s.stocked_for
                     AND b.slot_no = s.slot_no
                     AND b.player_id = p_player_id),
           v_hour + interval '1 hour'
    FROM market_stall s
    WHERE s.stocked_for = v_hour
    ORDER BY s.slot_no;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Buying from it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION market_buy(p_player_id BIGINT, p_slot SMALLINT)
RETURNS TABLE (label TEXT, quantity BIGINT, paid BIGINT, stones_left BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_hour TIMESTAMPTZ := date_trunc('hour', now());
    s      RECORD;
    v_what TEXT;
BEGIN
    PERFORM market_stock_for(v_hour);

    SELECT * INTO s FROM market_stall x
    WHERE x.stocked_for = v_hour AND x.slot_no = p_slot;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing in that place on the cart'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM market_bought b
               WHERE b.stocked_for = v_hour AND b.slot_no = p_slot
                 AND b.player_id = p_player_id) THEN
        RAISE EXCEPTION
            'you have already taken that one - he will have other things within the hour'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refuses rather than going negative, so a short purse costs nothing.
    PERFORM spend_material(p_player_id, 'spirit_stone', s.price);

    IF s.kind IN ('material', 'essence') THEN
        PERFORM grant_material(p_player_id, s.code, s.quantity);
        v_what := material_name(s.code);
    ELSIF s.kind = 'gu' THEN
        PERFORM grant_gu(p_player_id,
            (SELECT t.gu_type_id FROM gu_types t WHERE t.code = s.code));
        v_what := (SELECT t.name FROM gu_types t WHERE t.code = s.code);
    ELSE
        PERFORM grant_beast_egg(p_player_id,
            (SELECT cs.species_id FROM creature_species cs WHERE cs.code = s.code),
            LEAST(9, GREATEST(1, (SELECT cs.rank FROM creature_species cs
                                  WHERE cs.code = s.code)))::smallint,
            'rare', NULL);
        v_what := (SELECT cs.name FROM creature_species cs WHERE cs.code = s.code);
    END IF;

    INSERT INTO market_bought (stocked_for, slot_no, player_id)
    VALUES (v_hour, p_slot, p_player_id);

    RETURN QUERY
    SELECT v_what, s.quantity, s.price,
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = 'spirit_stone'), 0);
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who BIGINT;
    v_n   INTEGER;
    v_a   TEXT;
    v_b   TEXT;
    r     RECORD;
    v_got RECORD;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1301, 'market-probe') RETURNING player_id INTO v_who;

        -- 1. THE CART HAS THINGS ON IT.
        SELECT count(*) INTO v_n FROM market_today(v_who);
        IF v_n <> game_config_value('market_slots') THEN
            RAISE EXCEPTION 'the merchant laid out % of % slots',
                v_n, game_config_value('market_slots');
        END IF;

        -- 2. AND IT IS THE SAME CART TWICE. The hour is the stock; a shelf
        --    that rerolled on every look would be a slot machine.
        SELECT string_agg(code, ',' ORDER BY slot_no) INTO v_a
        FROM market_today(v_who);
        SELECT string_agg(code, ',' ORDER BY slot_no) INTO v_b
        FROM market_today(v_who);
        IF v_a IS DISTINCT FROM v_b THEN
            RAISE EXCEPTION 'the cart changed between two looks in one hour';
        END IF;

        -- 3. EVERYTHING ON IT HAS A NAME AND A PRICE. A slot naming something
        --    that does not exist is a slot nobody can buy.
        FOR r IN SELECT * FROM market_today(v_who) LOOP
            IF r.label IS NULL THEN
                RAISE EXCEPTION
                    'slot % offers % "%" and it has no name',
                    r.slot_no, r.kind, r.code;
            END IF;
            IF r.price <= 0 THEN
                RAISE EXCEPTION 'slot % is free', r.slot_no;
            END IF;
        END LOOP;

        -- 4. BUYING TAKES THE STONES AND HANDS THE THING OVER.
        SELECT * INTO r FROM market_today(v_who) ORDER BY price LIMIT 1;
        PERFORM grant_material(v_who, 'spirit_stone', r.price * 2);

        SELECT * INTO v_got FROM market_buy(v_who, r.slot_no);
        IF v_got.paid <> r.price THEN
            RAISE EXCEPTION 'asked % and took %', r.price, v_got.paid;
        END IF;
        RAISE NOTICE
            'bought "% x%" for % stones', v_got.label, v_got.quantity, v_got.paid;

        -- 5. AND ONLY ONCE. The cart is a chance, not a shop to empty.
        BEGIN
            PERFORM market_buy(v_who, r.slot_no);
            RAISE EXCEPTION 'the same slot was bought twice in one hour';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- 6. AND A SHORT PURSE BUYS NOTHING. `spend_material` refuses rather
        --    than going negative, so this must raise rather than hand over.
        DELETE FROM player_materials
        WHERE player_id = v_who AND material_code = 'spirit_stone';
        SELECT * INTO r FROM market_today(v_who)
        WHERE NOT taken ORDER BY price LIMIT 1;
        IF r.slot_no IS NOT NULL THEN
            BEGIN
                PERFORM market_buy(v_who, r.slot_no);
                RAISE EXCEPTION 'something was bought with no stones at all';
            EXCEPTION WHEN check_violation THEN
                NULL;
            END;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
