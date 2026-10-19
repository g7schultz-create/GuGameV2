-- 0255_an_audit_of_things_nothing_reads
--
-- Every one of the thirty-two live effects now has a reader, which was not
-- true this morning: 0225, 0243 and 0247 closed the last of them. So this
-- audit went looking at the other two places a system quietly stops existing -
-- dials nothing reads, and rules nothing enforces.
--
-- WHAT IT FOUND:
--
--   * `hunt_turn_cap` is a second name for `battle_turn_cap`. Both say 50,
--     both describe the same stalemate rule, and only one of them is read. A
--     designer tuning the wrong one would watch nothing happen.
--
--   * `gu_refine_aux_max` says it is a "hard ceiling on auxiliary materials in
--     one refinement" and `refine_gu` counts the array without ever comparing
--     it to anything. The ceiling was a sentence.
--
--   * `battle_act` still reads `lifesteal` into a variable it stopped using
--     when 0226 moved the swing into `player_swing`. Harmless, and it makes
--     the duel look like a second reader of an effect in exactly the audit
--     this migration is.
--
--   * `horde_gauntlet_exchanges` and `world_beast_body_multiple` are mine,
--     from today. The first described a whole-wave resolver that 0231 replaced
--     with one exchange a press; the second was read once by a data migration
--     and never again. Both imply they are tunable and neither is.
--
--   * `dual_path_primary_weight` describes how seed data was built and is read
--     by nothing at runtime.
--
-- WHAT IT FOUND AND DID NOT TOUCH: `training_sessions`, its resolver and
-- `training_max_hours` are a complete subsystem with no way in - nothing
-- inserts a session and nothing calls `resolve_training_session`. Deleting a
-- table is not an audit's job, so it is reported rather than removed.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Rules that were only sentences
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'refine_gu';

    old := '    n_aux := COALESCE(array_length(p_aux_codes, 1), 0);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'refine_gu no longer counts its auxiliaries the old way';
    END IF;

    EXECUTE replace(src, old,
'    n_aux := COALESCE(array_length(p_aux_codes, 1), 0);

    -- `gu_refine_aux_max` called itself a hard ceiling and nothing compared
    -- anything to it. A ceiling nobody checks is a sentence.
    IF n_aux > game_config_value(''gu_refine_aux_max'')::integer THEN
        RAISE EXCEPTION ''a refinement takes at most % auxiliary materials'',
            game_config_value(''gu_refine_aux_max'')::integer
            USING ERRCODE = ''check_violation'';
    END IF;');
END;
$$;


-- ---------------------------------------------------------------------------
-- A variable that read a stat and did nothing with it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'battle_act';

    old := '        steal     := player_stat(me.player_id, ''lifesteal'');';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer reads the leftover steal';
    END IF;
    src := replace(src, old, '');

    old := '    steal      NUMERIC;
';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer declares the leftover steal';
    END IF;
    src := replace(src, old, '');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- Dials that describe nothing
-- ---------------------------------------------------------------------------
-- `hunt_turn_cap` goes rather than being wired up: `battle_turn_cap` already
-- does the job, they hold the same 50, and two dials for one rule is the thing
-- that made this findable in the first place.

DELETE FROM game_config WHERE key IN (
    'hunt_turn_cap',
    'horde_gauntlet_exchanges',
    'world_beast_body_multiple',
    'dual_path_primary_weight');


DO $$
DECLARE
    orphan TEXT;
BEGIN
    -- Every live effect still has somewhere that reads it. This is the
    -- invariant the whole day was spent earning; it is worth keeping.
    SELECT string_agg(e.code, ', ') INTO orphan
    FROM gu_effects e
    WHERE e.is_live
      AND NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.prosrc LIKE '%''' || e.code || '''%'
          AND p.proname NOT IN ('player_stat', 'gu_stat', 'equipment_stat',
                                'physique_stat', 'root_stat', 'dwelling_stat',
                                'manual_stat', 'destiny_stat'));
    IF orphan IS NOT NULL THEN
        RAISE EXCEPTION 'these effects are worn and read by nothing: %', orphan;
    END IF;

    -- And the ceiling is a ceiling now.
    IF position('gu_refine_aux_max' IN
                (SELECT prosrc FROM pg_proc WHERE proname = 'refine_gu')) = 0 THEN
        RAISE EXCEPTION 'the auxiliary ceiling is still only a sentence';
    END IF;

    -- The duel no longer looks like a second reader of life steal.
    IF position('player_stat(me.player_id, ''lifesteal'')' IN
                (SELECT prosrc FROM pg_proc WHERE proname = 'battle_act')) <> 0 THEN
        RAISE EXCEPTION 'battle_act still reads a steal it does not use';
    END IF;

    -- Nothing above is a second name for something else.
    IF EXISTS (SELECT 1 FROM game_config WHERE key = 'hunt_turn_cap') THEN
        RAISE EXCEPTION 'there are still two dials for one stalemate';
    END IF;
END;
$$;
