-- 0436_a_penalty_that_introduces_itself_as_a_bonus
--
-- Hollow Victory reads "Body +-12".
--
-- `effect_amount` writes the sign itself on the base-stat branch and lets the
-- number write its own on the percentage branch:
--
--     WHEN f.is_base THEN '+' || round(p_magnitude)::text
--     ELSE round(100 * p_magnitude)::text || '%'
--
-- A negative percentage comes out "-5%" because the minus is already in the
-- number. A negative base stat comes out "+-12" because the plus is bolted on
-- in front of it. The branch that hardcodes a sign is the branch that cannot
-- cope with the other one.
--
-- It has been latent since the function was written and only surfaced now,
-- because until 0433 no base stat was ever negative: the three `base_` effects
-- were granted by Gu and gear, which only ever add. Hollow Victory carried
-- `max_hp -0.1000`, a percentage, and 0433 turned that into `base_hp -12`.
-- The conversion did not create the fault, it walked a value into the one
-- branch that could not print it.
--
-- WORTH FIXING NOW RATHER THAN WHEN IT SPREADS. One grant in the game is a
-- negative base stat today. Two more are negative `damage_reduction`
-- - Heaven's Scorn at -0.05 and Heaven's Grudge at -0.08 - and those become
-- negative `base_defense` as soon as that conversion lands, which is the next
-- step of the same programme. This is cheaper to fix while it is one row.
--
-- The sign now comes from the number in both branches. `to_char` is not used
-- for it: 'SG9999' would pad, and a signed zero is not wanted either - an
-- effect worth nothing should read "+0" rather than "-0", which the CASE
-- gives for free by testing for less-than.
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
    -- since 0436: '+' || '-12' is "+-12", which is how Hollow Victory spent
    -- its life introducing a penalty as a bonus.
    SELECT CASE
        WHEN f.is_base AND round(p_magnitude) < 0
            THEN round(p_magnitude)::text
        WHEN f.is_base
            THEN '+' || round(p_magnitude)::text
        ELSE round(100 * p_magnitude)::text || '%'
    END
    FROM gu_effects f WHERE f.code = p_effect;
$fn$;

COMMENT ON FUNCTION effect_amount(text, numeric) IS
    'What an effect gives, in the unit that effect is measured in and with one sign. Base stats are points and everything else is a fraction; a negative of either reads as a negative rather than as "+-12".';


-- ---------------------------------------------------------------------------
-- One sign, whichever branch and whichever direction
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- The reported line, first and by name.
    IF effect_amount('base_hp', -12) <> '-12' THEN
        RAISE EXCEPTION 'Hollow Victory still reads %',
            effect_amount('base_hp', -12);
    END IF;

    -- And the shape of it, asked of both branches in both directions rather
    -- than of the one row that happened to be reported.
    IF effect_amount('base_hp', 12)        <> '+12'  THEN RAISE EXCEPTION 'a base gain lost its plus'; END IF;
    IF effect_amount('base_hp', 0)         <> '+0'   THEN RAISE EXCEPTION 'nothing should read +0, got %', effect_amount('base_hp', 0); END IF;
    IF effect_amount('crit_damage', 0.45)  <> '45%'  THEN RAISE EXCEPTION 'a percentage gained a sign'; END IF;
    IF effect_amount('crit_damage', -0.05) <> '-5%'  THEN RAISE EXCEPTION 'a percentage lost its minus'; END IF;

    -- Nothing anywhere in the game prints two signs in a row. Asked of every
    -- real grant rather than of a number chosen to pass.
    SELECT string_agg(format('%s %s -> %s', x.src, x.effect_code, x.said), ', ')
    INTO v_bad
    FROM (
        SELECT 'destiny' AS src, de.effect_code,
               effect_amount(de.effect_code, de.magnitude) AS said
        FROM destiny_effects de
        UNION ALL
        SELECT 'gu', g.effect_code, effect_amount(g.effect_code, g.magnitude)
        FROM gu_type_effects g
        UNION ALL
        SELECT 'physique', p.effect_code, effect_amount(p.effect_code, p.magnitude)
        FROM physique_effects p
        UNION ALL
        SELECT 'root', ro.effect_code, effect_amount(ro.effect_code, ro.magnitude)
        FROM root_effects ro
        UNION ALL
        SELECT 'equipment', ee.effect_code,
               effect_amount(ee.effect_code, ee.magnitude)
        FROM equipment_effects ee
    ) x
    WHERE x.said LIKE '+-%' OR x.said LIKE '-+%' OR x.said LIKE '++%';

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these print two signs: %', v_bad;
    END IF;

    FOR r IN
        SELECT d.name, de.effect_code,
               effect_amount(de.effect_code, de.magnitude) AS said
        FROM destiny_effects de
        JOIN destinies d ON d.code = de.code
        WHERE de.magnitude < 0
        ORDER BY d.name, de.effect_code
    LOOP
        RAISE NOTICE 'every penalty in the game: % : % %',
            rpad(r.name, 18), rpad(r.effect_code, 18), r.said;
    END LOOP;
END;
$probe$;
