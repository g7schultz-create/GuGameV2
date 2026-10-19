-- 0183_qi_comes_faster_to_the_stronger
--
-- `settle_passive_cultivation` read a flat `passive_cultivation_per_hour` of
-- 100 and knew nothing about what realm the cultivator was in. A Dao Seeking
-- cultivator drew qi at exactly the rate somebody who registered this morning
-- does, while every realm costs about SEVEN times the one below it:
--
--   Core Formation        24,761
--   Nascent Soul         169,836
--   Spirit Severing    1,164,903
--   Dao Seeking        7,990,067
--   Immortal Realm    54,803,869
--
-- The only multiplier against that is `cultivation_rate`, capped at +100% by
-- `gu_effects`, and the two strongest cultivators here sit at 0.961 and
-- 0.945 - within 6% of a ceiling they can never pass. So Spirit Severing was
-- 243 days of perfect play and Dao Seeking was 1,665.
--
-- An exponential cost against a flat capped rate is not a difficulty curve,
-- it is a wall. The rate scales with the square of realm rank now, which is
-- also the canon reading: a stronger cultivator has a wider aperture and
-- draws more from the same air.
--
-- Each realm now costs 3.0x to 5.4x the one below rather than a flat 6.86,
-- and the step rises slowly instead of compounding at a constant rate.
--
--   realm 3      1x -> 9x     days at the cap   5 -> 1
--   realm 4     16x                            35 -> 2
--   realm 5     25x                           243 -> 10
--   realm 6     36x                         1,665 -> 46
--   realm 7     49x                        11,417 -> 233
--
-- Rank 1 is untouched at 1x, so nothing about a new cultivator's first days
-- changes. The exponent is a config row rather than a literal, because the
-- shape of this curve is the sort of thing that gets retuned.
--
-- Cultivation only. Physique and insight climb against thresholds that are
-- nothing like this steep, and scaling them here would be changing three
-- things while measuring one.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('passive_realm_exponent', 2,
     'Passive cultivation scales with realm rank raised to this. 2 keeps each '
     'realm roughly four to five times the last rather than seven, which is '
     'the gap between a climb and a wall.');


CREATE FUNCTION realm_cultivation_scale(p_rank SMALLINT)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    -- Rank 1 is 1 whatever the exponent, so a beginner's first days are
    -- never affected by tuning the top of the ladder.
    SELECT power(GREATEST(1, COALESCE(p_rank, 1)),
                 game_config_value('passive_realm_exponent'));
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
    realm_scale   NUMERIC := 1;
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
    SELECT realm_cultivation_scale(r.rank) INTO realm_scale
    FROM realms r WHERE r.realm_id = cult.realm_id;
    realm_scale := COALESCE(realm_scale, 1);

    cult_offered := round(
        (paid + cult_boost * cult_hours)
        * game_config_value('passive_cultivation_per_hour')
        * realm_scale
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
    said  NUMERIC;
    worst NUMERIC;
BEGIN
    -- Rank 1 untouched, and the curve rising.
    IF realm_cultivation_scale(1::smallint) <> 1 THEN
        RAISE EXCEPTION 'a beginner is no longer on the plain rate';
    END IF;
    IF realm_cultivation_scale(3::smallint) <> 9
       OR realm_cultivation_scale(5::smallint) <> 25 THEN
        RAISE EXCEPTION 'the scale is not the square of the rank';
    END IF;

    FOR said IN SELECT r FROM generate_series(1, 8) AS r LOOP
        IF realm_cultivation_scale(said::smallint)
           < realm_cultivation_scale(GREATEST(1, said - 1)::smallint) THEN
            RAISE EXCEPTION 'the scale falls at rank %', said;
        END IF;
    END LOOP;

    -- The point of the change, stated as the thing that was wrong. The raw
    -- ladder climbs by a flat 6.86 every realm, compounding forever. Scaled,
    -- it runs 3.05 at Core Formation to 5.42 at the ninth realm - rising,
    -- but always below the raw step, which is the whole claim.
    SELECT max(ratio) INTO worst FROM (
        SELECT (r.needs / realm_cultivation_scale(r.rank::smallint))
               / NULLIF(LAG(r.needs / realm_cultivation_scale(r.rank::smallint))
                        OVER (ORDER BY r.rank), 0) AS ratio
        FROM (SELECT rank, min(cultivation_required) AS needs
              FROM realms WHERE rank >= 2 GROUP BY rank) r
    ) x;

    IF worst >= 6 THEN
        RAISE EXCEPTION
            'a realm still takes %x the one below it', round(worst, 1);
    END IF;

    -- And the settle asks rather than assuming.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'settle_passive_cultivation')
       NOT LIKE '%realm_cultivation_scale%' THEN
        RAISE EXCEPTION 'the settle still cultivates at a flat rate';
    END IF;
END;
$$;
