-- 0584_a_pen_is_priced_in_the_essence_people_actually_hold
--
-- 0582 priced a pen at tier^2 * 50, so a tier 9 egg cost 4050 of essence value.
-- Then I asked the live world what essence it holds, which I should have done
-- before picking the number:
--
--     clearwest     177 White Litchi (2,430,000 each), 213 Yellow Apricot
--                   (243,000,000 each) - and nothing shallower AT ALL
--     shinonn._.    40 Green Grape (243), 42 Red Date (24,300), ...
--     sylvrime      14 Jade Plum (3), 5 Blood Cherry (81), ...
--
-- TWO THINGS WERE WRONG.
--
-- The bill was meaningless. 4050 against a hoard of 52 billion in essence value
-- is not a gate, it is a rounding error - and `beast_feed_needed`, the ladder
-- this sits beside, charges 270 at its shallowest rung and 656 MILLION at its
-- deepest. 4050 is nowhere on that scale.
--
-- And worse, it was a TRAP. Essence is spent in whole units, so a bill of 4050
-- paid with the only essence clearwest owns comes to
--
--     ceil(4050 / 2430000) = 1 unit of White Litchi = 2,430,000 of value
--
-- for a 4050 bill: 99.8% of it destroyed, silently, by a cultivator picking the
-- only thing in their satchel. 0582's own comment called a deeper essence
-- "going further", which is true by the unit and exactly backwards by the value.
--
-- THE FIX IS BOTH HALVES.
--
-- `farm_essence_per_tier` 50 -> 30000, so a tier 9 pen costs 2,430,000 - one
-- White Litchi exactly - and a tier 1 pen costs 30,000, which is a Red Date and
-- change. The bill now lands inside the economy it is billed against.
--
-- And `farm_place` refuses an essence whose SINGLE UNIT is worth more than the
-- whole bill, naming what it would have wasted. That caps the overpay below one
-- unit in every case instead of at 600x.
--
-- It also gives the ladder a shape nobody had to write down: a deep egg is what
-- lets you spend a deep essence. A tier 1 pen will not take White Litchi,
-- because 2,430,000 > 30,000; a tier 9 pen will, because it costs exactly that.
-- Yellow Apricot at 243,000,000 is too dear for any pen, which is right - it is
-- the fuel of the last rung of the immortal ladder, not chicken feed.
--
-- NOBODY LOSES A PEN OVER THIS. `player_farm` is empty; 0582 applied today and
-- the cog went live minutes ago.


UPDATE game_config
SET value = 30000,
    description = 'Immortal essence VALUE needed per tier squared to pen an egg. A tier 9 pen costs 2,430,000 - one White Litchi - and a tier 1 pen 30,000. Raised from 50 in 0584: at 50 the bill was 4050, a rounding error against the hoards that exist, and it forced a 2,430,000-value overpay on the only essence the richest cultivator owns.'
WHERE key = 'farm_essence_per_tier';


-- ---------------------------------------------------------------------------
-- And an essence too dear for the bill is refused rather than burnt
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT;
    guard   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'farm_place' AND pronamespace = 'public'::regnamespace;

    anchor := '    v_qty  := GREATEST(1, ceil(v_need / v_unit))::bigint;';
    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'farm_place does not size the payment the way it did';
    END IF;

    guard :=
        '    -- NOT WITH SOMETHING WORTH MORE THAN THE WHOLE BILL (0584).'       || chr(10) ||
        '    -- Essence is spent in whole units, so paying 4050 with a single'   || chr(10) ||
        '    -- White Litchi worth 2,430,000 destroyed 99.8% of it - and that'   || chr(10) ||
        '    -- was the only essence the richest cultivator in the world held.'  || chr(10) ||
        '    -- This caps the overpay below one unit instead of at 600x.'        || chr(10) ||
        '    IF v_unit > v_need THEN'                                           || chr(10) ||
        '        RAISE EXCEPTION'                                               || chr(10) ||
        '            ''one % is worth % and this pen wants only % - it would '   ||
        'waste %. Something shallower'','                                       || chr(10) ||
        '            material_name(p_essence_code), v_unit, v_need,'            || chr(10) ||
        '            v_unit - v_need'                                           || chr(10) ||
        '            USING ERRCODE = ''check_violation'';'                      || chr(10) ||
        '    END IF;'                                                           || chr(10) ||
        chr(10) ||
        anchor;

    patched := replace(src, anchor, guard);
    IF patched = src THEN
        RAISE EXCEPTION 'the farm_place patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_sp   BIGINT;
    v_egg  BIGINT;
    v_bill NUMERIC;
    v_pen  SMALLINT;
    v_paid BIGINT;
BEGIN
    -- 1. THE BILL LANDS WHERE THE ESSENCE IS. One White Litchi, exactly, for
    --    the deepest egg the world hands out.
    v_bill := farm_essence_needed(9::smallint);
    IF v_bill <> (SELECT unit_value FROM immortal_essences
                  WHERE material_code = 'white_litchi_essence') THEN
        RAISE EXCEPTION
            'a tier 9 pen costs % and one White Litchi is worth %',
            v_bill, (SELECT unit_value FROM immortal_essences
                     WHERE material_code = 'white_litchi_essence');
    END IF;
    RAISE NOTICE 'a tier 9 pen costs % of essence value', v_bill;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1105, 'essence-probe') RETURNING player_id INTO v_who;
        INSERT INTO player_dwelling (player_id, stage) VALUES (v_who, 4)
        ON CONFLICT (player_id) DO UPDATE SET stage = 4;

        SELECT cd.species_id INTO v_sp FROM creature_drops cd LIMIT 1;

        PERFORM grant_material(v_who, 'yellow_apricot_essence', 10);
        PERFORM grant_material(v_who, 'white_litchi_essence', 10);
        PERFORM grant_material(v_who, 'red_date_essence', 1000);

        -- 2. TOO DEAR IS REFUSED. Yellow Apricot is worth a hundred times the
        --    deepest pen, which is exactly the burn this migration is about.
        PERFORM grant_beast_egg(v_who, v_sp, 9::smallint, 'rare', NULL);
        SELECT egg_id INTO v_egg FROM player_beast_eggs
        WHERE owner_id = v_who AND hatched_at IS NULL LIMIT 1;

        BEGIN
            PERFORM farm_place(v_who, v_egg, 'yellow_apricot_essence');
            RAISE EXCEPTION
                'a pen took an essence worth a hundred times its bill';
        EXCEPTION WHEN check_violation THEN
            NULL;   -- the refusal we wanted
        END;

        -- 3. AND THE RIGHT-SIZED ONE IS TAKEN, at one unit.
        SELECT f.pen_no, f.essence_spent INTO v_pen, v_paid
        FROM farm_place(v_who, v_egg, 'white_litchi_essence') f;
        IF v_paid <> 1 THEN
            RAISE EXCEPTION
                'a tier 9 pen took % White Litchi and should have taken 1', v_paid;
        END IF;
        RAISE NOTICE 'a tier 9 pen took % White Litchi', v_paid;

        -- 4. A SHALLOW PEN WILL NOT TAKE A DEEP ESSENCE EITHER. 30,000 against
        --    White Litchi's 2,430,000 - the emergent rule, asserted so it stays.
        PERFORM grant_beast_egg(v_who, v_sp, 1::smallint, 'common', NULL);
        SELECT egg_id INTO v_egg FROM player_beast_eggs
        WHERE owner_id = v_who AND hatched_at IS NULL LIMIT 1;

        BEGIN
            PERFORM farm_place(v_who, v_egg, 'white_litchi_essence');
            RAISE EXCEPTION 'a tier 1 pen swallowed a White Litchi';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- ...but Red Date, at 24,300 against 30,000, is the right size for it.
        SELECT f.essence_spent INTO v_paid
        FROM farm_place(v_who, v_egg, 'red_date_essence') f;
        IF v_paid <> 2 THEN
            RAISE EXCEPTION
                'a tier 1 pen took % Red Date; 30000/24300 rounds up to 2', v_paid;
        END IF;
        RAISE NOTICE 'a tier 1 pen took % Red Date', v_paid;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
