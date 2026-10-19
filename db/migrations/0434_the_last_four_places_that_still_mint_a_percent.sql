-- 0434_the_last_four_places_that_still_mint_a_percent
--
-- 0433 moved 335 max_hp GRANTS onto base_hp and left the four places that
-- MINT them alone, on the grounds that a generator is a different job from a
-- grant. That was true and it was still the wrong place to stop: the test
-- suite refused it, and it was right to.
--
--     test_no_live_effect_goes_unspoken   max_hp is live and no Gu grants it
--     test_a_rarer_body_is_worth_more     base_hp 25.2 on a body allowed 0.28
--
-- Both are the same fault seen from two sides. A currency half converted is
-- worse than either currency: `max_hp` still had a forge rolling it, a
-- servant handing it out and a row on the stat sheet, while no Gu in the game
-- could produce one. This finishes it.
--
-- THE UNIT SCALE, which is the idea this migration turns on. `base_hp` is
-- counted in HP POINTS and every other effect in the table is counted as a
-- FRACTION. Three separate places hold a number that has to be read in one of
-- those two units - the forge's shares, the servant tiers, and a physique's
-- budget step - and none of them can simply be multiplied, because each is
-- shared with effects that are still fractions:
--
--     part_effects.share  CHECK (share > 0 AND share <= 1)
--     slot_effects.share  CHECK (share > 0 AND share <= 1)
--     servant_tiers       pct_bonus is shared with Strength and Cultivation
--
-- The first draft of this migration tried to scale the shares by 120 and was
-- refused by that constraint, which was right to refuse it: a share is a
-- PROPORTION OF A BUDGET, and a proportion above one is not a large share, it
-- is a category error. So the scale moves to where it belongs - onto the
-- effect itself, as `gu_effects.unit_scale`, read by everything that turns one
-- of these shared numbers into a magnitude. One definition, and a share stays
-- a share.
--
-- THE STEP is the same fact seen in the physique budget. `gu_effects.step` is
-- denominated for a percent - 0.03 means three percent - and `base_hp`
-- inherited 0.02 from back when nothing granted it. 0433 began granting it in
-- points, so three bodies instantly read as worth more than their tier allows.
-- It becomes 3.60: max_hp's own 0.03 through the same 120x, because the budget
-- and the grants have to agree or the budget stops meaning anything.
--
-- NOBODY MOVES. Same promise and same method as 0433: a fresh snapshot, the
-- conversion, then a probe that refuses the migration if any live body's
-- maximum has changed by more than a point of rounding.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What everybody is, before the last four places change
-- ---------------------------------------------------------------------------

DO $fresh$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;
END;
$fresh$;

INSERT INTO stat_conversion_snapshot
    (migration, player_id, max_hp, current_hp, strength, defense)
SELECT '0434', pp.player_id, pp.max_hp, pp.current_hp, pp.strength, pp.defense
FROM player_physique pp;


-- ---------------------------------------------------------------------------
-- An effect says what one point of it is worth
-- ---------------------------------------------------------------------------

ALTER TABLE gu_effects
    ADD COLUMN unit_scale NUMERIC(12,4) NOT NULL DEFAULT 1;

COMMENT ON COLUMN gu_effects.unit_scale IS
    'What one point of a SHARED number - a forge share, a servant tier - is worth in this effect''s own units. Fractions carry 1. base_hp carries 120 because it is counted in HP points, and the numbers it is minted from are shared with effects that are still fractions and so cannot be rescaled for it.';

UPDATE gu_effects SET unit_scale = 120 WHERE code = 'base_hp';

UPDATE gu_effects SET step = 3.60 WHERE code = 'base_hp';


-- ---------------------------------------------------------------------------
-- Wider columns, because a point of flesh is not a fraction
-- ---------------------------------------------------------------------------

-- Three views read these and Postgres will not widen a column out from under
-- one, so they are lifted, the column is changed, and they are put back from
-- their own definitions - the same rule the functions follow. Captured rather
-- than retyped, so this cannot quietly rewrite a view on its way past.
DO $widen$
DECLARE
    defs  JSONB := '{}'::jsonb;
    r     RECORD;
    v     TEXT;
    views TEXT[] := ARRAY['auction_board', 'player_equipment_stats',
                          'player_gu_stats'];
BEGIN
    FOR r IN
        SELECT c.relname, pg_get_viewdef(c.oid, true) AS def
        FROM pg_class c
        WHERE c.relkind = 'v' AND c.relname = ANY (views)
          AND c.relnamespace = 'public'::regnamespace
    LOOP
        defs := defs || jsonb_build_object(r.relname, r.def);
    END LOOP;

    IF (SELECT count(*) FROM jsonb_object_keys(defs)) <> array_length(views, 1) THEN
        RAISE EXCEPTION 'expected % dependent views and captured %',
            array_length(views, 1), (SELECT count(*) FROM jsonb_object_keys(defs));
    END IF;

    FOREACH v IN ARRAY views LOOP
        EXECUTE format('DROP VIEW %I', v);
    END LOOP;

    EXECUTE 'ALTER TABLE gu_type_effects   ALTER COLUMN magnitude TYPE NUMERIC(12,4)';
    EXECUTE 'ALTER TABLE equipment_effects ALTER COLUMN magnitude TYPE NUMERIC(12,4)';
    EXECUTE 'ALTER TABLE physique_effects  ALTER COLUMN magnitude TYPE NUMERIC(12,4)';
    EXECUTE 'ALTER TABLE destiny_effects   ALTER COLUMN magnitude TYPE NUMERIC(12,4)';
    EXECUTE 'ALTER TABLE root_effects      ALTER COLUMN magnitude TYPE NUMERIC(12,4)';

    FOREACH v IN ARRAY views LOOP
        EXECUTE format('CREATE VIEW %I AS %s', v, defs->>v);
    END LOOP;

    FOREACH v IN ARRAY views LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relkind = 'v'
                       AND c.relname = v
                       AND c.relnamespace = 'public'::regnamespace) THEN
            RAISE EXCEPTION 'view % was dropped and not restored', v;
        END IF;
    END LOOP;
END;
$widen$;


-- ---------------------------------------------------------------------------
-- The forge mints flesh instead of a fraction
-- ---------------------------------------------------------------------------

-- Only the effect code moves. The share stays exactly what it was, because it
-- is a proportion of the forge's budget and always was.

INSERT INTO part_effects (part, effect_code, share)
SELECT e.part, 'base_hp', e.share
FROM part_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT (part, effect_code)
DO UPDATE SET share = part_effects.share + EXCLUDED.share;
DELETE FROM part_effects WHERE effect_code = 'max_hp';

INSERT INTO slot_effects (slot, effect_code, share)
SELECT e.slot, 'base_hp', e.share
FROM slot_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT (slot, effect_code)
DO UPDATE SET share = slot_effects.share + EXCLUDED.share;
DELETE FROM slot_effects WHERE effect_code = 'max_hp';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    after  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'forge' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'forge is missing';
    END IF;

    anchor := concat(
'           round(sum(c.magnitude), 4)', chr(10),
'    FROM (');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer sums its effect magnitudes where it did';
    END IF;
    after := replace(body, anchor, concat(
'           -- In the effect''s own units since 0434. A share is a proportion', chr(10),
'           -- of the budget and stays one; what a proportion is WORTH is a', chr(10),
'           -- fact about the effect, and so lives on the effect.', chr(10),
'           round(sum(c.magnitude) * COALESCE(ef.unit_scale, 1), 4)', chr(10),
'    FROM ('));

    anchor := concat(
'    GROUP BY c.effect_code, ef.cap', chr(10),
'    HAVING round(sum(c.magnitude), 4) > 0');
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge no longer groups its effects where it did';
    END IF;
    after := replace(after, anchor, concat(
'    GROUP BY c.effect_code, ef.cap, ef.unit_scale', chr(10),
'    HAVING round(sum(c.magnitude) * COALESCE(ef.unit_scale, 1), 4) > 0'));

    EXECUTE after;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A servant hands over the same units
-- ---------------------------------------------------------------------------

UPDATE servant_bonuses SET effect_code = 'base_hp'
WHERE kind = 'health' AND effect_code = 'max_hp';

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_stat' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_stat is missing';
    END IF;

    anchor := '        END * servant_star_scale(ps.stars)';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_stat no longer scales by stars where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        END * servant_star_scale(ps.stars)', chr(10),
'          -- And in the effect''s own units since 0434. The tier numbers are', chr(10),
'          -- shared with every other kind of servant, so a Health servant', chr(10),
'          -- cannot be paid by rescaling them.', chr(10),
'          * COALESCE((SELECT ef.unit_scale FROM gu_effects ef', chr(10),
'                      WHERE ef.code = p_effect), 1)'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the body stops asking after an effect nothing grants
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'apply_physique_xp' AND pronamespace = 'public'::regnamespace;

    anchor := concat(
'    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0)', chr(10),
'                + COALESCE(path_hp, 0) + player_stat(p_player_id, ''max_hp'')', chr(10),
'                + foundation_bonus(p_player_id, ''hp'');');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer builds the HP multiplier where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- max_hp left this sum in 0434. Every grant of it became base_hp, which', chr(10),
'    -- is added to the BASE below rather than to this multiplier - and that', chr(10),
'    -- move is the whole point, since the base is what the realm multiplies.', chr(10),
'    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0)', chr(10),
'                + COALESCE(path_hp, 0)', chr(10),
'                + foundation_bonus(p_player_id, ''hp'');'));
END;
$patch$;


UPDATE gu_effects SET is_live = FALSE, description =
    'Retired in 0434. Every grant became base_hp, which the realm multiplies instead of the HP multiplier absorbing it. Kept as a row rather than deleted because 174 pieces of equipment, 155 Gu and the forge all referenced it, and a code that has been in the world should stay readable.'
WHERE code = 'max_hp';


-- ---------------------------------------------------------------------------
-- Everybody is put back exactly where they were
-- ---------------------------------------------------------------------------

DO $settle$
DECLARE
    r        RECORD;
    base_now NUMERIC;
    got      BIGINT;
    adjust   NUMERIC;
BEGIN
    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;

    FOR r IN
        SELECT s.player_id, s.max_hp AS want_hp
        FROM stat_conversion_snapshot s
        WHERE s.migration = '0434' AND s.max_hp IS NOT NULL AND s.max_hp > 0
    LOOP
        SELECT pp.max_hp INTO got FROM player_physique pp
        WHERE pp.player_id = r.player_id;
        CONTINUE WHEN got IS NULL OR got = 0;

        base_now := game_config_value('physique_base_hp')
                  + player_stat(r.player_id, 'base_hp')
                  + legacy_stat(r.player_id, 'base_hp');
        adjust   := base_now * (r.want_hp::numeric / got::numeric - 1);

        IF round(adjust, 12) <> 0 THEN
            INSERT INTO player_legacy_stats
                (player_id, effect_code, magnitude, reason)
            VALUES (r.player_id, 'base_hp',
                    round(legacy_stat(r.player_id, 'base_hp') + adjust, 12),
                    'max_hp fully retired in 0434; holds this cultivator where 0433 left them')
            ON CONFLICT (player_id, effect_code)
            DO UPDATE SET magnitude = EXCLUDED.magnitude, reason = EXCLUDED.reason;
        END IF;
    END LOOP;

    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;

    UPDATE player_physique pp
    SET current_hp = LEAST(pp.max_hp, s.current_hp)
    FROM stat_conversion_snapshot s
    WHERE s.migration = '0434' AND s.player_id = pp.player_id
      AND s.current_hp IS NOT NULL;
END;
$settle$;


-- ---------------------------------------------------------------------------
-- The currency is gone, and it took nobody with it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    SELECT string_agg(format('%s: %s -> %s', p.discord_name, s.max_hp, pp.max_hp), ', ')
    INTO v_bad
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0434' AND p.deleted_at IS NULL
      AND abs(pp.max_hp - s.max_hp) > 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators moved: %', v_bad;
    END IF;

    -- Not one place in the game still mints or grants the old currency.
    SELECT string_agg(x.src, ', ') INTO v_bad FROM (
        SELECT 'gu_type_effects' AS src WHERE EXISTS (SELECT 1 FROM gu_type_effects WHERE effect_code='max_hp')
        UNION ALL SELECT 'equipment_effects' WHERE EXISTS (SELECT 1 FROM equipment_effects WHERE effect_code='max_hp')
        UNION ALL SELECT 'physique_effects'  WHERE EXISTS (SELECT 1 FROM physique_effects  WHERE effect_code='max_hp')
        UNION ALL SELECT 'destiny_effects'   WHERE EXISTS (SELECT 1 FROM destiny_effects   WHERE effect_code='max_hp')
        UNION ALL SELECT 'root_effects'      WHERE EXISTS (SELECT 1 FROM root_effects      WHERE effect_code='max_hp')
        UNION ALL SELECT 'part_effects'      WHERE EXISTS (SELECT 1 FROM part_effects      WHERE effect_code='max_hp')
        UNION ALL SELECT 'slot_effects'      WHERE EXISTS (SELECT 1 FROM slot_effects      WHERE effect_code='max_hp')
        UNION ALL SELECT 'servant_bonuses'   WHERE EXISTS (SELECT 1 FROM servant_bonuses   WHERE effect_code='max_hp')
        UNION ALL SELECT 'dwelling_facilities' WHERE EXISTS (SELECT 1 FROM dwelling_facilities WHERE effect_code='max_hp')
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still deal in max_hp: %', v_bad;
    END IF;

    -- And nothing reads it any more either, which is the half that rots.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'apply_physique_xp'
        AND pronamespace = 'public'::regnamespace) LIKE '%''max_hp''%' THEN
        RAISE EXCEPTION 'the body still asks player_stat for max_hp';
    END IF;

    -- The unit scale really is read, by both of the things that mint from a
    -- shared number. A scale nothing consults is a column, not a rule.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'forge'
        AND pronamespace = 'public'::regnamespace) NOT LIKE '%unit_scale%' THEN
        RAISE EXCEPTION 'the forge does not read the unit scale';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'servant_stat'
        AND pronamespace = 'public'::regnamespace) NOT LIKE '%unit_scale%' THEN
        RAISE EXCEPTION 'servant_stat does not read the unit scale';
    END IF;

    -- A share is still a share.
    IF EXISTS (SELECT 1 FROM part_effects WHERE share > 1)
       OR EXISTS (SELECT 1 FROM slot_effects WHERE share > 1) THEN
        RAISE EXCEPTION 'a forge share was scaled past a proportion';
    END IF;

    -- The budget and the grants agree about what a point of flesh is.
    SELECT string_agg(format('%s %s=%s allowed %s', p.code, e.effect_code,
                             e.magnitude, round(ef.step * pw.ranks, 4)), ', ')
    INTO v_bad
    FROM physique_effects e
    JOIN physiques p ON p.physique_id = e.physique_id
    JOIN physique_power pw ON pw.tier = p.tier
    JOIN gu_effects ef ON ef.code = e.effect_code
    WHERE e.magnitude > ef.step * pw.ranks + 0.0001;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a body is worth more than its tier allows: %', v_bad;
    END IF;

    -- Every live effect still has a Gu that can produce it.
    SELECT string_agg(f.code, ', ') INTO v_bad
    FROM gu_effects f
    WHERE f.is_live
      AND NOT EXISTS (SELECT 1 FROM gu_type_effects e WHERE e.effect_code = f.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are live with no Gu behind them: %', v_bad;
    END IF;

    FOR r IN
        SELECT p.discord_name, pp.max_hp,
               round(player_stat(p.player_id, 'base_hp'), 1) AS from_gear,
               round(legacy_stat(p.player_id, 'base_hp'), 1) AS from_ledger
        FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL
        ORDER BY pp.max_hp DESC LIMIT 6
    LOOP
        RAISE NOTICE '  % : %  (gear %, ledger %)',
            rpad(r.discord_name, 18), r.max_hp, r.from_gear, r.from_ledger;
    END LOOP;
END;
$probe$;
