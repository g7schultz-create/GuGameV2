-- 0060_a_spent_boost_does_not_crash_the_settle
--
-- 0059 decremented a boost and then deleted the empty ones, in that order,
-- against a column declared `CHECK (hours_left > 0)`. A boost consumed exactly
-- to nothing therefore tried to write a zero the constraint forbids - and
-- since `settle_passive_cultivation` runs at the top of nearly every command,
-- that is not a failed pill. It is a character that cannot open its own
-- profile until somebody deletes the row by hand.
--
-- The CHECK is right and stays: a boost row with nothing left in it is not a
-- state worth having. What was wrong is the order. Exhausted rows are swept
-- away first, and only what survives is decremented - which by definition has
-- more hours in it than were spent.
--
-- Found by a test that gave a boost two hours and settled ten.
--
-- Forward-only. Do not edit once applied.

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

    -- Swept away FIRST, then spent. `hours_left > 0` is a CHECK, and it is
    -- the right one - a boost row with nothing left in it is not a state
    -- worth having - so the exhausted rows have to go before anything tries
    -- to write a zero into them.
    DELETE FROM player_boosts b
    WHERE b.player_id = p_player_id
      AND ((b.kind = 'cultivation_rate' AND b.hours_left <= cult_hours)
        OR (b.kind = 'attainment_rate'  AND b.hours_left <= att_hours));

    UPDATE player_boosts b SET hours_left = b.hours_left - cult_hours
    WHERE b.player_id = p_player_id AND b.kind = 'cultivation_rate';
    UPDATE player_boosts b SET hours_left = b.hours_left - att_hours
    WHERE b.player_id = p_player_id AND b.kind = 'attainment_rate';

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;
