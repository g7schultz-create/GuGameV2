-- 0059_pills_that_change_the_rate
--
-- A pill that makes cultivation FASTER, rather than handing over a lump of it.
--
-- 0057 said a pill is instant "because there is no buff system, no duration,
-- nothing that outlives a command". That was true and it was also a wall in
-- the wrong place: the interesting cultivation pill in every story about this
-- is the one that makes the next month worth more, not the one that skips a
-- week.
--
-- A BOOST IS HOURS, NOT A CLOCK. Building it as an expiry timestamp would have
-- meant inventing the one thing this game has refused since 0006 - something
-- that ticks - and worse, the hours would have burned while nobody was
-- cultivating. `player_boosts.hours_left` is spent only by time that is
-- actually settled, so an hour bought is an hour had. It also needs no
-- scheduler, no sweeper and no clock skew, which is the same reason
-- `last_tick_at` works.
--
-- EXPENSIVE, BY GRADE AND NOT BY GATE. `pill_kinds.min_tier` says an effect
-- will not fix in place below a grade, and Tier 5 wants 70 potency - a dozen
-- Tier 6 herbs, which are one gather in a hundred and twenty. Below that the
-- pot does not fail: it comes out as the plainer pill that Path also makes.
-- A recipe that punishes an honest attempt teaches nothing; one that gives you
-- the lesser thing teaches exactly what was missing.
--
-- WHICH PATHS. Qi and Heaven brew the rate rather than the lump, and Wisdom
-- and Dream brew attainment rate rather than insight - the four Paths whose
-- whole identity is the pace of the work rather than its product. They are
-- moved, not added to, so no Path brews two things.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A grade an effect will not form below
-- ---------------------------------------------------------------------------

ALTER TABLE pill_kinds ADD COLUMN min_tier SMALLINT NOT NULL DEFAULT 1
    CHECK (min_tier BETWEEN 1 AND 7);

ALTER TABLE pill_kinds ADD COLUMN fallback TEXT
    REFERENCES pill_kinds (code) ON DELETE RESTRICT;

CREATE INDEX pill_kinds_fallback_idx ON pill_kinds (fallback);

COMMENT ON COLUMN pill_kinds.min_tier IS
    'The grade below which this effect will not hold, and the pill comes out as `fallback` instead.';


-- ---------------------------------------------------------------------------
-- The two new kinds
-- ---------------------------------------------------------------------------
-- `per_point` is hours here rather than a quantity of anything: a Tier 5 pill
-- is 45 hours of a faster clock, which beats the lump the same grade would
-- have given if - and only if - the hours are actually spent cultivating.

INSERT INTO pill_kinds (code, name, per_point, emoji, description, min_tier, fallback) VALUES
    ('cultivation_rate', 'Quickened Cultivation', 3, '⏩',
     'Hours during which cultivation runs faster. Spent by time settled, never by the calendar.',
     5, 'cultivation'),
    ('attainment_rate', 'Quickened Insight', 3, '🔮',
     'Hours during which a focused Path yields more insight.',
     5, 'insight');

-- How much faster, by grade. Below Tier 5 these are unreachable, which the
-- zeroes say out loud rather than leaving to a join that returns nothing.
ALTER TABLE pill_tiers ADD COLUMN rate_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0
    CHECK (rate_bonus >= 0);

UPDATE pill_tiers SET rate_bonus = v.bonus
FROM (VALUES (5, 0.2500), (6, 0.3500), (7, 0.5000)) AS v (tier, bonus)
WHERE pill_tiers.tier = v.tier;

-- The four Paths whose identity is the pace rather than the product.
UPDATE path_pill_kinds SET kind = 'cultivation_rate' WHERE path_code IN ('qi', 'heaven');
UPDATE path_pill_kinds SET kind = 'attainment_rate'  WHERE path_code IN ('wisdom', 'dream');

INSERT INTO pill_endings (kind, ending) VALUES
    ('cultivation_rate','Quickening Elixir'),('cultivation_rate','Hastening Pill'),
    ('cultivation_rate','Swift Current Elixir'),
    ('attainment_rate','Insight Elixir'),('attainment_rate','Opening Pill'),
    ('attainment_rate','Clear Sight Elixir');


-- ---------------------------------------------------------------------------
-- player_boosts
-- ---------------------------------------------------------------------------

CREATE TABLE player_boosts (
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    kind       TEXT   NOT NULL REFERENCES pill_kinds (code) ON DELETE RESTRICT,

    -- Additive, like every other bonus in this game: a +25% boost on a +5%
    -- race is +30%, never a product of the two.
    magnitude  NUMERIC(6, 4) NOT NULL CHECK (magnitude > 0),
    hours_left NUMERIC(8, 2) NOT NULL CHECK (hours_left > 0),

    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, kind)
);

CREATE INDEX player_boosts_kind_idx ON player_boosts (kind);

COMMENT ON TABLE player_boosts IS
    'Hours of a faster rate, spent by settled time rather than by the clock. One row per player per kind; a second pill blends into the first.';

-- Two pills of one kind blend rather than stack, weighted by the hours each
-- brings. Taking the stronger magnitude would have let a long weak pill and a
-- short strong one become a long strong one.
CREATE FUNCTION grant_boost(
    p_player_id BIGINT, p_kind TEXT, p_magnitude NUMERIC, p_hours NUMERIC
) RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    total NUMERIC;
BEGIN
    INSERT INTO player_boosts (player_id, kind, magnitude, hours_left)
    VALUES (p_player_id, p_kind, p_magnitude, p_hours)
    ON CONFLICT (player_id, kind) DO UPDATE SET
        magnitude = (player_boosts.magnitude * player_boosts.hours_left
                     + EXCLUDED.magnitude * EXCLUDED.hours_left)
                    / (player_boosts.hours_left + EXCLUDED.hours_left),
        hours_left = player_boosts.hours_left + EXCLUDED.hours_left
    RETURNING hours_left INTO total;

    RETURN total;
END;
$$;


-- ---------------------------------------------------------------------------
-- take_pill, which now has somewhere to put an hour
-- ---------------------------------------------------------------------------

CREATE FUNCTION percent_text(p_value NUMERIC)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT '+' || round(p_value * 100) || '%';
$$;

CREATE OR REPLACE FUNCTION take_pill(p_player_id BIGINT, p_pill_id BIGINT)
RETURNS TABLE (
    pill_name  TEXT,
    kind       TEXT,
    granted    BIGINT,
    detail     TEXT,
    remaining  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     player_pills%ROWTYPE;
    before BIGINT;
    after  BIGINT;
    bonus  NUMERIC;
    banked NUMERIC;
    said   TEXT;
    left_n SMALLINT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    IF it.kind IN ('cultivation_rate', 'attainment_rate') THEN
        SELECT pt.rate_bonus INTO bonus FROM pill_tiers pt WHERE pt.tier = it.tier;
        banked := grant_boost(p_player_id, it.kind, bonus, it.magnitude);
        after  := it.magnitude;
        said   := percent_text(bonus) || ' for ' || round(it.magnitude)
                  || ' hours of cultivation, ' || round(banked) || ' banked in total.';

    ELSIF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The bottleneck refused the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        SELECT pp.physique_xp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        SELECT pp.physique_xp INTO after FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        after := after - before;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        SELECT COALESCE(a.insight, 0) INTO before
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        PERFORM grant_path_insight(p_player_id, it.path_code, it.magnitude, 0, 0);
        SELECT COALESCE(a.insight, 0) INTO after
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        after := after - before;
        said := 'Insight into ' || it.path_code || '.';

    ELSIF it.kind = 'healing' THEN
        SELECT pp.current_hp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The body could not hold all of it.'
                     ELSE 'Health, at once.' END;

    ELSE
        SELECT pc.qi INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        UPDATE player_cultivation pc
        SET qi = LEAST(
                (SELECT r.qi_capacity FROM realms r WHERE r.realm_id = pc.realm_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id
        RETURNING pc.qi INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The aperture would not hold the rest.'
                     ELSE 'Battle Qi, at once.' END;
    END IF;

    IF it.quantity > 1 THEN
        UPDATE player_pills SET quantity = quantity - 1 WHERE pill_id = p_pill_id
        RETURNING quantity INTO left_n;
    ELSE
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
        left_n := 0;
    END IF;

    RETURN QUERY SELECT it.name, it.kind, GREATEST(0, COALESCE(after, 0)), said, left_n;
END;
$$;


-- ---------------------------------------------------------------------------
-- brew, and the settle that spends what it made
-- ---------------------------------------------------------------------------

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

    made_mag := GREATEST(1, round(base_mag * per_point * keep));

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

CREATE OR REPLACE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
RETURNS TABLE (
    hours              NUMERIC,
    capped             BOOLEAN,
    cultivation_gained BIGINT,
    physique_gained    BIGINT,
    insight_gained     BIGINT,
    hp_restored        BIGINT,
    focus_path         TEXT,
    realm_before       SMALLINT,
    realm_after        SMALLINT,
    level_before       SMALLINT,
    level_after        SMALLINT,
    tier_before        SMALLINT,
    tier_after         SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult          player_cultivation%ROWTYPE;
    rates         player_trait_rates%ROWTYPE;
    baseline      NUMERIC := game_config_value('training_aptitude_baseline');
    cap_hours     NUMERIC := game_config_value('passive_cap_hours');
    manual_cult   NUMERIC := 0;
    manual_phys   NUMERIC := 0;
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_offered  BIGINT;
    cult_gain     BIGINT;
    cult_before   BIGINT;
    cult_after    BIGINT;
    phys_gain     BIGINT;
    insight_gain  BIGINT := 0;
    hp_gain       BIGINT := 0;
    hp_before     BIGINT;
    hp_after      BIGINT;
    r_before      SMALLINT;
    r_after       SMALLINT;
    l_before      SMALLINT;
    l_after       SMALLINT;
    t_before      SMALLINT;
    t_after       SMALLINT;
    cult_boost    NUMERIC := 0;
    cult_hours    NUMERIC := 0;
    att_boost     NUMERIC := 0;
    att_hours     NUMERIC := 0;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    elapsed    := EXTRACT(EPOCH FROM (now() - cult.last_tick_at)) / 3600.0;
    was_capped := elapsed > cap_hours;
    paid       := LEAST(elapsed, cap_hours);

    SELECT * INTO rates FROM player_trait_rates WHERE player_id = p_player_id;

    -- A boost is hours, not a clock. Nothing in this game ticks, so a pill
    -- that "lasts twelve hours" would have had to invent one - and would then
    -- have burned those hours while nobody was cultivating. These are spent
    -- only by time that is actually settled, so an hour bought is an hour had.
    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO cult_boost, cult_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';

    SELECT b.magnitude, LEAST(paid, b.hours_left) INTO att_boost, att_hours
    FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

    cult_boost := COALESCE(cult_boost, 0);
    cult_hours := COALESCE(cult_hours, 0);
    att_boost  := COALESCE(att_boost, 0);
    att_hours  := COALESCE(att_hours, 0);

    SELECT b.cultivation_rate_bonus, b.physique_rate_bonus
    INTO manual_cult, manual_phys
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;
    manual_cult := COALESCE(manual_cult, 0) + gu_stat(p_player_id, 'cultivation_rate');
    manual_phys := COALESCE(manual_phys, 0);

    SELECT pc.realm_id, pc.cultivation INTO r_before, cult_before
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_offered := round(
        (paid + cult_boost * cult_hours)
        * game_config_value('passive_cultivation_per_hour')
        * (COALESCE(rates.cultivation_multiplier, 1) + manual_cult)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * (COALESCE(rates.physique_multiplier, 1) + manual_phys)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            (paid + att_boost * att_hours)
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_offered);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    -- What was actually banked, not what was offered. The bottleneck can
    -- refuse most of it, and a card that reports the offer is a card that lies.
    SELECT pc.cultivation INTO cult_after
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    cult_gain := GREATEST(0, cult_after - cult_before);

    SELECT pp.current_hp INTO hp_before
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    UPDATE player_physique pp
    SET current_hp = least(pp.max_hp,
                           pp.current_hp + floor(paid * 60 * pp.regeneration)::bigint)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO hp_after;

    hp_gain := GREATEST(0, COALESCE(hp_after, 0) - COALESCE(hp_before, 0));

    IF cult.focus_path IS NOT NULL THEN
        t_after := grant_path_insight(
            p_player_id, cult.focus_path, insight_gain, round(paid * 3600)::bigint, 0
        );
    ELSE
        t_after := t_before;
    END IF;

    -- Spent, and swept away when there is nothing left of them.
    UPDATE player_boosts b SET hours_left = b.hours_left - cult_hours
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';
    UPDATE player_boosts b SET hours_left = b.hours_left - att_hours
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';
    DELETE FROM player_boosts b
    WHERE b.player_id = p_player_id AND b.hours_left <= 0;

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;
