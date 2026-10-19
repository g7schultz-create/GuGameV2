-- 0138_a_run_remembers_what_it_made
--
-- 0137 found the pills a run produced by asking which of the player's pills
-- were brewed after the run began:
--
--     started := clock_timestamp();       -- inside the function
--     ... WHERE pp.brewed_at >= started
--
-- `player_pills.brewed_at` defaults to `now()`, which is the TRANSACTION
-- timestamp - fixed at the statement that opened it, and therefore always
-- EARLIER than a clock_timestamp() taken during execution. So the filter
-- excluded every row it was written to include: a seven-pot run reported seven
-- pills made and handed back an empty list of them, and the merge that folds
-- identical pills together never folded anything.
--
-- 0137 checked the counts and did not check `made`, which is why its probe
-- passed. A test that asserts everything except the thing that is wrong is the
-- normal way this goes.
--
-- Timestamps are the wrong instrument regardless. `brew` returns the id of the
-- pill it made, so the run collects ids as it goes and asks about exactly
-- those - no window, no clock, and correct even if two runs somehow overlap.
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
    minted   BIGINT[] := '{}';
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
            n_pills := n_pills + COALESCE(one.quantity, 1);
            minted  := minted || one.pill_id;
        ELSE
            n_bad  := n_bad + 1;
            n_back := n_back + COALESCE(one.handed_back, 0);
        END IF;
    END LOOP;

    -- Two pots of one recipe roll different harmony and therefore different
    -- magnitude, so they are genuinely different pills and stay separate rows.
    -- Where every column DOES match they are the same pill, and a shelf
    -- listing it twice would be the shelf being wrong.
    WITH same AS (
        SELECT min(pp.pill_id) AS keeper, sum(pp.quantity) AS total,
               array_agg(pp.pill_id) AS ids
        FROM player_pills pp
        WHERE pp.pill_id = ANY (minted)
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
                    'name', pp.name, 'tier', pp.tier, 'kind', pp.kind,
                    'magnitude', pp.magnitude, 'harmony', pp.harmony,
                    'quantity', pp.quantity)
                    ORDER BY pp.tier DESC, pp.magnitude DESC)
                FROM player_pills pp
                WHERE pp.pill_id = ANY (minted)),
               '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION brew_many(BIGINT, TEXT[], INTEGER[], INTEGER) IS
    'One recipe, N pots, each rolling its own harmony. Refuses before spending if the herbs for the whole run are not there, and reports exactly the pills it minted.';


-- The probe 0137 wrote, plus the assertion it was missing.
DO $$
DECLARE
    ghost BIGINT;
    run   RECORD;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999138, 'migration 0138 probe')
    RETURNING player_id INTO ghost;

    PERFORM grant_material(ghost, 'spirit_dew_grass', 200);
    PERFORM grant_material(ghost, 'clear_mind_orchid', 200);

    SELECT * INTO run FROM brew_many(
        ghost, ARRAY['spirit_dew_grass', 'clear_mind_orchid'], ARRAY[4, 4], 2);

    IF run.attempts <> 2 OR run.succeeded + run.spoiled <> 2 THEN
        RAISE EXCEPTION 'a run of two reported % attempts, % ok, % spoiled',
            run.attempts, run.succeeded, run.spoiled;
    END IF;
    IF run.herbs_spent <> 16 THEN
        RAISE EXCEPTION 'two pots of eight herbs spent %', run.herbs_spent;
    END IF;

    -- The one 0137 did not make.
    IF run.succeeded > 0 AND jsonb_array_length(run.made) = 0 THEN
        RAISE EXCEPTION
            'the run made % pill(s) and reported none of them', run.succeeded;
    END IF;
    IF jsonb_array_length(run.made) <> (
        SELECT count(*) FROM player_pills WHERE owner_id = ghost
    ) THEN
        RAISE EXCEPTION 'the run named % pills and the shelf holds %',
            jsonb_array_length(run.made),
            (SELECT count(*) FROM player_pills WHERE owner_id = ghost);
    END IF;

    DELETE FROM player_pills WHERE owner_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
