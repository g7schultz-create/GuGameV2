-- 0118_the_broker_does_not_buy_his_own_money
--
-- `broker_offer` excludes the `currency` category, which is Spirit Jade and
-- nothing else. Spirit stones are filed under `gathering` - they are dug out
-- of the ground like everything else there - so the counter offered to buy
-- three spirit stones for three spirit stones.
--
-- Harmless arithmetic and a nonsense sentence: a merchant who trades a coin
-- for the same coin is not a merchant. The rate is 1:1 so nothing could have
-- been farmed through it, but "Spirit Stone x3 - 3 stones" on the counter is
-- the sort of line that makes a player distrust every other line on it.
--
-- Excluded by code rather than by category, because the category is right:
-- a spirit stone IS a gathering material. What it is not is merchandise, and
-- only the Broker needs to know that.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION broker_price_material(p_code TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(material_grade(m.rarity)
                             * game_config_value('broker_material_rate')))::bigint
    FROM materials m
    WHERE m.code = p_code
      AND m.category <> 'currency'
      -- The coin he pays in. Buying it back would be a merchant trading a
      -- stone for a stone.
      AND m.code <> 'spirit_stone';
$$;


CREATE OR REPLACE FUNCTION broker_offer(p_player_id BIGINT)
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
      AND m.code <> 'spirit_stone'

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
    'Everything the Broker would take and what he would pay. Equipped gear, equipped books, Spirit Jade and his own spirit stones are all left off.';
