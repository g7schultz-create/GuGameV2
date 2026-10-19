-- 0176_the_cauldron_fills_by_the_room_it_has
--
-- `alchemy_max_batch` is 5 and the biggest batch anybody has ever brewed is
-- 2. It is read - I said otherwise and was wrong - but it cannot bind, and
-- the reason is arithmetic between two tables that were tuned separately.
--
-- The batch was `1 + floor((total - floor) / (floor * 0.5))`, so a third pill
-- wanted twice the grade's floor potency and a fifth wanted four times. The
-- grade, meanwhile, is the highest tier whose floor the potency clears, and
-- `pill_tiers` climbs by about 1.9x a step:
--
--   tier 3   floor 18   next 36    ratio 2.00   best batch possible 2
--   tier 4   floor 36   next 70    ratio 1.94   best batch possible 2
--   tier 5   floor 70   next 130   ratio 1.86   best batch possible 2
--   tier 6   floor 130  next 240   ratio 1.85   best batch possible 2
--
-- Above tier 2 the potency for a third pill promotes you a grade instead, so
-- the batch resets to 1 at a higher tier. Batches of 3, 4 and 5 existed only
-- at tier 7, where there is no grade left to be promoted into.
--
-- So the overshoot is now measured against the room there actually is - the
-- gap to the next grade - divided into `alchemy_max_batch` steps. At a
-- grade's floor you get one pill; just short of the next grade you get five;
-- crossing over gives one of something better. The dial is the dial again.
--
-- Nothing about grade, harmony, potency or magnitude moves.
--
-- Forward-only. Do not edit once applied.


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


-- The check that would have caught it: every batch size the config allows has
-- to be reachable inside every grade's own band, top grade included.

DO $$
DECLARE
    most  INTEGER := game_config_value('alchemy_max_batch');
    row_t RECORD;
    span  NUMERIC;
    step  NUMERIC;
    got   INTEGER;
BEGIN
    FOR row_t IN
        SELECT pt.tier, pt.potency_required AS floor_p,
               (SELECT min(p2.potency_required) FROM pill_tiers p2
                WHERE p2.tier > pt.tier) AS next_p
        FROM pill_tiers pt ORDER BY pt.tier
    LOOP
        span := COALESCE(row_t.next_p - row_t.floor_p,
                         row_t.floor_p * game_config_value('alchemy_batch_divisor'));
        step := GREATEST(0.01, span / most);

        -- Just short of the next grade, which is the most this band can hold.
        got := LEAST(most, 1 + floor(
            ((COALESCE(row_t.next_p, row_t.floor_p + span) - 0.01) - row_t.floor_p)
            / step));

        IF got <> most THEN
            RAISE EXCEPTION
                'tier % tops out at a batch of % and the config says %',
                row_t.tier, got, most;
        END IF;

        -- And exactly at the floor it is one pill, not a free handful.
        IF 1 + floor((row_t.floor_p - row_t.floor_p) / step) <> 1 THEN
            RAISE EXCEPTION 'tier % pays a batch for the bare minimum', row_t.tier;
        END IF;
    END LOOP;
END;
$$;
