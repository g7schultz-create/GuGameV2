-- 0287_the_hunt_and_the_room_say_it_too
--
-- The last two lanes. 0286 took the three with a single return site; these
-- two were held back because they are the awkward ones - `battle_act` answers
-- from four different places and the dungeon answers in jsonb - and putting
-- all five through in one migration is how 0277 broke every swing in the game.
--
-- THE HUNT ALSO CARRIES THE BEAST'S BODY. The other lanes only needed to say
-- what the beast did, because the report was about the boss. The hunt was
-- "I don't see their health", so this one returns `pet_hp` and `pet_max_hp`
-- as well, and it returns them on every branch - including the one where you
-- broke away without swinging. A health bar that vanishes when you flee is
-- worse than no health bar.
--
-- The name comes off the beast at heel rather than off the swing, so it is
-- there whether or not the beast got to do anything. `pet_at_heel` and not
-- `pet_standing`: a downed beast still has a bar, and the bar is how you find
-- out it is down.
--
-- THE DUNGEON GETS KEYS, NOT COLUMNS. Its round log is jsonb and every screen
-- reading it already ignores keys it does not know, so a new key is the
-- cheapest safe thing that can be added to that lane.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The hunt
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
    anchors TEXT[] := ARRAY[
        '    took       RECORD;',
        '    p_hp := me.current_hp;',
        '        dmg_out   := swung.dealt;',
        '    reduce     := took.reduced;',
        'dodged boolean, healed bigint)',
        '                                0::smallint, 0::smallint, FALSE, 0::bigint;',
        '                            n_strikes, n_crits, FALSE, healed_by;',
        chr(10) || '                            n_strikes, n_crits, was_dodged, healed_by;',
        chr(10) || '                        n_strikes, n_crits, was_dodged, healed_by;'
    ];
    a    TEXT;
    tail TEXT := ',' || chr(10) ||
        '                        pet_dmg, pet_nm, pet_took, pet_fell,' ||
        chr(10) || '                        pet_hp(beast), pet_max_hp(beast);';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'battle_act';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    -- Every anchor exactly once, checked before a single one is replaced.
    FOREACH a IN ARRAY anchors LOOP
        IF (length(body) - length(replace(body, a, ''))) / length(a) <> 1 THEN
            RAISE EXCEPTION 'battle_act: anchor is not unique: %', a;
        END IF;
    END LOOP;

    body := replace(body, '    took       RECORD;',
        '    took       RECORD;' || chr(10) ||
        '    beast      BIGINT;' || chr(10) ||
        '    pet_dmg    BIGINT := 0;' || chr(10) ||
        '    pet_nm     TEXT;' || chr(10) ||
        '    pet_took   BIGINT := 0;' || chr(10) ||
        '    pet_fell   BOOLEAN := FALSE;');

    -- As soon as there is a combatant to read it off.
    body := replace(body, '    p_hp := me.current_hp;',
        '    beast := pet_at_heel(me.player_id);' || chr(10) ||
        '    SELECT b.name INTO pet_nm FROM player_beasts b' || chr(10) ||
        '    WHERE b.beast_id = beast;' || chr(10) || chr(10) ||
        '    p_hp := me.current_hp;');

    body := replace(body, '        dmg_out   := swung.dealt;',
        '        dmg_out   := swung.dealt;' || chr(10) ||
        '        pet_dmg   := COALESCE(swung.pet_dealt, 0);');

    body := replace(body, '    reduce     := took.reduced;',
        '    reduce     := took.reduced;' || chr(10) ||
        '    pet_took   := COALESCE(took.covered, 0);' || chr(10) ||
        '    pet_fell   := COALESCE(took.pet_down, FALSE);');

    body := replace(body, 'dodged boolean, healed bigint)',
        'dodged boolean, healed bigint, pet_dealt bigint, pet_name text, ' ||
        'pet_covered bigint, pet_down boolean, pet_hp bigint, pet_max_hp bigint)');

    -- All four return sites. Their tails differ by indentation, which is why
    -- each of them could be asserted unique above.
    body := replace(body,
        '                                0::smallint, 0::smallint, FALSE, 0::bigint;',
        '                                0::smallint, 0::smallint, FALSE, 0::bigint' || tail);
    body := replace(body,
        '                            n_strikes, n_crits, FALSE, healed_by;',
        '                            n_strikes, n_crits, FALSE, healed_by' || tail);
    body := replace(body,
        chr(10) || '                            n_strikes, n_crits, was_dodged, healed_by;',
        chr(10) || '                            n_strikes, n_crits, was_dodged, healed_by' || tail);
    body := replace(body,
        chr(10) || '                        n_strikes, n_crits, was_dodged, healed_by;',
        chr(10) || '                        n_strikes, n_crits, was_dodged, healed_by' || tail);

    DROP FUNCTION battle_act(BIGINT, TEXT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The room
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'dungeon_resolve_round';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_resolve_round is missing';
    END IF;

    IF (length(body) - length(replace(body, '            ''damage'', dealt,', '')))
       / length('            ''damage'', dealt,') <> 1 THEN
        RAISE EXCEPTION 'room: the strike log anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, '                ''who'', run.boss_name, ''kind'', ''boss'',', '')))
       / length('                ''who'', run.boss_name, ''kind'', ''boss'',') <> 1 THEN
        RAISE EXCEPTION 'room: the boss log anchor is not unique';
    END IF;

    body := replace(body, '            ''damage'', dealt,',
        '            ''damage'', dealt,' || chr(10) ||
        '            ''pet_damage'', COALESCE(swung.pet_dealt, 0),' || chr(10) ||
        '            ''pet'', swung.pet_name,');

    body := replace(body, '                ''who'', run.boss_name, ''kind'', ''boss'',',
        '                ''who'', run.boss_name, ''kind'', ''boss'',' || chr(10) ||
        '                ''pet_covered'', COALESCE(took.covered, 0),' || chr(10) ||
        '                ''pet'', took.pet_name,');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- All five lanes now carry the beast
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    missing TEXT := '';
BEGIN
    IF pg_get_function_result(
           (SELECT oid FROM pg_proc WHERE proname = 'battle_act'))
       NOT LIKE '%pet_max_hp%' THEN
        missing := missing || ' battle_act';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'dungeon_resolve_round')
       NOT LIKE '%pet_damage%' THEN
        missing := missing || ' dungeon_resolve_round';
    END IF;

    IF missing <> '' THEN
        RAISE EXCEPTION 'these lanes still swallow the beast:%', missing;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A real hunt, from opening the fight to reading the beast's bar
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    beast BIGINT;
    sp    BIGINT;
    b_id  BIGINT;
    got   RECORD;
    move  BIGINT;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    WHERE b.at_heel
    ORDER BY b.tier DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast; the tests carry this';
        RETURN;
    END IF;

    move := dungeon_default_move(who);
    IF move IS NULL THEN
        RAISE NOTICE 'that cultivator knows nothing to swing; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE battles SET status = 'expired', ended_at = now()
        WHERE status = 'active'
          AND battle_id IN (SELECT battle_id FROM battle_combatants
                            WHERE player_id = who);

        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

        b_id := battle_open(who, sp);
        SELECT * INTO got FROM battle_act(b_id, 'attack', move);

        IF got.pet_max_hp IS NULL OR got.pet_max_hp <= 0 THEN
            RAISE EXCEPTION 'the hunt does not know the beast has a body';
        END IF;
        IF got.pet_hp IS NULL THEN
            RAISE EXCEPTION 'the hunt does not know what the beast has left';
        END IF;
        IF got.pet_name IS NULL THEN
            RAISE EXCEPTION 'the hunt will not name the beast at your heel';
        END IF;

        RAISE NOTICE 'the hunt reports % at %/% health',
            got.pet_name, got.pet_hp, got.pet_max_hp;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
