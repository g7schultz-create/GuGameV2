-- 0424_the_anvil_says_what_it_is_making
--
-- Both doors onto the anvil describe the technique they are about to produce
-- in every way except the one that matters. /enlighten names the quality
-- ("Profound Insight"), the Paths and the three boons on the board.
-- /inscribe names the floor the pile guarantees and which Paths it can reach.
-- Neither says what the thing will HIT FOR.
--
-- A player is therefore asked to choose between a Clear Insight and a
-- Profound one, or to decide whether a pile of pages is worth burning,
-- without the number that decision is actually about. The forge card even
-- SELECTs `technique_power_for` for its "Last forged" line and then prints
-- only the name and the grade - the number was fetched and thrown away.
--
-- WHAT A GRADE IS WORTH is not a secret and is not complicated:
--
--     technique_forge_power_base * player_power_multiple(you) * grade
--
-- It is already written down inside `technique_power_for`, which lifted it
-- verbatim out of `compute_technique_damage` in 0395 so the two could not
-- disagree. This migration lifts it one step further out, into
-- `technique_grade_power`, so a SCREEN can ask what a grade would be worth
-- without a third copy of the arithmetic appearing in Python. The enlighten
-- cog's own docstring is explicit that a screen which computes the pipeline
-- itself is the first thing to diverge from it.
--
-- `technique_power_for` then calls it rather than keeping the expression, so
-- there is still exactly one place that knows what a grade is worth - which is
-- the whole reason 0395 existed.
--
-- WHAT THE SCREENS DO WITH IT. /enlighten holds a real `power_grade` and can
-- therefore print an exact figure. /inscribe holds only a FLOOR, so it prints
-- the band: what the pile guarantees and what it could reach, taken from
-- `enlighten_qualities.grade_min` and `grade_max` of the floor it landed on.
-- A floor with a number under it is a floor somebody can decide about.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_grade_power(p_player_id bigint, p_grade numeric)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- What a grade is worth to THIS cultivator today. The ceiling is 0392's:
    -- a forged technique is a grade against a realm, and the realm ladder is
    -- exponential, so the product needs a stop well inside what a bigint holds.
    SELECT LEAST(1000000000000000::numeric, round(
        game_config_value('technique_forge_power_base')
        * player_power_multiple(p_player_id) * GREATEST(0, p_grade)))::bigint;
$$;

COMMENT ON FUNCTION technique_grade_power(bigint, numeric) IS
    'What a technique of this grade would hit for in this cultivator''s hands. The one definition; `technique_power_for` asks it and so do the forge screens, because a screen that does this sum itself is the first thing to drift from the damage pipeline.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'technique_power_for'
      AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'technique_power_for is missing';
    END IF;

    anchor := concat(
'        SELECT LEAST(1000000000000000::numeric, round(', chr(10),
'            game_config_value(''technique_forge_power_base'')', chr(10),
'            * player_power_multiple(p_player_id) * f.power_grade))');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'technique_power_for no longer works out its power where it did';
    END IF;

    EXECUTE replace(body, anchor,
'        SELECT technique_grade_power(p_player_id, f.power_grade)');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The same number, whoever asks for it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_one  RECORD;
    r      RECORD;
BEGIN
    IF (SELECT prosrc FROM pg_proc
        WHERE proname = 'technique_power_for'
          AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%technique_grade_power%' THEN
        RAISE EXCEPTION 'technique_power_for still keeps its own copy';
    END IF;

    -- A forged technique must answer the same either way, or the screen and
    -- the swing are telling a player two different numbers.
    FOR v_one IN
        SELECT f.player_id, f.technique_id, f.power_grade
        FROM technique_forges f
        WHERE f.technique_id IS NOT NULL
        ORDER BY f.forge_id DESC LIMIT 5
    LOOP
        IF technique_power_for(v_one.player_id, v_one.technique_id)
           <> technique_grade_power(v_one.player_id, v_one.power_grade) THEN
            RAISE EXCEPTION
                'technique % reads % through one door and % through the other',
                v_one.technique_id,
                technique_power_for(v_one.player_id, v_one.technique_id),
                technique_grade_power(v_one.player_id, v_one.power_grade);
        END IF;
    END LOOP;

    -- And a deeper grade is worth more, or the ladder on the screen is a lie.
    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

    IF technique_grade_power(v_who, 4.2) <= technique_grade_power(v_who, 0.4) THEN
        RAISE EXCEPTION 'a Dao Revelation is not worth more than a Common one';
    END IF;

    FOR r IN
        SELECT q.name, q.grade_min, q.grade_max,
               technique_grade_power(v_who, q.grade_min) AS floor_power,
               technique_grade_power(v_who, q.grade_max) AS best_power
        FROM enlighten_qualities q ORDER BY q.sort_order
    LOOP
        RAISE NOTICE '% : grade % to %, hits for % to %',
            rpad(r.name, 22), r.grade_min, r.grade_max,
            r.floor_power, r.best_power;
    END LOOP;
END;
$probe$;
