-- 0274_an_anvil_takes_more_than_one_metal
--
-- A cauldron takes two to six herbs and adds up what they carry. An anvil took
-- exactly one ore, and then
--
--     grade := LEAST(tier_by_pot, ore.tier, smith_tier_cap(skill));
--
-- capped the piece at that one ore's tier. So a tier 1 ore made a tier 1 piece
-- and nothing else, however much of it went on, and the low end of every
-- prospecting trip was worth nothing to anybody. Players hold millions of
-- tier 1 ore against a few hundred of tier 7.
--
-- So the anvil takes several metals, the way the cauldron takes several herbs.
-- Potency sums across all of them and the BEST ore leads: it sets the ceiling,
-- the signature effect, the Path and the name. Low ore is filler that carries
-- a good forging the rest of the way to the next tier.
--
-- Two things already in the harmony sum turn out to price that filler on their
-- own, which is why this needs no separate rule against it:
--
--   * `spread` is the distance between the best and worst grade on the anvil,
--     at -2 harmony each. Tier 7 ore bulked out with tier 1 is a spread of 6,
--     which is 12 harmony off the piece's quality band.
--   * every distinct Path is another seam at -4, and cheap ore rarely shares
--     a Path with the good metal.
--
-- A smith may still do it. It costs them the finish rather than the tier,
-- which is the trade a smith should be allowed to make.
--
-- NOTE, deliberately not guarded against: `spirit_stone` is both the currency
-- and a tier 1 ore, and one player holds 8.9 million of it. A single tier 7
-- ore now sets the ceiling and spirit stones can supply the rest of the
-- potency, at the harmony cost above. That was weighed and chosen; the dials
-- to reverse it are forge_max_ores (set to 1) or the spread penalty.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('forge_base_ores', 2,
     'Metals a smith may lay on the anvil at once before any ladder step. Two, '
     'so mixing is the ordinary way to forge rather than a late unlock.'),
    ('forge_max_ores', 4,
     'The most metals one forging may use, however skilled. Fewer than the '
     'cauldron holds herbs: a piece is mostly one metal and the rest is '
     'filler.');

INSERT INTO profession_steps (ladder, step, level_required) VALUES
    ('forge_ores', 1, 20), ('forge_ores', 2, 45);


CREATE FUNCTION smith_ore_slots(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(
        game_config_value('forge_max_ores'),
        game_config_value('forge_base_ores')
        + ladder_steps('forge_ores', p_level))::smallint;
$$;

COMMENT ON FUNCTION smith_ore_slots(SMALLINT) IS
    'How many kinds of metal fit on one anvil, the way alchemy_herb_slots counts herbs.';


DROP FUNCTION forge(BIGINT, TEXT, TEXT, INTEGER, TEXT[], INTEGER[], TEXT);

CREATE FUNCTION forge(
    p_player_id BIGINT,
    p_slot      TEXT,
    p_ores      TEXT[],
    p_ore_qtys  INTEGER[],
    p_parts     TEXT[],
    p_part_qtys INTEGER[],
    p_protect   TEXT DEFAULT NULL
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
    ore_slots   SMALLINT;
    n_ores      INTEGER;
    n_parts     INTEGER;
    known       INTEGER;
    ore         ores%ROWTYPE;
    lead_ore    TEXT;
    best_tier   SMALLINT;
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

    n_ores := COALESCE(array_length(p_ores, 1), 0);
    IF n_ores <> COALESCE(array_length(p_ore_qtys, 1), 0) THEN
        RAISE EXCEPTION 'every metal needs a quantity' USING ERRCODE = 'check_violation';
    END IF;
    IF n_ores < 1 THEN
        RAISE EXCEPTION 'a forging starts with ore' USING ERRCODE = 'check_violation';
    END IF;
    IF n_ores <> (SELECT count(DISTINCT x) FROM unnest(p_ores) AS x) THEN
        RAISE EXCEPTION 'name each metal once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_ore_qtys) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'a metal with none of it in is not on the anvil'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_ores) AS u (code) JOIN ores o ON o.material_code = u.code;
    IF known <> n_ores THEN
        RAISE EXCEPTION 'a forging starts with ore, and one of those is not'
            USING ERRCODE = 'check_violation';
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

    skill     := profession_level(p_player_id, 'blacksmithing');
    slots     := smith_part_slots(skill);
    ore_slots := smith_ore_slots(skill);

    IF n_ores > ore_slots THEN
        RAISE EXCEPTION 'your anvil holds % metals, not %', ore_slots, n_ores
            USING ERRCODE = 'check_violation';
    END IF;
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

    -- ---- which metal leads ----------------------------------------------
    -- The best one, because that is what the piece is: a tier 7 blade bulked
    -- out with scrap is still a tier 7 blade. Ties go to whichever there is
    -- most of, so the lead is never arbitrary.
    SELECT o.material_code INTO lead_ore
    FROM unnest(p_ores, p_ore_qtys) AS u (code, quantity)
    JOIN ores o ON o.material_code = u.code
    ORDER BY o.tier DESC, o.tier::numeric ^ 2 * u.quantity DESC, o.material_code
    LIMIT 1;

    SELECT * INTO ore FROM ores WHERE material_code = lead_ore;
    best_tier := ore.tier;

    IF best_tier > smith_tier_cap(skill) THEN
        RAISE EXCEPTION 'you cannot work tier % metal yet - your anvil reaches tier %',
            best_tier, smith_tier_cap(skill) USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.path_code INTO ore_path FROM materials m WHERE m.code = lead_ore;

    -- ---- what is on the anvil -------------------------------------------
    -- Squared, so depth cannot be bought cheaply with volume - four hundred
    -- tier 1 ore still only carries what eight tier 7 do. Summed across every
    -- metal, the way a cauldron sums its herbs.
    SELECT COALESCE(sum(o.tier::numeric ^ 2 * u.quantity), 0) INTO ore_pot
    FROM unnest(p_ores, p_ore_qtys) AS u (code, quantity)
    JOIN ores o ON o.material_code = u.code;

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

    -- The best metal is still the ceiling. Filler carries a forging up to
    -- what its best ore could always have reached; it does not carry it past.
    grade := LEAST(tier_by_pot, best_tier, smith_tier_cap(skill));

    -- Insurance, paid before the attempt. `spend_jade` refuses rather than
    -- going negative, so an unaffordable protection stops the craft here
    -- rather than half way through it.
    IF p_protect IS NOT NULL THEN
        IF NOT (p_protect = ANY (p_ores)) AND NOT (p_protect = ANY (p_parts)) THEN
            RAISE EXCEPTION 'you can only protect something that is on the anvil'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, jade_material_protection_cost(p_protect), 'protect_forging');
    END IF;

    -- ---- spend ----------------------------------------------------------
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_ores, p_ore_qtys) AS u (code, quantity);
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity);

    spent := COALESCE((SELECT sum(q) FROM unnest(p_ore_qtys) AS q), 0)
           + COALESCE((SELECT sum(q) FROM unnest(p_part_qtys) AS q), 0);

    -- ---- harmony --------------------------------------------------------
    -- Every Path on the anvil now, metals included. A second metal from a
    -- Path that fights the first is a seam like any other.
    relief := LEAST(1, player_stat(p_player_id, 'refine_conflict_relief'));

    SELECT COALESCE(sum(
        CASE WHEN pair_harmony(a.p, b.p) < 0
             THEN pair_harmony(a.p, b.p) * (1 - relief)
             ELSE pair_harmony(a.p, b.p) END
    ), 0)
    INTO pair_sum
    FROM (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_ores || p_parts) AS u (code)
          JOIN materials m ON m.code = u.code) a
    JOIN (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_ores || p_parts) AS u (code)
          JOIN materials m ON m.code = u.code) b
      ON a.p < b.p;

    SELECT count(*) INTO echoes
    FROM unnest(p_parts) AS u (code)
    JOIN materials m ON m.code = u.code
    WHERE m.path_code = ore_path;

    SELECT count(DISTINCT m.path_code) INTO distinct_n
    FROM unnest(p_ores || p_parts) AS u (code)
    JOIN materials m ON m.code = u.code;

    -- The distance between the best thing on the anvil and the worst. This is
    -- what filler costs: tier 7 ore carried by tier 1 is a spread of six.
    SELECT max(g) - min(g) INTO spread
    FROM (SELECT o.tier AS g
          FROM unnest(p_ores) AS u (code)
          JOIN ores o ON o.material_code = u.code
          UNION ALL
          SELECT material_grade(m.rarity)
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

        PERFORM grant_material(p_player_id, u.code,
                    CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                         THEN u.quantity::bigint
                         ELSE floor(u.quantity * refund)::bigint END)
        FROM unnest(p_ores || p_parts, p_ore_qtys || p_part_qtys) AS u (code, quantity)
        WHERE (CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                    THEN u.quantity ELSE floor(u.quantity * refund) END) > 0;

        back := COALESCE((SELECT sum(CASE WHEN u.code IS NOT DISTINCT FROM p_protect
                                          THEN u.quantity
                                          ELSE floor(u.quantity * refund) END)
                          FROM unnest(p_ores || p_parts,
                                      p_ore_qtys || p_part_qtys) AS u (code, quantity)), 0);

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

    budget    := base_mag * keep_frac
                 * (1 + player_stat(p_player_id, 'forge_power'));
    ore_side  := budget * game_config_value('forge_ore_share');
    sig_side  := ore_side * game_config_value('forge_signature_share');
    base_side := ore_side - sig_side;
    part_side := budget - ore_side;

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
            ore_path, lead_ore, react_word)
    RETURNING player_equipment.equipment_id INTO made_id;

    -- ---- what it is worth -----------------------------------------------
    INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
    SELECT made_id, c.effect_code,
           LEAST(ef.cap, round(sum(c.magnitude), 4))
    FROM (
        -- what the leading metal is known for
        SELECT ore.signature AS effect_code, sig_side AS magnitude
        UNION ALL
        SELECT se.effect_code, base_side * se.share
        FROM slot_effects se WHERE se.slot = p_slot
        UNION ALL
        SELECT pe.effect_code,
               part_side * (pp.pot / GREATEST(part_pot, 1)) * pe.share
        FROM (SELECT bp.part,
                     material_grade(m.rarity)::numeric ^ 2 * u.quantity AS pot
              FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
              JOIN materials m ON m.code = u.code
              JOIN beast_parts bp ON bp.material_code = u.code) pp
        JOIN part_effects pe ON pe.part = pp.part
        UNION ALL
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

COMMENT ON FUNCTION forge(BIGINT, TEXT, TEXT[], INTEGER[], TEXT[], INTEGER[], TEXT) IS
    'Several metals and several beast parts into one piece. Potency sums across every metal the way a cauldron sums its herbs; the best ore leads, setting the ceiling, the signature and the name.';
