-- 0084_the_crafts_read_the_three_new_words
--
-- 0083 wrote `forge_power`, `brew_potency` and `gu_potency` and gave eleven
-- rolled traits that speak them. This is the other half: a word with no
-- consumer is the thing `is_live` exists to admit, and all three shipped
-- flagged live.
--
-- One line each, and each one lands where the craft decides how much of itself
-- to hand over:
--
--   forge()     - on the piece's budget, AFTER the tier and the quality band
--                 have set it, so a Smith's Hand reaches every stat the piece
--                 has rather than one of them.
--   brew()      - on the pill's magnitude, beside the harmony retention it
--                 already multiplies through.
--   refine_gu() - on the potency an auxiliary bench is worth, which is what
--                 buys the star ceiling.
--
-- All three are additive fractions on a value that was already a product of
-- fractions, which is the arithmetic this schema has used since 0008.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- forge, from 0065_blacksmithing
-- ---------------------------------------------------------------------------
-- The Unique root's whole identity, and the only line it needed.

CREATE OR REPLACE FUNCTION forge(
    p_player_id  BIGINT,
    p_slot       TEXT,
    p_ore_code   TEXT,
    p_ore_qty    INTEGER,
    p_parts      TEXT[],
    p_part_qtys  INTEGER[]
)
RETURNS TABLE (
    succeeded    BOOLEAN,
    harmony      SMALLINT,
    potency      NUMERIC,
    equipment_id BIGINT,
    item_name    TEXT,
    item_tier    SMALLINT,
    quality      TEXT,
    slot         TEXT,
    path_code    TEXT,
    reaction     TEXT,
    exp_gained   BIGINT,
    level_after  SMALLINT,
    spent_total  BIGINT,
    handed_back  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill       SMALLINT;
    slots       SMALLINT;
    n_parts     INTEGER;
    known       INTEGER;
    ore         ores%ROWTYPE;
    ore_path    TEXT;
    refund      NUMERIC;
    relief      NUMERIC;
    total       NUMERIC := 0;
    ore_pot     NUMERIC := 0;
    part_pot    NUMERIC := 0;
    h           NUMERIC := 50;
    pair_sum    NUMERIC := 0;
    echoes      INTEGER := 0;
    distinct_n  INTEGER := 1;
    spread      INTEGER := 0;
    final_h     SMALLINT;
    grade       SMALLINT;
    tier_by_pot SMALLINT;
    base_mag    NUMERIC;
    keep_frac   NUMERIC;
    band        TEXT;
    budget      NUMERIC;
    ore_side    NUMERIC;
    sig_side    NUMERIC;
    base_side   NUMERIC;
    part_side   NUMERIC;
    react       forge_reactions%ROWTYPE;
    react_word  TEXT;
    react_eff   TEXT;
    react_mag   NUMERIC := 0;
    lead_word   TEXT;
    made_name   TEXT;
    made_id     BIGINT;
    gained      BIGINT;
    lvl         SMALLINT;
    spent       BIGINT := 0;
    back        BIGINT := 0;
BEGIN
    -- ---- the anvil ------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM equipment_slots WHERE code = p_slot) THEN
        RAISE EXCEPTION 'there is nothing worn as a %', p_slot
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO ore FROM ores WHERE material_code = p_ore_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'a forging starts with ore, and % is not ore', p_ore_code
            USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_ore_qty, 0) < 1 THEN
        RAISE EXCEPTION 'a forging needs ore in it' USING ERRCODE = 'check_violation';
    END IF;

    n_parts := COALESCE(array_length(p_parts, 1), 0);
    IF n_parts <> COALESCE(array_length(p_part_qtys, 1), 0) THEN
        RAISE EXCEPTION 'every part needs a quantity' USING ERRCODE = 'check_violation';
    END IF;
    IF n_parts < 1 THEN
        RAISE EXCEPTION 'ore alone is an ingot. A piece needs something off a beast in it'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_parts <> (SELECT count(DISTINCT x) FROM unnest(p_parts) AS x) THEN
        RAISE EXCEPTION 'name each part once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_part_qtys) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'a part with none of it in is not on the anvil'
            USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'blacksmithing');
    slots := smith_part_slots(skill);
    IF n_parts > slots THEN
        RAISE EXCEPTION 'your anvil holds % beast materials, not %', slots, n_parts
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_parts) AS u (code)
    JOIN beast_parts bp ON bp.material_code = u.code;

    IF known <> n_parts THEN
        RAISE EXCEPTION 'only beast materials go on the anvil, and one of those is not'
            USING ERRCODE = 'check_violation';
    END IF;

    IF ore.tier > smith_tier_cap(skill) THEN
        RAISE EXCEPTION 'you cannot work tier % metal yet - your anvil reaches tier %',
            ore.tier, smith_tier_cap(skill) USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.path_code INTO ore_path FROM materials m WHERE m.code = p_ore_code;

    -- ---- what is on the anvil -------------------------------------------
    -- Squared, so depth cannot be bought with volume. The ore caps the tier
    -- besides, but the curve is what makes a Tier 6 ingot feel like one.
    ore_pot := ore.tier::numeric ^ 2 * p_ore_qty;

    SELECT COALESCE(sum(material_grade(m.rarity)::numeric ^ 2 * u.quantity), 0)
    INTO part_pot
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
    JOIN materials m ON m.code = u.code;

    total := ore_pot + part_pot;

    SELECT max(et.tier) INTO tier_by_pot
    FROM equipment_tiers et WHERE et.potency_required <= total;

    IF tier_by_pot IS NULL THEN
        RAISE EXCEPTION 'there is not enough on the anvil to make anything - tier 1 wants % potency',
            (SELECT potency_required FROM equipment_tiers WHERE tier = 1)
            USING ERRCODE = 'check_violation';
    END IF;

    -- Ore is the foundation, so it is also the ceiling.
    grade := LEAST(tier_by_pot, ore.tier, smith_tier_cap(skill));

    -- ---- spend ----------------------------------------------------------
    PERFORM spend_material(p_player_id, p_ore_code, p_ore_qty::bigint);
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity);

    spent := p_ore_qty + COALESCE((SELECT sum(q) FROM unnest(p_part_qtys) AS q), 0);

    -- ---- harmony --------------------------------------------------------
    relief := LEAST(1, physique_stat(p_player_id, 'refine_conflict_relief'));

    SELECT COALESCE(sum(
        CASE WHEN pair_harmony(a.p, b.p) < 0
             THEN pair_harmony(a.p, b.p) * (1 - relief)
             ELSE pair_harmony(a.p, b.p) END
    ), 0)
    INTO pair_sum
    FROM (SELECT DISTINCT p FROM (
              SELECT ore_path AS p
              UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                       JOIN materials m ON m.code = u.code) x) a
    JOIN (SELECT DISTINCT p FROM (
              SELECT ore_path AS p
              UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                       JOIN materials m ON m.code = u.code) y) b
      ON a.p < b.p;

    SELECT count(*) INTO echoes
    FROM unnest(p_parts) AS u (code)
    JOIN materials m ON m.code = u.code
    WHERE m.path_code = ore_path;

    SELECT count(DISTINCT p) INTO distinct_n
    FROM (SELECT ore_path AS p
          UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                   JOIN materials m ON m.code = u.code) z;

    SELECT max(g) - min(g) INTO spread
    FROM (SELECT ore.tier AS g
          UNION ALL SELECT material_grade(m.rarity)
                    FROM unnest(p_parts) AS u (code)
                    JOIN materials m ON m.code = u.code) w;

    h := h
       + pair_sum
       + 9 * echoes                -- a part that echoes the metal settles it
       - 4 * (distinct_n - 1)      -- every extra Path is another seam
       - 2 * spread                -- grades that do not match sit badly
       + skill * 0.9
       + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- ruined ---------------------------------------------------------
    IF final_h < game_config_value('forge_failure_threshold') THEN
        refund := game_config_value('forge_refund');

        PERFORM grant_material(p_player_id, p_ore_code, floor(p_ore_qty * refund)::bigint)
        WHERE floor(p_ore_qty * refund) > 0;

        PERFORM grant_material(p_player_id, u.code, floor(u.quantity * refund)::bigint)
        FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
        WHERE floor(u.quantity * refund) > 0;

        back := floor(p_ore_qty * refund)
              + COALESCE((SELECT sum(floor(q * refund)) FROM unnest(p_part_qtys) AS q), 0);

        gained := GREATEST(10, round(grade * game_config_value('forge_exp_per_tier') / 2));
        lvl := grant_profession_exp(p_player_id, 'blacksmithing', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, total, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, p_slot, ore_path, NULL::text,
                            gained, lvl, spent, back;
        RETURN;
    END IF;

    -- ---- the piece ------------------------------------------------------
    SELECT eq.rarity, eq.keep INTO band, keep_frac
    FROM equipment_qualities eq WHERE eq.min_harmony <= final_h
    ORDER BY eq.min_harmony DESC LIMIT 1;

    SELECT et.base_magnitude INTO base_mag
    FROM equipment_tiers et WHERE et.tier = grade;

    -- A Smith's Hand is applied to the WHOLE budget rather than to one
    -- effect, so it reaches every stat the piece ends up with.
    budget    := base_mag * keep_frac
                 * (1 + player_stat(p_player_id, 'forge_power'));
    ore_side  := budget * game_config_value('forge_ore_share');
    sig_side  := ore_side * game_config_value('forge_signature_share');
    base_side := ore_side - sig_side;
    part_side := budget - ore_side;

    -- A conflict a smith is good enough to use.
    SELECT r.* INTO react
    FROM forge_reactions r
    JOIN unnest(p_parts) AS u (code) ON TRUE
    JOIN materials m ON m.code = u.code
    WHERE ((r.path_a = ore_path AND r.path_b = m.path_code)
        OR (r.path_b = ore_path AND r.path_a = m.path_code))
      AND r.min_level <= skill
    ORDER BY r.min_level DESC
    LIMIT 1;

    IF FOUND THEN
        react_word := react.word;
        react_eff  := react.effect_code;
        react_mag  := budget * game_config_value('forge_reaction_share');
    END IF;

    -- The part carrying the most weight is the one the name remembers.
    SELECT pk.word INTO lead_word
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    JOIN beast_parts bp ON bp.material_code = u.code
    JOIN part_kinds pk ON pk.code = bp.part
    GROUP BY pk.word
    ORDER BY sum(material_grade(m.rarity)::numeric ^ 2 * u.quantity) DESC
    LIMIT 1;

    made_name := forged_name(ore.word, COALESCE(lead_word, 'Beast'), p_slot,
                             final_h, react_word);

    INSERT INTO player_equipment
        (owner_id, name, slot, tier, quality, harmony, path_code, ore_code, reaction)
    VALUES (p_player_id, made_name, p_slot, grade, band, final_h,
            ore_path, p_ore_code, react_word)
    RETURNING player_equipment.equipment_id INTO made_id;

    -- ---- what it is worth -----------------------------------------------
    -- Three sources and a reaction, summed per effect and capped once. The cap
    -- belongs to the effect, not to whichever table granted it.
    INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
    SELECT made_id, c.effect_code,
           LEAST(ef.cap, round(sum(c.magnitude), 4))
    FROM (
        -- what the metal is known for
        SELECT ore.signature AS effect_code, sig_side AS magnitude
        UNION ALL
        -- what the slot is for
        SELECT se.effect_code, base_side * se.share
        FROM slot_effects se WHERE se.slot = p_slot
        UNION ALL
        -- what came off the beasts, each part paid its share of the weight
        SELECT pe.effect_code,
               part_side * (pp.pot / GREATEST(part_pot, 1)) * pe.share
        FROM (SELECT bp.part,
                     material_grade(m.rarity)::numeric ^ 2 * u.quantity AS pot
              FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
              JOIN materials m ON m.code = u.code
              JOIN beast_parts bp ON bp.material_code = u.code) pp
        JOIN part_effects pe ON pe.part = pp.part
        UNION ALL
        -- and the reaction, if the smith could hold it
        SELECT react_eff, react_mag WHERE react_eff IS NOT NULL
    ) c
    JOIN gu_effects ef ON ef.code = c.effect_code
    GROUP BY c.effect_code, ef.cap
    HAVING round(sum(c.magnitude), 4) > 0;

    gained := GREATEST(10, grade * game_config_value('forge_exp_per_tier'));
    lvl := grant_profession_exp(p_player_id, 'blacksmithing', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, total, made_id, made_name, grade, band,
                        p_slot, ore_path, react_word, gained, lvl, spent, 0::bigint;
END;
$$;

-- ---------------------------------------------------------------------------
-- brew, from 0059_pills_that_change_the_rate
-- ---------------------------------------------------------------------------
-- Cauldron Sense, on what the pill actually pays out.

CREATE OR REPLACE FUNCTION brew(
    p_player_id  BIGINT,
    p_codes      TEXT[],
    p_quantities INTEGER[]
)
RETURNS TABLE (
    succeeded    BOOLEAN,
    harmony      SMALLINT,
    potency      NUMERIC,
    pill_id      BIGINT,
    pill_name    TEXT,
    pill_tier    SMALLINT,
    pill_kind    TEXT,
    path_code    TEXT,
    magnitude    BIGINT,
    quantity     SMALLINT,
    exp_gained   BIGINT,
    level_after  SMALLINT,
    spent_total  BIGINT,
    handed_back  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill     SMALLINT;
    slots     SMALLINT;
    n_herbs   INTEGER;
    known     INTEGER;
    refund    NUMERIC;
    relief    NUMERIC;
    total     NUMERIC := 0;
    h         NUMERIC := 50;
    pair_sum  NUMERIC := 0;
    lead_path TEXT;
    lead_n    INTEGER;
    distinct_n INTEGER;
    spread    INTEGER;
    final_h   SMALLINT;
    grade     SMALLINT;
    floor_p   NUMERIC;
    base_mag  NUMERIC;
    keep      NUMERIC;
    kind_code TEXT;
    per_point NUMERIC;
    made_mag  BIGINT;
    batch     SMALLINT;
    made_name TEXT;
    made_id   BIGINT;
    gained    BIGINT;
    lvl       SMALLINT;
    spent     BIGINT := 0;
    back      BIGINT := 0;
BEGIN
    -- ---- the cauldron ---------------------------------------------------
    n_herbs := COALESCE(array_length(p_codes, 1), 0);
    IF n_herbs <> COALESCE(array_length(p_quantities, 1), 0) THEN
        RAISE EXCEPTION 'every herb needs a quantity' USING ERRCODE = 'check_violation';
    END IF;
    IF n_herbs < 2 THEN
        RAISE EXCEPTION 'a brew needs at least two herbs' USING ERRCODE = 'check_violation';
    END IF;
    IF n_herbs <> (SELECT count(DISTINCT x) FROM unnest(p_codes) AS x) THEN
        RAISE EXCEPTION 'name each herb once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_quantities) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'a herb with none of it in is not in the cauldron'
            USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'alchemy');
    slots := alchemy_herb_slots(skill);
    IF n_herbs > slots THEN
        RAISE EXCEPTION 'your cauldron holds % herbs, not %', slots, n_herbs
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_codes) AS u (code)
    JOIN materials m ON m.code = u.code
    WHERE m.tier IS NOT NULL;

    IF known <> n_herbs THEN
        RAISE EXCEPTION 'only herbs go in a cauldron, and one of those is not'
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- spend ----------------------------------------------------------
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_codes, p_quantities) AS u (code, quantity);

    spent := COALESCE((SELECT sum(q) FROM unnest(p_quantities) AS q), 0);

    -- ---- what is in the pot ---------------------------------------------
    SELECT COALESCE(sum(m.tier * u.quantity), 0),
           count(DISTINCT m.path_code),
           max(m.tier) - min(m.tier)
    INTO total, distinct_n, spread
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code;

    SELECT m.path_code, count(*)
    INTO lead_path, lead_n
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    GROUP BY m.path_code
    ORDER BY sum(m.tier * u.quantity) DESC, count(*) DESC
    LIMIT 1;

    -- ---- harmony --------------------------------------------------------
    relief := LEAST(1, physique_stat(p_player_id, 'refine_conflict_relief'));

    SELECT COALESCE(sum(
        CASE WHEN pair_harmony(a.p, b.p) < 0
             THEN pair_harmony(a.p, b.p) * (1 - relief)
             ELSE pair_harmony(a.p, b.p) END
    ), 0)
    INTO pair_sum
    FROM (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_codes) AS u (code) JOIN materials m ON m.code = u.code) a
    JOIN (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_codes) AS u (code) JOIN materials m ON m.code = u.code) b
      ON a.p < b.p;

    h := h
       + pair_sum
       + 8 * (lead_n - 1)          -- one Path repeated steadies the pot
       - 4 * (distinct_n - 1)      -- every extra Path is another seam
       - 2 * spread                -- grades that do not match sit badly
       + skill * 0.75
       + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- spoiled --------------------------------------------------------
    IF final_h < game_config_value('alchemy_failure_threshold') THEN
        refund := game_config_value('alchemy_refund');

        PERFORM grant_material(p_player_id, u.code, floor(u.quantity * refund)::bigint)
        FROM unnest(p_codes, p_quantities) AS u (code, quantity)
        WHERE floor(u.quantity * refund) > 0;

        back := COALESCE((SELECT sum(floor(q * refund)) FROM unnest(p_quantities) AS q), 0);

        gained := GREATEST(10, round(total * game_config_value('alchemy_exp_per_tier') / 6));
        lvl := grant_profession_exp(p_player_id, 'alchemy', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, total, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, lead_path, NULL::bigint,
                            NULL::smallint, gained, lvl, spent, back;
        RETURN;
    END IF;

    -- ---- the pill -------------------------------------------------------
    SELECT pt.tier, pt.potency_required, pt.base_magnitude
    INTO grade, floor_p, base_mag
    FROM pill_tiers pt WHERE pt.potency_required <= total
    ORDER BY pt.tier DESC LIMIT 1;

    IF grade IS NULL THEN
        RAISE EXCEPTION 'there is not enough in the pot to make anything'
            USING ERRCODE = 'check_violation';
    END IF;

    keep := CASE
        WHEN final_h >= 100 THEN 1.30
        WHEN final_h >= 90  THEN 1.17
        WHEN final_h >= 75  THEN 1.02
        WHEN final_h >= 60  THEN 0.875
        WHEN final_h >= 40  THEN 0.70
        ELSE 0.50
    END;

    SELECT ppk.kind INTO kind_code FROM path_pill_kinds ppk WHERE ppk.path_code = lead_path;

    -- Some effects will not fix in place below a grade. The pot does not fail
    -- for it - it comes out as the plainer thing that Path also makes, which
    -- is a worse pill and not a wasted afternoon.
    SELECT COALESCE(pk.fallback, pk.code) INTO kind_code
    FROM pill_kinds pk WHERE pk.code = kind_code AND pk.min_tier > grade;
    IF kind_code IS NULL THEN
        SELECT ppk.kind INTO kind_code FROM path_pill_kinds ppk
        WHERE ppk.path_code = lead_path;
    END IF;

    SELECT pk.per_point INTO per_point FROM pill_kinds pk WHERE pk.code = kind_code;

    made_mag := GREATEST(1, round(base_mag * per_point * keep
                                  * (1 + player_stat(p_player_id, 'brew_potency'))));

    -- Overshooting a grade fills the cauldron rather than wasting it.
    batch := LEAST(
        game_config_value('alchemy_max_batch'),
        1 + floor((total - floor_p)
                  / GREATEST(1, floor_p * game_config_value('alchemy_batch_divisor')))
    )::smallint;

    made_name := brewed_pill_name(lead_path, kind_code, final_h);

    INSERT INTO player_pills
        (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
    VALUES (p_player_id, made_name, grade, kind_code, lead_path, made_mag, batch, final_h)
    RETURNING player_pills.pill_id INTO made_id;

    gained := GREATEST(10, grade * game_config_value('alchemy_exp_per_tier'));
    lvl := grant_profession_exp(p_player_id, 'alchemy', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, total, made_id, made_name, grade, kind_code,
                        lead_path, made_mag, batch, gained, lvl, spent, 0::bigint;
END;
$$;

-- ---------------------------------------------------------------------------
-- refine_gu, from 0039_recipe_reachability
-- ---------------------------------------------------------------------------
-- Worm Sense, on the potency an auxiliary bench is worth.

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

    -- Worm Sense. The bench is worth more to somebody who knows what to
    -- do with it, and potency is what buys the star ceiling.
    potency := potency * (1 + player_stat(p_player_id, 'gu_potency'));

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
