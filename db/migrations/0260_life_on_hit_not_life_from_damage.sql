-- 0260_life_on_hit_not_life_from_damage
--
-- Life Steal returns a share of damage dealt, and damage quadruples every
-- great realm. So sustain grows with offence, while what a fight can do to you
-- is capped - `boss_bite_cap` takes at most 18% of your health, and Damage
-- Reduction quarters that. Miyuki heals 199,204 an exchange against a bite of
-- 123,721 and nets +75,483 in her favour, forever. A world boss cannot kill
-- her, and no amount of tuning the boss changes that: whatever it hits for,
-- she heals a fraction of a number that is bigger.
--
-- The stat is not overtuned. It is coupled to the wrong thing.
--
-- SO IT IS LIFE ON HIT. A fraction of the wearer's OWN maximum health, per
-- strike that lands, with no reference to how hard the strike was. Sustain is
-- now bounded by the same pool it is refilling, which is the only quantity in
-- this game that cannot run away from what is hitting you.
--
--     healed = max_hp x lifesteal x life_on_hit_rate x strikes landed
--
-- PER STRIKE, so Extra Strikes and Life on Hit are a real pairing rather than
-- two unrelated numbers - which is the same relationship they had when it was
-- a share of damage, kept deliberately.
--
-- The rate is set so that a MAXED Life on Hit returns about seventy per cent
-- of a world boss's bite. That is a build that fights far longer than anyone
-- else and still loses if it stands there, which is what sustain is supposed
-- to be. At Miyuki's current 0.146 it returns about a quarter of a bite.
--
-- The number on the Gu does not change - 157 Gu and 21 pieces of equipment
-- carry it and rewriting them would be a second migration's worth of risk for
-- no gain. What changes is what the number means, so the effect is renamed to
-- say so.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('life_on_hit_rate', 0.04,
     'What one point of Life on Hit returns per strike, as a share of the '
     'wearer''s own maximum health. Set so a maxed build takes back about '
     'seventy per cent of a world beast''s bite - a long fight, not an '
     'unlosable one.');

UPDATE gu_effects
SET name = 'Life on Hit',
    description = 'Health back on every strike that lands, as a share of your '
                  'own maximum. It does not care how hard you hit.'
WHERE code = 'lifesteal';


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'player_swing';

    -- ---- count what actually landed --------------------------------------
    old := '    FOR strike IN 1..n_strikes LOOP
        EXIT WHEN left_hp <= 0;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing no longer loops its strikes the old way';
    END IF;
    src := replace(src, old,
'    FOR strike IN 1..n_strikes LOOP
        EXIT WHEN left_hp <= 0;
        landed := landed + 1;');

    -- ---- and heal off the body rather than off the damage -----------------
    old := '    IF steal > 0 AND out_dmg > 0 THEN
        got_back := floor(out_dmg * steal);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing no longer steals life the old way';
    END IF;
    src := replace(src, old,
'    -- Life on hit: a share of the wearer''s OWN maximum health per strike
    -- that landed, with no reference to how hard it was. A share of damage
    -- grew with offence, and offence quadruples every great realm, so sustain
    -- outran anything a capped bite could do about it.
    --
    -- A fight that tracks no body - a horde channel - still has one on the
    -- physique, and its healing is counted as contribution rather than health.
    IF steal > 0 AND landed > 0 THEN
        got_back := floor(
            COALESCE(p_player_max_hp,
                     (SELECT pp.max_hp FROM player_physique pp
                      WHERE pp.player_id = p_player_id), 0)
            * steal * game_config_value(''life_on_hit_rate'') * landed);');

    old := '    got_back  BIGINT := 0;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing no longer declares what comes back';
    END IF;
    src := replace(src, old,
'    got_back  BIGINT := 0;
    landed    INTEGER := 0;');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who     BIGINT;
    move    BIGINT;
    species BIGINT;
    weak    RECORD;
    strong  RECORD;
    body    BIGINT;
    heal    BIGINT;
    bite    BIGINT;
BEGIN
    SELECT pp.player_id, pp.max_hp INTO who, body
    FROM player_physique pp
    JOIN players p ON p.player_id = pp.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
      AND player_stat(pp.player_id, 'lifesteal') > 0
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody carries it; the tests carry this';
        RETURN;
    END IF;

    move    := dungeon_default_move(who);
    species := (SELECT cs.species_id FROM creature_species cs
                WHERE cs.kind = 'beast' LIMIT 1);

    BEGIN
        -- Wounded, so there is room to take anything back at all.
        SELECT * INTO weak FROM player_swing(
            who, move, species, 99999999::bigint, 0::bigint,
            (body / 2)::bigint, body, 1);

        IF weak.healed <= 0 THEN
            RAISE EXCEPTION 'a strike returned nothing';
        END IF;

        -- The whole point: it does not move when the damage does. The same
        -- body against a target it cannot dent returns the same health.
        SELECT * INTO strong FROM player_swing(
            who, move, species, 99999999999::bigint, 0::bigint,
            (body / 2)::bigint, body, 1);

        IF weak.strikes = strong.strikes
           AND weak.healed <> strong.healed THEN
            RAISE EXCEPTION
                'healing still tracks the damage: % against %',
                weak.healed, strong.healed;
        END IF;

        -- And a maxed build does not out-heal a world beast's bite.
        heal := floor(body * (SELECT cap FROM gu_effects WHERE code = 'lifesteal')
                      * game_config_value('life_on_hit_rate') * 2);
        bite := floor(body * game_config_value('boss_bite_cap')
                      * (1 - LEAST(game_config_value('damage_reduction_ceiling'),
                                   (SELECT cap FROM gu_effects
                                    WHERE code = 'damage_reduction'))));

        IF heal >= bite THEN
            RAISE EXCEPTION
                'a maxed build still takes back % against a bite of %',
                heal, bite;
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
