-- 0288_a_guard_is_not_a_swing
--
-- 0286 broke the gauntlet for anybody who did not attack.
--
-- That migration was careful about exactly this hazard and then applied the
-- care to the wrong record. Its own header explains that `took` is only
-- assigned on the branch where something swings back, and copies it into a
-- plain variable for that reason. `swung` has the same shape and got none of
-- that treatment: it is only assigned on the branch where the cultivator
-- attacks, so a Guard - which spends the turn without swinging - reached
--
--     COALESCE(swung.pet_dealt, 0), swung.pet_name
--
-- with `swung` never assigned, and Postgres refused the whole return with
-- "record swung is not assigned yet". COALESCE cannot save it; the record has
-- no tuple structure at all, so naming any field of it is the error.
--
-- Five gauntlet tests caught it before anybody guarded in a live tide.
--
-- The fix is the one 0286 already used for `took`: plain variables that start
-- at zero, filled on the branch that has something to fill them with.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_gauntlet_swing';

    IF body IS NULL THEN
        RAISE EXCEPTION 'horde_gauntlet_swing is missing';
    END IF;

    IF (length(body) - length(replace(body, '    pet_took  BIGINT := 0;', '')))
       / length('    pet_took  BIGINT := 0;') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the declaration anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, '        out_dmg   := swung.dealt;', '')))
       / length('        out_dmg   := swung.dealt;') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the swing anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body,
           '        COALESCE(swung.pet_dealt, 0), swung.pet_name, pet_took, pet_fell;', '')))
       / length('        COALESCE(swung.pet_dealt, 0), swung.pet_name, pet_took, pet_fell;') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the return anchor is not unique';
    END IF;

    body := replace(body, '    pet_took  BIGINT := 0;',
        '    pet_took  BIGINT := 0;' || chr(10) ||
        '    pet_dmg   BIGINT := 0;' || chr(10) ||
        '    pet_nm    TEXT;');

    -- On the branch that actually swings, and nowhere else.
    body := replace(body, '        out_dmg   := swung.dealt;',
        '        out_dmg   := swung.dealt;' || chr(10) ||
        '        pet_dmg   := COALESCE(swung.pet_dealt, 0);' || chr(10) ||
        '        pet_nm    := swung.pet_name;');

    -- And on the branch that only gets hit, so a guarding cultivator whose
    -- beast covered for them still sees which beast it was.
    IF (length(body) - length(replace(body, '        pet_took := COALESCE(took.covered, 0);', '')))
       / length('        pet_took := COALESCE(took.covered, 0);') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the cover anchor is not unique';
    END IF;

    body := replace(body, '        pet_took := COALESCE(took.covered, 0);',
        '        pet_took := COALESCE(took.covered, 0);' || chr(10) ||
        '        pet_nm   := COALESCE(pet_nm, took.pet_name);');

    body := replace(body,
        '        COALESCE(swung.pet_dealt, 0), swung.pet_name, pet_took, pet_fell;',
        '        pet_dmg, pet_nm, pet_took, pet_fell;');

    DROP FUNCTION horde_gauntlet_swing(BIGINT, TEXT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- A guard gets through, and still says what the beast covered
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
BEGIN
    SELECT prosrc INTO src FROM pg_proc WHERE proname = 'horde_gauntlet_swing';

    -- The return may name no field of `swung`: that is the whole bug.
    IF position('swung.pet' IN substr(src, position('RETURN QUERY' IN src))) > 0 THEN
        RAISE EXCEPTION 'the gauntlet return still reads a field off swung';
    END IF;

    IF position('pet_dmg   := COALESCE(swung.pet_dealt, 0);' IN src) = 0 THEN
        RAISE EXCEPTION 'the gauntlet never fills the beast''s blow';
    END IF;
END;
$$;
