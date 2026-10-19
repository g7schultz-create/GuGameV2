-- 0578_one_set_of_notes_a_corpse
--
-- `delve_spoils` rolls a creature's WHOLE drop table `p_rolls` times, and a
-- `deep` tile is worth twenty-four rolls. Each roll's quantity is then
-- multiplied by the cultivator's gathering stack. Against a rogue carrying
-- Ancient Venerable Notes at 12%:
--
--     24 rolls x 0.12 = 2.9 hits, each x1.43 yield   ->  about 4 sets a kill
--
-- while clearing the whole Vault of Unclaimed Dao pays exactly one, at 35%. So
-- the quickest route to a Venerable rung was to stand in a delve killing the
-- same kind of rogue, which is not what a dead Venerable's working papers are
-- meant to be.
--
-- ONE SET A CORPSE. Twenty-four rolls still happen and everything else on the
-- table still stacks - the farm stays exactly as farmable as it was, which is
-- what was asked for. What changes is that no corpse is carrying four copies
-- of the same notebook, which it should not have been in the first place.
--
-- Not a chance change. 12% per kill is a reasonable rate for a rogue who
-- walked this ladder; it was the multiplication that was wrong.
--
-- WORTH KNOWING, AND DELIBERATELY NOT CHANGED HERE: essence has exactly the
-- same shape and it is twenty times larger. The same rogue, the same deep
-- tile:
--
--     white_litchi_essence   0.65 chance, 2-5 each   ->  about 78 a kill
--
-- Essence is the fuel of the immortal ladder and 78 of it off one corpse is a
-- much bigger hole than four notebooks. It is left alone because nobody asked
-- for it and it is a balance decision rather than a bug - but the number is
-- written down here so it is a decision rather than a surprise.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'delve_spoils' AND pronamespace = 'public'::regnamespace;

    -- A flag, declared beside the rest.
    IF position('    i     INTEGER;' IN src) = 0 THEN
        RAISE EXCEPTION 'delve_spoils does not declare its loop the way it did';
    END IF;
    patched := replace(src, '    i     INTEGER;',
'    i     INTEGER;
    v_once BOOLEAN := FALSE;   -- 0578. Whether the notes have already come up.');

    -- Skipped once it has already been granted, BEFORE the roll - so a corpse
    -- that has given up its notebook does not keep rolling for another.
    IF position('            CONTINUE WHEN random() >= one.chance;' IN src) = 0 THEN
        RAISE EXCEPTION 'delve_spoils does not roll each drop the way it did';
    END IF;
    patched := replace(patched,
'            CONTINUE WHEN random() >= one.chance;',
'            -- ONE SET A CORPSE (0578). A deep tile rolls this table
            -- twenty-four times, so at 12% a single rogue was handing over
            -- about four sets of the same notebook while the whole Vault pays
            -- one. The other twenty-four rolls go on exactly as they were.
            CONTINUE WHEN one.material_code = ''ancient_venerable_notes''
                          AND v_once;
            CONTINUE WHEN random() >= one.chance;
            IF one.material_code = ''ancient_venerable_notes'' THEN
                v_once := TRUE;
            END IF;');

    -- And never more than one at a time, whatever the gathering stack says.
    IF position('            v_qty := GREATEST(1, round(' IN patched) = 0 THEN
        RAISE EXCEPTION 'delve_spoils does not size a drop the way it did';
    END IF;
    patched := replace(patched,
'            v_qty := GREATEST(1, round(
                (one.min_quantity
                 + floor(random() * (one.max_quantity - one.min_quantity + 1)))
                * v_mul))::bigint;',
'            v_qty := GREATEST(1, round(
                (one.min_quantity
                 + floor(random() * (one.max_quantity - one.min_quantity + 1)))
                * v_mul))::bigint;
            -- A gathering stack finds more herbs on a carcass. It does not
            -- find more copies of a book.
            IF one.material_code = ''ancient_venerable_notes'' THEN
                v_qty := 1;
            END IF;');

    IF patched = src THEN
        RAISE EXCEPTION 'the delve_spoils patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_sp    BIGINT;
    v_rolls INTEGER;
    v_got   JSONB;
    v_notes BIGINT;
    v_other BIGINT;
    i       INTEGER;
    v_max   BIGINT := 0;
    v_tot   BIGINT := 0;
BEGIN
    SELECT k.drop_rolls INTO v_rolls FROM delve_tile_kinds k
    ORDER BY k.drop_rolls DESC LIMIT 1;

    SELECT cd.species_id INTO v_sp FROM creature_drops cd
    WHERE cd.material_code = 'ancient_venerable_notes' LIMIT 1;

    IF v_sp IS NULL THEN
        RAISE NOTICE 'nothing carries the notes, so nothing was rolled';
        RETURN;
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1101, 'spoils-probe') RETURNING player_id INTO v_who;

        -- 1. NEVER MORE THAN ONE A CORPSE, over enough kills that four would
        --    have shown up many times at the old rate.
        FOR i IN 1..60 LOOP
            DELETE FROM player_materials
            WHERE player_id = v_who AND material_code = 'ancient_venerable_notes';

            PERFORM delve_spoils(v_who, v_sp, v_rolls);

            SELECT COALESCE(quantity, 0) INTO v_notes FROM player_materials
            WHERE player_id = v_who AND material_code = 'ancient_venerable_notes';

            IF v_notes > 1 THEN
                RAISE EXCEPTION
                    'one corpse gave % sets of notes across % rolls',
                    v_notes, v_rolls;
            END IF;
            v_tot := v_tot + v_notes;
        END LOOP;

        RAISE NOTICE
            '60 kills at % rolls each: % sets of notes, never more than one at a time',
            v_rolls, v_tot;

        -- 2. AND THE ROLL STILL HAPPENS. A cap that quietly stopped them
        --    dropping at all would pass the check above and break the item.
        IF v_tot = 0 THEN
            RAISE EXCEPTION
                'sixty kills produced no notes at all - the cap closed the drop';
        END IF;

        -- 3. AND EVERYTHING ELSE ON THE TABLE STILL STACKS. The farm was meant
        --    to stay farmable; only the notebook is capped.
        DELETE FROM player_materials WHERE player_id = v_who;
        PERFORM delve_spoils(v_who, v_sp, v_rolls);

        SELECT max(pm.quantity) INTO v_other FROM player_materials pm
        WHERE pm.player_id = v_who
          AND pm.material_code <> 'ancient_venerable_notes';

        IF COALESCE(v_other, 0) <= 1 THEN
            RAISE EXCEPTION
                'the rest of the table stopped stacking too - the biggest '
                'single haul off one corpse was %', COALESCE(v_other, 0);
        END IF;
        RAISE NOTICE
            'the rest of the table still stacks - % of one thing off one corpse',
            v_other;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
