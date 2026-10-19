-- 0191_wearing_a_set_must_not_need_a_body
--
-- 0190's `load_preset` ends by re-reading the body, and it is right to:
-- `player_physique.max_hp` is a CACHED column computed from
-- `player_stat(player, 'max_hp')`, which counts equipment. Change four pieces
-- of gear at once and the stored maximum is stale until something else
-- recomputes it.
--
-- But it called `apply_physique_xp` unguarded, and that function raises
-- 'player % has no physique row'. One account here has no physique row - The
-- Auction House, which holds gear people have listed - and any future system
-- account would be the same. A preset that raises instead of dressing
-- somebody is worse than a stale maximum.
--
-- The tests caught it before a player did, on a freshly made character.
--
-- Note for later: `equip_item` does NOT do this refresh at all, so equipping
-- by hand still leaves `max_hp` stale until the next training tick. That is
-- older than this feature and is left alone here rather than changed
-- underneath a migration about presets.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION public.load_preset(p_player_id bigint, p_preset_id bigint)
 RETURNS TABLE(name text, gu_worn integer, manuals_worn integer, gear_worn integer, techniques_set integer, missing integer, refused text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    it     RECORD;
    one    RECORD;
    left_out TEXT[] := '{}';
    worn_g INTEGER := 0;
BEGIN
    SELECT * INTO it FROM preset_shelf s
    WHERE s.preset_id = p_preset_id AND s.player_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your sets'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Emptied first, every time. The aperture is checked per Gu as it goes
    -- in, so a set that fits only once the old one is out would otherwise be
    -- refused halfway through.
    DELETE FROM player_gu_equipped WHERE player_id = p_player_id;
    DELETE FROM player_manual_slots WHERE player_id = p_player_id;
    DELETE FROM player_equipped WHERE player_id = p_player_id;
    DELETE FROM player_loadout WHERE player_id = p_player_id;

    FOR one IN
        SELECT x.gu_id, t.name FROM preset_gu x
        JOIN player_gu g ON g.gu_id = x.gu_id
        JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE x.preset_id = p_preset_id AND g.owner_id = p_player_id
        ORDER BY t.size DESC, x.gu_id
    LOOP
        BEGIN
            INSERT INTO player_gu_equipped (player_id, gu_id)
            VALUES (p_player_id, one.gu_id);
            worn_g := worn_g + 1;
        EXCEPTION WHEN check_violation THEN
            -- The aperture shrank, or the Gu grew. Say which rather than
            -- failing the whole change of clothes.
            left_out := left_out || (one.name || ' will not fit the aperture');
        END;
    END LOOP;

    INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
    SELECT p_player_id, x.slot_index, x.manual_id
    FROM preset_manuals x
    JOIN player_manuals pm
      ON pm.manual_id = x.manual_id AND pm.player_id = p_player_id
    JOIN manuals m ON m.manual_id = x.manual_id
    WHERE x.preset_id = p_preset_id
      AND m.required_rank <= COALESCE(
          (SELECT r.rank FROM player_cultivation pc
           JOIN realms r ON r.realm_id = pc.realm_id
           WHERE pc.player_id = p_player_id), 0);

    INSERT INTO player_equipped (player_id, slot, equipment_id)
    SELECT p_player_id, x.slot, x.equipment_id
    FROM preset_gear x
    JOIN player_equipment pe
      ON pe.equipment_id = x.equipment_id AND pe.owner_id = p_player_id
    WHERE x.preset_id = p_preset_id;

    INSERT INTO player_loadout (player_id, slot_index, technique_id)
    SELECT p_player_id, x.slot_index, x.technique_id
    FROM preset_techniques x
    WHERE x.preset_id = p_preset_id
      AND EXISTS (SELECT 1 FROM player_usable_techniques u
                  WHERE u.player_id = p_player_id
                    AND u.technique_id = x.technique_id);

    -- `player_physique.max_hp` is cached and reads `player_stat(.., 'max_hp')`,
    -- which counts equipment - so changing a whole set at once has to re-read
    -- the body. Guarded because not everything with a player row has one: the
    -- Auction House holds gear and has no physique, and would otherwise make
    -- this raise instead of dress somebody.
    IF EXISTS (SELECT 1 FROM player_physique x WHERE x.player_id = p_player_id) THEN
        PERFORM apply_physique_xp(p_player_id, 0);
    END IF;

    RETURN QUERY
    SELECT it.name, worn_g,
           (SELECT count(*)::integer FROM player_manual_slots m
            WHERE m.player_id = p_player_id),
           (SELECT count(*)::integer FROM player_equipped w
            WHERE w.player_id = p_player_id),
           (SELECT count(*)::integer FROM player_loadout l
            WHERE l.player_id = p_player_id),
           ((it.gu_saved + it.manuals_saved + it.gear_saved + it.techniques_saved)
            - (worn_g
               + (SELECT count(*) FROM player_manual_slots m WHERE m.player_id = p_player_id)
               + (SELECT count(*) FROM player_equipped w WHERE w.player_id = p_player_id)
               + (SELECT count(*) FROM player_loadout l WHERE l.player_id = p_player_id))
           )::integer,
           array_to_string(left_out, ', ');
END;
$function$;


-- Dressed for real, on somebody with no physique row, inside a
-- subtransaction that is thrown away.

DO $probe$
DECLARE
    house BIGINT;
    made  BIGINT;
    back  RECORD;
BEGIN
    SELECT p.player_id INTO house FROM players p
    WHERE NOT EXISTS (SELECT 1 FROM player_physique x
                      WHERE x.player_id = p.player_id)
    LIMIT 1;

    IF house IS NULL THEN
        RAISE NOTICE 'everybody has a physique row; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT s.preset_id INTO made FROM save_preset(house, 'probe set') s;
        SELECT * INTO back FROM load_preset(house, made);

        IF back.name IS NULL THEN
            RAISE EXCEPTION 'a body-less account could not wear a set';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
