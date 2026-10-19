-- 0133_found_is_a_word_plpgsql_already_owns
--
-- 0131 rewrote `roll_manual_drop` and added a lookup guarded by `IF NOT FOUND`.
-- The function has declared a BIGINT local called `found` since 0021, and a
-- declared variable SHADOWS plpgsql's built-in FOUND - so `NOT FOUND` was
-- `NOT <a bigint>`, and every kill raised
--
--     argument of NOT must be type boolean, not type bigint
--
-- Not caught by the migration's own checks, because those exercise the content
-- and the config rather than the code path; caught by the command test that
-- fights something, which is the test that runs the function.
--
-- The variable is renamed rather than the guard rewritten. `FOUND` is
-- plpgsql's word and the fix is to stop taking it.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION roll_manual_drop(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    beast  RECORD;
    picked BIGINT;
BEGIN
    SELECT cs.rank, cs.kind INTO beast
    FROM creature_species cs WHERE cs.species_id = p_species_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- The hard fights, and only them. Rolled first because it is the rarer and
    -- better outcome, and a kill that yields a killer move should not also
    -- yield a stat manual.
    IF beast.kind IN ('elite', 'boss', 'world')
       AND random() < game_config_value('technique_manual_drop_chance') THEN
        SELECT m.manual_id INTO picked
        FROM manuals m
        WHERE m.code IS NOT NULL
          AND m.archetype = 'technique'
          AND m.required_rank <= GREATEST(beast.rank, 1)
          AND NOT EXISTS (
              SELECT 1 FROM player_manuals pm
              WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
          )
        ORDER BY random()
        LIMIT 1;

        IF picked IS NOT NULL THEN
            INSERT INTO player_manuals (player_id, manual_id)
            VALUES (p_player_id, picked)
            ON CONFLICT DO NOTHING;
            RETURN picked;
        END IF;
    END IF;

    IF random() >= game_config_value('manual_drop_chance') THEN
        RETURN NULL;
    END IF;

    SELECT m.manual_id INTO picked
    FROM manuals m
    WHERE m.code IS NOT NULL
      AND m.archetype <> 'technique'
      AND m.required_rank <= GREATEST(beast.rank, 1)
      AND NOT EXISTS (
          SELECT 1 FROM player_manuals pm
          WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
      )
    ORDER BY random()
    LIMIT 1;

    IF picked IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, picked)
    ON CONFLICT DO NOTHING;

    RETURN picked;
END;
$$;

COMMENT ON FUNCTION roll_manual_drop(BIGINT, BIGINT) IS
    'A manual off a corpse. Elites, bosses and world beasts roll first for a technique manual; everything else can only ever yield an ordinary one.';


-- It has to survive being called, which is the whole of what went wrong.
DO $$
DECLARE
    victim BIGINT;
    ghost  BIGINT;
BEGIN
    SELECT cs.species_id INTO victim FROM creature_species cs
    WHERE cs.kind = 'elite' ORDER BY cs.rank DESC LIMIT 1;

    INSERT INTO players (discord_id, discord_name)
    VALUES (-999133, 'migration 0133 probe')
    RETURNING player_id INTO ghost;

    -- Called enough times that both branches and both misses are exercised.
    FOR i IN 1..40 LOOP
        PERFORM roll_manual_drop(ghost, victim);
    END LOOP;

    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
