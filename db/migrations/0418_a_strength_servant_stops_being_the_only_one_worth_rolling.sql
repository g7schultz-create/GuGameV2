-- 0418_a_strength_servant_stops_being_the_only_one_worth_rolling
--
-- 0414 gave Strength its own column because Sinew is points rather than a
-- share, and then filled that column with numbers picked to look generous
-- instead of numbers measured against anything. Laid beside what a five-star
-- Venerable of each other kind is worth, as a share of its own ceiling:
--
--     Health          0.12 of 1.00      12 per cent of the ceiling
--     Aperture        0.12 of 1.00      12
--     Attack          0.12 of 2.00       6
--     Cultivation     0.12 of 3.00       4
--     Double Strike   0.05 of 3.00       1.7
--     Strength          20 of 30        67          <- this one
--
-- `physique_base_strength` is 30 and the Sinew ceiling is 30, so Sinew can
-- already double a body's strength on its own. Twenty of it from one servant
-- was two thirds of that, and it would have made Hei Lou Lan, Chu Du and the
-- two Strength Venerables strictly the best things on the wheel - not because
-- anybody decided Strength should be the best, but because the column they
-- read was the only one nobody had checked against a ceiling.
--
-- Rescaled to about a tenth of the Sinew ceiling at the top, which puts a
-- Strength servant beside a Health one instead of above everything. Three
-- points at five stars is still real: it is what a good pair of boots pays
-- after 0407, and it multiplies by the realm climb before it is rounded.
--
-- The column becomes NUMERIC because the useful range is now under two and an
-- integer cannot hold a tier ladder inside that. Fractions are not lost:
-- `apply_physique_xp` adds this to a NUMERIC base and multiplies by the realm
-- before rounding, so a tenth of a point is a real number of strength to a
-- rank 18 immortal.
--
-- AND THE CHECK THAT WOULD HAVE CAUGHT IT. The probe now asserts that no
-- bonus, at the best tier and the best star, is worth more than
-- `servant_bonus_ceiling_share` of the effect it feeds. The old value fails
-- it by a factor of four. Anybody adding a tier or a bonus kind later gets
-- told, rather than finding out the way this was found out.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_bonus_ceiling_share', 0.15,
     'The most of an effect''s own ceiling that a single servant may be worth, at the best tier and the highest star. A fence around the flat/share mistake that 0418 had to undo: a bonus measured in different units from its neighbours is a bonus nobody can eyeball.');


ALTER TABLE servant_tiers
    ALTER COLUMN flat_bonus TYPE NUMERIC USING flat_bonus::numeric;

UPDATE servant_tiers SET flat_bonus = v.flat
FROM (VALUES
    (1, 0.10),
    (2, 0.25),
    (3, 0.40),
    (4, 0.50),
    (5, 0.75),
    (6, 1.10),
    (7, 1.50)
) AS v (tier, flat)
WHERE servant_tiers.tier = v.tier;

COMMENT ON COLUMN servant_tiers.flat_bonus IS
    'What a Strength servant of this tier grants in Sinew POINTS, since Sinew is not a share. Scaled in 0418 to about a tenth of the Sinew ceiling at five stars, which is where every other bonus sits against its own.';


-- ---------------------------------------------------------------------------
-- No bonus is worth more of its ceiling than the others are of theirs
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_share NUMERIC := game_config_value('servant_bonus_ceiling_share');
    r       RECORD;
BEGIN
    SELECT string_agg(
        format('%s takes %s of %s', x.bonus, round(x.share, 3), x.feeds), ', ')
    INTO v_bad
    FROM (
        SELECT b.name AS bonus, ef.name AS feeds,
               (CASE WHEN b.is_flat   THEN t.flat_bonus
                     WHEN b.is_strike THEN t.strike_bonus
                     ELSE t.pct_bonus END
                * servant_star_scale(
                    game_config_value('servant_max_stars')::smallint))
               / ef.cap AS share
        FROM servant_bonuses b
        JOIN gu_effects ef ON ef.code = b.effect_code
        JOIN servant_tiers t ON t.tier = (SELECT max(tier) FROM servant_tiers)
    ) x
    WHERE x.share > v_share;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these are worth more of their ceiling than a servant may be: %',
            v_bad;
    END IF;

    -- And the ladder still climbs, or the tiers stop meaning anything.
    IF EXISTS (
        SELECT 1 FROM servant_tiers a
        JOIN servant_tiers b ON b.tier = a.tier + 1
        WHERE b.flat_bonus <= a.flat_bonus
    ) THEN
        RAISE EXCEPTION 'the Strength ladder does not climb with the tier';
    END IF;

    FOR r IN
        SELECT b.name AS bonus, ef.name AS feeds, ef.cap,
               round(CASE WHEN b.is_flat   THEN t.flat_bonus
                          WHEN b.is_strike THEN t.strike_bonus
                          ELSE t.pct_bonus END
                     * servant_star_scale(5::smallint), 4) AS best,
               round(100 * (CASE WHEN b.is_flat   THEN t.flat_bonus
                                 WHEN b.is_strike THEN t.strike_bonus
                                 ELSE t.pct_bonus END
                            * servant_star_scale(5::smallint)) / ef.cap, 1)
                 AS pct_of_ceiling
        FROM servant_bonuses b
        JOIN gu_effects ef ON ef.code = b.effect_code
        JOIN servant_tiers t ON t.tier = 7
        ORDER BY 5 DESC
    LOOP
        RAISE NOTICE '% -> % : five-star Venerable gives % (% of the ceiling)',
            rpad(r.bonus, 14), rpad(r.feeds, 20), r.best, r.pct_of_ceiling;
    END LOOP;
END;
$probe$;
