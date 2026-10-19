-- 0261_a_strike_that_lands_always_returns_something
--
-- 0260 tied Life on Hit to the wearer's own maximum health, and a new
-- cultivator's maximum is 120.
--
--     120 x 0.15 x 0.04 = 0.72, floored to nothing
--
-- So the effect does exactly zero until somewhere around 170 maximum health,
-- which is most of the way through the first body rank. A Gu that says it
-- gives health back and gives none is worse than one that says nothing - and
-- it is precisely the class of thing this codebase has spent the day
-- deleting.
--
-- A strike that lands returns at least a point. Negligible to anyone the rate
-- actually serves, and the difference between an effect and a decoration to
-- anyone it does not. It is the same `GREATEST(1, ...)` the damage pipeline
-- has always used to stop a landed blow rounding away to nothing.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'player_swing';

    old := '        got_back := floor(
            COALESCE(p_player_max_hp,
                     (SELECT pp.max_hp FROM player_physique pp
                      WHERE pp.player_id = p_player_id), 0)
            * steal * game_config_value(''life_on_hit_rate'') * landed);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing no longer returns life the 0260 way';
    END IF;

    src := replace(src, old,
'        got_back := GREATEST(landed, floor(
            COALESCE(p_player_max_hp,
                     (SELECT pp.max_hp FROM player_physique pp
                      WHERE pp.player_id = p_player_id), 0)
            * steal * game_config_value(''life_on_hit_rate'') * landed));');

    EXECUTE src;
END;
$$;


DO $$
DECLARE
    who     BIGINT;
    move    BIGINT;
    species BIGINT;
    swung   RECORD;
BEGIN
    -- The smallest body that carries it, which is where the rounding bit.
    SELECT pp.player_id INTO who
    FROM player_physique pp
    JOIN players p ON p.player_id = pp.player_id
    WHERE p.deleted_at IS NULL
      AND dungeon_default_move(pp.player_id) IS NOT NULL
      AND player_stat(pp.player_id, 'lifesteal') > 0
    ORDER BY pp.max_hp ASC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody small carries it; the tests carry this';
        RETURN;
    END IF;

    move    := dungeon_default_move(who);
    species := (SELECT cs.species_id FROM creature_species cs
                WHERE cs.kind = 'beast' LIMIT 1);

    BEGIN
        -- A body of 120, wounded, against something it cannot fell.
        SELECT * INTO swung FROM player_swing(
            who, move, species, 99999999::bigint, 0::bigint,
            10::bigint, 120::bigint, 1);

        IF swung.healed < 1 THEN
            RAISE EXCEPTION
                'a strike returned nothing to a body of 120';
        END IF;

        -- And it still cannot overfill.
        IF swung.healed > 110 THEN
            RAISE EXCEPTION 'a strike returned % into room for 110', swung.healed;
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
