-- 0116_the_broker_pays_in_stones
--
-- Somewhere to turn surplus into the currency the world actually spends.
--
-- Spirit stones are what a dwelling costs, and until now the only way to get
-- one was to find a cache while exploring - two to nine at a time. Meanwhile a
-- cultivator's bag holds five thousand units of material they will never use:
-- the wrong Path's herbs, ore below their smithing tier, the sixth Tier 1
-- sabre they forged while levelling. None of it converts into anything.
--
-- The Broker is the floor under all of it. He buys, he never sells, and he
-- pays less than a thing is worth to somebody who wants it - which is what
-- makes him a floor rather than a market. The auction house is where you go
-- when your Gu is worth something to a person; the Broker is where you go
-- when it is worth something to nobody.
--
-- WHAT HE PAYS, AND WHY THAT NUMBER. A material is worth its grade in stones:
-- one for a common, four for an epic. That is deliberately in line with what
-- an hour of exploring pays - a cache is two to nine stones - so an hour of
-- gathering and an hour of exploring come out roughly level, and neither
-- becomes the obvious way to fund a Grotto-Heaven.
--
-- Equipment is priced off `equipment_tiers.potency_required`, which is
-- already the game's own measure of what went into a piece, multiplied by the
-- grade of its quality band. Manuals are priced off `manual_tiers.bonus_budget`
-- for the same reason. Neither invents a scale; both read the one that exists,
-- so retuning the tiers retunes the till.
--
-- HE WILL NOT TAKE WHAT YOU ARE USING. Equipped gear and equipped manuals are
-- refused rather than silently unequipped, the same call `unbind_manuals`
-- made about a book you are reading.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('broker_material_rate', 1.0,
     'Spirit stones the Broker pays per point of material grade. One common is one stone.'),
    ('broker_equipment_rate', 1.0,
     'Multiplier on a piece''s tier potency when the Broker prices it.'),
    ('broker_manual_rate', 20.0,
     'Spirit stones per point of a manual tier''s bonus budget, times one hundred.');


-- ---------------------------------------------------------------------------
-- What he offers
-- ---------------------------------------------------------------------------

CREATE FUNCTION broker_price_material(p_code TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(material_grade(m.rarity)
                             * game_config_value('broker_material_rate')))::bigint
    FROM materials m WHERE m.code = p_code AND m.category <> 'currency';
$$;

COMMENT ON FUNCTION broker_price_material(TEXT) IS
    'Stones for one unit. NULL for Spirit Jade, which is money and not merchandise.';


CREATE FUNCTION broker_price_equipment(p_equipment_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(et.potency_required
                             * material_grade(pe.quality)
                             * game_config_value('broker_equipment_rate')))::bigint
    FROM player_equipment pe
    JOIN equipment_tiers et ON et.tier = pe.tier
    WHERE pe.equipment_id = p_equipment_id;
$$;

COMMENT ON FUNCTION broker_price_equipment(BIGINT) IS
    'What a forged piece fetches: the potency its tier demanded, weighted by the quality band it came out at.';


CREATE FUNCTION broker_price_manual(p_manual_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(mt.bonus_budget * 100
                             * game_config_value('broker_manual_rate')))::bigint
    FROM manuals m
    JOIN manual_tiers mt ON mt.tier = m.tier
    WHERE m.manual_id = p_manual_id;
$$;

COMMENT ON FUNCTION broker_price_manual(BIGINT) IS
    'What a book fetches, off the same bonus budget its tier is defined by. The Binder pays in pages; the Broker pays in stones.';


-- ---------------------------------------------------------------------------
-- The counter
-- ---------------------------------------------------------------------------
-- Everything a cultivator could put on it, priced, in one place - so the
-- screen, the confirmation and the sale all read the same figures.

CREATE FUNCTION broker_offer(p_player_id BIGINT)
RETURNS TABLE (
    kind      TEXT,
    ref       TEXT,
    label     TEXT,
    emoji     TEXT,
    detail    TEXT,
    quantity  BIGINT,
    unit      BIGINT,
    total     BIGINT
)
LANGUAGE sql STABLE
AS $$
    SELECT 'material', pm.material_code, material_name(pm.material_code),
           m.emoji,
           m.rarity || ' ' || m.category,
           pm.quantity,
           broker_price_material(pm.material_code),
           pm.quantity * broker_price_material(pm.material_code)
    FROM player_materials pm
    JOIN materials m ON m.code = pm.material_code
    WHERE pm.player_id = p_player_id AND pm.quantity > 0
      AND m.category <> 'currency'

    UNION ALL

    SELECT 'equipment', pe.equipment_id::text, pe.name,
           s.emoji,
           'tier ' || pe.tier || ' ' || pe.quality || ' ' || lower(s.name),
           1,
           broker_price_equipment(pe.equipment_id),
           broker_price_equipment(pe.equipment_id)
    FROM player_equipment pe
    JOIN equipment_slots s ON s.code = pe.slot
    WHERE pe.owner_id = p_player_id
      AND NOT EXISTS (SELECT 1 FROM player_equipped w
                      WHERE w.equipment_id = pe.equipment_id)

    UNION ALL

    SELECT 'manual', m.manual_id::text, m.name,
           '📕',
           'tier ' || m.tier || ' ' || m.archetype,
           1,
           broker_price_manual(m.manual_id),
           broker_price_manual(m.manual_id)
    FROM player_manuals pm
    JOIN manuals m ON m.manual_id = pm.manual_id
    WHERE pm.player_id = p_player_id
      AND NOT EXISTS (SELECT 1 FROM player_manual_slots s
                      WHERE s.player_id = pm.player_id AND s.manual_id = m.manual_id)

    ORDER BY 1, 8 DESC, 3;
$$;

COMMENT ON FUNCTION broker_offer(BIGINT) IS
    'Everything the Broker would take and what he would pay for it. Equipped gear and equipped books are already left off.';


-- ---------------------------------------------------------------------------
-- Selling
-- ---------------------------------------------------------------------------

CREATE FUNCTION sell_to_broker(
    p_player_id BIGINT,
    p_kind      TEXT,
    p_refs      TEXT[],
    p_quantities BIGINT[] DEFAULT NULL
) RETURNS TABLE (
    sold        INTEGER,
    stones_paid BIGINT,
    detail      JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    item     RECORD;
    want     BIGINT;
    price    BIGINT;
    paid     BIGINT := 0;
    count_of INTEGER := 0;
    lines    JSONB := '[]'::jsonb;
    i        INTEGER;
BEGIN
    IF p_refs IS NULL OR array_length(p_refs, 1) IS NULL THEN
        RAISE EXCEPTION 'put something on the counter first'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_kind NOT IN ('material', 'equipment', 'manual') THEN
        RAISE EXCEPTION 'the Broker does not deal in %', p_kind
            USING ERRCODE = 'check_violation';
    END IF;

    FOR i IN 1..array_length(p_refs, 1) LOOP
        want := COALESCE(p_quantities[i], 1);

        IF p_kind = 'material' THEN
            SELECT pm.material_code, pm.quantity,
                   material_name(pm.material_code) AS name
            INTO item
            FROM player_materials pm
            WHERE pm.player_id = p_player_id AND pm.material_code = p_refs[i];

            IF NOT FOUND OR item.quantity < want THEN
                RAISE EXCEPTION 'you do not have % of that', want
                    USING ERRCODE = 'check_violation';
            END IF;

            price := broker_price_material(p_refs[i]);
            IF price IS NULL THEN
                RAISE EXCEPTION 'the Broker deals in Spirit Jade, he does not buy it'
                    USING ERRCODE = 'check_violation';
            END IF;

            PERFORM spend_material(p_player_id, p_refs[i], want);
            paid := paid + price * want;
            count_of := count_of + 1;
            lines := lines || jsonb_build_object(
                'name', item.name, 'quantity', want, 'stones', price * want);

        ELSIF p_kind = 'equipment' THEN
            SELECT pe.equipment_id, pe.name INTO item
            FROM player_equipment pe
            WHERE pe.equipment_id = p_refs[i]::bigint
              AND pe.owner_id = p_player_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'that is not yours to sell'
                    USING ERRCODE = 'check_violation';
            END IF;
            IF EXISTS (SELECT 1 FROM player_equipped w
                       WHERE w.equipment_id = item.equipment_id) THEN
                RAISE EXCEPTION '% is being worn. Take it off first', item.name
                    USING ERRCODE = 'check_violation';
            END IF;

            price := broker_price_equipment(item.equipment_id);
            DELETE FROM player_equipment WHERE equipment_id = item.equipment_id;
            paid := paid + price;
            count_of := count_of + 1;
            lines := lines || jsonb_build_object(
                'name', item.name, 'quantity', 1, 'stones', price);

        ELSE
            SELECT m.manual_id, m.name INTO item
            FROM player_manuals pm
            JOIN manuals m ON m.manual_id = pm.manual_id
            WHERE pm.player_id = p_player_id AND m.manual_id = p_refs[i]::bigint;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'that is not yours to sell'
                    USING ERRCODE = 'check_violation';
            END IF;
            IF EXISTS (SELECT 1 FROM player_manual_slots s
                       WHERE s.player_id = p_player_id
                         AND s.manual_id = item.manual_id) THEN
                RAISE EXCEPTION '% is equipped. Take it off first', item.name
                    USING ERRCODE = 'check_violation';
            END IF;

            price := broker_price_manual(item.manual_id);
            DELETE FROM player_manuals
            WHERE player_id = p_player_id AND manual_id = item.manual_id;
            paid := paid + price;
            count_of := count_of + 1;
            lines := lines || jsonb_build_object(
                'name', item.name, 'quantity', 1, 'stones', price);
        END IF;
    END LOOP;

    PERFORM grant_material(p_player_id, 'spirit_stone', paid);

    RETURN QUERY SELECT count_of, paid, lines;
END;
$$;

COMMENT ON FUNCTION sell_to_broker(BIGINT, TEXT, TEXT[], BIGINT[]) IS
    'Puts things on the counter and takes stones off it. Refuses anything being worn or read, and never touches Spirit Jade.';
