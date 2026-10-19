-- 0137_the_run_reads_the_columns_brew_actually_returns
--
-- 0136's loop reads `one.batch` and `one.herbs_back` off the record `brew`
-- hands back. `brew` calls them `quantity` and `handed_back`, and has since
-- 0059 - so every run raised
--
--     record "one" has no field "batch"
--
-- on the first pot. plpgsql resolves a record field at RUN time, so nothing
-- about this was catchable at CREATE FUNCTION; the migration applied cleanly
-- and the function was broken from the moment it existed. The same shape as
-- 0133, three days running: a function that parses is not a function that
-- works, and the only proof is calling it.
--
-- So this one calls it. The DO block at the bottom brews a real run for a
-- throwaway player and throws the results away.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION brew_many(
    p_player_id  BIGINT,
    p_codes      TEXT[],
    p_quantities INTEGER[],
    p_times      INTEGER
)
RETURNS TABLE (
    attempts     INTEGER,
    succeeded    INTEGER,
    spoiled      INTEGER,
    pills_made   BIGINT,
    herbs_spent  BIGINT,
    herbs_back   BIGINT,
    exp_gained   BIGINT,
    level_after  SMALLINT,
    best_harmony SMALLINT,
    worst_harmony SMALLINT,
    made         JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill    SMALLINT;
    ceiling  SMALLINT;
    short    RECORD;
    one      RECORD;
    started  TIMESTAMPTZ := clock_timestamp();
    n_ok     INTEGER := 0;
    n_bad    INTEGER := 0;
    n_pills  BIGINT  := 0;
    n_back   BIGINT  := 0;
    n_exp    BIGINT  := 0;
    lvl      SMALLINT;
    best     SMALLINT := 0;
    worst    SMALLINT := 150;
    spent    BIGINT;
BEGIN
    IF p_times < 1 THEN
        RAISE EXCEPTION 'a run of no brews is not a run'
            USING ERRCODE = 'check_violation';
    END IF;

    skill   := profession_level(p_player_id, 'alchemy');
    ceiling := alchemy_max_brews(skill);

    IF p_times > ceiling THEN
        RAISE EXCEPTION 'your Alchemy runs % pots at a time, not %', ceiling, p_times
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything, before anything. `brew` would refuse the fourth pot on its
    -- own, but by then three pots of herbs are gone and the player asked for
    -- a run rather than for whatever fitted.
    SELECT u.code, material_name(u.code) AS name,
           u.quantity * p_times AS wanted,
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = u.code), 0) AS held
    INTO short
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    WHERE COALESCE((SELECT pm.quantity FROM player_materials pm
                    WHERE pm.player_id = p_player_id
                      AND pm.material_code = u.code), 0) < u.quantity * p_times
    ORDER BY u.code
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION '% pots want % %, and you hold %',
            p_times, short.wanted, short.name, short.held
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(u.quantity), 0) * p_times INTO spent
    FROM unnest(p_codes, p_quantities) AS u (code, quantity);

    FOR i IN 1..p_times LOOP
        SELECT * INTO one FROM brew(p_player_id, p_codes, p_quantities, NULL);

        n_exp := n_exp + one.exp_gained;
        lvl   := one.level_after;
        best  := GREATEST(best, one.harmony);
        worst := LEAST(worst, one.harmony);

        IF one.succeeded THEN
            n_ok    := n_ok + 1;
            -- `quantity`, which is what a pot yields once 0135 let it overfill.
            n_pills := n_pills + COALESCE(one.quantity, 1);
        ELSE
            n_bad  := n_bad + 1;
            n_back := n_back + COALESCE(one.handed_back, 0);
        END IF;
    END LOOP;

    -- `clock_timestamp`, not `now()`: the whole run is one transaction, so
    -- now() is the same instant for every pot in it and a window measured from
    -- it would sweep up pills brewed before this call in the same statement.
    WITH same AS (
        SELECT min(pp.pill_id) AS keeper, sum(pp.quantity) AS total,
               array_agg(pp.pill_id) AS ids
        FROM player_pills pp
        WHERE pp.owner_id = p_player_id AND pp.brewed_at >= started
        GROUP BY pp.name, pp.tier, pp.kind, pp.path_code, pp.magnitude, pp.harmony
        HAVING count(*) > 1
    ), merged AS (
        UPDATE player_pills pp SET quantity = same.total
        FROM same WHERE pp.pill_id = same.keeper
        RETURNING pp.pill_id
    )
    DELETE FROM player_pills pp
    USING same
    WHERE pp.pill_id = ANY (same.ids) AND pp.pill_id <> same.keeper;

    RETURN QUERY
    SELECT p_times, n_ok, n_bad, n_pills, spent, n_back, n_exp,
           COALESCE(lvl, skill), best, worst,
           COALESCE(
               (SELECT jsonb_agg(jsonb_build_object(
                    'name', x.name, 'tier', x.tier, 'kind', x.kind,
                    'magnitude', x.magnitude, 'harmony', x.harmony,
                    'quantity', x.quantity)
                    ORDER BY x.tier DESC, x.magnitude DESC)
                FROM (
                    SELECT pp.name, pp.tier, pp.kind, pp.magnitude,
                           pp.harmony, pp.quantity
                    FROM player_pills pp
                    WHERE pp.owner_id = p_player_id AND pp.brewed_at >= started
                ) x),
               '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION brew_many(BIGINT, TEXT[], INTEGER[], INTEGER) IS
    'One recipe, N pots, each rolling its own harmony. Refuses before spending if the herbs for the whole run are not there.';


-- It has to survive being called, which is the whole of what went wrong.
DO $$
DECLARE
    ghost BIGINT;
    run   RECORD;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999137, 'migration 0137 probe')
    RETURNING player_id INTO ghost;

    PERFORM grant_material(ghost, 'spirit_dew_grass', 200);
    PERFORM grant_material(ghost, 'clear_mind_orchid', 200);

    SELECT * INTO run FROM brew_many(
        ghost, ARRAY['spirit_dew_grass', 'clear_mind_orchid'], ARRAY[4, 4], 2);

    IF run.attempts <> 2 THEN
        RAISE EXCEPTION 'a run of two reported % attempts', run.attempts;
    END IF;
    IF run.succeeded + run.spoiled <> 2 THEN
        RAISE EXCEPTION 'a pot neither succeeded nor spoiled';
    END IF;
    IF run.herbs_spent <> 16 THEN
        RAISE EXCEPTION 'two pots of eight herbs spent %', run.herbs_spent;
    END IF;
    IF run.exp_gained <= 0 THEN
        RAISE EXCEPTION 'a run taught nothing';
    END IF;

    -- And the refusal has to arrive before the herbs do.
    BEGIN
        PERFORM brew_many(ghost, ARRAY['spirit_dew_grass', 'clear_mind_orchid'],
                          ARRAY[500, 500], 2);
        RAISE EXCEPTION 'a run nobody can afford was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    DELETE FROM player_pills WHERE owner_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
