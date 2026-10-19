-- 0087_jade_protects_what_it_can
--
-- The sink. Four crafts destroy things on failure, and now one of them can be
-- insured.
--
-- WHY THIS SINK AND NOT A SHOP. The design document's guiding rule is that
-- jade should "preserve opportunities, facilitate exchange, reduce risk, and
-- access services - not replace cultivation, gathering, crafting, or combat."
-- Protection is the purest form of that: the player still had to mine the ore,
-- level the profession and take the attempt. Jade buys back exactly one thing
-- that would otherwise have been lost, and no power that was not already
-- earned.
--
-- IT IS PAID UP FRONT, WHICH IS THE POINT. Charging only on failure would make
-- protection free whenever it was not needed, and a free option is not a
-- decision. Paid in advance it is insurance, and the question - is this
-- attempt risky enough to insure - is one the screens can already answer:
-- /refine forecasts its harmony range before committing, and /forge and
-- /alchemy both show what is on the bench.
--
-- ONE PARAMETER, DEFAULTED, so every existing caller keeps working unchanged.
-- Adding a defaulted parameter creates a DIFFERENT function rather than
-- replacing one, so each of these is a DROP and a CREATE - and the old
-- three-argument form must go, or a call with the old arity becomes ambiguous.
--
-- WHAT PROTECTION MEANS IN EACH CRAFT, since each destroys differently:
--
--   refine()    - the protected page is excluded from the doomed set.
--   brew()      - the protected herb comes back whole instead of half.
--   forge()     - the same, for the ore or the beast material.
--   refine_gu() - the same, for the base, the secondary or an auxiliary.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What protection costs
-- ---------------------------------------------------------------------------
-- By grade, because a Tier 7 herb and a Tier 7 ore and a rare beast part are
-- the same size of loss. The document's own ladder: 5 at Tier 5, 10 at 6,
-- 20 at 7.

CREATE TABLE jade_protection_costs (
    grade SMALLINT PRIMARY KEY CHECK (grade BETWEEN 1 AND 10),
    cost  BIGINT   NOT NULL CHECK (cost > 0)
);

INSERT INTO jade_protection_costs (grade, cost) VALUES
    (1, 1), (2, 1), (3, 2), (4, 3), (5, 5), (6, 10), (7, 20),
    (8, 35), (9, 55), (10, 80);

COMMENT ON TABLE jade_protection_costs IS
    'What one attempt of insurance costs, by the grade of the thing insured. Manual pages reach 10; everything else stops at 7.';

CREATE FUNCTION jade_protection_cost(p_grade SMALLINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT c.cost FROM jade_protection_costs c
    WHERE c.grade <= GREATEST(1, p_grade)
    ORDER BY c.grade DESC LIMIT 1;
$$;

-- What insuring a named MATERIAL costs: ore and beast parts by rarity, herbs
-- by their alchemical tier, because that is the grade each craft reads.
CREATE FUNCTION jade_material_protection_cost(p_code TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT jade_protection_cost(GREATEST(
        COALESCE(m.tier, 0),
        COALESCE((SELECT o.tier FROM ores o WHERE o.material_code = m.code), 0),
        material_grade(m.rarity)
    )::smallint)
    FROM materials m WHERE m.code = p_code;
$$;

COMMENT ON FUNCTION jade_material_protection_cost(TEXT) IS
    'The dearest reading of what a material is worth - its herb tier, its ore tier or its rarity - because insuring the same thing should not be cheaper through one craft than another.';


-- ---------------------------------------------------------------------------
-- refine, from 0079_the_retention_ladder_is_a_table
-- ---------------------------------------------------------------------------
-- The protected page is simply not in the set the failure draws from.

DROP FUNCTION refine(BIGINT, BIGINT[]);

CREATE FUNCTION refine(
    p_player_id BIGINT,
    p_page_ids  BIGINT[],
    p_protect   BIGINT DEFAULT NULL
)
RETURNS TABLE (
    succeeded   BOOLEAN,
    harmony     SMALLINT,
    manual_id   BIGINT,
    manual_name TEXT,
    tier        SMALLINT,
    archetype   TEXT,
    retained    NUMERIC,
    exp_gained  BIGINT,
    level_after SMALLINT,
    destroyed   INTEGER,
    quality     TEXT,
    draws       INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill      SMALLINT;
    cap        SMALLINT;
    n          INTEGER;
    look       RECORD;
    final_h    SMALLINT;
    keep       NUMERIC;
    band       TEXT;
    lift       NUMERIC;
    n_draws    INTEGER;
    budget     NUMERIC;
    new_manual BIGINT;
    new_name   TEXT;
    gained     BIGINT;
    lvl        SMALLINT;
    killed     INTEGER := 0;
    guard_cost BIGINT := 0;
BEGIN
    -- ---- validate -------------------------------------------------------
    SELECT COALESCE(pr.level, 1) INTO skill
    FROM (SELECT 1) _ LEFT JOIN player_refinement pr ON pr.player_id = p_player_id;

    cap := refinement_max_pages(skill);
    n   := COALESCE(array_length(p_page_ids, 1), 0);

    IF n < 2 THEN
        RAISE EXCEPTION 'a refinement needs at least two pages'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n > cap THEN
        RAISE EXCEPTION 'your Refinement skill allows % pages at once, not %', cap, n
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_page_ids) AS want(id)
        WHERE NOT EXISTS (
            SELECT 1 FROM manual_pages mp
            WHERE mp.page_id = want.id
              AND mp.owner_id = p_player_id
              AND mp.consumed_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'those are not all your unused pages'
            USING ERRCODE = 'check_violation';
    END IF;


    -- Insurance, paid before the attempt. `spend_jade` refuses rather than
    -- going negative, so an unaffordable protection stops the craft here
    -- rather than half way through it.
    IF p_protect IS NOT NULL THEN
        IF NOT (p_protect = ANY (p_page_ids)) THEN
            RAISE EXCEPTION 'you can only protect a page that is in the refinement'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, jade_protection_cost(
            (SELECT mp.tier FROM manual_pages mp WHERE mp.page_id = p_protect)), 'protect_page');
    END IF;

    -- ---- what the pages are worth ---------------------------------------
    SELECT * INTO look FROM refine_forecast(p_player_id, p_page_ids);
    IF look IS NULL THEN
        RAISE EXCEPTION 'those pages could not be read'
            USING ERRCODE = 'check_violation';
    END IF;

    final_h := GREATEST(0, LEAST(140, round(look.base_harmony + (random() * 8 - 4))))::smallint;

    gained := GREATEST(10, round(look.total_power * 0.4 + final_h * 0.6));

    -- ---- failure ---------------------------------------------------------
    IF final_h < game_config_value('refinement_failure_threshold') THEN
        WITH doomed AS (
            SELECT mp.page_id FROM manual_pages mp
            WHERE mp.page_id = ANY (p_page_ids)
              AND mp.page_id IS DISTINCT FROM p_protect
            ORDER BY random() LIMIT GREATEST(1, n / 3)
        )
        DELETE FROM manual_pages WHERE page_id IN (SELECT page_id FROM doomed);
        GET DIAGNOSTICS killed = ROW_COUNT;

        lvl := grant_refinement_exp(p_player_id, gained / 3, FALSE);
        RETURN QUERY SELECT FALSE, final_h, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, 0::numeric,
                            gained / 3, lvl, killed, NULL::text, 0;
        RETURN;
    END IF;

    keep := refinement_keep(final_h);

    -- ---- the last roll ---------------------------------------------------
    n_draws := manual_quality_draws(final_h);
    band    := roll_manual_quality(final_h);
    SELECT mq.budget_multiplier INTO lift
    FROM manual_qualities mq WHERE mq.rarity = band;

    SELECT mt.bonus_budget INTO budget
    FROM manual_tiers mt WHERE mt.tier = look.forecast_tier;
    budget := budget * keep * lift;

    -- ---- the manual ------------------------------------------------------
    new_name := refined_manual_name(look.dominant, look.archetype, final_h,
                                    look.forecast_tier);

    INSERT INTO manuals (name, tier, required_rank, archetype,
                         harmony, quality, created_by, refined_at, description)
    VALUES (new_name, look.forecast_tier,
            GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2)), look.archetype,
            final_h, band, p_player_id, now(),
            'Refined from ' || n || ' pages.')
    RETURNING manuals.manual_id INTO new_manual;

    -- Each page type pays into the column page_types says it feeds, in
    -- proportion to the power it brought.
    PERFORM apply_manual_bonus(new_manual, share.manual_column,
                               budget * share.part)
    FROM (
        SELECT pt.manual_column, sum(mp.power) / look.total_power AS part
        FROM manual_pages mp
        JOIN page_types pt ON pt.code = mp.page_type
        WHERE mp.page_id = ANY (p_page_ids)
        GROUP BY pt.manual_column
    ) AS share;

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_manual, mp.path_code,
           LEAST(1, sum(mp.power) / look.total_power)
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
    GROUP BY mp.path_code;

    -- A move it could plausibly teach: something of its dominant Path that a
    -- cultivator of its rank could hold. Often nothing, which is fine - most
    -- refined manuals are cultivation aids, not weapon books.
    INSERT INTO manual_techniques (manual_id, technique_id)
    SELECT new_manual, t.technique_id
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND tp.path_code = look.dominant
      AND t.rank <= GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2))
      AND look.archetype = 'offensive'
    ORDER BY t.base_power DESC
    LIMIT 1
    ON CONFLICT DO NOTHING;

    UPDATE manual_pages
    SET consumed_by = new_manual, consumed_at = now()
    WHERE page_id = ANY (p_page_ids);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, new_manual);

    lvl := grant_refinement_exp(p_player_id, gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, new_manual, new_name, look.forecast_tier,
                        look.archetype, keep * lift, gained, lvl, 0, band, n_draws;
END;
$$;

-- ---------------------------------------------------------------------------
-- brew, from 0084_the_crafts_read_the_three_new_words
-- ---------------------------------------------------------------------------
-- A spoiled cauldron hands the insured herb back whole.

DROP FUNCTION brew(BIGINT, TEXT[], INTEGER[]);

CREATE FUNCTION brew(
    p_player_id  BIGINT,
    p_codes      TEXT[],
    p_quantities INTEGER[],
    p_protect    TEXT DEFAULT NULL
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


    -- Insurance, paid before the attempt. `spend_jade` refuses rather than
    -- going negative, so an unaffordable protection stops the craft here
    -- rather than half way through it.
    IF p_protect IS NOT NULL THEN
        IF NOT (p_protect = ANY (p_codes)) THEN
            RAISE EXCEPTION 'you can only protect a herb that is in the cauldron'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, jade_material_protection_cost(p_protect), 'protect_herb');
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

        -- The insured herb comes back whole; everything else comes back
        -- at the refund rate.
        PERFORM grant_material(p_player_id, u.code,
                    CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                         THEN u.quantity::bigint
                         ELSE floor(u.quantity * refund)::bigint END)
        FROM unnest(p_codes, p_quantities) AS u (code, quantity)
        WHERE (CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                    THEN u.quantity ELSE floor(u.quantity * refund) END) > 0;

        back := COALESCE((SELECT sum(CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                                          THEN u.quantity
                                          ELSE floor(u.quantity * refund) END)
                          FROM unnest(p_codes, p_quantities) AS u (code, quantity)), 0);

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
-- forge, from 0084_the_crafts_read_the_three_new_words
-- ---------------------------------------------------------------------------
-- A ruined forging rakes the insured material back whole.

DROP FUNCTION forge(BIGINT, TEXT, TEXT, INTEGER, TEXT[], INTEGER[]);

CREATE FUNCTION forge(
    p_player_id  BIGINT,
    p_slot       TEXT,
    p_ore_code   TEXT,
    p_ore_qty    INTEGER,
    p_parts      TEXT[],
    p_part_qtys  INTEGER[],
    p_protect    TEXT DEFAULT NULL
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


    -- Insurance, paid before the attempt. `spend_jade` refuses rather than
    -- going negative, so an unaffordable protection stops the craft here
    -- rather than half way through it.
    IF p_protect IS NOT NULL THEN
        IF p_protect <> p_ore_code AND NOT (p_protect = ANY (p_parts)) THEN
            RAISE EXCEPTION 'you can only protect something that is on the anvil'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, jade_material_protection_cost(p_protect), 'protect_forging');
    END IF;

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

        -- Whatever was insured is raked back whole.
        PERFORM grant_material(p_player_id, p_ore_code,
                    CASE WHEN p_ore_code IS NOT DISTINCT FROM p_protect
                         THEN p_ore_qty::bigint
                         ELSE floor(p_ore_qty * refund)::bigint END)
        WHERE (CASE WHEN p_ore_code IS NOT DISTINCT FROM p_protect
                    THEN p_ore_qty ELSE floor(p_ore_qty * refund) END) > 0;

        PERFORM grant_material(p_player_id, u.code,
                    CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                         THEN u.quantity::bigint
                         ELSE floor(u.quantity * refund)::bigint END)
        FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
        WHERE (CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                    THEN u.quantity ELSE floor(u.quantity * refund) END) > 0;

        back := (CASE WHEN p_ore_code IS NOT DISTINCT FROM p_protect
                      THEN p_ore_qty ELSE floor(p_ore_qty * refund) END)
              + COALESCE((SELECT sum(CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                                          THEN u.quantity
                                          ELSE floor(u.quantity * refund) END)
                          FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)), 0);

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
