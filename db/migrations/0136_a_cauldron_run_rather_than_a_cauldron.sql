-- 0136_a_cauldron_run_rather_than_a_cauldron
--
-- 0135 made overfilling pay, which is a lucky double and not what anybody
-- means by "make me ten healing pills". This is the other thing: set the
-- recipe once and brew it N times.
--
-- EACH REPETITION ROLLS ITS OWN HARMONY. That is the whole design decision.
-- Brewing ten of one recipe should return a spread - three excellent, one
-- spoiled - rather than ten copies of one result, because the gamble is what
-- alchemy IS. A run that averaged the roll would be a different, duller game
-- with the same herbs going in.
--
-- WHAT IS SPENT IS CHECKED FIRST. The herbs for the whole run are verified
-- before any of them are taken, so a run either happens or does not. Half a
-- run with the herbs gone is the worst outcome available and it is the one a
-- naive loop produces.
--
-- NO INSURANCE IN A RUN. `brew`'s `p_protect` is a jade-priced net for one
-- careful expensive pot. Charged once across ten brews it is nearly free;
-- charged per brew it is absurd. A run is for commodity brewing, and the
-- single-pot command keeps the net.
--
-- HOW MANY is a profession ladder, like every other craft limit in this
-- schema. Two at the start, ten by level 120, on the same accelerating rungs
-- 0106 gave mining and refining.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('alchemy_base_brews', 2,
     'Brews in one run before the ladder adds any. Two, so a run is a run from the first level.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;

INSERT INTO profession_steps (ladder, step, level_required) VALUES
    ('alchemy_brews', 1, 8),
    ('alchemy_brews', 2, 18),
    ('alchemy_brews', 3, 30),
    ('alchemy_brews', 4, 44),
    ('alchemy_brews', 5, 60),
    ('alchemy_brews', 6, 78),
    ('alchemy_brews', 7, 98),
    ('alchemy_brews', 8, 120)
ON CONFLICT DO NOTHING;


CREATE FUNCTION alchemy_max_brews(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT (game_config_value('alchemy_base_brews')
            + ladder_steps('alchemy_brews', p_level))::smallint;
$$;

COMMENT ON FUNCTION alchemy_max_brews(SMALLINT) IS
    'How many pots an Alchemist of this level can run back to back. Askable for a level nobody has reached.';


-- ---------------------------------------------------------------------------
-- brew_many
-- ---------------------------------------------------------------------------
-- A loop around `brew`, which stays exactly as it is - every rule about what
-- a cauldron accepts, what it makes and what a failure hands back is already
-- written there and must not be written twice.

CREATE FUNCTION brew_many(
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
            n_pills := n_pills + one.batch;
        ELSE
            n_bad  := n_bad + 1;
            n_back := n_back + COALESCE(one.herbs_back, 0);
        END IF;
    END LOOP;

    -- Two pots of the same recipe roll different harmony and therefore
    -- different magnitude, so they are genuinely different pills and are left
    -- as separate rows. Where every column DOES match, they are the same pill
    -- and a shelf listing it twice would be the shelf being wrong.
    WITH same AS (
        SELECT min(pp.pill_id) AS keeper, sum(pp.quantity) AS total,
               array_agg(pp.pill_id) AS ids
        FROM player_pills pp
        WHERE pp.owner_id = p_player_id
          AND pp.brewed_at >= now() - interval '1 minute'
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
           COALESCE(lvl, skill),
           CASE WHEN p_times > 0 THEN best END,
           CASE WHEN p_times > 0 THEN worst END,
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
                    WHERE pp.owner_id = p_player_id
                      AND pp.brewed_at >= now() - interval '1 minute'
                ) x),
               '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION brew_many(BIGINT, TEXT[], INTEGER[], INTEGER) IS
    'One recipe, N pots, each rolling its own harmony. Refuses before spending if the herbs for the whole run are not there.';


DO $$
BEGIN
    -- A ladder that never moves is a ladder nobody climbs, and one that
    -- outruns the game is a promise it cannot keep.
    IF alchemy_max_brews(1::smallint) < 2 THEN
        RAISE EXCEPTION 'a level 1 Alchemist cannot run a run';
    END IF;
    IF alchemy_max_brews(200::smallint) <> 10 THEN
        RAISE EXCEPTION 'the run ceiling is %, not the 10 intended',
            alchemy_max_brews(200::smallint);
    END IF;
END;
$$;
