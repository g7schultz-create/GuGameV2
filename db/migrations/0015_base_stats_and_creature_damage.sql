-- 0015_base_stats_and_creature_damage
--
-- Gives a body level 1 character non-zero DEFENSE and STRENGTH, and adds the
-- other half of the combat pipeline: what a creature does to a player.
--
-- These ship together on purpose. Base defense is mechanically inert without a
-- function that reads it, and a creature damage function reads a defense that
-- is zero today, so neither half is testable alone.
--
-- Three things arrive here that are worth reading before the numbers:
--
--   1. `apply_physique_xp` computes defense as
--      round(def_rate * (level - 1) * mult), and (1 - 1) = 0. No rate change
--      and no race, root or physique multiplier can ever fix that - only a
--      base term can. Same for strength. That is the whole bug.
--
--   2. `compute_creature_damage` mirrors 0008's shape exactly, including all
--      four of its clamps, so battle_actions takes it unchanged and the combat
--      log reads identically in both directions.
--
--   3. HP REGENERATION. This is the one that stops the migration being a trap.
--      `player_physique.current_hp` has, since 0006, been written in exactly
--      one place - apply_physique_xp - as least(current_hp + hp_gained, max_hp)
--      where hp_gained is the max_hp delta. It is monotonically increasing.
--      There is no heal, no rest, no revive anywhere in the repository.
--      `player_physique.regeneration` (0006, "HP regenerated per minute out of
--      combat", DEFAULT 1) has had zero consumers since the day it was written,
--      and `player_physique.last_tick_at` beside it has never been read.
--
--      So the moment anything can subtract HP, loss becomes PERMANENT: four
--      tutorial-tier fights would leave a character at 0 with no path back, and
--      migrations are forward-only. Shipping the damage function without the
--      regeneration consumer would be shipping that trap. It is four lines and
--      it needs no new config row, because the rate is already a per-player
--      column. It also finally gives last_tick_at the consumer it was created
--      for.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Numbers
-- ---------------------------------------------------------------------------
-- The first UPDATE of a game_config row in this project's history. The
-- convention was stated in prose in 0009 and this is what it looks like in
-- practice: a new migration changing the row, never an edit to the one that
-- inserted it.

UPDATE game_config
SET value = 120,
    description = 'PLACEHOLDER - max HP at body level 1, before multipliers. '
                  'Raised from 100 in 0015 to buy a flee window at rank 2.'
WHERE key = 'physique_base_hp';

INSERT INTO game_config (key, value, description) VALUES
    ('physique_base_defense', 20,
     'PLACEHOLDER - defense at body level 1, before multipliers. Five body levels'' worth, so a new character is not made of paper.'),
    ('physique_base_strength', 30,
     'PLACEHOLDER - strength at body level 1, before multipliers. Five body levels'' worth. Consumed by nothing yet - see the note below.'),
    ('creature_attack_scale', 1,
     'Multiplier from creature_species.base_attack to pre-defense damage. 1 means the bestiary''s Attack column is literally the damage, matching how techniques.base_power reads.'),
    ('creature_defense_scale_per_rank', 2,
     'Defense is worth less against a higher-rank creature: the diminishing-returns constant is multiplied by this per rank above 1.');

-- On physique_base_strength: it deliberately feeds no formula in this
-- migration. Strength has had no consumer since 0009, and wiring it into
-- outgoing damage here would add a fourth multiplicative system on top of
-- attainment, matchup and traits, and would silently desync /damage's preview
-- from the combat log. When it does get a consumer it should be a flat
-- ADDITIVE term on pre_defense, not another multiplier, so it cannot compound.
-- Until then this makes the character sheet honest rather than showing 0.


-- ---------------------------------------------------------------------------
-- apply_physique_xp, replaced
-- ---------------------------------------------------------------------------
-- Identical to the 0013 version except that defense and strength now carry a
-- base term, exactly as max_hp already did. The base is inside the
-- multiplication so traits scale it the same way they scale base HP - a
-- Rockman's +10% defense applies to the whole stat, not only to the part
-- earned by levelling.

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    base_def  NUMERIC := game_config_value('physique_base_defense');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    base_str  NUMERIC := game_config_value('physique_base_strength');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
    new_level   SMALLINT;
    new_max_hp  BIGINT;
    hp_gained   BIGINT;
BEGIN
    SELECT * INTO row_before FROM player_physique WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    SELECT tr.hp_multiplier, tr.defense_multiplier, tr.strength_multiplier
    INTO mult_hp, mult_def, mult_str
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;

    mult_hp  := COALESCE(mult_hp, 1);
    mult_def := COALESCE(mult_def, 1);
    mult_str := COALESCE(mult_str, 1);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = round((base_def + def_rate * (new_level - 1)) * mult_def),
        strength    = round((base_str + str_rate * (new_level - 1)) * mult_str)
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- compute_creature_damage
-- ---------------------------------------------------------------------------
-- The other direction of 0008's pipeline. Same five-stage return shape, same
-- clamps, so battle_actions stores either direction in the same columns and
-- "why did that hit for 41?" is answered the same way for both.
--
--   pre_defense = base_attack * creature_attack_scale * external
--   final       = pre_defense * dscale / (dscale + defense)
--   dscale      = defense_scale * creature_defense_scale_per_rank ^ (rank - 1)
--
-- The rank term is the important part, and it is not a new system - it is the
-- existing hyperbola given the one input it was missing.
--
-- Without it, defense is rank-blind: body level is gated only by wall-clock
-- time (6.25 hours per level, linear, uncapped) while realm is gated by a ~1.9x
-- exponential, so a player who does nothing but idle accumulates unbounded
-- mitigation against a FIXED creature attack ladder. Measured against the live
-- roster, a pure idler at body level 19 - 112 hours, no race or root bonuses,
-- holding one rank 2 technique - beat the rank 3 elite the design calls
-- "unambiguously out of reach", 8 hits to 9. By day 60 the rank 9 world boss
-- needed twelve hits to kill them.
--
-- With the rank term at 2, that idler dies at 19 and first wins at body level
-- 40, which is 244 hours - and the rank 3 realm unlocks at 247.6. So you beat
-- a rank 3 creature almost exactly when you reach rank 3, which is the
-- property worth having.
--
-- Rank 1 is unaffected in every case, because 2^0 = 1: the Qi Condensation
-- tier keeps the exact numbers it was tuned to.

CREATE FUNCTION compute_creature_damage(
    p_attacker_species_id BIGINT,
    p_defender_player_id  BIGINT,
    p_external_multiplier NUMERIC DEFAULT 1,
    p_defense             BIGINT  DEFAULT NULL
) RETURNS TABLE (
    base_power       INTEGER,
    attainment_bonus NUMERIC,
    matchup_modifier NUMERIC,
    pre_defense      NUMERIC,
    final_damage     BIGINT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    atk           INTEGER;
    rank_of       SMALLINT;
    scale         NUMERIC;
    dscale        NUMERIC;
    def           BIGINT;
    raw           NUMERIC;
    after_defense NUMERIC;
BEGIN
    SELECT cs.base_attack, cs.rank INTO STRICT atk, rank_of
    FROM creature_species cs
    WHERE cs.species_id = p_attacker_species_id;

    scale  := game_config_value('creature_attack_scale');
    dscale := game_config_value('defense_scale')
              * power(game_config_value('creature_defense_scale_per_rank'), rank_of - 1);

    -- NULL means "read the defender's own defense". 0008 defaults its defense
    -- to 0 because its defender is a static species row; here the defender is
    -- a player whose defense already lives in a table, so looking it up is the
    -- correct default and passing a number is the override for a dry run.
    def := COALESCE(
        p_defense,
        (SELECT pp.defense FROM player_physique pp WHERE pp.player_id = p_defender_player_id),
        0
    );

    IF atk <= 0 THEN
        raw := 0;
    ELSE
        raw := atk * scale * p_external_multiplier;
    END IF;

    after_defense := raw * dscale / (dscale + GREATEST(def, 0));

    RETURN QUERY SELECT
        atk,
        -- Honest zeros rather than omitted columns. Creatures hold no
        -- attainment, and there is no player-side incoming-Path resistance
        -- profile yet; when there is, it lands here without a signature change.
        0::NUMERIC,
        0::NUMERIC,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;

COMMENT ON FUNCTION compute_creature_damage(BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'Creature -> player damage, mirroring compute_technique_damage. Defense is worth less against higher-rank attackers; pass p_defense to override the lookup.';


-- ---------------------------------------------------------------------------
-- settle_passive_cultivation, replaced
-- ---------------------------------------------------------------------------
-- Same function with one addition: out-of-combat HP regeneration, using the
-- `regeneration` column 0006 provided and nothing has read since.
--
-- It runs after apply_physique_xp so a body level gained in the same settle has
-- already raised max_hp, and least(max_hp, ...) then clamps against the new cap
-- rather than the old one. It is monotonically non-decreasing, so it cannot
-- fight with a future writer that subtracts HP.
--
-- The return type gains a column, so this is a DROP and CREATE rather than a
-- CREATE OR REPLACE.

DROP FUNCTION settle_passive_cultivation(BIGINT);

CREATE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
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
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_gain     BIGINT;
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

    SELECT pc.realm_id INTO r_before FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_gain := round(
        paid
        * game_config_value('passive_cultivation_per_hour')
        * COALESCE(rates.cultivation_multiplier, 1)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * COALESCE(rates.physique_multiplier, 1)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            paid
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_gain);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    -- Out-of-combat regeneration. `regeneration` is HP per minute and is a
    -- per-player column, so the rate is data rather than a literal here.
    -- The prior value is read into a variable rather than compared inside
    -- RETURNING, where a subquery would be reading the statement's own
    -- snapshot and the intent would be far from obvious.
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

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, COALESCE(hp_gain, 0), cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;

COMMENT ON FUNCTION settle_passive_cultivation(BIGINT) IS
    'Pays out elapsed idle time, regenerates HP, and advances last_tick_at by what was paid. Safe to call on every command; a zero-elapsed call grants zero.';


-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
-- Existing characters were built by the old formula and are carrying defense 0
-- and strength 0. Granting 0 XP re-runs the stat derivation without moving
-- anyone's level or XP, which is the point of those stats being a pure function
-- of (level, traits) rather than an accumulated total.

DO $$
DECLARE
    id BIGINT;
BEGIN
    FOR id IN SELECT player_id FROM player_physique LOOP
        PERFORM apply_physique_xp(id, 0);
    END LOOP;
END;
$$;
