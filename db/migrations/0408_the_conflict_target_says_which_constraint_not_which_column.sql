-- 0408_the_conflict_target_says_which_constraint_not_which_column
--
-- 0407 gave both minters an `ON CONFLICT (equipment_id, effect_code)` so the
-- overflow trigger could not collide with the statement that fired it. In
-- `forge` that does not compile:
--
--     column reference "equipment_id" is ambiguous
--     DETAIL: It could refer to either a PL/pgSQL variable or a table column.
--
-- `forge` RETURNS TABLE with an `equipment_id` column, so the name is already
-- taken inside its own body - which is why the line above it has always said
-- `RETURNING player_equipment.equipment_id INTO made_id` rather than just
-- `RETURNING equipment_id`. The existing qualification was the warning, and
-- 0407 walked past it.
--
-- A conflict target cannot be table-qualified the way that RETURNING can -
-- `ON CONFLICT (equipment_effects.equipment_id, ...)` is a syntax error, not a
-- fix. What it can do is name the constraint instead of inferring one, which
-- takes the column names out of the expression entirely and says the same
-- thing more exactly: this insert merges on the primary key.
--
-- `dungeon_mint_equipment` compiled fine, having no such column. It is changed
-- too, because "the one that happens not to collide today" is the same kind of
-- reasoning that put the ambiguity in `forge`.
--
-- Also: `effect_overflow_rules.spills_to` is a foreign key with no index, which
-- the schema test sweeps for. Two rows will never need it. The test is right
-- anyway - the rule is what keeps the next table from being the one that
-- matters.
--
-- Forward-only. Do not edit once applied.


CREATE INDEX effect_overflow_rules_spills_to_idx
    ON effect_overflow_rules (spills_to);


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    named  TEXT;
    fname  TEXT;
BEGIN
    anchor := '    ON CONFLICT (equipment_id, effect_code) DO UPDATE';
    named  := '    ON CONFLICT ON CONSTRAINT equipment_effects_pkey DO UPDATE';

    FOREACH fname IN ARRAY ARRAY['forge', 'dungeon_mint_equipment'] LOOP
        SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
        WHERE proname = fname AND pronamespace = 'public'::regnamespace;
        IF body IS NULL THEN
            RAISE EXCEPTION '% is missing', fname;
        END IF;
        IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
            RAISE EXCEPTION '% does not carry 0407''s conflict target once', fname;
        END IF;
        EXECUTE replace(body, anchor, named);
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Both mint a piece again, and the overflow still lands
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_made  BIGINT;
    v_over  TEXT;
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND proname IN ('forge', 'dungeon_mint_equipment')
          AND prosrc LIKE '%ON CONFLICT (equipment_id, effect_code)%'
    ) THEN
        RAISE EXCEPTION 'a minter still infers its conflict target by column';
    END IF;

    IF (SELECT count(*) FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND proname IN ('forge', 'dungeon_mint_equipment')
          AND prosrc LIKE '%ON CONSTRAINT equipment_effects_pkey%') <> 2 THEN
        RAISE EXCEPTION 'a minter lost its merge entirely';
    END IF;

    -- Compiling is not running. A plpgsql body is parsed when it is first
    -- EXECUTEd, so `CREATE OR REPLACE` accepted 0407's ambiguous column
    -- without complaint and the whole test suite found it instead. Call both
    -- for real, on a subtransaction that is thrown away.
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        PERFORM grant_material(v_who, 'iron_ore', 4000);
        PERFORM grant_material(v_who, 'dragon_scale', 40);
        -- Ore alone is an ingot; a piece needs something off a beast in it.
        SELECT f.equipment_id INTO v_made
        FROM forge(v_who, 'boots', ARRAY['iron_ore'], ARRAY[3000],
                   ARRAY['dragon_scale'], ARRAY[20]) f;
        IF v_made IS NULL THEN
            RAISE EXCEPTION 'forge ran but minted nothing';
        END IF;

        v_made := dungeon_mint_equipment(v_who, 8::smallint, 2.0, 'Probe');
        IF v_made IS NULL THEN
            RAISE EXCEPTION 'the dungeon minted nothing';
        END IF;

        -- Whatever either of them made, nothing is stored over its ceiling.
        SELECT string_agg(ee.effect_code || ' ' || ee.magnitude, ', ')
        INTO v_over
        FROM equipment_effects ee
        JOIN player_equipment e ON e.equipment_id = ee.equipment_id
        JOIN gu_effects ef ON ef.code = ee.effect_code
        WHERE e.owner_id = v_who AND ee.magnitude > ef.cap;
        IF v_over IS NOT NULL THEN
            RAISE EXCEPTION 'stored over the ceiling: %', v_over;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'both minters merge on the primary key and the trigger holds';
END;
$probe$;
