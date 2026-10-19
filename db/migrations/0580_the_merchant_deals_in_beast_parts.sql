-- 0580_the_merchant_deals_in_beast_parts
--
-- He could not. The material lane draws
--
--     FROM materials m WHERE m.tier IS NOT NULL
--
-- and not one of the sixty-two beast materials has a tier - they are graded by
-- RARITY, because a tusk is not a tier-four tusk, it is a common one. So every
-- hide, horn, scale and gallbladder in the game was invisible to the cart, and
-- the only way to get one was to go and kill the thing wearing it.
--
-- A LANE OF ITS OWN rather than widening the material lane, for two reasons.
-- The price has to come off `material_grade(rarity)` instead of a tier, and the
-- cart marks each slot with its kind - a boar tusk under a herb's sprig is a
-- small lie told every hour.
--
-- THE WEIGHTS ARE ADDED TO, NOT REDISTRIBUTED. The four existing lanes keep
-- their numbers and beast comes in at 20, so the total goes 100 -> 120 and
-- everything else keeps its absolute footing while taking a proportional share
-- of the slots:
--
--     material 55 -> 45.8%    essence 20 -> 16.7%    beast 20 -> 16.7%
--     gu       18 -> 15.0%    egg      7 ->  5.8%
--
-- That is deliberate. Rebalancing the cart is not what was asked for; stocking
-- a shelf it never had is.
--
-- `market_buy` needs one word: beast materials are materials, so they already
-- grant correctly - the branch just has to admit them.


-- ---------------------------------------------------------------------------
-- The kind is allowed on the shelf
-- ---------------------------------------------------------------------------

ALTER TABLE market_stall DROP CONSTRAINT market_stall_kind_check;
ALTER TABLE market_stall ADD CONSTRAINT market_stall_kind_check
    CHECK (kind = ANY (ARRAY['material', 'essence', 'gu', 'egg', 'beast']));


-- ---------------------------------------------------------------------------
-- He stocks it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'market_stock_for' AND pronamespace = 'public'::regnamespace;

    anchor := '(''gu'', 18.0), (''egg'', 7.0)) AS k(kind, weight)';
    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'market_stock_for does not weight its lanes the way it did';
    END IF;
    patched := replace(src, anchor,
        '(''gu'', 18.0), (''egg'', 7.0),' || chr(10) ||
        '                     -- 0580. Added to the four, not carved out of them.' || chr(10) ||
        '                     (''beast'', 20.0)) AS k(kind, weight)');

    -- The lane itself, ahead of the egg branch that closes the chain.
    anchor := '        ELSE' || chr(10) ||
              '            SELECT cs.code, LEAST(9, GREATEST(1, cs.rank)) INTO v_code, v_tier';
    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'market_stock_for does not end on the egg lane any more';
    END IF;
    patched := replace(patched, anchor,
        '        ELSIF v_kind = ''beast'' THEN' || chr(10) ||
        '            -- Graded, not tiered. A beast material carries no tier at' || chr(10) ||
        '            -- all, so `material_grade` of its rarity stands in for one -' || chr(10) ||
        '            -- the same number `beast_food_value` squares when the same' || chr(10) ||
        '            -- tusk is fed to a pet, rather than a second opinion about' || chr(10) ||
        '            -- what a tusk is worth.' || chr(10) ||
        '            SELECT m.code, material_grade(m.rarity)::smallint' || chr(10) ||
        '              INTO v_code, v_tier' || chr(10) ||
        '            FROM materials m' || chr(10) ||
        '            WHERE m.category = ''beast''' || chr(10) ||
        '            ORDER BY random() LIMIT 1;' || chr(10) ||
        '            -- Fewer than a herb. You butcher for these; he is only a' || chr(10) ||
        '            -- convenience, and the farm added in 0582 is the real road.' || chr(10) ||
        '            v_qty   := 5 + floor(random() * 20);' || chr(10) ||
        '            v_price := GREATEST(1, round(power(v_tier, 2)' || chr(10) ||
        '                       * game_config_value(''market_markup'') * 2 * v_qty));' || chr(10) ||
        chr(10) ||
        '        ELSE' || chr(10) ||
        '            SELECT cs.code, LEAST(9, GREATEST(1, cs.rank)) INTO v_code, v_tier');

    IF patched = src THEN
        RAISE EXCEPTION 'the market_stock_for patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- And it is granted when bought
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'market_buy' AND pronamespace = 'public'::regnamespace;

    anchor := 'IF s.kind IN (''material'', ''essence'') THEN';
    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'market_buy does not route materials the way it did';
    END IF;

    -- A beast part IS a material; `grant_material` and `material_name` both
    -- already do the right thing with one. Only the branch was too narrow.
    patched := replace(src, anchor,
        'IF s.kind IN (''material'', ''essence'', ''beast'') THEN');

    IF patched = src THEN
        RAISE EXCEPTION 'the market_buy patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_hour  TIMESTAMPTZ;
    v_beast INTEGER := 0;
    v_slots INTEGER := game_config_value('market_slots')::int;
    v_bad   TEXT;
    v_who   BIGINT;
    v_got   RECORD;
    i       INTEGER;
BEGIN
    BEGIN
        -- 1. HE ACTUALLY PUTS THEM OUT. Sixty carts of six slots is 360 draws
        --    against a one-in-six lane; zero would mean it never fires.
        FOR i IN 1..60 LOOP
            v_hour := date_trunc('hour', now()) + make_interval(hours => 1000 + i);
            PERFORM market_stock_for(v_hour);
            SELECT v_beast + count(*) INTO v_beast
            FROM market_stall s WHERE s.stocked_for = v_hour AND s.kind = 'beast';
        END LOOP;

        IF v_beast = 0 THEN
            RAISE EXCEPTION
                'sixty carts of % slots held no beast material at all', v_slots;
        END IF;
        RAISE NOTICE
            'beast materials filled % of % slots across sixty carts',
            v_beast, 60 * v_slots;

        -- 2. AND ONLY BEAST MATERIALS IN THAT LANE. A kind pointing at a herb
        --    would price it off the wrong scale and still look fine on screen.
        SELECT string_agg(DISTINCT s.code, ', ') INTO v_bad
        FROM market_stall s
        WHERE s.kind = 'beast'
          AND NOT EXISTS (SELECT 1 FROM materials m
                          WHERE m.code = s.code AND m.category = 'beast');
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'the beast lane stocked these non-beast codes: %', v_bad;
        END IF;

        -- 3. AND ONE CAN BE BOUGHT. `market_buy` reads the CURRENT hour, so
        --    the shelf it reads has to be this one.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1102, 'market-probe') RETURNING player_id INTO v_who;

        DELETE FROM market_stall WHERE stocked_for = date_trunc('hour', now());
        INSERT INTO market_stall (stocked_for, slot_no, kind, code, quantity, price)
        SELECT date_trunc('hour', now()), 1, 'beast', m.code, 7, 1000
        FROM materials m WHERE m.category = 'beast' ORDER BY m.code LIMIT 1;

        PERFORM grant_material(v_who, 'spirit_stone', 1000000);
        SELECT * INTO v_got FROM market_buy(v_who, 1::smallint);

        IF v_got.quantity <> 7 THEN
            RAISE EXCEPTION 'buying a beast part handed over % not 7', v_got.quantity;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM player_materials pm
            JOIN materials m ON m.code = pm.material_code
            WHERE pm.player_id = v_who AND m.category = 'beast' AND pm.quantity = 7
        ) THEN
            RAISE EXCEPTION 'market_buy reported a beast part but granted none';
        END IF;
        RAISE NOTICE 'bought % x7 off the cart', v_got.label;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
