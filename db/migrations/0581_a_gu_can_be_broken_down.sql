-- 0581_a_gu_can_be_broken_down
--
-- A Gu had exactly one way out of the jar that was not a trade: `nurture_gu`,
-- which eats SAME-KIND copies to add a star. That leaves the lone spare with
-- nowhere to go at all - 19 of grafv's kinds sit at exactly two copies, which
-- is one short of the three a 2-star feeding wants, so the spare is dead weight
-- forever. Across the live world:
--
--     grafv         123 spare copies, 19 kinds stuck at a lone spare
--     m_i_y_u_k_i.  115 spare copies, 16 stuck
--     clearwest      34 spare copies, 16 stuck
--
-- WHAT IT RETURNS, and why that number. Every one of the 3043 Gu types has a
-- recipe in `gu_recipe_costs` with a base material and a secondary, so a
-- breakdown has a real basis: a share of what refining it actually cost. The
-- share is `gu_breakdown_return`, 0.30.
--
-- Deliberately below `gu_refine_refund` (0.50). A FAILED refinement hands back
-- half and leaves you nothing; a breakdown hands back less because you got a
-- working Gu out of the bargain and are choosing to undo it. If breaking down
-- paid more than failing, the optimal play would be to refine, succeed, and
-- immediately smash it - which is not a sentence that should be true.
--
-- STARS ARE PAID FOR. `nurture_gu` ate copies to get there: reaching S stars
-- consumed sum(2..S) of the same kind, so the Gu in your hand embodies
-- S*(S+1)/2 copies in all - 1, 3, 6, 10, 15 at one through five stars. The
-- breakdown multiplies by that, or smashing a 5-star would quietly destroy
-- fourteen Gu worth of material and hand back one Gu's worth.
--
-- It never returns nothing: GREATEST(1, ...) on each half, because a rank-1
-- common at 30% of four rounds to one and a yield of zero reads as a bug.


INSERT INTO game_config (key, value, description) VALUES
    ('gu_breakdown_return', 0.30,
     'The share of a Gu recipe''s materials handed back when the Gu is broken down. Below gu_refine_refund (0.50) on purpose: a failed refinement leaves you nothing, while a breakdown undoes a Gu that worked.');


-- ---------------------------------------------------------------------------
-- What it would give
-- ---------------------------------------------------------------------------
-- Split out from the doing, so the screen can show the price of a decision
-- before it is taken. One definition, read by both.

CREATE FUNCTION gu_breakdown_yield(p_gu_id BIGINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, emoji TEXT, quantity BIGINT)
LANGUAGE sql STABLE AS $$
    WITH it AS (
        SELECT g.stars,
               -- The copies this Gu embodies: itself, plus every one that was
               -- fed to it on the way up. 1, 3, 6, 10, 15.
               (g.stars * (g.stars + 1) / 2)::numeric AS copies,
               c.base_material, c.base_quantity,
               c.secondary_material, c.secondary_quantity
        FROM player_gu g
        JOIN gu_recipe_costs c ON c.gu_type_id = g.gu_type_id
        WHERE g.gu_id = p_gu_id
    ),
    halves AS (
        SELECT it.base_material AS code, it.base_quantity AS qty, it.copies FROM it
        UNION ALL
        SELECT it.secondary_material, it.secondary_quantity, it.copies FROM it
    )
    SELECT h.code, material_name(h.code), m.emoji,
           GREATEST(1, floor(h.qty * h.copies
                             * game_config_value('gu_breakdown_return')))::bigint
    FROM halves h
    JOIN materials m ON m.code = h.code
    WHERE h.code IS NOT NULL
    ORDER BY 1;
$$;


-- ---------------------------------------------------------------------------
-- Breaking it
-- ---------------------------------------------------------------------------

CREATE FUNCTION break_down_gu(p_player_id BIGINT, p_gu_id BIGINT)
RETURNS TABLE (gu_name TEXT, stars SMALLINT, got JSONB)
LANGUAGE plpgsql AS $$
DECLARE
    it   RECORD;
    v_got JSONB := '{}'::jsonb;
    one  RECORD;
BEGIN
    SELECT g.gu_id, g.stars AS st, t.name
    INTO it
    FROM player_gu g
    JOIN gu_types t ON t.gu_type_id = g.gu_type_id
    WHERE g.gu_id = p_gu_id AND g.owner_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your Gu'
            USING ERRCODE = 'check_violation';
    END IF;

    -- WORN COMES OFF FIRST. Deleting an equipped Gu would cascade out of
    -- `player_gu_equipped` and silently shrink a build mid-fight, and the
    -- aperture is the one number this game is balanced on.
    IF EXISTS (SELECT 1 FROM player_gu_equipped e WHERE e.gu_id = p_gu_id) THEN
        RAISE EXCEPTION
            '% is in your aperture - take it out before breaking it down',
            it.name USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM auction_listings a
               WHERE a.gu_id = p_gu_id AND a.status = 'open') THEN
        RAISE EXCEPTION '% is up for sale - cancel the listing first', it.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- Any trade still in play, whatever the word for it is. Guarding on what a
    -- FINISHED trade looks like means a new status cannot quietly open a hole.
    IF EXISTS (SELECT 1 FROM trade_offer_gu og
               JOIN trades tr ON tr.trade_id = og.trade_id
               WHERE og.gu_id = p_gu_id
                 AND tr.status NOT IN ('complete', 'cancelled')) THEN
        RAISE EXCEPTION '% is on the table in a trade', it.name
            USING ERRCODE = 'check_violation';
    END IF;

    FOR one IN SELECT * FROM gu_breakdown_yield(p_gu_id) LOOP
        PERFORM grant_material(p_player_id, one.material_code, one.quantity);
        v_got := v_got || jsonb_build_object(one.material_name, one.quantity);
    END LOOP;

    DELETE FROM player_gu WHERE gu_id = p_gu_id;

    RETURN QUERY SELECT it.name, it.st, v_got;
END;
$$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_type  BIGINT;
    v_gu    BIGINT;
    v_gu2   BIGINT;
    v_rows  INTEGER;
    v_one   BIGINT;
    v_five  BIGINT;
    v_name  TEXT;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1103, 'breakdown-probe') RETURNING player_id INTO v_who;

        -- A kind with BOTH halves on its recipe, so the two-row case is tested.
        SELECT c.gu_type_id INTO v_type FROM gu_recipe_costs c
        WHERE c.secondary_material IS NOT NULL LIMIT 1;

        -- 1. IT HANDS SOMETHING BACK, and the recipe's own materials.
        v_gu := grant_gu(v_who, v_type);
        SELECT count(*) INTO v_rows FROM gu_breakdown_yield(v_gu);
        IF v_rows <> 2 THEN
            RAISE EXCEPTION
                'a recipe with two halves yielded % rows on breakdown', v_rows;
        END IF;

        IF EXISTS (SELECT 1 FROM gu_breakdown_yield(v_gu) y WHERE y.quantity < 1) THEN
            RAISE EXCEPTION 'a breakdown offered a yield below one';
        END IF;

        IF EXISTS (
            SELECT 1 FROM gu_breakdown_yield(v_gu) y
            WHERE y.material_code NOT IN (
                SELECT c.base_material FROM gu_recipe_costs c
                WHERE c.gu_type_id = v_type
                UNION ALL
                SELECT c.secondary_material FROM gu_recipe_costs c
                WHERE c.gu_type_id = v_type)
        ) THEN
            RAISE EXCEPTION 'a breakdown offered a material the recipe never used';
        END IF;

        -- 2. STARS PAY. Five stars embodies fifteen copies against one, so the
        --    yield has to be fifteen times as large - not equal, which is what
        --    forgetting the multiple would look like.
        SELECT y.quantity INTO v_one FROM gu_breakdown_yield(v_gu) y
        ORDER BY y.material_code LIMIT 1;

        v_gu2 := grant_gu(v_who, v_type);
        UPDATE player_gu SET stars = 5 WHERE gu_id = v_gu2;
        SELECT y.quantity INTO v_five FROM gu_breakdown_yield(v_gu2) y
        ORDER BY y.material_code LIMIT 1;

        IF v_five <= v_one THEN
            RAISE EXCEPTION
                'a 5-star broke down to % against a 1-star''s % - stars paid nothing',
                v_five, v_one;
        END IF;
        RAISE NOTICE
            'one star returns %, five stars returns % of the same material',
            v_one, v_five;

        -- 3. IT IS ACTUALLY GRANTED AND THE GU IS ACTUALLY GONE.
        SELECT b.gu_name INTO v_name FROM break_down_gu(v_who, v_gu) b;
        IF EXISTS (SELECT 1 FROM player_gu WHERE gu_id = v_gu) THEN
            RAISE EXCEPTION '% survived being broken down', v_name;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM player_materials pm
                       WHERE pm.player_id = v_who AND pm.quantity > 0) THEN
            RAISE EXCEPTION 'breaking down % granted nothing', v_name;
        END IF;

        -- 4. A WORN GU REFUSES. This is the one that protects a live build.
        INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (v_gu2, v_who);
        BEGIN
            PERFORM break_down_gu(v_who, v_gu2);
            RAISE EXCEPTION 'an equipped Gu was broken down out of the aperture';
        EXCEPTION WHEN check_violation THEN
            NULL;   -- which is the refusal we wanted
        END;

        -- 5. AND SOMEBODY ELSE'S REFUSES.
        BEGIN
            PERFORM break_down_gu(v_who + 999999, v_gu2);
            RAISE EXCEPTION 'a stranger broke down somebody else''s Gu';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
