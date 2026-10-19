-- 0461_a_forge_may_commit_to_what_it_carries
--
-- Every technique anybody has ever forged is an attack. `forge_take` writes
-- `category` as the literal 'attack' and always has, so a day's meditation
-- produces damage and only damage - and then, a third of the time, hangs a
-- small rider off it:
--
--     clear 28 / common 40    no effect at all        68 per cent
--     profound 18 / great 9   one effect              27
--     heavenly 4              two                      4
--     dao 1                   three                    1
--
-- So the riders exist and are already drawn from the Paths the technique
-- stands on. What is missing is the technique that is ABOUT its effect: the
-- stance, the mending art, the thing that holds a creature's attention. 0459
-- seeded nine of those by hand; none of them can be forged, and the Trial asks
-- for exactly those three things.
--
-- SO A FORGE THAT CARRIES SOMETHING MAY COMMIT TO IT. When at least one effect
-- was drawn, the technique can come out as a stance instead of a strike:
--
--     it keeps          15 per cent of the damage it would have done
--     its effects are   three times the size, clamped at the kind's own cap
--     they last         one turn longer
--     its category      follows the effect - mending is support, warding is
--                       defence, a pull is utility
--
-- WHICH PATHS YOU WALKED DECIDES HOW LIKELY. `path_effect_bias` already knows
-- that some Paths lean toward mending and others toward raw force; the chance
-- is the base chance scaled by how far the forge's Paths lean away from
-- attack_up. A forge on Qi and Water commits far more readily than one on
-- Sword and Lightning. That makes the stance a consequence of what the
-- cultivator walked in with rather than a coin landing on its edge.
--
-- IT CANNOT HAPPEN TO A PLAIN FORGE. No effects drawn, no stance - a technique
-- with 15 per cent damage and nothing to show for it would be a punishment for
-- rolling badly twice.
--
-- THE CAP IS STILL THE CAP. Tripling a magnitude is clamped by
-- `battle_effect_kinds.cap`, so the ceiling a stance reaches is the ceiling
-- anything reaches; what it buys is getting there in one technique.
--
-- Lifted and patched. The name, the Paths, the power budget, the manual and
-- the weight-rounding below it are untouched.
--
-- `lead_kind` rather than `leading`, which is reserved in Postgres by way
-- of `trim(leading ...)`. The same family as the `BOTH` collision in 0439.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('enlighten_stance_chance', 0.35,
     'The base chance that a forged technique which drew at least one effect commits to it and comes out as a stance rather than a strike. Scaled by how far the forge''s Paths lean away from raw damage, so the real figure runs from about 0.18 to about 0.53.'),
    ('enlighten_stance_power_share', 0.15,
     'What damage a stance keeps. Not zero: a technique that throws your whole turn away is one nobody chooses, and the point is a trade rather than a renunciation.'),
    ('enlighten_stance_effect_multiple', 3.0,
     'How much larger a stance''s effects are than the same roll hung off an attack. Clamped afterwards by each kind''s own cap, so this buys reaching the ceiling in one technique rather than raising it.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    better TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'forge_take' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'forge_take is missing';
    END IF;

    -- ---- room for what the decision needs --------------------------------
    anchor := concat(
'        kinds JSONB := ''[]''::jsonb;', chr(10),
'        k     RECORD;', chr(10),
'    BEGIN');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer declares its effect draw here';
    END IF;

    body := replace(body, anchor, concat(
'        kinds JSONB := ''[]''::jsonb;', chr(10),
'        k     RECORD;', chr(10),
'        lean    NUMERIC;', chr(10),
'        stance  BOOLEAN := FALSE;', chr(10),
'        lead_kind TEXT;', chr(10),
'    BEGIN'));

    -- ---- and the commitment itself ---------------------------------------
    anchor := concat(
'        IF jsonb_array_length(kinds) > 0 THEN', chr(10),
'            -- Qualified: `technique_id` is also this function''s own OUT', chr(10),
'            -- parameter, and Postgres will not choose between them.', chr(10),
'            UPDATE techniques SET effects = jsonb_build_object(''apply'', kinds),', chr(10),
'                   cooldown_turns = LEAST(5, 1 + jsonb_array_length(kinds))', chr(10),
'            WHERE techniques.technique_id = new_t;', chr(10),
'        END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer writes its effects where it did';
    END IF;

    better := concat(
'        IF jsonb_array_length(kinds) > 0 THEN', chr(10),
'            -- 0461: a forge that drew something may commit to it. How far', chr(10),
'            -- these Paths lean away from raw force decides how readily.', chr(10),
'            SELECT COALESCE(', chr(10),
'                sum(pb.weight) FILTER (WHERE pb.effect_code <> ''attack_up'')', chr(10),
'                / NULLIF(sum(pb.weight), 0), 0.5)', chr(10),
'            INTO lean', chr(10),
'            FROM path_effect_bias pb WHERE pb.path_code = ANY (f.paths);', chr(10),
'', chr(10),
'            stance := random() < game_config_value(''enlighten_stance_chance'')', chr(10),
'                               * (0.5 + COALESCE(lean, 0.5));', chr(10),
'', chr(10),
'            IF stance THEN', chr(10),
'                -- Three times the size, and never past the kind''''s own cap.', chr(10),
'                SELECT jsonb_agg(jsonb_set(jsonb_set(el,', chr(10),
'                           ''{magnitude}'', to_jsonb(LEAST(bk.cap, round(', chr(10),
'                               (el ->> ''magnitude'')::numeric', chr(10),
'                               * game_config_value(''enlighten_stance_effect_multiple''),', chr(10),
'                               3)))),', chr(10),
'                           ''{turns}'', to_jsonb(', chr(10),
'                               (el ->> ''turns'')::integer + 1)))', chr(10),
'                INTO kinds', chr(10),
'                FROM jsonb_array_elements(kinds) el', chr(10),
'                JOIN battle_effect_kinds bk ON bk.code = el ->> ''code'';', chr(10),
'', chr(10),
'                lead_kind := kinds -> 0 ->> ''code'';', chr(10),
'            END IF;', chr(10),
'', chr(10),
'            -- Qualified: `technique_id` is also this function''s own OUT', chr(10),
'            -- parameter, and Postgres will not choose between them.', chr(10),
'            UPDATE techniques SET effects = jsonb_build_object(''apply'', kinds),', chr(10),
'                   cooldown_turns = LEAST(5, 1 + jsonb_array_length(kinds))', chr(10),
'            WHERE techniques.technique_id = new_t;', chr(10),
'', chr(10),
'            IF stance THEN', chr(10),
'                UPDATE techniques t SET', chr(10),
'                    category = CASE lead_kind', chr(10),
'                        WHEN ''regen''      THEN ''support''', chr(10),
'                        WHEN ''defence_up'' THEN ''defense''', chr(10),
'                        WHEN ''block_up''   THEN ''defense''', chr(10),
'                        WHEN ''taunt''      THEN ''utility''', chr(10),
'                        ELSE ''support'' END,', chr(10),
'                    base_power = GREATEST(0, round(t.base_power', chr(10),
'                        * game_config_value(''enlighten_stance_power_share'')))::bigint,', chr(10),
'                    description = t.description', chr(10),
'                        || '' It came out a stance rather than a strike: most''', chr(10),
'                        || '' of its force went into what it leaves behind.''', chr(10),
'                WHERE t.technique_id = new_t;', chr(10),
'            END IF;', chr(10),
'        END IF;');

    EXECUTE replace(body, anchor, better);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A stance is a real trade, and a plain forge is untouched
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_src   TEXT;
    v_cap   NUMERIC;
    v_over  INTEGER;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc
    WHERE proname = 'forge_take' AND pronamespace = 'public'::regnamespace;

    -- The commitment is gated on having drawn something. A stance with no
    -- effect would be an attack at fifteen per cent and nothing else.
    IF strpos(v_src, 'stance := random()') = 0 THEN
        RAISE EXCEPTION 'the forge never decides whether to commit';
    END IF;
    IF strpos(v_src, 'IF jsonb_array_length(kinds) > 0 THEN') = 0 THEN
        RAISE EXCEPTION 'the commitment is no longer behind an effect draw';
    END IF;

    -- Everything the patch was not allowed to disturb is still there.
    FOREACH v_src IN ARRAY ARRAY[
        'INSERT INTO technique_paths',
        'INSERT INTO manuals',
        'technique_forge_power_base',
        'path_words'
    ] LOOP
        IF strpos((SELECT prosrc FROM pg_proc WHERE proname = 'forge_take'
                   AND pronamespace = 'public'::regnamespace), v_src) = 0 THEN
            RAISE EXCEPTION 'the patch lost %', v_src;
        END IF;
    END LOOP;

    -- No kind may be lifted past its own ceiling by the tripling. Checked
    -- arithmetically against the live caps rather than trusted.
    SELECT count(*) INTO v_over
    FROM battle_effect_kinds b
    WHERE b.cap * 0.25 * 2.0 * 1.3
          * game_config_value('enlighten_stance_effect_multiple') <= b.cap;
    IF v_over > 0 THEN
        RAISE EXCEPTION
            'the multiple is so small that % kinds can never reach their cap',
            v_over;
    END IF;

    FOR v_cap IN SELECT b.cap FROM battle_effect_kinds b LOOP
        IF LEAST(v_cap, v_cap * 0.25 * 2.0 * 1.3
                 * game_config_value('enlighten_stance_effect_multiple')) > v_cap THEN
            RAISE EXCEPTION 'a stance can exceed a cap of %', v_cap;
        END IF;
    END LOOP;

    -- And the trade is a trade: a stance must keep some damage and lose most.
    IF game_config_value('enlighten_stance_power_share') <= 0
       OR game_config_value('enlighten_stance_power_share') >= 0.5 THEN
        RAISE EXCEPTION
            'a stance keeping % of its damage is not a trade',
            game_config_value('enlighten_stance_power_share');
    END IF;
END;
$probe$;
