-- 0069_a_body_resists_and_holds
--
-- Two things a physique has been promising and could not say.
--
-- THIRTY-SIX OF FORTY-TWO BODIES CARRY AN `unmodelled` PROMISE. Most of them
-- can be paid in the shared effect vocabulary as it already stands - 0066
-- folded `physique_stat` into `player_stat`, so a body granting evasion or
-- penetration now reaches a fight with no engine change at all. Two promises
-- cannot, and they are the two this migration builds. 0070 spends them.
--
-- RESISTANCE, WHICH 0015 LEFT A HOOK FOR. Eight bodies promise resistance to a
-- Path - Flameblood to Fire, Jade Skin to Poison, Northern Dark Ice to Ice -
-- and `compute_creature_damage` has returned a hardcoded zero in its
-- `matchup_modifier` column since 0015, above a comment reading "there is no
-- player-side incoming-Path resistance profile yet; when there is, it lands
-- here without a signature change." It lands here, and the signature does not
-- change.
--
-- A COLUMN, NOT A TABLE, this once. `physique_path_bonuses` is already keyed
-- exactly (physique_id, path_code) and already holds what a body's
-- relationship with a Path is worth in two directions - attainment and damage
-- dealt. Damage taken is the third direction of the same relationship, not a
-- new kind of fact, so it is the third column and not a fourth table.
--
-- CAPACITY, WHICH TWO TABLES DISAGREED ABOUT ALREADY. `battle_open` and
-- `take_pill` both clamp Qi to `realms.qi_capacity`, written out twice. A body
-- that holds more Qi than its aperture should would have made them disagree,
-- so the capacity becomes a function first and gains the body second - which
-- is the only reason `take_pill` is touched at all.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- One more word in the shared vocabulary
-- ---------------------------------------------------------------------------

INSERT INTO gu_effects (code, name, description, cap, is_live, emoji, sort_order) VALUES
    ('max_qi', 'Battle Qi Capacity',
     'A deeper aperture. More Qi to spend on techniques before a fight runs dry.',
     1.0000, TRUE, '💧', 95);


-- ---------------------------------------------------------------------------
-- player_max_qi
-- ---------------------------------------------------------------------------
-- What the aperture holds, in one place rather than in two callers.

CREATE FUNCTION player_max_qi(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, round(
        COALESCE((SELECT r.qi_capacity
                  FROM player_cultivation pc
                  JOIN realms r ON r.realm_id = pc.realm_id
                  WHERE pc.player_id = p_player_id), 1)
        * (1 + player_stat(p_player_id, 'max_qi'))
    ))::bigint;
$$;

COMMENT ON FUNCTION player_max_qi(BIGINT) IS
    'The realm''s Qi capacity, widened by anything the cultivator is carrying, wearing or born with.';


-- ---------------------------------------------------------------------------
-- Resistance
-- ---------------------------------------------------------------------------

ALTER TABLE physique_path_bonuses
    ADD COLUMN resistance NUMERIC(6, 4) NOT NULL DEFAULT 0
    CHECK (resistance >= 0 AND resistance <= 0.9000);

COMMENT ON COLUMN physique_path_bonuses.resistance IS
    'Fraction of incoming damage this body turns aside when the attacker leads with this Path. The third direction of a relationship the other two columns already describe.';

INSERT INTO game_config (key, value, description) VALUES
    ('physique_resistance_cap', 0.75,
     'Most of an incoming blow a body may resist on Path alone, however the resistances add up.');


-- ---------------------------------------------------------------------------
-- compute_creature_damage, with the hook filled
-- ---------------------------------------------------------------------------
-- 0015's function. Resistance is read off the attacker's PRIMARY Path - every
-- one of the sixty-two species has exactly one, by unique index - and lands in
-- the `matchup_modifier` column that has been returning an honest zero for
-- fifty-four migrations.

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

    -- What this body refuses from that Path. Capped, so a stack of
    -- resistances can never make a cultivator immune to a whole Path.
    SELECT COALESCE(ppb.resistance, 0) INTO resist
    FROM creature_paths cp
    JOIN player_physique pp ON pp.player_id = p_defender_player_id
    JOIN physique_path_bonuses ppb
      ON ppb.physique_id = pp.physique_id AND ppb.path_code = cp.path_code
    WHERE cp.species_id = p_attacker_species_id AND cp.is_primary;

    resist := LEAST(game_config_value('physique_resistance_cap'),
                    GREATEST(0, COALESCE(resist, 0)));

    IF atk <= 0 THEN
        raw := 0;
    ELSE
        raw := atk * scale * p_external_multiplier;
    END IF;

    after_defense := raw * dscale / (dscale + GREATEST(def, 0)) * (1 - resist);

    RETURN QUERY SELECT
        atk,
        -- Creatures still hold no attainment. The second zero is no longer a
        -- zero: it is what this body takes off the blow, signed the way a
        -- modifier is.
        0::NUMERIC,
        (-resist)::NUMERIC,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;


-- ---------------------------------------------------------------------------
-- battle_open, from 0030_interactive_battles
-- ---------------------------------------------------------------------------
-- The pool a fight opens with.

CREATE OR REPLACE FUNCTION battle_open(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    species  creature_species%ROWTYPE;
    body     player_physique%ROWTYPE;
    max_qi   BIGINT;
    b_id     BIGINT;
BEGIN
    SELECT * INTO STRICT species FROM creature_species WHERE species_id = p_species_id;
    SELECT * INTO STRICT body FROM player_physique WHERE player_id = p_player_id;

    IF body.current_hp <= 0 THEN
        RAISE EXCEPTION 'no strength left to fight' USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_active_battle WHERE player_id = p_player_id) THEN
        RAISE EXCEPTION 'already in a battle' USING ERRCODE = 'check_violation';
    END IF;

    max_qi := player_max_qi(p_player_id);

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('pve', 'active', floor(random() * 9223372036854775806)::bigint)
    RETURNING battles.battle_id INTO b_id;

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp, current_qi)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'max_qi', max_qi),
            body.max_hp, body.current_hp, max_qi);

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp,
         intent_move_id)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, species.base_hp,
            roll_creature_intent(p_species_id));

    INSERT INTO player_active_battle (player_id, battle_id) VALUES (p_player_id, b_id);

    INSERT INTO player_bestiary (player_id, species_id, times_encountered)
    VALUES (p_player_id, p_species_id, 1)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            last_seen_at      = now();

    RETURN b_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- take_pill, from 0059_pills_that_change_the_rate
-- ---------------------------------------------------------------------------
-- And the ceiling a Qi pill fills to, which has to be the same ceiling.

CREATE OR REPLACE FUNCTION take_pill(p_player_id BIGINT, p_pill_id BIGINT)
RETURNS TABLE (
    pill_name  TEXT,
    kind       TEXT,
    granted    BIGINT,
    detail     TEXT,
    remaining  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     player_pills%ROWTYPE;
    before BIGINT;
    after  BIGINT;
    bonus  NUMERIC;
    banked NUMERIC;
    said   TEXT;
    left_n SMALLINT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    IF it.kind IN ('cultivation_rate', 'attainment_rate') THEN
        SELECT pt.rate_bonus INTO bonus FROM pill_tiers pt WHERE pt.tier = it.tier;
        banked := grant_boost(p_player_id, it.kind, bonus, it.magnitude);
        after  := it.magnitude;
        said   := percent_text(bonus) || ' for ' || round(it.magnitude)
                  || ' hours of cultivation, ' || round(banked) || ' banked in total.';

    ELSIF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The bottleneck refused the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        SELECT pp.physique_xp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        SELECT pp.physique_xp INTO after FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        after := after - before;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        SELECT COALESCE(a.insight, 0) INTO before
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        PERFORM grant_path_insight(p_player_id, it.path_code, it.magnitude, 0, 0);
        SELECT COALESCE(a.insight, 0) INTO after
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        after := after - before;
        said := 'Insight into ' || it.path_code || '.';

    ELSIF it.kind = 'healing' THEN
        SELECT pp.current_hp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The body could not hold all of it.'
                     ELSE 'Health, at once.' END;

    ELSE
        SELECT pc.qi INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        UPDATE player_cultivation pc
        SET qi = LEAST(
                player_max_qi(p_player_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id
        RETURNING pc.qi INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The aperture would not hold the rest.'
                     ELSE 'Battle Qi, at once.' END;
    END IF;

    IF it.quantity > 1 THEN
        UPDATE player_pills SET quantity = quantity - 1 WHERE pill_id = p_pill_id
        RETURNING quantity INTO left_n;
    ELSE
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
        left_n := 0;
    END IF;

    RETURN QUERY SELECT it.name, it.kind, GREATEST(0, COALESCE(after, 0)), said, left_n;
END;
$$;
