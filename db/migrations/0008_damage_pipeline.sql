-- 0008_damage_pipeline
--
-- The spec's damage flow (section 13), as database functions:
--
--     Technique Base Damage
--             |
--     Relevant Path Attainment        <- technique_attainment_bonus()
--             |
--     Path Weakness / Resistance      <- technique_matchup_modifier()
--             |
--     Dao Marks / Equipment / Buffs   <- external multiplier parameter (hook)
--             |
--     Enemy Defense                   <- defense parameter
--             |
--     Final Damage                    <- compute_technique_damage()
--
-- In SQL rather than Python because the numbers these functions read - the
-- chart, the tiers, the overrides, the caps - all live in tables. Putting the
-- math next to the data means one implementation serves the bot, ad-hoc psql
-- balance queries, and the tests; there is no second copy in Python to drift.
--
-- The Dao Marks / equipment / buffs stage is deliberately a plain multiplier
-- parameter for now: those systems do not exist yet, and when they do, they
-- can supply their factor without this pipeline changing shape.
--
-- Forward-only. Once this has run anywhere, do not edit it - write a new
-- migration instead (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- Tunables this pipeline reads
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('defense_scale', 100,
     'Diminishing-returns constant for defense: damage is scaled by scale/(scale+defense), so this many points of defense halves incoming damage.');


-- ---------------------------------------------------------------------------
-- technique_attainment_bonus
-- ---------------------------------------------------------------------------
-- The weighted attainment bonus for one player using one technique (spec
-- sections 2 and 5). Each of the technique's Paths contributes its tier's
-- damage_bonus scaled by the Path's weight; the weights-sum-to-1 trigger on
-- technique_paths makes this exactly the spec's simple average for even
-- splits and its weighted formula for uneven ones.
--
-- LEFT JOINs because player_path_attainment is sparse: a missing row IS
-- Uninitiated, tier 0, bonus 0 - not an error.

CREATE FUNCTION technique_attainment_bonus(
    p_player_id    BIGINT,
    p_technique_id BIGINT
) RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(SUM(tp.weight * tiers.damage_bonus), 0)
    FROM technique_paths tp
    LEFT JOIN player_path_attainment ppa
           ON ppa.player_id = p_player_id
          AND ppa.path_code = tp.path_code
    JOIN attainment_tiers tiers
           ON tiers.tier = COALESCE(ppa.tier, 0)
    WHERE tp.technique_id = p_technique_id;
$$;

COMMENT ON FUNCTION technique_attainment_bonus(BIGINT, BIGINT) IS
    'Weight-averaged attainment damage bonus for a player using a technique. Missing attainment rows read as Uninitiated.';


-- ---------------------------------------------------------------------------
-- technique_matchup_modifier
-- ---------------------------------------------------------------------------
-- The total matchup modifier for one technique against one species, reading
-- the resolved creature_incoming_paths view (explicit overrides beat the
-- derived chart).
--
-- Rules, from spec sections 3 and 5:
--   * Each of the technique's Paths contributes its full interaction modifier;
--     advantages and resistances SUM, so "weak to Fire but resistant to Sword"
--     partially cancels.
--   * The total is clamped to [matchup_penalty_floor, matchup_bonus_cap].
--   * Paths with no interaction contribute nothing (neutral = absent row).
--
-- Immunity is the special case: returns exactly -1 (final damage 0) only when
-- EVERY one of the technique's Paths is immune. A dual-Path move with one
-- immune component instead feeds that -1.0 into the sum, where the floor
-- clamps it - the un-immune half still lands, weakened. This is a design
-- decision, not spec text; the spec never combines immunity with dual typing.

CREATE FUNCTION technique_matchup_modifier(
    p_technique_id BIGINT,
    p_species_id   BIGINT
) RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    path_count   INTEGER;
    immune_count INTEGER;
    total        NUMERIC;
    cap          NUMERIC;
    floor_value  NUMERIC;
BEGIN
    SELECT count(*) INTO path_count
    FROM technique_paths
    WHERE technique_id = p_technique_id;

    SELECT
        count(*) FILTER (WHERE ci.interaction = 'immunity'),
        COALESCE(SUM(mi.damage_modifier), 0)
    INTO immune_count, total
    FROM technique_paths tp
    JOIN creature_incoming_paths ci
      ON ci.species_id = p_species_id
     AND ci.path_code  = tp.path_code
    JOIN matchup_interactions mi ON mi.code = ci.interaction
    WHERE tp.technique_id = p_technique_id;

    IF path_count > 0 AND immune_count = path_count THEN
        RETURN -1;  -- fully immune: every component Path is negated
    END IF;

    SELECT value INTO cap         FROM game_config WHERE key = 'matchup_bonus_cap';
    SELECT value INTO floor_value FROM game_config WHERE key = 'matchup_penalty_floor';

    RETURN LEAST(cap, GREATEST(floor_value, total));
END;
$$;

COMMENT ON FUNCTION technique_matchup_modifier(BIGINT, BIGINT) IS
    'Summed, clamped matchup modifier for a technique vs a species. Returns exactly -1 only on total immunity.';


-- ---------------------------------------------------------------------------
-- compute_technique_damage
-- ---------------------------------------------------------------------------
-- The whole pipeline in one call, returning every intermediate stage rather
-- than a bare number: battle_actions stores the breakdown, the combat log
-- displays it, and a balance question ("why did that hit for 15,000?") is
-- answered by reading the row instead of re-deriving it.
--
--   pre_defense  = base * (1 + attainment) * (1 + matchup) * external
--   final        = pre_defense * scale / (scale + defense)
--
-- p_external_multiplier is the Dao Marks / equipment / buffs hook - pass 1
-- until those systems exist. Defense uses diminishing returns rather than
-- subtraction so no defense value ever makes a hit heal or hard-zero.
--
-- A damaging hit that gets through never rounds below 1 (chip damage); a
-- technique with zero base power or a fully-immune target deals exactly 0.

CREATE FUNCTION compute_technique_damage(
    p_attacker_player_id  BIGINT,
    p_technique_id        BIGINT,
    p_defender_species_id BIGINT,
    p_external_multiplier NUMERIC DEFAULT 1,
    p_defense             BIGINT  DEFAULT 0
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
    tech_base     INTEGER;
    attainment    NUMERIC;
    matchup       NUMERIC;
    scale         NUMERIC;
    raw           NUMERIC;
    after_defense NUMERIC;
BEGIN
    SELECT t.base_power INTO STRICT tech_base
    FROM techniques t
    WHERE t.technique_id = p_technique_id;

    attainment := technique_attainment_bonus(p_attacker_player_id, p_technique_id);
    matchup    := technique_matchup_modifier(p_technique_id, p_defender_species_id);

    IF tech_base <= 0 OR matchup = -1 THEN
        raw := 0;
    ELSE
        raw := tech_base * (1 + attainment) * (1 + matchup) * p_external_multiplier;
    END IF;

    SELECT value INTO scale FROM game_config WHERE key = 'defense_scale';
    after_defense := raw * scale / (scale + GREATEST(p_defense, 0));

    RETURN QUERY SELECT
        tech_base,
        attainment,
        matchup,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;

COMMENT ON FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'Full damage pipeline with per-stage breakdown. external_multiplier is the Dao Marks/equipment/buffs hook; pass 1 until those exist.';
