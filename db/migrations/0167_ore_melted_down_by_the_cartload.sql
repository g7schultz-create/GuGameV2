-- 0167_ore_melted_down_by_the_cartload
--
-- m_i_y_u_k_i. holds 28,227 ore across 22 kinds and 199 beast materials. A
-- forging takes ore AND at least one beast material, so the parts are the
-- limiting reagent by two orders of magnitude: she could forge 199 times, on
-- 199 separate screens, and still be sitting on twenty-eight thousand rocks.
--
-- Nearly eleven thousand of them are tier 1 and will never be worth forging
-- into anything - the ore is the ceiling on the piece, so a tier 1 ingot makes
-- a tier 1 item forever. That is a material the game hands out by the hundred
-- and gives no way to spend.
--
-- Smelting is the disposal route: ore melted down for the practice of melting
-- it, no beast material, no piece at the end. Deliberately much worse per ore
-- than forging - an efficient tier 1 forging is 15 EXP a potency and this is
-- 0.25 - because it competes with nothing. It is what you do with the surplus
-- you were never going to forge.
--
-- Gated on `smith_tier_cap` exactly as forging is, which makes the low tiers
-- the ones you can actually melt early and turns the surplus into the ladder
-- out of it: melt the tier 1 pile, raise the cap, reach the tier 5 ore that
-- was sitting there unusable.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('smelt_exp_per_potency', 0.25,
     'Blacksmithing EXP per point of ore potency (tier squared x quantity) '
     'melted down. An efficient tier 1 forging is 15 EXP a potency and also '
     'produces a piece, so smelting is never the better use of ore you could '
     'forge - only of the ore you could not.');


CREATE FUNCTION smelt_many(
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

    -- Every refusal is found before anything is spent, and each one names the
    -- ore it is about. A bulk action that half-works and reports a number is
    -- worse than one that does nothing and says which rock was the problem.
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


-- A function that parses is not a function that works. Melted on a live
-- smith inside a subtransaction that is thrown away, so the ore, the EXP and
-- the level all come back.

DO $$
DECLARE
    who    BIGINT;
    rock   TEXT;
    got    RECORD;
    before BIGINT;
    after  BIGINT;
    banked BIGINT;
BEGIN
    SELECT pm.player_id, pm.material_code, pm.quantity INTO who, rock, before
    FROM player_materials pm
    JOIN ores o ON o.material_code = pm.material_code
    WHERE pm.quantity >= 10
      AND o.tier <= smith_tier_cap(profession_level(pm.player_id, 'blacksmithing'))
    ORDER BY pm.quantity DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no smith with ore to probe; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT * INTO got FROM smelt_many(who, ARRAY[rock], ARRAY[10::bigint]);

        IF got.melted <> 10 THEN
            RAISE EXCEPTION 'ten went in and % came out of the count', got.melted;
        END IF;
        IF got.exp_gained < 1 THEN
            RAISE EXCEPTION 'a cartload of ore was worth no practice at all';
        END IF;
        IF got.level_after < got.level_before THEN
            RAISE EXCEPTION 'smelting cost the smith a level';
        END IF;

        -- The ore has to actually leave the satchel. A furnace that pays out
        -- without consuming is the only bug here that would matter.
        SELECT pm.quantity INTO after FROM player_materials pm
        WHERE pm.player_id = who AND pm.material_code = rock;
        IF COALESCE(after, 0) <> before - 10 THEN
            RAISE EXCEPTION 'held % before and % after melting ten', before, after;
        END IF;

        SELECT pp.exp INTO banked FROM player_professions pp
        WHERE pp.player_id = who AND pp.profession = 'blacksmithing';
        IF banked IS NULL OR banked < got.exp_gained THEN
            RAISE EXCEPTION 'the EXP was reported but not banked';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
