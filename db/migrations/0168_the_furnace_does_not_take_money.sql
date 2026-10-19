-- 0168_the_furnace_does_not_take_money
--
-- `spirit_stone` is a row in `ores`: tier 1, signature cultivation_rate. That
-- is deliberate for the anvil - a spirit stone is a mineral and forging with
-- it gives a piece that helps you cultivate - and it has been true since the
-- forge was written.
--
-- 0167 made it dangerous. The furnace melts by the tier and by the cartload,
-- and "Melt all - 21,248 ore" would have quietly included clearwest's 6,205
-- Spirit Stones. A single press would have incinerated the money, at a fifth
-- of an EXP a stone, with no piece and no way back. The forge never had that
-- shape: it takes one ore at a time and asks how much.
--
-- Spirit Stone is not marked as currency anywhere. `materials.category` says
-- 'gathering' for it, the same as Iron Ore - only `spirit_jade` is 'currency'
-- - and 22 migrations name the string directly. So the marker is written
-- down here rather than a 23rd place guessing, and the furnace reads it.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE currency_materials (
    material_code TEXT PRIMARY KEY REFERENCES materials (code) ON DELETE CASCADE,
    note          TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE currency_materials IS
    'Materials that are money. Anything that consumes materials in bulk has '
    'to know which of them a player would never mean to spend that way.';

INSERT INTO currency_materials (material_code, note) VALUES
    ('spirit_stone', 'Buys techniques, paid by beasts and bosses. Also tier 1 ore.'),
    ('spirit_jade',  'Wagers, the auction, material protection.');


CREATE OR REPLACE FUNCTION smelt_many(
    p_player_id  BIGINT,
    p_codes      TEXT[],
    p_quantities BIGINT[]
)
RETURNS TABLE (
    kinds           INTEGER,
    melted          BIGINT,
    potency         NUMERIC,
    exp_gained      BIGINT,
    level_before    SMALLINT,
    level_after     SMALLINT,
    tier_cap_before SMALLINT,
    tier_cap_after  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    n        INTEGER;
    was      SMALLINT;
    now_lvl  SMALLINT;
    total    NUMERIC := 0;
    burned   BIGINT := 0;
    earned   BIGINT;
    one      RECORD;
    offender TEXT;
BEGIN
    n := COALESCE(array_length(p_codes, 1), 0);

    IF n = 0 THEN
        RAISE EXCEPTION 'nothing was put in the furnace'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n <> COALESCE(array_length(p_quantities, 1), 0) THEN
        RAISE EXCEPTION 'every ore needs a quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n <> (SELECT count(DISTINCT x) FROM unnest(p_codes) AS x) THEN
        RAISE EXCEPTION 'name each ore once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;

    was := profession_level(p_player_id, 'blacksmithing');

    -- Money first, because it is the refusal that matters most and the only
    -- one where being told afterwards would be useless.
    SELECT m.name INTO offender
    FROM unnest(p_codes) AS u (code)
    JOIN currency_materials cm ON cm.material_code = u.code
    JOIN materials m ON m.code = u.code
    LIMIT 1;
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION '% is money, whatever else it is', offender
            USING ERRCODE = 'check_violation';
    END IF;

    -- Every other refusal is also found before anything is spent, and each
    -- one names the ore it is about. A bulk action that half-works and
    -- reports a number is worse than one that does nothing and says which
    -- rock was the problem.
    SELECT u.code INTO offender
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    WHERE NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = u.code)
    LIMIT 1;
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION 'a furnace takes ore, and % is not ore', offender
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT u.code INTO offender
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    WHERE COALESCE(u.quantity, 0) < 1
    LIMIT 1;
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION 'none of % is not a quantity', offender
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.name || ' is tier ' || o.tier INTO offender
    FROM unnest(p_codes) AS u (code)
    JOIN ores o ON o.material_code = u.code
    JOIN materials m ON m.code = u.code
    WHERE o.tier > smith_tier_cap(was)
    ORDER BY o.tier DESC
    LIMIT 1;
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION
            'your furnace reaches tier % and % - melt what you can work first',
            smith_tier_cap(was), offender
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.name INTO offender
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    WHERE COALESCE((SELECT pm.quantity FROM player_materials pm
                    WHERE pm.player_id = p_player_id
                      AND pm.material_code = u.code), 0) < u.quantity
    LIMIT 1;
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION 'you do not hold that much %', offender
            USING ERRCODE = 'check_violation';
    END IF;

    -- Squared, the same curve the anvil reads, so a tier 6 rock is worth
    -- thirtysix tier 1 ones here exactly as it is there.
    FOR one IN
        SELECT u.code, u.quantity, o.tier,
               o.tier::numeric ^ 2 * u.quantity AS potency
        FROM unnest(p_codes, p_quantities) AS u (code, quantity)
        JOIN ores o ON o.material_code = u.code
    LOOP
        PERFORM spend_material(p_player_id, one.code, one.quantity);
        total  := total + one.potency;
        burned := burned + one.quantity;
    END LOOP;

    -- Rounded once at the end rather than per ore: rounding each kind would
    -- pay nothing at all for a single tier 1 rock and quietly lose the
    -- remainder on every other line.
    earned := GREATEST(1, round(total * game_config_value('smelt_exp_per_potency')));
    now_lvl := grant_profession_exp(p_player_id, 'blacksmithing', earned, TRUE);

    RETURN QUERY SELECT n, burned, total, earned, was, now_lvl,
                        smith_tier_cap(was), smith_tier_cap(now_lvl);
END;
$$;


-- Asked of the live cultivator holding the most of it, inside a
-- subtransaction that is thrown away either way. A refusal that only exists
-- in a comment is not a refusal.

DO $$
DECLARE
    who    BIGINT;
    before BIGINT;
BEGIN
    SELECT pm.player_id, pm.quantity INTO who, before
    FROM player_materials pm
    WHERE pm.material_code = 'spirit_stone'
    ORDER BY pm.quantity DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds a Spirit Stone to probe with';
        RETURN;
    END IF;

    BEGIN
        PERFORM * FROM smelt_many(who, ARRAY['spirit_stone'], ARRAY[1::bigint]);
        RAISE EXCEPTION 'the furnace took money';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%is money%' THEN
                RAISE EXCEPTION 'refused for the wrong reason: %', SQLERRM;
            END IF;
    END;

    IF (SELECT pm.quantity FROM player_materials pm
        WHERE pm.player_id = who AND pm.material_code = 'spirit_stone') <> before THEN
        RAISE EXCEPTION 'the probe spent a Spirit Stone';
    END IF;
END;
$$;
