-- 0433_a_percent_becomes_a_thing_your_realm_multiplies
--
-- THE FIRST STEP of moving this game off percent bonuses and onto base stats
-- that a realm multiplies. It does `max_hp` and nothing else, on purpose:
-- HP is the one of the three where the conversion can be made EXACTLY
-- neutral, so it is the right place to prove the machinery before the two
-- that cannot be (attack_power and damage_reduction both change the SHAPE of
-- a formula, not just which term a number sits in).
--
-- WHY THIS IS WORTH DOING, measured rather than assumed. The percent system
-- has stopped paying the people who use it most. Every effect is capped, and
-- the caps bind hard:
--
--     pashu0        attack_power 4.29 raw against a cap of 2.00
--     m_i_y_u_k_i.  attack_power 4.06, base_hp 218 against a cap of 120
--     ._.visha._.   attack_power 3.60, damage_reduction 1.00 against 0.75
--
-- More than half of pashu0's attack gear does nothing whatsoever. A bonus
-- that is a share of a fixed pool stops being a reward the moment the pool is
-- full, and six cultivators are standing on the lid. A base stat multiplied
-- by the realm has no such lid: it is worth more every rank, forever, which
-- is the whole reason the three `base_` effects were written that way.
--
-- THE MACHINERY IS ALREADY HERE, which is why this is an extension and not an
-- invention. `apply_physique_xp` has always read:
--
--     max_hp = (physique_base_hp + player_stat('base_hp')) * mult * climbed
--
-- where `climbed` is `player_power_multiple` - 2^(rank-1) on cultivation
-- times the same again on the body. `base_hp` is already a flat thing the
-- realm multiplies. `max_hp` is a percent that lands in `mult`. This moves
-- 335 grants from the second to the first.
--
-- NOBODY MOVES, AND IT IS SOLVED RATHER THAN HOPED FOR. A single conversion
-- rate cannot preserve everybody, because what a percent is worth depends on
-- the cultivator wearing it - the rate each of the fourteen affected players
-- would need ranges from 90 to 229. So the grants convert at one clean rate,
-- 120x, which is the naked body itself ("+50% Max HP" becomes "+60 Flesh",
-- exactly what it was worth to a cultivator with nothing else on), and the
-- REMAINDER is written to a per-player ledger that holds each cultivator
-- exactly where they stood. The probe asserts every live max_hp is unchanged.
--
-- THE LEDGER IS NOT A FUDGE, it is the honest name for what it holds: the
-- difference between what somebody earned under the old rules and what the
-- new rules would have given them. It sits outside the cap deliberately,
-- because a cultivator must not lose something they already had to a ceiling
-- that arrived after it.
--
-- THE CAP GOES UP, from 120 to 960 - eight times the naked body rather than
-- one. It has to: 335 grants worth up to 87 points each land in a pool that
-- stopped at 120, and m_i_y_u_k_i. is already 98 points over it. The ledger
-- absorbs that too, so raising the lid changes nobody TODAY; it is what makes
-- the next piece of gear count.
--
-- WHAT THIS DOES NOT DO. `part_effects` and `slot_effects` still roll max_hp
-- as a percent, so newly forged gear keeps arriving in the old currency for
-- now. That is deliberate - they are the GENERATOR rather than a grant, and
-- the forge budget they are shares of is denominated in percent, so
-- converting them means repricing that budget too. `max_hp` therefore stays a
-- live, working effect; nothing reads a dead column. It is the next step, not
-- an oversight.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The ledger: what somebody had, kept across a change to how it is counted
-- ---------------------------------------------------------------------------

CREATE TABLE player_legacy_stats (
    player_id   BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    effect_code TEXT   NOT NULL REFERENCES gu_effects(code) ON DELETE RESTRICT,
    -- Twelve decimals, not four. The realm multiplier reaches 3e8 on a
    -- developed body, so a ledger rounded to 0.0001 lands 30,000 HP away
    -- from where it was aimed - which is exactly what the first run of
    -- this migration did before the probe refused it.
    magnitude   NUMERIC(30,12) NOT NULL,
    reason      TEXT   NOT NULL,
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, effect_code)
);

COMMENT ON TABLE player_legacy_stats IS
    'Per-cultivator adjustments that hold somebody exactly where they stood across a change to how a stat is counted. Read OUTSIDE the effect cap on purpose: a ceiling that arrives after the fact must not take something away that was already earned.';

CREATE INDEX player_legacy_stats_effect_idx ON player_legacy_stats (effect_code);

CREATE OR REPLACE FUNCTION legacy_stat(p_player_id bigint, p_effect text)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE((SELECT l.magnitude FROM player_legacy_stats l
                     WHERE l.player_id = p_player_id
                       AND l.effect_code = p_effect), 0)::numeric;
$fn$;

COMMENT ON FUNCTION legacy_stat(bigint, text) IS
    'The grandfathered part of a stat. Deliberately not inside player_stat, so it is never clipped by the cap that the rest of the sources share.';


-- ---------------------------------------------------------------------------
-- What everybody was, before anything moved
-- ---------------------------------------------------------------------------

CREATE TABLE stat_conversion_snapshot (
    migration  TEXT   NOT NULL,
    player_id  BIGINT NOT NULL,
    max_hp     BIGINT,
    current_hp BIGINT,
    strength   BIGINT,
    defense    BIGINT,
    taken_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (migration, player_id)
);

COMMENT ON TABLE stat_conversion_snapshot IS
    'Kept rather than dropped: it is the evidence that a conversion moved nobody, and the only thing a later migration can check itself against.';

-- Recomputed FIRST, then recorded. `player_physique` holds what was last
-- written, which is not always what the cultivator's gear says today - a
-- manual equipped since their last recompute sits there unfelt. Snapshotting
-- the stale number and then recomputing would report that staleness as drift
-- caused by this migration, which is how the first run of it blamed itself
-- for sylvrime having picked something up.
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
SELECT '0433', pp.player_id, pp.max_hp, pp.current_hp, pp.strength, pp.defense
FROM player_physique pp;


-- ---------------------------------------------------------------------------
-- The body reads the ledger
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'apply_physique_xp' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'apply_physique_xp is missing';
    END IF;

    -- One anchor across all three lines, so there is no way to land half of
    -- this: an EXECUTE that applied to HP and not to sinew would be a silent
    -- difference between two stats that are supposed to work the same way.
    anchor := concat(
'    base_hp  := base_hp  + player_stat(p_player_id, ''base_hp'');', chr(10),
'    base_def := base_def + player_stat(p_player_id, ''base_defense'');', chr(10),
'    base_str := base_str + player_stat(p_player_id, ''base_strength'');');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer adds the base stats where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- Plus the ledger, which is outside the cap since 0433: what somebody', chr(10),
'    -- already had must not be taken by a ceiling that arrived later.', chr(10),
'    base_hp  := base_hp  + player_stat(p_player_id, ''base_hp'')', chr(10),
'                         + legacy_stat(p_player_id, ''base_hp'');', chr(10),
'    base_def := base_def + player_stat(p_player_id, ''base_defense'')', chr(10),
'                         + legacy_stat(p_player_id, ''base_defense'');', chr(10),
'    base_str := base_str + player_stat(p_player_id, ''base_strength'')', chr(10),
'                         + legacy_stat(p_player_id, ''base_strength'');'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The lid comes off
-- ---------------------------------------------------------------------------

UPDATE gu_effects SET cap = 960, description =
    'Flesh on the bone, before your realm multiplies it. Counted apart from Maximum HP, so a body already at that ceiling still grows. Raised from 120 to 960 in 0433 - eight times the naked body rather than one - because the percent grants that used to sit in the multiplier now land here, and m_i_y_u_k_i. was already 98 points over the old lid with it doing nothing.'
WHERE code = 'base_hp';


-- ---------------------------------------------------------------------------
-- 335 grants change currency
-- ---------------------------------------------------------------------------

-- Merge rather than rename, because a Gu or a piece of gear may already carry
-- base_hp of its own and the primary key would refuse a second row. The
-- INSERT ... ON CONFLICT adds to what is there, then the old rows go.

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT e.gu_type_id, 'base_hp', e.magnitude * 120
FROM gu_type_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT (gu_type_id, effect_code)
DO UPDATE SET magnitude = gu_type_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM gu_type_effects WHERE effect_code = 'max_hp';

INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
SELECT e.equipment_id, 'base_hp', e.magnitude * 120
FROM equipment_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT ON CONSTRAINT equipment_effects_pkey
DO UPDATE SET magnitude = equipment_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM equipment_effects WHERE effect_code = 'max_hp';

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT e.physique_id, 'base_hp', e.magnitude * 120
FROM physique_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT (physique_id, effect_code)
DO UPDATE SET magnitude = physique_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM physique_effects WHERE effect_code = 'max_hp';

INSERT INTO destiny_effects (code, effect_code, magnitude)
SELECT e.code, 'base_hp', e.magnitude * 120
FROM destiny_effects e WHERE e.effect_code = 'max_hp'
ON CONFLICT (code, effect_code)
DO UPDATE SET magnitude = destiny_effects.magnitude + EXCLUDED.magnitude;
DELETE FROM destiny_effects WHERE effect_code = 'max_hp';


-- ---------------------------------------------------------------------------
-- Everybody is recomputed, then held exactly where they were
-- ---------------------------------------------------------------------------

DO $settle$
DECLARE
    r        RECORD;
    base_now NUMERIC;
    want     BIGINT;
    got      BIGINT;
    adjust   NUMERIC;
BEGIN
    -- First pass: let the new numbers land.
    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;

    -- Then solve the ledger. max_hp = (base + L) * mult * climbed, and
    -- mult * climbed is simply max_hp / base at L = 0 - so the adjustment
    -- falls out without recomputing a multiplier this migration cannot see:
    --
    --     L = base_now * (wanted / got - 1)
    --
    FOR r IN
        SELECT s.player_id, s.max_hp AS want_hp, s.current_hp AS want_cur
        FROM stat_conversion_snapshot s
        WHERE s.migration = '0433' AND s.max_hp IS NOT NULL AND s.max_hp > 0
    LOOP
        SELECT pp.max_hp INTO got FROM player_physique pp
        WHERE pp.player_id = r.player_id;
        CONTINUE WHEN got IS NULL OR got = 0;

        base_now := game_config_value('physique_base_hp')
                  + player_stat(r.player_id, 'base_hp');
        adjust   := base_now * (r.want_hp::numeric / got::numeric - 1);

        IF round(adjust, 12) <> 0 THEN
            INSERT INTO player_legacy_stats
                (player_id, effect_code, magnitude, reason)
            VALUES (r.player_id, 'base_hp', round(adjust, 12),
                    'max_hp became base_hp in 0433; this is the difference between the flat rate and what they held')
            ON CONFLICT (player_id, effect_code)
            DO UPDATE SET magnitude = EXCLUDED.magnitude, reason = EXCLUDED.reason;
        END IF;
    END LOOP;

    -- Second pass, now with the ledger in hand.
    FOR r IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(r.player_id, 0);
    END LOOP;

    -- And put the health bar back where it was, since apply_physique_xp
    -- carries the SHARE across and a share of a restored maximum can still
    -- round to a neighbouring point.
    UPDATE player_physique pp
    SET current_hp = LEAST(pp.max_hp, s.current_hp)
    FROM stat_conversion_snapshot s
    WHERE s.migration = '0433' AND s.player_id = pp.player_id
      AND s.current_hp IS NOT NULL;
END;
$settle$;


-- ---------------------------------------------------------------------------
-- Not one cultivator is a point heavier or lighter than they were
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_worst NUMERIC;
    r       RECORD;
BEGIN
    -- The whole promise of the migration, asked of every live body.
    SELECT string_agg(format('%s: %s -> %s', p.discord_name, s.max_hp, pp.max_hp),
                      ', ' ORDER BY p.discord_name),
           max(abs(pp.max_hp - s.max_hp))
    INTO v_bad, v_worst
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0433'
      AND p.deleted_at IS NULL
      AND abs(pp.max_hp - s.max_hp) > 1;   -- 1 point of rounding is allowed

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators moved: %', v_bad;
    END IF;

    -- Strength and defence are not in this migration at all and must not have
    -- drifted as a side effect of touching the HP multiplier.
    SELECT string_agg(p.discord_name, ', ') INTO v_bad
    FROM stat_conversion_snapshot s
    JOIN player_physique pp ON pp.player_id = s.player_id
    JOIN players p ON p.player_id = s.player_id
    WHERE s.migration = '0433' AND p.deleted_at IS NULL
      AND (pp.strength <> s.strength OR pp.defense <> s.defense);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'HP conversion disturbed sinew or hide for: %', v_bad;
    END IF;

    -- Nothing may still be handing out the old currency to a player.
    SELECT string_agg(x.src, ', ') INTO v_bad FROM (
        SELECT 'gu_type_effects' AS src WHERE EXISTS (
            SELECT 1 FROM gu_type_effects WHERE effect_code = 'max_hp')
        UNION ALL SELECT 'equipment_effects' WHERE EXISTS (
            SELECT 1 FROM equipment_effects WHERE effect_code = 'max_hp')
        UNION ALL SELECT 'physique_effects' WHERE EXISTS (
            SELECT 1 FROM physique_effects WHERE effect_code = 'max_hp')
        UNION ALL SELECT 'destiny_effects' WHERE EXISTS (
            SELECT 1 FROM destiny_effects WHERE effect_code = 'max_hp')
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still grant max_hp to a player: %', v_bad;
    END IF;

    -- The ledger must not be load-bearing for somebody who never had any of
    -- this. A player with no max_hp gear needs no adjustment at all.
    IF EXISTS (SELECT 1 FROM player_legacy_stats WHERE magnitude = 0) THEN
        RAISE EXCEPTION 'the ledger holds a zero, which means it was written blind';
    END IF;

    RAISE NOTICE 'worst drift across every live body: % point(s)',
        COALESCE(v_worst, 0);
    FOR r IN
        SELECT p.discord_name, s.max_hp AS was, pp.max_hp AS now_is,
               round(player_stat(p.player_id, 'base_hp'), 1) AS from_gear,
               round(legacy_stat(p.player_id, 'base_hp'), 1) AS from_ledger
        FROM stat_conversion_snapshot s
        JOIN player_physique pp ON pp.player_id = s.player_id
        JOIN players p ON p.player_id = s.player_id
        WHERE s.migration = '0433' AND p.deleted_at IS NULL
        ORDER BY pp.max_hp DESC LIMIT 8
    LOOP
        RAISE NOTICE '  % : % -> %  (gear %, ledger %)',
            rpad(r.discord_name, 18), r.was, r.now_is, r.from_gear, r.from_ledger;
    END LOOP;
END;
$probe$;
