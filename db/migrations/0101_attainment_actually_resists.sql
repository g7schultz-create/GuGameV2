-- 0101_attainment_actually_resists
--
-- `attainment_tiers.resistance_bonus` has been seeded since 0003 and read by
-- nothing. A Grandmaster of the Sword Path was told, on /tiers, that they turn
-- aside 10% of Sword damage, and then took full damage from every sword in the
-- world. That is worse than a missing feature: it is a number on a screen that
-- the game disagrees with.
--
-- 0069 built the channel this belongs in. It reads the attacker's primary Path
-- and takes the defending BODY's resistance off the blow, additively, under a
-- cap. Attainment resistance is the same shape - what you understand of a Path
-- is what you can turn aside of it - so it adds into the same place rather
-- than inventing a second one.
--
-- ONE READER, TWO CALLERS. The screen that shows a player their resistance and
-- the function that applies it in a fight must not be two separate sums; that
-- is how a bonus comes to be advertised at one value and paid at another. So
-- the arithmetic moves into `player_path_resistance` and both read it.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION player_path_resistance(p_player_id BIGINT, p_path_code TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('physique_resistance_cap'),
        GREATEST(0,
            -- What the body refuses.
            COALESCE((SELECT ppb.resistance
                      FROM player_physique pp
                      JOIN physique_path_bonuses ppb
                        ON ppb.physique_id = pp.physique_id
                       AND ppb.path_code = p_path_code
                      WHERE pp.player_id = p_player_id), 0)
            -- Plus what understanding it refuses. A missing attainment row is
            -- Uninitiated, which is tier 0, which is zero - not an error.
            + COALESCE((SELECT t.resistance_bonus
                        FROM player_path_attainment ppa
                        JOIN attainment_tiers t ON t.tier = ppa.tier
                        WHERE ppa.player_id = p_player_id
                          AND ppa.path_code = p_path_code), 0)
        )
    );
$$;

COMMENT ON FUNCTION player_path_resistance(BIGINT, TEXT) IS
    'Fraction of a blow led with this Path that this cultivator turns aside: body plus attainment, added, under the one cap. The screens and the damage pipeline both read this.';


-- ---------------------------------------------------------------------------
-- compute_creature_damage, reading the one source
-- ---------------------------------------------------------------------------
-- 0069's function with its inline physique lookup replaced. Nothing else about
-- it changes: same signature, same columns, same additive channel.

CREATE OR REPLACE FUNCTION compute_creature_damage(
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
    resist        NUMERIC := 0;
    after_defense NUMERIC;
BEGIN
    SELECT cs.base_attack, cs.rank INTO STRICT atk, rank_of
    FROM creature_species cs
    WHERE cs.species_id = p_attacker_species_id;

    scale  := game_config_value('creature_attack_scale');
    dscale := game_config_value('defense_scale')
              * power(game_config_value('creature_defense_scale_per_rank'), rank_of - 1);

    def := COALESCE(
        p_defense,
        (SELECT pp.defense FROM player_physique pp WHERE pp.player_id = p_defender_player_id),
        0
    );

    -- Body and attainment together, capped, off the attacker's primary Path -
    -- every one of the species has exactly one, by unique index.
    SELECT COALESCE(player_path_resistance(p_defender_player_id, cp.path_code), 0)
    INTO resist
    FROM creature_paths cp
    WHERE cp.species_id = p_attacker_species_id AND cp.is_primary;

    resist := COALESCE(resist, 0);

    IF atk <= 0 THEN
        raw := 0;
    ELSE
        raw := atk * scale * p_external_multiplier;
    END IF;

    after_defense := raw * dscale / (dscale + GREATEST(def, 0)) * (1 - resist);

    RETURN QUERY SELECT
        atk,
        -- Creatures still hold no attainment.
        0::NUMERIC,
        (-resist)::NUMERIC,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;


-- ---------------------------------------------------------------------------
-- What a Path is currently worth to one cultivator
-- ---------------------------------------------------------------------------
-- Everything /insight needs about one Path, derived rather than restated, so
-- the screen cannot drift from the pipeline the way /tiers had.
--
-- Sparse on purpose in the other direction: this returns a row for EVERY Path,
-- including the thirty-odd nobody has touched, because "where would I learn
-- fastest" is a question about the ones you have not started.

CREATE FUNCTION player_path_standing(p_player_id BIGINT)
RETURNS TABLE (
    path_code       TEXT,
    path_name       TEXT,
    emoji           TEXT,
    category        TEXT,
    insight         BIGINT,
    tier            SMALLINT,
    tier_name       TEXT,
    damage_bonus    NUMERIC,
    resistance      NUMERIC,
    learn_rate      NUMERIC,
    dao_marks       INTEGER,
    hours_trained   NUMERIC,
    tier_floor      BIGINT,
    next_tier_name  TEXT,
    next_tier_at    BIGINT,
    focused         BOOLEAN
)
LANGUAGE sql STABLE
AS $$
    SELECT
        p.code, p.name, p.emoji, p.category,
        COALESCE(ppa.insight, 0),
        COALESCE(ppa.tier, 0)::smallint,
        here.name,
        here.damage_bonus,
        player_path_resistance(p_player_id, p.code),
        player_attainment_rate(p_player_id, p.code),
        COALESCE(ppa.dao_marks, 0),
        round(COALESCE(ppa.seconds_trained, 0) / 3600.0, 1),
        here.insight_required,
        up.name,
        up.insight_required,
        (pc.focus_path = p.code)
    FROM paths p
    CROSS JOIN player_cultivation pc
    LEFT JOIN player_path_attainment ppa
           ON ppa.player_id = p_player_id AND ppa.path_code = p.code
    JOIN attainment_tiers here ON here.tier = COALESCE(ppa.tier, 0)
    -- The next rung, or nothing at the top of the ladder.
    LEFT JOIN attainment_tiers up ON up.tier = COALESCE(ppa.tier, 0) + 1
    WHERE pc.player_id = p_player_id
    ORDER BY COALESCE(ppa.insight, 0) DESC, p.sort_order, p.name;
$$;

COMMENT ON FUNCTION player_path_standing(BIGINT) IS
    'Every Path from one cultivator''s side: insight, tier, what the tier is worth, and how fast they would learn it. One row per Path, touched or not.';
