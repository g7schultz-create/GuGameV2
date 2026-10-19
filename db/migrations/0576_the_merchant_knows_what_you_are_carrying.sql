-- 0576_the_merchant_knows_what_you_are_carrying
--
-- 0575 priced the cart off `broker_price_material`'s world, where three stones
-- is a lot. Against the world that exists it was free:
--
--     the dearest thing on the cart      27,648,000 stones
--     what sylvrime is carrying       8,541,134,933,771,362
--
-- Three hundred million carts. shinonn could have bought every slot forty
-- million times over without noticing, which is not a merchant, it is a
-- vending machine somebody left unlocked.
--
-- The markups are raised so the cart is priced against the purse it is being
-- shown to. For scale, the deepest sink in the game is the Vault door at
-- 9.2 billion stones, and the cart should sit in the same country as that
-- rather than five orders below it:
--
--     a tier 13 herb, eighty-odd of them      ~7e11
--     a rank 18 essence, two or three         ~1e12
--     a worm, by rank                         ~5e11
--     a beast egg, by its rank                ~1e12
--
-- So the richest cultivator in the world can clear two or three carts before
-- it costs them something, and anybody below the top of the ladder is choosing
-- one slot out of six. That is the shape a shop should have.
--
-- Nothing about WHAT he carries changes, only the asking price - and because
-- the cart is keyed on the hour, the one already standing out there keeps its
-- old prices until it turns. Nobody is charged more for something they were
-- already looking at.


UPDATE game_config SET value = 250000000,
    description = 'Multiplier on a thing''s tier^2 and count to reach what the merchant asks. Sized against what cultivators actually carry - at 900 the dearest slot on the cart was 27 million stones against purses holding eight quadrillion.'
WHERE key = 'market_markup';

UPDATE game_config SET value = 100000000000,
    description = 'The same, for a Gu, priced off its rank rather than a tier. Dearer than a herb because a worm is not a herb.'
WHERE key = 'market_gu_markup';

UPDATE game_config SET value = 60000000000,
    description = 'The same, for a beast egg.'
WHERE key = 'market_egg_markup';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_rich  BIGINT;
    v_cart  BIGINT;
    v_dear  BIGINT;
    v_door  BIGINT;
    v_hour  TIMESTAMPTZ := date_trunc('hour', now()) + interval '1 hour';
    i       INTEGER;
BEGIN
    SELECT p.player_id INTO v_who FROM players p LIMIT 1;

    -- TWENTY CARTS, NOT ONE. What the merchant lays out is drawn at random, so
    -- a single cart of tier 1 weeds and a single cart of tier 13 blooms differ
    -- by two orders of magnitude. The first version of this judged one draw
    -- and was measuring the dice.
    FOR i IN 1..20 LOOP
        PERFORM market_stock_for(v_hour + make_interval(hours => i));
    END LOOP;

    SELECT round(avg(per_cart)), max(per_slot) INTO v_cart, v_dear
    FROM (
        SELECT sum(price) AS per_cart, max(price) AS per_slot
        FROM market_stall
        WHERE stocked_for > v_hour
        GROUP BY stocked_for
    ) x;

    SELECT max(pm.quantity) INTO v_rich
    FROM player_materials pm JOIN players p ON p.player_id = pm.player_id
    WHERE pm.material_code = 'spirit_stone' AND p.discord_id > 0;

    SELECT max(d.stone_cost) INTO v_door FROM dungeons d;

    RAISE NOTICE
        'twenty carts: % on average, dearest slot seen %', v_cart, v_dear;
    RAISE NOTICE
        'the richest purse is %, and the deepest dungeon door is %',
        v_rich, v_door;

    -- 1. A CART IS WORTH NOTICING. If an average one costs less than a single
    --    dungeon door, it is not a sink.
    IF v_cart < v_door THEN
        RAISE EXCEPTION
            'an average cart costs % and a dungeon door costs % - the merchant '
            'is still free', v_cart, v_door;
    END IF;

    -- 2. AND IT IS STILL BUYABLE. A cart whose dearest slot nobody in the
    --    world can afford is a shop with the shutters down.
    IF v_rich IS NOT NULL AND v_dear > v_rich THEN
        RAISE EXCEPTION
            'the dearest slot seen is % and nobody holds more than %',
            v_dear, v_rich;
    END IF;

    -- 3. AND NOT SO CHEAP THAT THE DEEPEST PURSE CLEARS IT A THOUSAND TIMES.
    IF v_rich IS NOT NULL AND v_cart * 1000 < v_rich THEN
        RAISE EXCEPTION
            'the richest purse covers an average cart % times over',
            v_rich / GREATEST(1, v_cart);
    END IF;

    RAISE NOTICE
        'the richest cultivator can clear an average cart % time(s) over',
        round(v_rich::numeric / GREATEST(1, v_cart), 1);

    DELETE FROM market_stall WHERE stocked_for > v_hour;
    DELETE FROM market_stall WHERE stocked_for = v_hour;
END
$probe$;
