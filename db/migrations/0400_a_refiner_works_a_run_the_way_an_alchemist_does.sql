-- 0400_a_refiner_works_a_run_the_way_an_alchemist_does
--
-- An alchemist has had `brew_many` for a while: name the herbs once, say how
-- many pots, and the run is worked through with one press. A Gu Refiner makes
-- one worm per press, and a bench is the sort of thing you stand at for an
-- afternoon.
--
-- `refine_many` is the same function for the other profession, deliberately
-- built to the same shape so the two benches behave the same way:
--
--   IT LOOPS OVER `refine_gu` rather than reimplementing it. That function
--     scores harmony off the ingredient pairs, rolls potency, decides stars,
--     hands back `gu_refine_refund` of everything on a failure and carries the
--     experience ladder. A second copy would be five chances to disagree.
--
--   IT CHECKS THE WHOLE RUN BEFORE IT SPENDS ANY OF IT, which is the part of
--     `brew_many` worth copying most. `refine_gu` would refuse the fourth
--     attempt on its own, but by then three sets of ingredients are gone and
--     the player asked for a run rather than for whatever fitted.
--
--   AND THE RUN LENGTH IS A PROFESSION LADDER, `gu_refine_runs`, laid on the
--     same levels `alchemy_brews` uses - 8, 18, 30, 44, 60, 78, 98, 120. Two
--     at the start and ten at the top, exactly as an alchemist gets. Two
--     professions that do the same shape of work should not have two different
--     shapes of ladder.
--
-- WHAT IT DOES NOT COPY. Brewing merges identical pills into one stack at the
-- end, because two pots of one recipe that rolled the same everything ARE the
-- same pill and a shelf listing it twice would be the shelf being wrong. Gu do
-- not stack - every worm is its own row with its own stars and its own harmony,
-- and `nurture_gu` eats duplicates one at a time. So there is no merge step
-- here, and that is a real difference between the two crafts rather than an
-- omission.
--
-- Who this reaches today: clearwest at Gu Refiner 65 and m_i_y_u_k_i at 64 run
-- six at a time; pashu0 at 15 runs three; everybody else two.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('gu_refine_base_runs', 2,
     'Refinements a novice Gu Refiner works in one run, before the gu_refine_runs ladder adds to it. Two, the same as an alchemist starts with.');


-- The same levels `alchemy_brews` climbs. Two crafts of the same shape should
-- not have two shapes of ladder.
INSERT INTO profession_steps (ladder, step, level_required)
SELECT 'gu_refine_runs', s.step, s.level_required
FROM profession_steps s WHERE s.ladder = 'alchemy_brews';


CREATE FUNCTION gu_refine_max_runs(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $$
    SELECT (game_config_value('gu_refine_base_runs')
            + ladder_steps('gu_refine_runs', p_level))::smallint;
$$;

COMMENT ON FUNCTION gu_refine_max_runs(SMALLINT) IS
    'How many refinements a Gu Refiner of this level works in one run. The companion of alchemy_max_brews, on the same ladder.';


CREATE FUNCTION refine_many(
    p_player_id BIGINT, p_gu_type_id BIGINT,
    p_aux_codes TEXT[] DEFAULT NULL, p_aux_quantities INTEGER[] DEFAULT NULL,
    p_times INTEGER DEFAULT 1
)
RETURNS TABLE (attempts INTEGER, succeeded INTEGER, spoiled INTEGER,
               gu_made INTEGER, materials_spent BIGINT, materials_back BIGINT,
               exp_gained BIGINT, level_after SMALLINT,
               best_harmony SMALLINT, worst_harmony SMALLINT,
               best_stars SMALLINT, made JSONB)
LANGUAGE plpgsql
AS $$
DECLARE
    v_skill  SMALLINT;
    v_cap    SMALLINT;
    v_recipe gu_recipe_costs%ROWTYPE;
    v_short  RECORD;
    v_one    RECORD;
    v_minted BIGINT[] := '{}';
    v_ok     INTEGER := 0;
    v_bad    INTEGER := 0;
    v_back   BIGINT := 0;
    v_exp    BIGINT := 0;
    v_lvl    SMALLINT;
    v_best   SMALLINT := 0;
    v_worst  SMALLINT := 150;
    v_stars  SMALLINT := 0;
    v_spent  BIGINT;
BEGIN
    IF COALESCE(p_times, 1) < 1 THEN
        RAISE EXCEPTION 'a run of no refinements is not a run'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_recipe FROM gu_recipe_costs c
    WHERE c.gu_type_id = p_gu_type_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that Gu cannot be refined' USING ERRCODE = 'check_violation';
    END IF;

    v_skill := profession_level(p_player_id, 'gu_refining');
    v_cap   := gu_refine_max_runs(v_skill);

    IF p_times > v_cap THEN
        RAISE EXCEPTION
            'your Gu Refining works % at a time, not %', v_cap, p_times
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything, before anything. `refine_gu` would refuse the fourth attempt
    -- on its own and three sets of ingredients would already be gone.
    SELECT w.code, material_name(w.code) AS name,
           w.quantity * p_times AS wanted,
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = w.code), 0) AS held
    INTO v_short
    FROM (
        SELECT v_recipe.base_material AS code, v_recipe.base_quantity AS quantity
        UNION ALL
        SELECT v_recipe.secondary_material, v_recipe.secondary_quantity
        UNION ALL
        SELECT u.code, u.quantity
        FROM unnest(COALESCE(p_aux_codes, '{}'::text[]),
                    COALESCE(p_aux_quantities, '{}'::integer[])) AS u (code, quantity)
    ) w
    WHERE COALESCE((SELECT pm.quantity FROM player_materials pm
                    WHERE pm.player_id = p_player_id
                      AND pm.material_code = w.code), 0) < w.quantity * p_times
    ORDER BY w.code
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION '% refinements want % %, and you hold %',
            p_times, v_short.wanted, v_short.name, v_short.held
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT (v_recipe.base_quantity + v_recipe.secondary_quantity
            + COALESCE((SELECT sum(u.quantity)
                        FROM unnest(COALESCE(p_aux_quantities, '{}'::integer[]))
                             AS u (quantity)), 0)) * p_times
    INTO v_spent;

    FOR i IN 1..p_times LOOP
        SELECT * INTO v_one FROM refine_gu(p_player_id, p_gu_type_id,
                                           p_aux_codes, p_aux_quantities);

        v_exp   := v_exp + v_one.exp_gained;
        v_lvl   := v_one.level_after;
        v_best  := GREATEST(v_best, v_one.harmony_score);
        v_worst := LEAST(v_worst, v_one.harmony_score);

        IF v_one.succeeded THEN
            v_ok     := v_ok + 1;
            v_stars  := GREATEST(v_stars, COALESCE(v_one.stars_made, 1));
            v_minted := v_minted || v_one.new_gu_id;
        ELSE
            v_bad  := v_bad + 1;
            v_back := v_back + COALESCE(v_one.handed_back, 0);
        END IF;
    END LOOP;

    -- No merge step, unlike `brew_many`. Every Gu is its own row with its own
    -- stars and its own harmony, and `nurture_gu` eats duplicates one at a
    -- time - stacking them would be taking that apart.
    RETURN QUERY
    SELECT p_times, v_ok, v_bad, v_ok, v_spent, v_back, v_exp,
           COALESCE(v_lvl, v_skill), v_best, v_worst, v_stars,
           COALESCE(
               (SELECT jsonb_agg(jsonb_build_object(
                    'gu_id', g.gu_id, 'name', t.name, 'rank', t.rank,
                    'emoji', t.emoji, 'stars', g.stars, 'harmony', g.harmony,
                    'rarity', t.rarity)
                    ORDER BY g.stars DESC, g.harmony DESC)
                FROM player_gu g
                JOIN gu_types t ON t.gu_type_id = g.gu_type_id
                WHERE g.gu_id = ANY (v_minted)),
               '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION refine_many(BIGINT, BIGINT, TEXT[], INTEGER[], INTEGER) IS
    'Works a run of refinements through refine_gu, after checking the whole run is affordable. The companion of brew_many, on the same ladder shape.';


-- ---------------------------------------------------------------------------
-- A run is that many singles, and it refuses before it spends
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_gu    BIGINT;
    v_r     RECORD;
    v_got   RECORD;
    v_held  BIGINT;
    v_after BIGINT;
BEGIN
    -- The ladder is the alchemist's, rung for rung.
    IF EXISTS (
        SELECT 1 FROM profession_steps a
        FULL JOIN profession_steps b
               ON b.ladder = 'gu_refine_runs' AND b.step = a.step
        WHERE a.ladder = 'alchemy_brews'
          AND (b.level_required IS DISTINCT FROM a.level_required)
    ) THEN
        RAISE EXCEPTION 'the two benches do not climb the same ladder';
    END IF;

    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL
    ORDER BY profession_level(p.player_id, 'gu_refining') DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody to measure; the tests carry this';
        RETURN;
    END IF;

    RAISE NOTICE 'a refiner of level % works % at a time',
        profession_level(v_who, 'gu_refining'),
        gu_refine_max_runs(profession_level(v_who, 'gu_refining'));

    BEGIN
        -- A recipe they are levelled for.
        SELECT c.* INTO v_r FROM gu_recipe_costs c
        JOIN gu_types t ON t.gu_type_id = c.gu_type_id
        WHERE c.required_level <= profession_level(v_who, 'gu_refining')
          AND t.rank <= game_config_value('gu_max_refinable_rank')
        ORDER BY t.rank DESC LIMIT 1;

        IF v_r.gu_type_id IS NULL THEN
            RAISE NOTICE 'nothing they can make; the tests carry this';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- ---- it refuses a run it cannot pay for, BEFORE spending ----------
        UPDATE player_materials SET quantity = 0
        WHERE player_id = v_who
          AND material_code IN (v_r.base_material, v_r.secondary_material);

        PERFORM grant_material(v_who, v_r.base_material,
                               v_r.base_quantity::bigint * 2);
        PERFORM grant_material(v_who, v_r.secondary_material,
                               v_r.secondary_quantity::bigint * 2);

        SELECT pm.quantity INTO v_held FROM player_materials pm
        WHERE pm.player_id = v_who AND pm.material_code = v_r.base_material;

        BEGIN
            PERFORM refine_many(v_who, v_r.gu_type_id, NULL, NULL, 3);
            RAISE EXCEPTION 'a run it could not afford went ahead anyway';
        EXCEPTION
            WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%and you hold%' THEN
                    RAISE EXCEPTION 'it refused for the wrong reason: %', SQLERRM;
                END IF;
        END;

        SELECT pm.quantity INTO v_after FROM player_materials pm
        WHERE pm.player_id = v_who AND pm.material_code = v_r.base_material;

        IF v_after <> v_held THEN
            RAISE EXCEPTION
                'a refused run still spent ingredients: % became %', v_held, v_after;
        END IF;

        -- ---- and a run it CAN pay for works through ------------------------
        SELECT * INTO v_got FROM refine_many(v_who, v_r.gu_type_id, NULL, NULL, 2);

        IF v_got.attempts <> 2 THEN
            RAISE EXCEPTION 'asked for two, attempted %', v_got.attempts;
        END IF;
        IF v_got.succeeded + v_got.spoiled <> 2 THEN
            RAISE EXCEPTION 'two attempts came to % outcomes',
                v_got.succeeded + v_got.spoiled;
        END IF;
        IF v_got.succeeded > 0
           AND jsonb_array_length(v_got.made) <> v_got.succeeded THEN
            RAISE EXCEPTION
                'it made % and listed %', v_got.succeeded,
                jsonb_array_length(v_got.made);
        END IF;

        RAISE NOTICE
            'a run of two: % formed, % spoiled, % ingredients spent, % handed back',
            v_got.succeeded, v_got.spoiled, v_got.materials_spent,
            v_got.materials_back;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
