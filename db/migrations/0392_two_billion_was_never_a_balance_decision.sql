-- 0392_two_billion_was_never_a_balance_decision
--
-- `compute_technique_damage` throws `integer out of range` for pashu0 today.
-- Not in some future realm - now, on a technique he already owns:
--
--     Ascendant Refinement Art   tech_base 1,834,454,352
--     his body                   thews       934,054,724
--                                sum       2,768,509,076   > 2,147,483,647
--
-- The line is `raw := (tech_base + thews) * ...` and both are declared INTEGER,
-- so the ADDITION is integer arithmetic and overflows before anything is
-- multiplied. The only reason nobody has seen it is that the technique is not
-- in his usable set - he has not equipped that manual. The day he does, every
-- swing he makes raises a database error instead of a number.
--
-- sylvrime is at 871M of the 2,147M and m_i_y_u_k_i at 495M. This was going to
-- happen to all three of them.
--
-- WHY THE CLAMP DID NOT SAVE IT. `tech_base` is already held to two billion,
-- and two billion is not a number anybody chose - it is INT_MAX with the round
-- numbers kept, a type guard wearing a game designer's hat. It guards the one
-- term and then the very next line adds an unguarded one to it.
--
-- So the type is the thing that is wrong, and it is wrong in four places that
-- have to move together or the overflow simply relocates:
--
--     tech_base, thews          the locals, and the addition between them
--     base_power, body_power    the columns this function RETURNS
--     battle_actions.base_power what the duel writes the first of those into
--     the clamp itself          which only existed to fit inside the first
--
-- THE CLAMP GOES UP RATHER THAN AWAY. A guard against a body doing something
-- absurd is still worth having - `raw` is numeric and `final_damage` is
-- bigint, but a value that has gone wrong upstream should stop here rather
-- than propagate. At 1e15 it is a thousand times past anything reachable
-- (pashu's best possible forge is 3.2e9) and comfortably inside bigint after
-- everything downstream multiplies it.
--
-- WHICH MEANS THIS IS ALSO A BALANCE CHANGE, AND IT IS WORTH SAYING SO. Two
-- billion was a real ceiling on forged power that nobody decided on. Lifting
-- it lets a deep cultivator's technique keep scaling with the realms above
-- them, which is what `player_power_multiple` was for. If a ceiling IS wanted,
-- it should be a number chosen for the game and put in `game_config` where it
-- can be argued about - not left as the largest signed 32-bit integer.
--
-- The return type changes, so this DROPs and recreates rather than replacing.
-- The body is lifted with `pg_get_functiondef` and patched, never retyped -
-- five surgical replacements, each asserted to match exactly once.
--
-- Forward-only. Do not edit once applied.


-- What the duel writes the returned base_power into.
ALTER TABLE battle_actions ALTER COLUMN base_power TYPE BIGINT;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_technique_damage';

    IF body IS NULL THEN
        RAISE EXCEPTION 'compute_technique_damage is missing';
    END IF;

    -- ---- what it hands back -----------------------------------------------
    anchor := 'RETURNS TABLE(base_power integer, attainment_bonus numeric, matchup_modifier numeric, pre_defense numeric, final_damage bigint, body_power integer)';
    swap   := 'RETURNS TABLE(base_power bigint, attainment_bonus numeric, matchup_modifier numeric, pre_defense numeric, final_damage bigint, body_power bigint)';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_technique_damage does not return what it did';
    END IF;
    body := replace(body, anchor, swap);

    -- ---- and the two terms it adds together -------------------------------
    anchor := '    tech_base     INTEGER;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'tech_base is not declared where it was';
    END IF;
    body := replace(body, anchor, '    tech_base     BIGINT;');

    anchor := '    thews         INTEGER;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'thews is not declared where it was';
    END IF;
    body := replace(body, anchor, '    thews         BIGINT;');

    anchor := '    ), tech_base)::integer;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'tech_base is not cast where it was';
    END IF;
    body := replace(body, anchor, '    ), tech_base)::bigint;');

    anchor := '        * game_config_value(''physique_strength_damage'')))::integer;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'thews is not cast where it was';
    END IF;
    body := replace(body, anchor,
        '        * game_config_value(''physique_strength_damage'')))::bigint;');

    -- ---- and the ceiling that only existed to fit inside an integer -------
    anchor := '        SELECT LEAST(2000000000::numeric, round(';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the clamp is not where 0360 put it';
    END IF;
    body := replace(body, anchor,
        '        SELECT LEAST(1000000000000000::numeric, round(');

    -- The return type moved, so REPLACE will not do it.
    DROP FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT);
    EXECUTE body;
END;
$patch$;


COMMENT ON FUNCTION compute_technique_damage(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT) IS
    'What one swing of a technique does. Everything wide enough to hold what the deepest cultivator in the game can actually produce, since 0392.';


-- ---------------------------------------------------------------------------
-- The swing that threw this morning
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r       RECORD;
    v_prey  BIGINT;
    v_hit   NUMERIC;
    v_n     INTEGER := 0;
    v_worst NUMERIC := 0;
BEGIN
    SELECT species_id INTO v_prey FROM creature_species
    WHERE kind = 'beast' ORDER BY rank LIMIT 1;

    -- Every forged technique in the game, swung. This is the set the overflow
    -- lived in and the only honest way to know it is gone.
    FOR r IN
        SELECT p.discord_name, t.name, f.player_id, f.technique_id,
               f.power_grade
        FROM technique_forges f
        JOIN techniques t ON t.technique_id = f.technique_id
        JOIN players p ON p.player_id = f.player_id
        WHERE f.finished_at IS NOT NULL
        ORDER BY f.power_grade DESC
    LOOP
        SELECT cd.final_damage INTO v_hit
        FROM compute_technique_damage(r.player_id, r.technique_id, v_prey,
                                      1::numeric, 0) cd;
        IF v_hit IS NULL THEN
            RAISE EXCEPTION '% swinging % came back with nothing',
                r.discord_name, r.name;
        END IF;
        v_n := v_n + 1;
        v_worst := GREATEST(v_worst, v_hit);
    END LOOP;

    RAISE NOTICE '% forged techniques all swing; the hardest lands %',
        v_n, round(v_worst);

    -- And the thing that actually threw: the sum of a clamped technique and a
    -- real body, which is 2.77e9 for pashu0 and was 620 million past INT_MAX.
    -- Built in a subquery so the multiple is computed per player rather than
    -- fought with in a GROUP BY.
    FOR r IN
        SELECT who.discord_name, who.sum_of
        FROM (
            SELECT p.discord_name,
                   LEAST(1000000000000000::numeric,
                         round(game_config_value('technique_forge_power_base')
                               * player_power_multiple(p.player_id)
                               * (SELECT max(f.power_grade)
                                  FROM technique_forges f
                                  WHERE f.player_id = p.player_id
                                    AND f.finished_at IS NOT NULL)))
                   + round(pp.strength
                           * game_config_value('physique_strength_damage'))
                       AS sum_of
            FROM players p
            JOIN player_physique pp ON pp.player_id = p.player_id
            WHERE p.deleted_at IS NULL
              AND EXISTS (SELECT 1 FROM technique_forges f
                          WHERE f.player_id = p.player_id
                            AND f.finished_at IS NOT NULL)
        ) who
        WHERE who.sum_of > 2147483647
        ORDER BY who.sum_of DESC
    LOOP
        RAISE NOTICE
            '% adds to % - past the old ceiling, and now fine',
            rpad(r.discord_name, 14), r.sum_of;
    END LOOP;

    -- Nothing downstream is narrower than what this now hands it.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND (c.table_name, c.column_name) IN
              (('battle_actions', 'base_power'))
          AND c.data_type <> 'bigint'
    ) THEN
        RAISE EXCEPTION 'the duel still writes its base power into an integer';
    END IF;
END;
$probe$;
