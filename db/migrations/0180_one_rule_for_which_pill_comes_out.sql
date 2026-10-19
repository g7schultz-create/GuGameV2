-- 0180_one_rule_for_which_pill_comes_out
--
-- Which pill a brew makes is three facts, not one: the Path's kind from
-- `path_pill_kinds`, that kind's `min_tier`, and its `fallback` when the brew
-- comes out below it. `brew` applied all three. The `/alchemy` preview
-- applied the first and joined straight from `path_pill_kinds` to
-- `pill_kinds`.
--
-- So a Heaven or Qi brew forecast to tier 4 told the player it would make
-- **Quickened Cultivation** - `cultivation_rate`, min_tier 5 - and the
-- cauldron handed back a plain Cultivation pill instead, with nothing said.
-- The one pill in the game that raises cultivation speed past the +100% stat
-- cap, promised on a screen and quietly swapped out.
--
-- Both sides read `pill_kind_for` now. And because the interesting case is
-- being one step under the floor rather than miles from it, there is a second
-- function for what a screen wants to say about that: which kind you would
-- get if you pushed the grade up one.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION pill_kind_for(p_path TEXT, p_tier SMALLINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    -- Below the floor a kind falls back to what it is a quickened version
    -- of; a kind with no fallback simply stands at any tier.
    SELECT CASE WHEN pk.min_tier > p_tier
                THEN COALESCE(pk.fallback, pk.code)
                ELSE pk.code END
    FROM path_pill_kinds ppk
    JOIN pill_kinds pk ON pk.code = ppk.kind
    WHERE ppk.path_code = p_path;
$$;


CREATE FUNCTION pill_kind_upgrade_at(p_path TEXT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    -- The tier at which this Path stops making the fallback and starts
    -- making the real thing. NULL when the Path has no such step, so a
    -- screen can say nothing rather than saying something untrue.
    SELECT pk.min_tier
    FROM path_pill_kinds ppk
    JOIN pill_kinds pk ON pk.code = ppk.kind
    WHERE ppk.path_code = p_path
      AND pk.min_tier > 1
      AND pk.fallback IS NOT NULL;
$$;


CREATE OR REPLACE FUNCTION public.brew(p_player_id bigint, p_codes text[], p_quantities integer[], p_protect text DEFAULT NULL::text)
 RETURNS TABLE(succeeded boolean, harmony smallint, potency numeric, pill_id bigint, pill_name text, pill_tier smallint, pill_kind text, path_code text, magnitude bigint, quantity smallint, exp_gained bigint, level_after smallint, spent_total bigint, handed_back bigint)
 LANGUAGE plpgsql
AS $function$
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
    next_p    NUMERIC;
    span      NUMERIC;
    step      NUMERIC;
    most      NUMERIC;
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

    -- 0180. The map, the floor and the fallback are one rule now, and the
    -- cauldron's preview reads the same one - it used to join
    -- `path_pill_kinds` straight to `pill_kinds` and promise a Quickened
    -- Cultivation that a tier 4 brew was never going to produce.
    kind_code := pill_kind_for(lead_path, grade);

    SELECT pk.per_point INTO per_point FROM pill_kinds pk WHERE pk.code = kind_code;

    made_mag := GREATEST(1, round(base_mag * per_point * keep
                                  * (1 + player_stat(p_player_id, 'brew_potency'))));

    -- Overshooting a grade fills the cauldron rather than wasting it - and
    -- the overshoot is measured against the room there is before the next
    -- grade, because that is all the room there is. Measuring it against a
    -- fraction of THIS grade's floor was the bug: the tier ladder climbs by
    -- about 1.9x and the divisor asked for 3x, so above tier 2 the potency
    -- for a third pill promoted you a tier instead and `alchemy_max_batch`
    -- could never be reached at all.
    SELECT min(pt.potency_required) INTO next_p
    FROM pill_tiers pt WHERE pt.tier > grade;

    most := GREATEST(1, game_config_value('alchemy_max_batch'));
    -- The top grade has nothing above it, so it borrows the ladder's own
    -- step. Without this the best cauldron in the game makes one pill.
    span := COALESCE(next_p - floor_p,
                     floor_p * game_config_value('alchemy_batch_divisor'));
    step := GREATEST(0.01, span / most);

    batch := LEAST(most, 1 + floor((total - floor_p) / step))::smallint;

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
$function$;


DO $$
DECLARE
    wrong TEXT;
BEGIN
    -- Every Path at every tier, against the rule brew used to carry inline.
    SELECT string_agg(p.code || '@' || t.tier || ' says ' || pill_kind_for(p.code, t.tier::smallint), ', ')
    INTO wrong
    FROM paths p
    JOIN path_pill_kinds ppk ON ppk.path_code = p.code
    JOIN pill_kinds pk ON pk.code = ppk.kind
    CROSS JOIN generate_series(1, 7) AS t (tier)
    WHERE pill_kind_for(p.code, t.tier::smallint) IS DISTINCT FROM
          CASE WHEN pk.min_tier > t.tier THEN COALESCE(pk.fallback, pk.code)
               ELSE pk.code END;

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'pill_kind_for disagrees with the tables: %', wrong;
    END IF;

    -- The case this exists for: Heaven and Qi below tier 5 are NOT the
    -- quickened kind, and at tier 5 they are.
    IF pill_kind_for('qi', 4::smallint) <> 'cultivation' THEN
        RAISE EXCEPTION 'a tier 4 Qi brew is claiming to be quickened';
    END IF;
    IF pill_kind_for('qi', 5::smallint) <> 'cultivation_rate' THEN
        RAISE EXCEPTION 'a tier 5 Qi brew is not quickened';
    END IF;
    IF pill_kind_upgrade_at('qi') <> 5 THEN
        RAISE EXCEPTION 'the Qi upgrade step is not tier 5';
    END IF;

    -- A Path with no step says nothing rather than something false.
    IF pill_kind_upgrade_at('water') IS NOT NULL THEN
        RAISE EXCEPTION 'healing was given an upgrade step it does not have';
    END IF;

    -- And brew asks rather than remembers.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'brew') NOT LIKE '%pill_kind_for%' THEN
        RAISE EXCEPTION 'brew still decides the kind for itself';
    END IF;
END;
$$;
