-- 0114_the_conflict_names_its_constraint
--
-- `build_facility` returns a column called `facility` and writes a table with
-- a column called `facility`, and `ON CONFLICT (player_id, facility)` cannot
-- tell which one is meant:
--
--     column reference "facility" is ambiguous
--     It could refer to either a PL/pgSQL variable or a table column.
--
-- Naming the constraint instead of the columns removes the question. The
-- alternative - renaming the output column - would change the function's
-- return type, and every caller with it, to work around a shadowing problem
-- that has a one-line answer.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION build_facility(p_player_id BIGINT, p_facility TEXT)
RETURNS TABLE (
    facility     TEXT,
    name         TEXT,
    emoji        TEXT,
    level_before SMALLINT,
    level_after  SMALLINT,
    effect_name  TEXT,
    effect_now   NUMERIC,
    stones_spent BIGINT,
    ore_spent    JSONB,
    beast_spent  JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    spec  dwelling_facilities%ROWTYPE;
    stage SMALLINT;
    slots SMALLINT;
    built INTEGER;
    was   SMALLINT := 0;
    want  SMALLINT;
    price RECORD;
    ores  JSONB;
    parts JSONB;
BEGIN
    SELECT * INTO spec FROM dwelling_facilities WHERE code = p_facility;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such thing as a %', p_facility
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pd.stage, s.facility_slots INTO stage, slots
    FROM player_dwelling pd
    JOIN dwelling_stages s ON s.stage = pd.stage
    WHERE pd.player_id = p_player_id;

    IF stage IS NULL THEN
        RAISE EXCEPTION 'you have nowhere to build it. **/dwelling** raises a first roof'
            USING ERRCODE = 'check_violation';
    END IF;

    IF stage < spec.min_stage THEN
        RAISE EXCEPTION 'a % wants at least a %',
            spec.name, (SELECT s.name FROM dwelling_stages s WHERE s.stage = spec.min_stage)
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pf.level INTO was FROM player_facilities pf
    WHERE pf.player_id = p_player_id AND pf.facility = p_facility;
    was := COALESCE(was, 0);

    IF was >= spec.max_level THEN
        RAISE EXCEPTION 'your % is as good as one gets', spec.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- A new facility needs a free slot; improving one already standing does
    -- not, which is what makes a full dwelling a decision rather than a wall.
    IF was = 0 THEN
        SELECT count(*) INTO built FROM player_facilities pf
        WHERE pf.player_id = p_player_id;
        IF built >= slots THEN
            RAISE EXCEPTION
                'your dwelling holds % and all of them are taken. Raise it, or improve what stands',
                slots
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    want := was + 1;
    SELECT * INTO price FROM facility_cost(p_facility, want);

    IF price.stone_cost > 0 THEN
        PERFORM spend_material(p_player_id, 'spirit_stone', price.stone_cost);
    END IF;
    ores  := spend_material_weight(p_player_id, 'ore', price.ore_weight);
    parts := spend_material_weight(p_player_id, 'beast', price.beast_weight);

    -- Named, not listed: `facility` is both an output column and a table
    -- column, and the constraint has only one meaning.
    INSERT INTO player_facilities AS pf (player_id, facility, level)
    VALUES (p_player_id, p_facility, want)
    ON CONFLICT ON CONSTRAINT player_facilities_pkey
        DO UPDATE SET level = EXCLUDED.level;

    RETURN QUERY
    SELECT spec.code, spec.name, spec.emoji, was, want,
           (SELECT e.name FROM gu_effects e WHERE e.code = spec.effect_code),
           spec.per_level * want,
           price.stone_cost, ores, parts;
END;
$$;
