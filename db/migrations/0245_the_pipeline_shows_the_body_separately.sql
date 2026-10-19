-- 0245_the_pipeline_shows_the_body_separately
--
-- 0244 folded Strength into the reported `base_power`, and /damage now says
-- "Base power 10,048" for a technique whose manual prints 10,000. The number
-- is honest - that IS what the multipliers act on - and it is still the wrong
-- thing to show, because it hides the 48 inside a figure the player can look
-- up somewhere else and find disagrees.
--
-- The /damage screen exists to show every stage. A stage folded into another
-- stage is the one thing it must not do.
--
-- So `base_power` goes back to being the technique's own, and the body gets a
-- column of its own beside it. The arithmetic is unchanged: both are still
-- summed before anything multiplies.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT);

CREATE FUNCTION compute_technique_damage(
    p_attacker_player_id  BIGINT,
    p_technique_id        BIGINT,
    p_defender_species_id BIGINT,
    p_external_multiplier NUMERIC DEFAULT 1,
    p_defense             BIGINT  DEFAULT 0
)
RETURNS TABLE (
    base_power       INTEGER,
    attainment_bonus NUMERIC,
    matchup_modifier NUMERIC,
    pre_defense      NUMERIC,
    final_damage     BIGINT,
    body_power       INTEGER
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    tech_base     INTEGER;
    thews         INTEGER;
    attainment    NUMERIC;
    matchup       NUMERIC;
    scale         NUMERIC;
    ext           NUMERIC;
    raw           NUMERIC;
    after_defense NUMERIC;
BEGIN
    SELECT t.base_power INTO STRICT tech_base
    FROM techniques t
    WHERE t.technique_id = p_technique_id;

    -- The body behind the technique. A cultivator with no physique row - a
    -- fixture, a record mid-creation - simply swings with the technique.
    thews := GREATEST(0, round(
        COALESCE((SELECT pp.strength FROM player_physique pp
                  WHERE pp.player_id = p_attacker_player_id), 0)
        * game_config_value('physique_strength_damage')))::integer;

    attainment := technique_attainment_bonus(p_attacker_player_id, p_technique_id);
    matchup    := technique_matchup_modifier(p_technique_id, p_defender_species_id);

    -- A body that is hard to counter cleanly. Only a RESISTANCE is softened.
    -- Immunity is left exactly where it is: -1 is a rule about the Path rather
    -- than a large resistance, and a body arguing with it would be arguing
    -- with the matchup chart itself.
    IF matchup < 0 AND matchup > -1 THEN
        matchup := matchup * (1 - LEAST(1,
            player_stat(p_attacker_player_id, 'matchup_relief')));
    END IF;

    -- Added to the external stack rather than multiplied through it, because
    -- everything in this game that raises damage adds.
    ext := p_external_multiplier
         + CASE WHEN (SELECT cs.kind FROM creature_species cs
                      WHERE cs.species_id = p_defender_species_id) = 'beast'
                THEN player_stat(p_attacker_player_id, 'beast_damage')
                ELSE 0 END;

    -- A technique with no power of its own is still not an attack, however
    -- strong the arm behind it - so the gate is on the technique, not the sum.
    IF tech_base <= 0 OR matchup = -1 THEN
        raw := 0;
    ELSE
        raw := (tech_base + thews) * (1 + attainment) * (1 + matchup) * ext;
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
        END,
        thews;
END;
$$;

COMMENT ON FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'What one technique does to one creature. `base_power` is the technique''s own and `body_power` is the Strength behind it; they are summed before anything multiplies, and shown apart so no screen folds one into the other.';


DO $$
DECLARE
    who   BIGINT;
    move  BIGINT;
    beast BIGINT;
    shown RECORD;
    printed INTEGER;
    was   BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody with a body to measure; the tests carry it';
        RETURN;
    END IF;

    move  := dungeon_default_move(who);
    beast := (SELECT cs.species_id FROM creature_species cs
              WHERE cs.kind = 'beast' LIMIT 1);
    SELECT t.base_power INTO printed FROM techniques t WHERE t.technique_id = move;

    BEGIN
        SELECT pp.strength INTO was FROM player_physique pp WHERE pp.player_id = who;
        UPDATE player_physique SET strength = 500 WHERE player_id = who;

        SELECT * INTO shown FROM compute_technique_damage(who, move, beast, 1, 0);

        -- What the manual prints is what the screen shows.
        IF shown.base_power <> printed THEN
            RAISE EXCEPTION 'the technique prints % and the pipeline says %',
                printed, shown.base_power;
        END IF;
        IF shown.body_power <> 500 THEN
            RAISE EXCEPTION 'the body contributed % rather than 500',
                shown.body_power;
        END IF;

        -- And they are still summed before anything multiplies. Measured
        -- against the same blow with no body behind it, because a resisted
        -- technique can come out under its own printed power.
        DECLARE
            bare NUMERIC;
        BEGIN
            UPDATE player_physique SET strength = 0 WHERE player_id = who;
            SELECT c.pre_defense INTO bare
            FROM compute_technique_damage(who, move, beast, 1, 0) c;

            IF shown.pre_defense <= bare THEN
                RAISE EXCEPTION
                    'the body was reported but not swung with: % against %',
                    shown.pre_defense, bare;
            END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
