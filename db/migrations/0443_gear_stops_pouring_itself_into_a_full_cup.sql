-- 0443_gear_stops_pouring_itself_into_a_full_cup
--
-- The gear update gave a piece a Rank and a Quality and so up to 3.45x the
-- budget it used to carry - 2.30 for five stars times 1.50 for a flawless
-- forging. Then it poured that budget into the same fourteen effects, and
-- thirteen of the fourteen are hard-capped fractions. Gear got a bigger
-- bucket and the cup it pours into did not change size.
--
-- MEASURED, WITH EVERY PIECE OF GEAR IN THE GAME ALREADY DELETED - so these
-- are Gu, physique and destiny alone, before a single forged piece is worn:
--
--     attack_power      cap 2.00   3 of the 4 deepest already AT it (raw 2.96)
--     crit_rate         cap 0.60   2 of 4 at it
--     lifesteal         cap 0.40   2 of 4 at it
--     armor_pen, damage_reduction, dodge, multi_hit, gathering_yield: 1 of 4
--
-- A freshly forged piece rolling attack_power gives the top three cultivators
-- in the game exactly nothing. Not a little - nothing. That is the answer to
-- "does the update make gear stronger": the budget, yes; what arrives, no.
--
-- THIS CONVERTS THE TWO THAT MATTER MOST. `attack_power` (427 grants) becomes
-- `base_strength` and `damage_reduction` (165) becomes `base_defense`, on the
-- same 0433 pattern that retired `max_hp` into `base_hp`. A base stat is
-- multiplied by the wearer's realm and has a ceiling eight times the naked
-- body rather than one, so it keeps paying at every rank instead of filling
-- up and stopping.
--
-- AND BOTH DESTINATIONS ARE REAL, which was checked rather than assumed:
--
--   base_strength reaches damage through `thews` in compute_technique_damage,
--     which is added to the technique's own power before everything else
--     multiplies it.
--   base_defense reaches mitigation through compute_creature_damage's
--     divisor - raw * dscale / (dscale + defence) - and `dscale` itself climbs
--     with the ATTACKER's rank. So defence keeps pace with what is hitting
--     you, forever, where a 0.75 fraction simply stops.
--
-- THE SHAPE OF THE CHANGE, because it is not a rename. attack_power was a
-- MULTIPLIER on the whole attack and base_strength is an ADDITION to one term
-- of it; damage_reduction was a fraction of the blow and base_defense is a
-- divisor. So nobody's numbers survive untouched and this migration does not
-- pretend otherwise. What it promises is narrower and checkable: NOBODY GETS
-- WEAKER. Every cultivator is measured before and after and the ledger tops
-- up anyone the conversion would have cost, while anyone it makes stronger
-- keeps it - that gain is the entire point of the exercise.
--
-- THE RATES are the naked body, the same rule max_hp took: 1.00 attack_power
-- becomes 30 base_strength because 30 is what a body has before gear, and
-- 1.00 damage_reduction becomes 20 base_defense for the same reason.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What everybody is, before any of it moves
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
SELECT '0443', pp.player_id, pp.max_hp, pp.current_hp, pp.strength, pp.defense
FROM player_physique pp;


-- ---------------------------------------------------------------------------
-- The two cups get bigger, and learn what a point of them is
-- ---------------------------------------------------------------------------

UPDATE gu_effects SET cap = 240, unit_scale = 30, step = 0.90, description =
    'Sinew before your realm multiplies it. Its own ceiling, apart from Attack Power. Raised from 30 to 240 in 0443 - eight times the naked body rather than one - when attack_power retired into it and its 2.00 ceiling stopped being where a cultivator''s strength ended.'
WHERE code = 'base_strength';

UPDATE gu_effects SET cap = 160, unit_scale = 20, step = 0.30, description =
    'Hide before your realm multiplies it. Reaches a blow through the defence divisor, whose scale climbs with the rank of whatever is swinging - so it keeps pace instead of stopping at a fraction. Raised from 20 to 160 in 0443.'
WHERE code = 'base_defense';


-- ---------------------------------------------------------------------------
-- 592 grants change currency
-- ---------------------------------------------------------------------------

-- The grants carry the rate. The GENERATORS - forge shares, ore signatures,
-- servant tiers - carry only the effect code, because `unit_scale` is what
-- turns a shared proportion into this effect's units and it was put on the
-- effect in 0434 for exactly this.

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT e.gu_type_id, 'base_strength', e.magnitude * 30
FROM gu_type_effects e WHERE e.effect_code = 'attack_power'
ON CONFLICT (gu_type_id, effect_code)
DO UPDATE SET magnitude = gu_type_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM gu_type_effects WHERE effect_code = 'attack_power';

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT e.gu_type_id, 'base_defense', e.magnitude * 20
FROM gu_type_effects e WHERE e.effect_code = 'damage_reduction'
ON CONFLICT (gu_type_id, effect_code)
DO UPDATE SET magnitude = gu_type_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM gu_type_effects WHERE effect_code = 'damage_reduction';

-- Equipment too. 0437 wiped every piece in the world, but the test suite
-- forges against this same database and a handful have been made since - so
-- "gear is empty" is a fact with a shelf life, and the migration checks
-- rather than assumes. The first run of this one asserted the retired pair
-- was gone and found it here.
INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
SELECT e.equipment_id, 'base_strength', e.magnitude * 30
FROM equipment_effects e WHERE e.effect_code = 'attack_power'
ON CONFLICT ON CONSTRAINT equipment_effects_pkey
DO UPDATE SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM equipment_effects WHERE effect_code = 'attack_power';

INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
SELECT e.equipment_id, 'base_defense', e.magnitude * 20
FROM equipment_effects e WHERE e.effect_code = 'damage_reduction'
ON CONFLICT ON CONSTRAINT equipment_effects_pkey
DO UPDATE SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM equipment_effects WHERE effect_code = 'damage_reduction';

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT e.physique_id, 'base_strength', e.magnitude * 30
FROM physique_effects e WHERE e.effect_code = 'attack_power'
ON CONFLICT (physique_id, effect_code)
DO UPDATE SET magnitude = physique_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM physique_effects WHERE effect_code = 'attack_power';

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT e.physique_id, 'base_defense', e.magnitude * 20
FROM physique_effects e WHERE e.effect_code = 'damage_reduction'
ON CONFLICT (physique_id, effect_code)
DO UPDATE SET magnitude = physique_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM physique_effects WHERE effect_code = 'damage_reduction';

INSERT INTO destiny_effects (code, effect_code, magnitude)
SELECT e.code, 'base_strength', e.magnitude * 30
FROM destiny_effects e WHERE e.effect_code = 'attack_power'
ON CONFLICT (code, effect_code)
DO UPDATE SET magnitude = destiny_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM destiny_effects WHERE effect_code = 'attack_power';

INSERT INTO destiny_effects (code, effect_code, magnitude)
SELECT e.code, 'base_defense', e.magnitude * 20
FROM destiny_effects e WHERE e.effect_code = 'damage_reduction'
ON CONFLICT (code, effect_code)
DO UPDATE SET magnitude = destiny_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM destiny_effects WHERE effect_code = 'damage_reduction';

INSERT INTO root_effects (root_code, effect_code, magnitude)
SELECT e.root_code, 'base_strength', e.magnitude * 30
FROM root_effects e WHERE e.effect_code = 'attack_power'
ON CONFLICT (root_code, effect_code)
DO UPDATE SET magnitude = root_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM root_effects WHERE effect_code = 'attack_power';

INSERT INTO root_effects (root_code, effect_code, magnitude)
SELECT e.root_code, 'base_defense', e.magnitude * 20
FROM root_effects e WHERE e.effect_code = 'damage_reduction'
ON CONFLICT (root_code, effect_code)
DO UPDATE SET magnitude = root_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM root_effects WHERE effect_code = 'damage_reduction';

-- The generators. Shares stay shares; `unit_scale` gives them their size.
UPDATE part_effects SET effect_code = 'base_strength' WHERE effect_code = 'attack_power';
UPDATE part_effects SET effect_code = 'base_defense'  WHERE effect_code = 'damage_reduction';
UPDATE slot_effects SET effect_code = 'base_strength' WHERE effect_code = 'attack_power';
UPDATE slot_effects SET effect_code = 'base_defense'  WHERE effect_code = 'damage_reduction';
UPDATE ores         SET signature   = 'base_strength' WHERE signature   = 'attack_power';
UPDATE ores         SET signature   = 'base_defense'  WHERE signature   = 'damage_reduction';
UPDATE forge_reactions SET effect_code = 'base_strength' WHERE effect_code = 'attack_power';
UPDATE forge_reactions SET effect_code = 'base_defense'  WHERE effect_code = 'damage_reduction';


-- ---------------------------------------------------------------------------
-- And the two readers stop asking for what nothing grants
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'player_external_multiplier'
      AND pronamespace = 'public'::regnamespace;

    anchor := '    + player_stat(p_player_id, ''attack_power'');';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the attack multiplier no longer reads attack_power where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- attack_power left this stack in 0443. It became base_strength, which', chr(10),
'    -- reaches damage through `thews` instead - added to the technique''s own', chr(10),
'    -- power rather than multiplying the whole of it, and with a ceiling that', chr(10),
'    -- is eight times the naked body rather than a flat 2.00.', chr(10),
'    + 0;'));
END;
$patch$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'player_take' AND pronamespace = 'public'::regnamespace;

    anchor := '    reduce := player_stat(p_player_id, ''damage_reduction'');';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'player_take no longer reads damage_reduction where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- damage_reduction left this line in 0443 and became base_defense, which', chr(10),
'    -- is read by the defence DIVISOR in compute_creature_damage instead. The', chr(10),
'    -- divisor''s scale climbs with the rank of whatever is swinging, so hide', chr(10),
'    -- keeps pace with the world; a fraction capped at 0.75 did not. `reduce`', chr(10),
'    -- still carries Braced and a fight''s own defence_up below.', chr(10),
'    reduce := 0;'));
END;
$patch$;


UPDATE gu_effects SET is_live = FALSE, description =
    'Retired in 0443 into base_strength. It was a multiplier on the whole attack with a ceiling of 2.00, and three of the four deepest cultivators sat on that ceiling with no gear on at all.'
WHERE code = 'attack_power';

UPDATE gu_effects SET is_live = FALSE, description =
    'Retired in 0443 into base_defense, which reaches a blow through the defence divisor rather than as a fraction of it, and so keeps pace with the rank of whatever is swinging.'
WHERE code = 'damage_reduction';


-- ---------------------------------------------------------------------------
-- Nobody is weaker, and the ledger says so rather than hoping
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

    -- Only ever a top-up. A cultivator the conversion made stronger keeps it -
    -- that is the point of the migration - and one it would have cost is put
    -- back where they stood.
    FOR r IN
        SELECT s.player_id, s.strength AS want_str, s.defense AS want_def
        FROM stat_conversion_snapshot s WHERE s.migration = '0443'
    LOOP
        SELECT pp.strength INTO got FROM player_physique pp
        WHERE pp.player_id = r.player_id;
        IF got IS NOT NULL AND got > 0 AND r.want_str > got THEN
            base_now := game_config_value('physique_base_strength')
                      + player_stat(r.player_id, 'base_strength')
                      + legacy_stat(r.player_id, 'base_strength');
            adjust := base_now * (r.want_str::numeric / got::numeric - 1);
            INSERT INTO player_legacy_stats
                (player_id, effect_code, magnitude, reason)
            VALUES (r.player_id, 'base_strength',
                    round(legacy_stat(r.player_id, 'base_strength') + adjust, 12),
                    'attack_power became base_strength in 0443; holds this cultivator at the strength they had')
            ON CONFLICT (player_id, effect_code)
            DO UPDATE SET magnitude = EXCLUDED.magnitude, reason = EXCLUDED.reason;
        END IF;

        SELECT pp.defense INTO got FROM player_physique pp
        WHERE pp.player_id = r.player_id;
        IF got IS NOT NULL AND got > 0 AND r.want_def > got THEN
            base_now := game_config_value('physique_base_defense')
                      + player_stat(r.player_id, 'base_defense')
                      + legacy_stat(r.player_id, 'base_defense');
            adjust := base_now * (r.want_def::numeric / got::numeric - 1);
            INSERT INTO player_legacy_stats
                (player_id, effect_code, magnitude, reason)
            VALUES (r.player_id, 'base_defense',
                    round(legacy_stat(r.player_id, 'base_defense') + adjust, 12),
                    'damage_reduction became base_defense in 0443; holds this cultivator at the hide they had')
            ON CONFLICT (player_id, effect_code)
            DO UPDATE SET magnitude = EXCLUDED.magnitude, reason = EXCLUDED.reason;
        END IF;
    END LOOP;

    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;
END;
$settle$;


DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- The promise: nobody weaker.
    SELECT string_agg(format('%s %s->%s', p.discord_name, s.strength, pp.strength), ', ')
    INTO v_bad
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0443' AND p.deleted_at IS NULL
      AND pp.strength < s.strength - 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lost sinew: %', v_bad;
    END IF;

    SELECT string_agg(format('%s %s->%s', p.discord_name, s.defense, pp.defense), ', ')
    INTO v_bad
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0443' AND p.deleted_at IS NULL
      AND pp.defense < s.defense - 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lost hide: %', v_bad;
    END IF;

    -- Nothing still grants or mints the retired pair.
    SELECT string_agg(x.src, ', ') INTO v_bad FROM (
        SELECT 'gu' AS src WHERE EXISTS (SELECT 1 FROM gu_type_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'equipment' WHERE EXISTS (SELECT 1 FROM equipment_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'physique' WHERE EXISTS (SELECT 1 FROM physique_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'destiny' WHERE EXISTS (SELECT 1 FROM destiny_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'root' WHERE EXISTS (SELECT 1 FROM root_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'part' WHERE EXISTS (SELECT 1 FROM part_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'slot' WHERE EXISTS (SELECT 1 FROM slot_effects WHERE effect_code IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'ore' WHERE EXISTS (SELECT 1 FROM ores WHERE signature IN ('attack_power','damage_reduction'))
        UNION ALL SELECT 'reaction' WHERE EXISTS (SELECT 1 FROM forge_reactions WHERE effect_code IN ('attack_power','damage_reduction'))
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still deal in the retired pair: %', v_bad;
    END IF;

    -- And every live effect still has a Gu behind it.
    SELECT string_agg(f.code, ', ') INTO v_bad
    FROM gu_effects f WHERE f.is_live
      AND NOT EXISTS (SELECT 1 FROM gu_type_effects e WHERE e.effect_code = f.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are live with no Gu behind them: %', v_bad;
    END IF;

    FOR r IN
        SELECT p.discord_name, s.strength AS was_str, pp.strength AS now_str,
               s.defense AS was_def, pp.defense AS now_def
        FROM stat_conversion_snapshot s
        JOIN player_physique pp ON pp.player_id = s.player_id
        JOIN players p ON p.player_id = s.player_id
        WHERE s.migration = '0443' AND p.deleted_at IS NULL
        ORDER BY pp.strength DESC LIMIT 6
    LOOP
        RAISE NOTICE '% sinew % -> %  hide % -> %',
            rpad(r.discord_name, 16), r.was_str, r.now_str, r.was_def, r.now_def;
    END LOOP;
END;
$probe$;
