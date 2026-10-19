-- 0244_strength_finally_hits_something
--
-- Strength did nothing. Not "less than you would expect" - nothing at all.
--
-- One function in the whole database touched `player_physique.strength`, and
-- it was `battle_open` writing the number into a snapshot that nothing ever
-- read back. Meanwhile the stat has a full apparatus behind it: a base and a
-- per-level rate, a multiplier from the physique's rarity, a `strength_bonus`
-- that manuals charge for, a trait foundation, and two places on /character.
-- Miyuki has tempered to body level 141 and is carrying 1,479 of it.
--
-- NOW IT IS FLAT DAMAGE, added to the technique's own power before everything
-- multiplies. That means it goes through attainment, the matchup and the
-- external stack exactly as base power does - so a tempered body does not
-- compete with Attack Power, it compounds with it. Attack Power is a
-- percentage of what you swing; Strength is part of what you swing.
--
-- WHAT THIS DOES NOT FIX, and it should be said rather than discovered: a flat
-- addition fades against a technique ladder that climbs geometrically. At 1:1
-- on the cultivators playing today it is worth +61% to pashu0 on a 300 power
-- technique and +8% to Miyuki on a 19,000 power one - which is backwards from
-- the effort each of them put in. Strength grows linearly with body level and
-- technique power grows by rank, so no constant multiplier fixes both ends.
-- `physique_strength_damage` is the lever; making the contribution climb with
-- body RANK rather than level is the structural answer, and it is a separate
-- decision from wiring the stat up at all.
--
-- The reported `base_power` includes it, because a blow that swung with 1,279
-- behind it should not tell the battle log it swung with 931.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('physique_strength_damage', 1,
     'How much of a cultivator''s Strength joins the technique''s own power '
     'before the multipliers. Flat, so it compounds with Attack Power rather '
     'than competing with it - and it fades against high tier techniques, '
     'which is what this dial is for.');


CREATE OR REPLACE FUNCTION compute_technique_damage(
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
    final_damage     BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    tech_base     INTEGER;
    thews         INTEGER;
    swung_with    INTEGER;
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

    swung_with := tech_base + thews;

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
        raw := swung_with * (1 + attainment) * (1 + matchup) * ext;
    END IF;

    SELECT value INTO scale FROM game_config WHERE key = 'defense_scale';
    after_defense := raw * scale / (scale + GREATEST(p_defense, 0));

    RETURN QUERY SELECT
        swung_with,
        attainment,
        matchup,
        raw,
        CASE WHEN raw <= 0 THEN 0
             ELSE GREATEST(1, round(after_defense))::BIGINT
        END;
END;
$$;

COMMENT ON FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'What one technique does to one creature. `base_power` is what the blow actually swung with - the technique plus the body behind it - not just what the manual prints.';


DO $$
DECLARE
    who   BIGINT;
    move  BIGINT;
    beast BIGINT;
    weak  RECORD;
    stout RECORD;
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

    BEGIN
        SELECT pp.strength INTO was FROM player_physique pp WHERE pp.player_id = who;

        UPDATE player_physique SET strength = 0 WHERE player_id = who;
        SELECT * INTO weak FROM compute_technique_damage(who, move, beast, 1, 0);

        UPDATE player_physique SET strength = GREATEST(1, was) * 4
        WHERE player_id = who;
        SELECT * INTO stout FROM compute_technique_damage(who, move, beast, 1, 0);

        IF stout.final_damage <= weak.final_damage THEN
            RAISE EXCEPTION
                'a body four times as strong hit for % against %',
                stout.final_damage, weak.final_damage;
        END IF;

        -- It joins the power the blow swung with, so the log tells the truth.
        IF stout.base_power <= weak.base_power THEN
            RAISE EXCEPTION 'the reported power did not move with the body';
        END IF;

        -- And a technique with no power of its own is still not an attack.
        UPDATE player_physique SET strength = 100000 WHERE player_id = who;
        IF (SELECT c.final_damage FROM compute_technique_damage(
                who,
                (SELECT t.technique_id FROM techniques t
                 WHERE t.base_power <= 0 LIMIT 1),
                beast, 1, 0) c) IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'a powerless technique swung for something';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
