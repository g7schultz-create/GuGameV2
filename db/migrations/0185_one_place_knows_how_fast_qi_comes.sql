-- 0185_one_place_knows_how_fast_qi_comes
--
-- `/cultivation` prints an hourly rate. It computed that rate itself, in
-- Python, from a copy of the settle's arithmetic - with a comment saying so:
--
--     The same arithmetic settle_passive_cultivation performs, shown rather
--     than applied ... a rate here that ignored them would advertise one
--     number and pay out another
--
-- Which is exactly what happened. 0183 gave the settle a realm term and the
-- screen never learned about it, so Grafv's card read 103 an hour while the
-- settle was paying 412. The comment predicted its own failure and the copy
-- still drifted the first time the original moved.
--
-- It was wrong before that too, in a quieter way: the screen summed
-- `gu_stat` where the settle sums `player_stat`, so equipment, dwelling,
-- root and physique contributions were missing. clearwest carries +55% of
-- cultivation speed on his gear alone and the screen has never counted it.
--
-- So the rate becomes a function and both sides ask it. A boost stays outside
-- it, because a boost buys extra HOURS rather than a faster hour - that is
-- what `(paid + cult_boost * cult_hours)` means and it is the reason a rate
-- pill can push past the +100% stat cap.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION cultivation_per_hour(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT game_config_value('passive_cultivation_per_hour')
         * realm_cultivation_scale(r.rank)
         -- Additive, every one of them: a +5% Race and a +2% manual make
         -- +7%, never +7.1%.
         * (COALESCE(tr.cultivation_multiplier, 1)
            + COALESCE(mb.cultivation_rate_bonus, 0)
            + player_stat(p_player_id, 'cultivation_rate'))
         * (pc.aptitude / game_config_value('training_aptitude_baseline'))
         * CASE WHEN pc.focus_path IS NULL THEN 1
                ELSE game_config_value('path_cultivation_xp_rate') END
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    LEFT JOIN player_trait_rates tr ON tr.player_id = pc.player_id
    LEFT JOIN player_manual_bonuses mb ON mb.player_id = pc.player_id
    WHERE pc.player_id = p_player_id;
$$;


CREATE OR REPLACE FUNCTION public.settle_passive_cultivation(p_player_id bigint)
 RETURNS TABLE(hours numeric, capped boolean, cultivation_gained bigint, cultivation_stored bigint, physique_gained bigint, insight_gained bigint, hp_restored bigint, focus_path text, realm_before smallint, realm_after smallint, level_before smallint, level_after smallint, tier_before smallint, tier_after smallint)
 LANGUAGE plpgsql
AS $function$
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
    res_before    BIGINT;
    res_after     BIGINT;
    cult_stored   BIGINT;
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
    manual_cult := COALESCE(manual_cult, 0) + player_stat(p_player_id, 'cultivation_rate');
    -- The body reads its own rate word now. Cultivation has consulted
    -- player_stat since 0066 and the physique never did, which is why a
    -- Gu that claimed to strengthen a cultivator did nothing for the
    -- pillar named after it.
    manual_phys := COALESCE(manual_phys, 0)
                   + player_stat(p_player_id, 'physique_rate');

    SELECT pc.realm_id, pc.cultivation, pc.reserve
    INTO r_before, cult_before, res_before
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    -- 0183. What a cultivator draws an hour now depends on what they have
    -- become. Every realm costs about seven times the one below it while the
    -- rate was flat and capped at +100%, so Spirit Severing was 243 days at
    -- the ceiling and Dao Seeking was four and a half years.
    -- 0185. The hourly draw is one function now. A boost still buys extra
    -- HOURS rather than a bigger rate, which is why it stays out here.
    cult_offered := round(
        (paid + cult_boost * cult_hours) * cultivation_per_hour(p_player_id)
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
    SELECT pc.cultivation, pc.reserve INTO cult_after, res_after
    FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    cult_gain   := GREATEST(0, cult_after - cult_before);
    -- Measured, not calculated. What the reserve took is whatever
    -- it is now holding that it was not holding before - so a full
    -- reserve reports the zero it actually stored.
    cult_stored := GREATEST(0, res_after - res_before);

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
        cult_gain, cult_stored, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$function$;


DO $$
DECLARE
    who   BIGINT;
    said  NUMERIC;
    scale NUMERIC;
BEGIN
    SELECT pc.player_id INTO who FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    ORDER BY r.rank DESC, pc.cultivation DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no cultivator to probe with; tests carry it';
        RETURN;
    END IF;

    said := cultivation_per_hour(who);
    IF said IS NULL OR said <= 0 THEN
        RAISE EXCEPTION 'the strongest cultivator draws % an hour', said;
    END IF;

    -- It has to carry the realm term, which is the thing the screen lost.
    SELECT realm_cultivation_scale(r.rank) INTO scale
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = who;

    IF said < game_config_value('passive_cultivation_per_hour') * scale * 0.5 THEN
        RAISE EXCEPTION
            'the rate ignores the realm: % against a scale of %', said, scale;
    END IF;

    -- And the settle asks rather than repeating.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'settle_passive_cultivation')
       NOT LIKE '%cultivation_per_hour%' THEN
        RAISE EXCEPTION 'the settle still carries its own copy of the rate';
    END IF;
END;
$$;
