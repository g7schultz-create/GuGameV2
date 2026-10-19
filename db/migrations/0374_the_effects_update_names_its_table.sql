-- 0374_the_effects_update_names_its_table
--
-- 0373 hangs the battle effects on a forged technique with:
--
--     UPDATE techniques SET effects = ... WHERE technique_id = new_t;
--
-- `forge_take` RETURNS TABLE(done, technique_id, manual_id, step), so
-- `technique_id` is a PL/pgSQL variable in that function as well as a column
-- on `techniques`, and Postgres refuses to guess:
--
--     column reference "technique_id" is ambiguous
--
-- One qualified name fixes it. What is worth more than the fix is why 0373's
-- own probe passed over it: effects are only attached from Profound Insight
-- upward, the probe forged exactly once, and it rolled Clear. Sixty per cent
-- of forges never reach that branch, so a single unseeded run is a coin toss
-- about whether the feature is tested at all.
--
-- The probe here does not roll for it. It walks EVERY tier, forces each one
-- onto a forge, and drives it through - so the branch is exercised whatever
-- the dice were going to say.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'            UPDATE techniques SET effects = jsonb_build_object(''apply'', kinds),', chr(10),
'                   cooldown_turns = LEAST(5, 1 + jsonb_array_length(kinds))', chr(10),
'            WHERE technique_id = new_t;');

    swap := concat(
'            -- Qualified: `technique_id` is also this function''s own OUT', chr(10),
'            -- parameter, and Postgres will not choose between them.', chr(10),
'            UPDATE techniques SET effects = jsonb_build_object(''apply'', kinds),', chr(10),
'                   cooldown_turns = LEAST(5, 1 + jsonb_array_length(kinds))', chr(10),
'            WHERE techniques.technique_id = new_t;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'forge_take';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer hangs effects where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every tier forged, not whichever one the dice offered
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    q      RECORD;
    fid    BIGINT;
    board  JSONB;
    got    RECORD;
    steps  INTEGER := game_config_value('technique_forge_steps')::integer;
    made   RECORD;
    carried INTEGER;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= game_config_value('technique_forge_min_rank')
    ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to forge with';
        RETURN;
    END IF;

    BEGIN
        FOR q IN SELECT * FROM enlighten_qualities ORDER BY sort_order LOOP
            DELETE FROM technique_forges
            WHERE player_id = who AND finished_at IS NULL;
            DELETE FROM player_cooldowns
            WHERE player_id = who AND action = 'forge_technique';

            fid := forge_begin(who, NULL);

            -- Forced onto the tier being tested rather than hoped for. The
            -- grade is moved with it so the pair stays coherent.
            UPDATE technique_forges
            SET quality = q.code,
                power_grade = round(q.grade_min
                                    + (q.grade_max - q.grade_min) / 2, 3)
            WHERE forge_id = fid;

            FOR i IN 1..steps LOOP
                board := forge_offer(fid);
                SELECT * INTO got FROM forge_take(fid, board -> 0 ->> 'code');
            END LOOP;

            SELECT t.name, t.effects, t.qi_cost_pct, t.cooldown_turns
            INTO made
            FROM techniques t
            JOIN technique_forges tf ON tf.technique_id = t.technique_id
            WHERE tf.forge_id = fid;

            IF made.name IS NULL THEN
                RAISE EXCEPTION '% built nothing', q.code;
            END IF;
            IF NOT technique_effects_well_formed(made.effects) THEN
                RAISE EXCEPTION '% came out malformed: %', q.code, made.effects;
            END IF;

            carried := COALESCE(jsonb_array_length(made.effects -> 'apply'), 0);

            -- A tier that promises effects must deliver them, and one that
            -- promises none must not invent any.
            IF q.effects > 0 AND carried = 0 THEN
                RAISE EXCEPTION
                    '% promises % effects and carried none', q.code, q.effects;
            END IF;
            IF q.effects = 0 AND carried > 0 THEN
                RAISE EXCEPTION
                    '% promises nothing and carried %', q.code, carried;
            END IF;
            IF carried > q.effects THEN
                RAISE EXCEPTION
                    '% promised % effects and carried %', q.code, q.effects, carried;
            END IF;

            -- And nothing it carries exceeds that effect's own ceiling.
            IF EXISTS (
                SELECT 1
                FROM jsonb_array_elements(COALESCE(made.effects -> 'apply',
                                                   '[]'::jsonb)) AS e
                JOIN battle_effect_kinds b ON b.code = e ->> 'code'
                WHERE (e ->> 'magnitude')::numeric > b.cap
            ) THEN
                RAISE EXCEPTION '% carried an effect past its cap: %',
                    q.code, made.effects;
            END IF;

            RAISE NOTICE '% : % (qi %, cd %) carrying % effect(s)',
                rpad(q.name, 20), made.name, made.qi_cost_pct,
                made.cooldown_turns, carried;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'all six tiers forged and rolled back';
END;
$probe$;
