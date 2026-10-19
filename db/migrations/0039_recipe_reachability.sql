-- 0039_recipe_reachability
--
-- Two things 0038 got wrong, found by asking the data rather than by reading
-- the recipes back.
--
-- SEVEN RECIPES ASKED FOR SOMETHING NOBODY CAN GET. Joining the recipes to
-- `creature_drops` and dividing gives the kills each secondary costs, and the
-- answers ran from 12 to 440 - and, for the Battle Bone Wheel, to a material
-- only a rank 9 leviathan carries. A price is a design decision; a price
-- nobody at that rank can pay is a recipe that is not in the game. The worst
-- of them are moved onto materials the same hunt already produces.
--
-- ONE RECIPE FOUGHT ITSELF. All-Out Effort is a Strength Gu that asked for a
-- Blood base and a Soul secondary, which the matchup chart scores at -11 and
-- -22: a floor harmony of 17, below the threshold at which the Gu forms at
-- all. Every attempt would have failed and eaten half of 180 blood flowers.
-- The check that catches it is now a test, because "no recipe is impossible"
-- is a rule about the whole table and not about the eight rows edited here.
--
-- THE TEMP TABLE IS GONE. `refine_gu` built `_aux ON COMMIT DROP`, which means
-- a second refinement inside one transaction dies on "relation _aux already
-- exists". Every bot command is its own transaction so nothing in play hits
-- it, but a test that refines twice does, and so would any future function
-- that refines on a player's behalf. The same work is set-based now: two
-- aggregates over `unnest`, no scratch table, no scoping surprise.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Recipes a player can actually shop for
-- ---------------------------------------------------------------------------

UPDATE gu_recipes r
SET base_material      = COALESCE(v.new_base, r.base_material),
    secondary_material = COALESCE(v.new_secondary, r.secondary_material)
FROM (VALUES
    -- Strength Gu, Blood base, Soul secondary. Refined against itself.
    ('all_out_effort_gu',             'strength_stone', 'tiger_fang'),
    -- Freed by the line above; iron bone is the commoner drop anyway.
    ('brute_force_longhorn_beetle_gu', NULL,            'iron_bone'),
    -- 270 bones off a rank 9 leviathan, for a Gu gated at Refiner level 15.
    ('battle_bone_wheel',              NULL,            'bone_fragment'),
    -- Poison in a Wood Gu: -22, and a ceiling of one star for ever.
    ('jade_skin_gu',                   NULL,            'cicada_shell'),
    -- A 10% drop off one species, six of them, for a rank 1 Gu.
    ('scale_armor_gu',                 NULL,            'fish_scale_shard'),
    -- Rank 2 rogues only, at 20%, for a Gu a beginner is meant to make.
    ('hope_gu',                        NULL,            'cicada_essence'),
    -- 60 kills for a rank 1 uncommon.
    ('ghost_fire_gu',                  NULL,            'soul_crystal')
) AS v (gu_code, new_base, new_secondary)
JOIN gu_types t ON t.code = v.gu_code
WHERE r.gu_type_id = t.gu_type_id;


-- ---------------------------------------------------------------------------
-- refine_gu, without the scratch table
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION refine_gu(
    p_player_id      BIGINT,
    p_gu_type_id     BIGINT,
    p_aux_codes      TEXT[]    DEFAULT '{}',
    p_aux_quantities INTEGER[] DEFAULT '{}'
)
RETURNS TABLE (
    succeeded     BOOLEAN,
    harmony_score SMALLINT,
    potency_score NUMERIC,
    stars_made    SMALLINT,
    new_gu_id     BIGINT,
    made_name     TEXT,
    exp_gained    BIGINT,
    level_after   SMALLINT,
    spent_total   BIGINT,
    handed_back   BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    recipe   gu_recipe_costs%ROWTYPE;
    skill    SMALLINT;
    slots    SMALLINT;
    n_aux    INTEGER;
    known    INTEGER;
    refund   NUMERIC;
    aux_h    NUMERIC := 0;
    pair_h   NUMERIC := 0;
    h        NUMERIC := 50;
    potency  NUMERIC := 0;
    spent    BIGINT  := 0;
    back     BIGINT  := 0;
    final_h  SMALLINT;
    stars    SMALLINT;
    gained   BIGINT;
    lvl      SMALLINT;
    made     BIGINT;
BEGIN
    -- ---- the recipe -----------------------------------------------------
    SELECT * INTO recipe FROM gu_recipe_costs c WHERE c.gu_type_id = p_gu_type_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that Gu cannot be refined' USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'gu_refining');
    IF skill < recipe.required_level THEN
        RAISE EXCEPTION 'a % takes Gu Refiner level %, and you are level %',
            recipe.gu_name, recipe.required_level, skill
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- the auxiliaries ------------------------------------------------
    n_aux := COALESCE(array_length(p_aux_codes, 1), 0);
    IF n_aux <> COALESCE(array_length(p_aux_quantities, 1), 0) THEN
        RAISE EXCEPTION 'every auxiliary material needs a quantity'
            USING ERRCODE = 'check_violation';
    END IF;

    slots := gu_refine_aux_slots(skill);
    IF n_aux > slots THEN
        RAISE EXCEPTION 'your bench holds % auxiliary materials, not %', slots, n_aux
            USING ERRCODE = 'check_violation';
    END IF;

    IF n_aux <> (SELECT count(DISTINCT x) FROM unnest(p_aux_codes) AS x) THEN
        RAISE EXCEPTION 'name each auxiliary material once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_aux_codes && ARRAY[recipe.base_material, recipe.secondary_material] THEN
        RAISE EXCEPTION 'the base and the secondary are already in the recipe'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_aux_codes) AS u (code)
    JOIN materials m ON m.code = u.code;

    IF known <> n_aux THEN
        RAISE EXCEPTION 'one of those auxiliary materials does not exist'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(p_aux_quantities) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'an auxiliary material with none of it in is not on the bench'
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- spend ----------------------------------------------------------
    -- A shortfall raises, which unwinds the whole call: nothing is ever half
    -- spent, so the order these come out in decides only which message the
    -- player reads first.
    PERFORM spend_material(p_player_id, recipe.base_material, recipe.base_quantity);
    PERFORM spend_material(p_player_id, recipe.secondary_material, recipe.secondary_quantity);
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_aux_codes, p_aux_quantities) AS u (code, quantity);

    spent := recipe.base_quantity + recipe.secondary_quantity
             + COALESCE((SELECT sum(q) FROM unnest(p_aux_quantities) AS q), 0);

    -- ---- harmony and potency --------------------------------------------
    -- A measure is `gu_refine_aux_unit` of something, and the third measure of
    -- the same material is the last one that counts: past that the only way
    -- on is a different material, which is what makes a bench a composition
    -- rather than a pile.
    SELECT COALESCE(sum(material_affinity(u.code, recipe.path_code) * mm.measure), 0),
           COALESCE(sum(ra.sort_order / 10.0 * mm.measure), 0)
    INTO aux_h, potency
    FROM unnest(p_aux_codes, p_aux_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    JOIN rarities ra ON ra.code = m.rarity
    CROSS JOIN LATERAL (
        SELECT LEAST(game_config_value('gu_refine_aux_measures'),
                     u.quantity::numeric / game_config_value('gu_refine_aux_unit'))
    ) AS mm (measure);

    -- Auxiliaries argue with each other as well as with the Gu. Halved,
    -- because a bench of eight would otherwise be decided entirely by the
    -- twenty-eight pairs among them.
    SELECT COALESCE(sum(pair_harmony(a.p, b.p)), 0) * 0.5
    INTO pair_h
    FROM (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_aux_codes) AS u (code)
          JOIN materials m ON m.code = u.code
          WHERE m.path_code IS NOT NULL) a
    JOIN (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_aux_codes) AS u (code)
          JOIN materials m ON m.code = u.code
          WHERE m.path_code IS NOT NULL) b ON a.p < b.p;

    h := h
       + material_affinity(recipe.base_material, recipe.path_code)
       + material_affinity(recipe.secondary_material, recipe.path_code)
       + skill * 0.75
       + aux_h
       + pair_h
       + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- outcome --------------------------------------------------------
    IF final_h < game_config_value('gu_refine_failure_threshold') THEN
        refund := game_config_value('gu_refine_refund');

        back := floor(recipe.base_quantity * refund)
                + floor(recipe.secondary_quantity * refund)
                + COALESCE((SELECT sum(floor(q * refund))
                            FROM unnest(p_aux_quantities) AS q), 0);

        IF floor(recipe.base_quantity * refund) > 0 THEN
            PERFORM grant_material(p_player_id, recipe.base_material,
                                   floor(recipe.base_quantity * refund)::bigint);
        END IF;
        IF floor(recipe.secondary_quantity * refund) > 0 THEN
            PERFORM grant_material(p_player_id, recipe.secondary_material,
                                   floor(recipe.secondary_quantity * refund)::bigint);
        END IF;
        PERFORM grant_material(p_player_id, u.code, floor(u.quantity * refund)::bigint)
        FROM unnest(p_aux_codes, p_aux_quantities) AS u (code, quantity)
        WHERE floor(u.quantity * refund) > 0;

        gained := GREATEST(10, recipe.exp_reward / 3);
        lvl := grant_profession_exp(p_player_id, 'gu_refining', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, round(potency, 2), NULL::smallint,
                            NULL::bigint, NULL::text, gained, lvl, spent, back;
        RETURN;
    END IF;

    SELECT COALESCE(max(g.stars), 1) INTO stars
    FROM gu_refine_grades g
    WHERE g.min_potency <= potency AND g.min_harmony <= final_h;

    -- Refined rather than found, so `found_in` stays NULL: nowhere is where
    -- this one came from.
    INSERT INTO player_gu (owner_id, gu_type_id, stars, harmony)
    VALUES (p_player_id, p_gu_type_id, stars, final_h)
    RETURNING gu_id INTO made;

    gained := recipe.exp_reward;
    lvl := grant_profession_exp(p_player_id, 'gu_refining', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, round(potency, 2), stars,
                        made, recipe.gu_name, gained, lvl, spent, 0::bigint;
END;
$$;
