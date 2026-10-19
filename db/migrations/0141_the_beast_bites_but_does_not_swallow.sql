-- 0141_the_beast_bites_but_does_not_swallow
--
-- 0140 sized the beast's HP to the roster and dropped its defense, and then
-- left its ATTACK alone - so a rank 7 Revenant answered a Qi Condensation
-- cultivator's strike by removing all of their health. Simulating the whole
-- roster against one beast landed eleven strikes out of a possible fifty:
-- everybody swung once, was knocked flat, and was told to go and rest.
--
--     strikes=11  total_damage=2791  beast: open at 2189/4980
--
-- An allowance of five strikes that the first strike ends is not an allowance.
--
-- The bite is capped at a fraction of the striker's own maximum health, so the
-- allowance is what actually limits a session and the counter is what makes
-- spending it cost something. `compute_creature_damage` still runs underneath,
-- which is what keeps physique, defense and the matchup chart worth having:
-- below the cap a tougher cultivator genuinely takes less, and only the
-- hopelessly outmatched feel the ceiling at all.
--
-- At 0.18 a striker who takes the full bite every time is spent after five,
-- which is exactly the allowance - so the two limits agree instead of one of
-- them being decorative.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('boss_bite_cap', 0.18,
     'Most of a striker''s maximum health one blow from a world beast can take. Five full bites is the whole strike allowance, so the two limits agree.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


CREATE OR REPLACE FUNCTION strike_boss(
    p_player_id    BIGINT,
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    encounter_id  BIGINT,
    beast_name    TEXT,
    technique     TEXT,
    dealt         BIGINT,
    taken         BIGINT,
    matchup       NUMERIC,
    boss_hp       BIGINT,
    boss_max_hp   BIGINT,
    my_hp         BIGINT,
    my_max_hp     BIGINT,
    strikes_left  INTEGER,
    slain         BOOLEAN,
    my_damage     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    live      RECORD;
    body      RECORD;
    move      BIGINT;
    move_name TEXT;
    hit       RECORD;
    back      BIGINT;
    spent     INTEGER;
    allowed   INTEGER := game_config_value('boss_strikes_each')::integer;
    left_hp   BIGINT;
    killed    BOOLEAN := FALSE;
    mine      BIGINT;
BEGIN
    PERFORM boss_open_if_due();

    SELECT e.encounter_id, e.species_id, e.current_hp, e.max_hp,
           cs.name, cs.base_defense
    INTO live
    FROM boss_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE e.status = 'open'
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'nothing is standing. **/boss** to see when the next one comes'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(bs.strikes, 0) INTO spent
    FROM (SELECT 1) _ LEFT JOIN boss_strikes bs
      ON bs.encounter_id = live.encounter_id AND bs.player_id = p_player_id;

    IF spent >= allowed THEN
        RAISE EXCEPTION 'you have spent all % of your strikes on this one', allowed
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.current_hp, pp.max_hp INTO body
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    IF body IS NULL OR body.current_hp <= 0 THEN
        RAISE EXCEPTION 'you have nothing left to swing with - **/rest**'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT t.technique_id, t.name INTO move, move_name
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    LEFT JOIN player_loadout l
           ON l.player_id = u.player_id AND l.technique_id = u.technique_id
    CROSS JOIN LATERAL compute_technique_damage(
        p_player_id, t.technique_id, live.species_id,
        player_external_multiplier(p_player_id, t.technique_id), 0) AS would
    WHERE u.player_id = p_player_id
      AND t.base_power > 0
      AND (p_technique_id IS NULL OR t.technique_id = p_technique_id)
    ORDER BY would.final_damage DESC, l.slot_index NULLS LAST, t.base_power DESC
    LIMIT 1;

    IF move IS NULL THEN
        RAISE EXCEPTION 'you know no technique that could hurt it'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO hit FROM compute_technique_damage(
        p_player_id, move, live.species_id,
        player_external_multiplier(p_player_id, move), 0);

    IF hit.final_damage <= 0 THEN
        RAISE EXCEPTION
            'it turns aside everything you know - bring another Path'
            USING ERRCODE = 'check_violation';
    END IF;

    left_hp := GREATEST(0, live.current_hp - hit.final_damage);
    killed  := left_hp = 0;

    UPDATE boss_encounters e
    SET current_hp = left_hp,
        status     = CASE WHEN killed THEN 'slain' ELSE e.status END,
        ended_at   = CASE WHEN killed THEN now() ELSE e.ended_at END,
        slayer_id  = CASE WHEN killed THEN p_player_id ELSE e.slayer_id END
    WHERE e.encounter_id = live.encounter_id;

    back := 0;
    IF NOT killed THEN
        SELECT LEAST(
                   gc.final_damage,
                   GREATEST(1, floor(body.max_hp
                                     * game_config_value('boss_bite_cap')))
               )::bigint
        INTO back
        FROM compute_creature_damage(live.species_id, p_player_id) gc;

        UPDATE player_physique pp
        SET current_hp = GREATEST(0, pp.current_hp - back)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO body.current_hp;
    END IF;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage, taken)
    VALUES (live.encounter_id, p_player_id, 1, hit.final_damage, back)
    ON CONFLICT ON CONSTRAINT boss_strikes_pkey DO UPDATE SET
        strikes     = boss_strikes.strikes + 1,
        damage      = boss_strikes.damage + EXCLUDED.damage,
        taken       = boss_strikes.taken + EXCLUDED.taken,
        last_struck = now()
    RETURNING boss_strikes.damage INTO mine;

    RETURN QUERY SELECT
        live.encounter_id, live.name, move_name,
        hit.final_damage, back, hit.matchup_modifier,
        left_hp, live.max_hp,
        body.current_hp, body.max_hp,
        allowed - spent - 1, killed, mine;
END;
$$;

COMMENT ON FUNCTION strike_boss(BIGINT, BIGINT) IS
    'One blow at the standing world beast, through the same damage pipeline a hunt uses, with the beast''s answer capped at a share of the striker''s health so the strike allowance is what limits a session.';


-- The allowance has to be the thing that runs out, not the health bar.
--
-- Counting strikes across the whole roster cannot say that: the first attempt
-- at this probe read 20 of a possible 50 and called it a swallowing, when what
-- actually happened was the beast dying on the twentieth blow and everybody
-- after it being told - correctly - that nothing was standing. A count of
-- strikes conflates "knocked flat" with "already won".
--
-- So this asserts the property directly, against a beast inflated past dying:
-- a striker who starts at full health must be able to spend their whole
-- allowance and still be standing at the end of it.

DO $$
DECLARE
    ghost   BIGINT;
    beast   BIGINT;
    r       RECORD;
    allowed INTEGER := game_config_value('boss_strikes_each')::integer;
    hp_left BIGINT;
BEGIN
    beast := boss_open_if_due();
    IF beast IS NULL THEN
        RAISE EXCEPTION 'no beast to test against';
    END IF;

    -- Out of reach of dying, so the only thing that can stop the loop is the
    -- striker running out of health or allowance.
    UPDATE boss_encounters
    SET max_hp = 1000000000, current_hp = 1000000000
    WHERE encounter_id = beast;

    INSERT INTO players (discord_id, discord_name)
    VALUES (-999141, 'migration 0141 probe')
    RETURNING player_id INTO ghost;

    INSERT INTO player_cultivation (player_id, cultivation, realm_id)
    VALUES (ghost, 0, 1);
    INSERT INTO player_physique (player_id, physique_id, body_level, max_hp, current_hp)
    VALUES (ghost, (SELECT physique_id FROM physiques LIMIT 1), 1, 1000, 1000);
    INSERT INTO player_techniques (player_id, technique_id)
    SELECT ghost, technique_id FROM techniques
    WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0;

    FOR i IN 1..allowed LOOP
        SELECT * INTO r FROM strike_boss(ghost);
        IF r.taken > 1000 * game_config_value('boss_bite_cap') THEN
            RAISE EXCEPTION 'the bite took % of a 1000 health body', r.taken;
        END IF;
    END LOOP;

    SELECT current_hp INTO hp_left FROM player_physique WHERE player_id = ghost;
    IF hp_left <= 0 THEN
        RAISE EXCEPTION
            'a striker spending exactly their allowance was left for dead';
    END IF;

    -- And the allowance is still what stops them.
    BEGIN
        PERFORM strike_boss(ghost);
        RAISE EXCEPTION 'the allowance did not hold';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    RAISE NOTICE 'boss probe: % strikes spent, % health left of 1000',
        allowed, hp_left;

    DELETE FROM boss_strikes WHERE player_id = ghost;
    DELETE FROM boss_encounters WHERE encounter_id = beast;
    DELETE FROM player_techniques WHERE player_id = ghost;
    DELETE FROM player_physique WHERE player_id = ghost;
    DELETE FROM player_cultivation WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
