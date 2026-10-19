-- 0444_the_ninth_place_that_granted_the_retired_pair
--
-- 0443 converted eight sources of `attack_power` and `damage_reduction` and
-- missed the ninth. `dwelling_facilities` is not an effects table like the
-- others - its magnitude lives in `per_level` rather than `magnitude`, so it
-- did not match the shape the other eight were converted with, and its own
-- probe did not look at it either.
--
--     ward_array  Ward Array  damage_reduction  0.0150 a level
--
-- The test suite found it, in the test that exists precisely for this:
--
--     test_every_facility_grants_something_that_exists -> ['ward_array']
--
-- A facility granting a retired effect is a building somebody spent stone on
-- that now does nothing. It is the same fault as a screen reading a renamed
-- column, one table further out - and the reason it survived 0443 is that I
-- enumerated the sources I remembered rather than asking the database which
-- ones there were. The probe below asks.
--
-- Forward-only. Do not edit once applied.


UPDATE dwelling_facilities
SET effect_code = 'base_defense',
    per_level   = per_level * 20,
    description = 'Hide, in points rather than as a share of a blow. Converted in 0444 when damage_reduction retired - at 0.30 a level this is the same shelter it always was, and unlike the fraction it used to grant it keeps pace with whatever is swinging.'
WHERE code = 'ward_array' AND effect_code = 'damage_reduction';

UPDATE dwelling_facilities
SET effect_code = 'base_strength',
    per_level   = per_level * 30
WHERE effect_code = 'attack_power';


-- And a TENTH, which the exhaustive probe below found after this migration
-- was written to fix the ninth. `servant_bonuses` maps a servant's kind to an
-- effect and keeps its magnitude on the tier, so only the code moves - the
-- `unit_scale` 0434 put on the effect is what gives it its size. Two rounds
-- of "the places I remembered" is the argument for asking the schema.
UPDATE servant_bonuses SET effect_code = 'base_strength'
WHERE effect_code = 'attack_power';
UPDATE servant_bonuses SET effect_code = 'base_defense'
WHERE effect_code = 'damage_reduction';


-- ---------------------------------------------------------------------------
-- Asked of the database rather than of my memory
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- Every table in the schema with an effect_code column, checked for the
    -- retired pair. 0443 listed the eight it remembered; this asks which
    -- tables actually exist, so a tenth cannot hide the same way the ninth did.
    FOR r IN
        SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE c.table_schema = 'public'
          AND t.table_type = 'BASE TABLE'
          AND c.column_name IN ('effect_code', 'signature')
        ORDER BY c.table_name
    LOOP
        EXECUTE format(
            'SELECT string_agg(DISTINCT %I, '', '') FROM %I WHERE %I IN (%L, %L)',
            r.column_name, r.table_name, r.column_name,
            'attack_power', 'damage_reduction')
        INTO v_bad;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION
                'table %.% still grants the retired pair: %',
                r.table_name, r.column_name, v_bad;
        END IF;
    END LOOP;

    -- And every facility grants something the game still reads, which is the
    -- test that caught this.
    SELECT string_agg(d.code, ', ') INTO v_bad
    FROM dwelling_facilities d
    JOIN gu_effects e ON e.code = d.effect_code
    WHERE NOT e.is_live;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these facilities grant a retired effect: %', v_bad;
    END IF;

    FOR r IN
        SELECT d.code, d.name, d.effect_code, d.per_level, d.max_level
        FROM dwelling_facilities d
        JOIN gu_effects e ON e.code = d.effect_code
        WHERE e.is_base ORDER BY d.code
    LOOP
        RAISE NOTICE 'facility % grants % % a level, to level %',
            rpad(r.name, 16), r.per_level, r.effect_code, r.max_level;
    END LOOP;
END;
$probe$;
