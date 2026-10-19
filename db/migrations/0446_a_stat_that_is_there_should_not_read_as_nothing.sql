-- 0446_a_stat_that_is_there_should_not_read_as_nothing
--
-- A forged helm reads:
--
--     🫀 Body +7
--     🧱 Hide +0
--
-- The Hide is real - 0.4 points of it - and `effect_amount` rounds it to the
-- integer, so it prints as nothing. `percent()` in the bot has had the answer
-- to this since it was written:
--
--     "A non-zero value that would round to 0% is floored to 1% (or -1%)
--      instead, because '+0%' beside a bonus that is genuinely doing
--      something is worse than being one point out."
--
-- Exactly the same argument, and the base-stat branch never got it. It is
-- worse here than it is for a percentage, because a base stat is MULTIPLIED
-- by the wearer's realm before it reaches anything: four tenths of a point of
-- Hide on a developed body is not a rounding error, it is millions of hide.
-- "+0" is the one reading that is definitely wrong.
--
-- Rounds away from zero rather than to the nearest, so a positive that would
-- vanish becomes +1 and a negative that would vanish becomes -1. A stat that
-- is genuinely zero still reads +0, which is correct and which nothing
-- grants anyway - `equipment_effects` only ever gets rows for effects a piece
-- actually has.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION effect_amount(p_effect text, p_magnitude numeric)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    -- A base stat is a count of points and a percentage is a fraction. The
    -- only thing that knows which is the effect itself.
    --
    -- The sign is taken from the number rather than written in front of it,
    -- since 0436. Since 0446 a non-zero magnitude never rounds away: it is
    -- floored to one point in whichever direction it was going, because a
    -- base stat is multiplied by the realm afterwards and "+0" beside
    -- something that is doing real work is the one answer that is certainly
    -- wrong.
    SELECT CASE
        WHEN f.is_base THEN
            CASE
                WHEN p_magnitude > 0 AND round(p_magnitude) = 0 THEN '+1'
                WHEN p_magnitude < 0 AND round(p_magnitude) = 0 THEN '-1'
                WHEN round(p_magnitude) < 0 THEN round(p_magnitude)::text
                ELSE '+' || round(p_magnitude)::text
            END
        ELSE round(100 * p_magnitude)::text || '%'
    END
    FROM gu_effects f WHERE f.code = p_effect;
$fn$;

COMMENT ON FUNCTION effect_amount(text, numeric) IS
    'What an effect gives, in the unit that effect is measured in, with one sign and never rounded away to nothing. Base stats are points and everything else is a fraction.';


-- ---------------------------------------------------------------------------
-- Nothing a piece actually has reads as nothing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
BEGIN
    -- The reported line.
    IF effect_amount('base_defense', 0.4) <> '+1' THEN
        RAISE EXCEPTION 'four tenths of hide still reads %',
            effect_amount('base_defense', 0.4);
    END IF;
    IF effect_amount('base_defense', -0.4) <> '-1' THEN
        RAISE EXCEPTION 'a small penalty still reads %',
            effect_amount('base_defense', -0.4);
    END IF;

    -- And the rest of the shape, unchanged by this.
    IF effect_amount('base_hp', 12)   <> '+12' THEN RAISE EXCEPTION 'a gain lost its plus'; END IF;
    IF effect_amount('base_hp', -12)  <> '-12' THEN RAISE EXCEPTION 'a loss lost its minus'; END IF;
    IF effect_amount('base_hp', 0)    <> '+0'  THEN RAISE EXCEPTION 'a true zero moved'; END IF;
    IF effect_amount('crit_rate', 0.6) <> '60%' THEN RAISE EXCEPTION 'a fraction moved'; END IF;

    -- Asked of every grant in the game: nothing a piece, a Gu or a body
    -- actually carries may print as zero.
    SELECT string_agg(format('%s %s = %s', x.src, x.code, x.said), ', ')
    INTO v_bad
    FROM (
        SELECT 'gu' AS src, effect_code AS code, magnitude,
               effect_amount(effect_code, magnitude) AS said FROM gu_type_effects
        UNION ALL
        SELECT 'equipment', effect_code, magnitude,
               effect_amount(effect_code, magnitude) FROM equipment_effects
        UNION ALL
        SELECT 'physique', effect_code, magnitude,
               effect_amount(effect_code, magnitude) FROM physique_effects
        UNION ALL
        SELECT 'destiny', effect_code, magnitude,
               effect_amount(effect_code, magnitude) FROM destiny_effects
        UNION ALL
        SELECT 'root', effect_code, magnitude,
               effect_amount(effect_code, magnitude) FROM root_effects
    ) x
    WHERE x.magnitude <> 0 AND x.said IN ('+0', '-0', '0%');

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are granted and read as nothing: %', v_bad;
    END IF;
END;
$probe$;
