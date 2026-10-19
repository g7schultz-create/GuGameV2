-- 0259_defence_is_softened_at_both_ends
--
-- Clearwest hit a rank 7 dungeon boss for 4,295. She hits a rank 2 beast for
-- 737,019. The boss has 23 million health, so that is five thousand rounds.
--
-- 0248 said defence should hold its value up the ladder and fixed exactly half
-- of it. A creature attacking a cultivator is softened by
--
--     dscale = defense_scale x creature_defense_scale_per_rank ^ (rank - 1)
--
-- so a defence stat that quadruples per rank meets a divisor that quadruples
-- per rank and keeps its share. A cultivator attacking a creature was softened
-- by a FLAT `defense_scale` of 60 - while 0249 gave every creature a defence
-- that quadruples per rank. Twenty-five at rank 1 becomes 102,400 at rank 7,
-- against a divisor that never moved, and the blow keeps six ten-thousandths
-- of itself.
--
-- The asymmetry is the whole bug. Both directions use the same shape now: the
-- divisor climbs with the rank of whoever is being hit, so a creature's
-- defence is worth the same share of a blow at every rank instead of becoming
-- an immunity somewhere around rank 5.
--
-- At rank 1 nothing changes, because the scale is raised to rank - 1 - which
-- is why the worked examples in the damage tests still hold.
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
    their_rank    SMALLINT;
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

    -- The divisor climbs with the rank of whoever is being hit, exactly as it
    -- does when a creature swings at a cultivator. Creature defence
    -- quadruples per rank; against a flat divisor that is not defence, it is
    -- an immunity by rank 5.
    SELECT COALESCE(cs.rank, 1) INTO their_rank
    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;

    scale := game_config_value('defense_scale')
             * power(game_config_value('creature_defense_scale_per_rank'),
                     GREATEST(0, COALESCE(their_rank, 1) - 1));

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
    'What one technique does to one creature. `base_power` is the technique''s own and `body_power` is the Strength behind it. The defence divisor climbs with the defender''s rank, the same way it does when a creature swings back - otherwise a defence stat that quadruples per rank becomes an immunity.';


DO $$
DECLARE
    who   BIGINT;
    move  BIGINT;
    boss  BIGINT;
    dealt BIGINT;
    hp    BIGINT;
    def   BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY pp.max_hp DESC LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry it';
        RETURN;
    END IF;

    move := dungeon_default_move(who);

    -- The deepest thing in the game that has a defence worth arguing with.
    SELECT cs.species_id, cs.base_hp, cs.base_defense INTO boss, hp, def
    FROM creature_species cs
    WHERE cs.kind = 'dungeon' ORDER BY cs.rank DESC LIMIT 1;

    SELECT c.final_damage INTO dealt
    FROM compute_technique_damage(
        who, move, boss,
        player_external_multiplier(who, move), def) c;

    -- The measure that matters: how many blows to fell it. Five thousand is
    -- what this migration exists to stop being the answer.
    IF dealt <= 0 THEN
        RAISE EXCEPTION 'the deepest boss takes nothing at all';
    END IF;

    IF hp / GREATEST(dealt, 1) > 2000 THEN
        RAISE EXCEPTION
            'the deepest boss still needs % blows to fell', hp / dealt;
    END IF;

    RAISE NOTICE 'deepest boss: % health, % a blow, % blows', hp, dealt,
        hp / GREATEST(dealt, 1);
END;
$$;
