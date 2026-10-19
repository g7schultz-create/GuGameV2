-- 0494_the_apex_costs_what_an_apex_should
--
-- 0493 gave the fifteen rank 9 Gu teeth. Three things then make them wrong to
-- own, and all three are measured rather than guessed.
--
-- ONE: THE RECIPES CANNOT BE USED AT ALL. `gu_max_refinable_rank` is 8. The
-- fifteen rank 9 recipes have sat in `gu_recipes` since 0036 behind a gate
-- that refuses them. The spec's phase 4 called this "reprice the fifteen rank
-- 9 recipes"; they were never reachable to be priced.
--
-- TWO: THE COST CURVE FLATTENS EXACTLY WHERE IT SHOULD STEEPEN.
--
--     rank   1     2     3     4     5     6     7     8     9
--     step   -    2.50  2.25  2.00  1.78  1.63  1.54  1.50  1.50
--
-- Every step is smaller than the one before it, and the apex gets the
-- smallest of all. 900 base at the `extreme` rarity multiplier of 14 is
-- 12,600 of a material - and the biggest single stock any cultivator holds of
-- a rank 9 base material is 48,242. So the most powerful worm in the game was
-- a quarter of one player's shelf.
--
-- The apex gets the LARGEST step instead: 8x, to 4,800 base, which is 67,200
-- after the rarity multiplier. Nobody can make one today, which is the point
-- of an apex. required_level goes 65 to 85 against a measured maximum
-- gu_refining of 98 and a mean of 39 - a gate only a specialist passes.
--
-- THREE: AND THEY WERE NOT RARE, THEY WERE THE COMMONEST THING AT THE TOP.
--
--     owned by rank    r5 125   r6 337   r7 64   r8 10   r9 158
--
-- 158 rank 9 worms against 10 at rank 8. They arrived over eighteen days of
-- real play, four to six an hour at peak, about nine a day. The route is
-- `claim_boss_reward`, which grants a slain boss's `signature_gu_type_id`
-- with no roll at all - `IF crest IS NOT NULL THEN grant_gu(...)`. Two
-- species carry a rank 9 crest:
--
--     Shadow Demon King        -> heaven_defying_chaos_gu
--     Heavenly Court General   -> heavenly_web_gu
--
-- Which are precisely the two worms 0493 just made the strongest in the game
-- - crit_damage 2.90 and multi_hit 3.40. A repeatable boss was handing the
-- apex of the ladder to every claimant, unconditionally. Before 0493 that
-- was harmless because the worms did nothing; now it would be the only build
-- worth having, and free.
--
-- So a crest at or above the configured rank needs a roll. Everything below
-- it is untouched, which is every other boss in the game: the 341 other
-- claims behave exactly as they did.
--
-- 8% keeps the two apex worms dropping - about one every day and a half
-- across the whole server rather than nine a day - so the boss is still the
-- fast route and the repriced recipe is the reliable one.
--
-- NOBODY LOSES A WORM. The 158 already owned stay owned. This changes what
-- arrives from here.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The gate, the price, and the roll
-- ---------------------------------------------------------------------------

UPDATE game_config SET value = 9 WHERE key = 'gu_max_refinable_rank';

UPDATE gu_refine_costs
SET base_quantity      = 4800,
    secondary_quantity = 2400,
    required_level     = 85,
    exp_reward         = 18000
WHERE rank = 9;

INSERT INTO game_config (key, value) VALUES
    ('boss_crest_rare_from',   9),
    ('boss_crest_rare_chance', 0.08)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ---------------------------------------------------------------------------
-- A crest worth the name is not handed over for turning up
-- ---------------------------------------------------------------------------

-- Lifted and patched. The anchor is the unconditional grant itself, and it is
-- a single line because the stored body is CRLF.
DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
    body   TEXT;
BEGIN
    src := pg_get_functiondef('claim_boss_reward(bigint,bigint)'::regprocedure);

    anchor := '            IF crest IS NOT NULL THEN';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the crest grant in claim_boss_reward is not there exactly once';
    END IF;

    body :=
        '            -- An apex crest is rolled for rather than handed over.' || chr(10) ||
        '            -- Two species carry a rank 9 signature and both of them' || chr(10) ||
        '            -- are repeatable, which put 158 of the strongest worms in' || chr(10) ||
        '            -- the game into play against 10 at rank 8. Everything' || chr(10) ||
        '            -- below the configured rank is untouched.' || chr(10) ||
        '            IF crest IS NOT NULL' || chr(10) ||
        '               AND (SELECT t.rank FROM gu_types t' || chr(10) ||
        '                    WHERE t.gu_type_id = crest)' || chr(10) ||
        '                   >= game_config_value(''boss_crest_rare_from'')' || chr(10) ||
        '               AND random() >= game_config_value(''boss_crest_rare_chance'')' || chr(10) ||
        '            THEN' || chr(10) ||
        '                crest := NULL;' || chr(10) ||
        '            END IF;' || chr(10) ||
        chr(10) ||
        anchor;

    src := replace(src, anchor, body);
    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Reachable, expensive, and rare
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_step  NUMERIC;
    v_cost  INTEGER;
    v_lvl   SMALLINT;
    v_kept  INTEGER;
    v_low   INTEGER;
    v_high  INTEGER;
    v_n     INTEGER;
BEGIN
    -- Reachable at all now.
    IF game_config_value('gu_max_refinable_rank') < 9 THEN
        RAISE EXCEPTION 'the fifteen rank 9 recipes are still behind the refining gate';
    END IF;

    -- The apex step is now the largest in the curve rather than the smallest.
    SELECT round(c9.base_quantity::NUMERIC / c8.base_quantity, 2) INTO v_step
    FROM gu_refine_costs c9, gu_refine_costs c8
    WHERE c9.rank = 9 AND c8.rank = 8;
    IF v_step < 2.5 THEN
        RAISE EXCEPTION 'the rank 9 step is % - still flatter than rank 2', v_step;
    END IF;

    -- And the curve only climbs, which it did before and must still.
    IF EXISTS (SELECT 1 FROM gu_refine_costs a JOIN gu_refine_costs b ON b.rank = a.rank + 1
               WHERE b.base_quantity <= a.base_quantity
                  OR b.secondary_quantity <= a.secondary_quantity
                  OR b.required_level <= a.required_level
                  OR b.exp_reward <= a.exp_reward) THEN
        RAISE EXCEPTION 'the refine cost curve stopped climbing';
    END IF;

    -- Expensive against what anybody actually holds. The largest stock of a
    -- rank 9 base material measured 48,242.
    SELECT min(base_quantity) INTO v_cost FROM gu_recipe_costs WHERE rank = 9;
    IF v_cost <= 48242 THEN
        RAISE EXCEPTION
            'a rank 9 recipe asks % which somebody can already pay', v_cost;
    END IF;

    -- A gate only a specialist passes: the measured ceiling is 98.
    SELECT required_level INTO v_lvl FROM gu_refine_costs WHERE rank = 9;
    SELECT count(*) INTO v_n FROM player_professions
    WHERE profession = 'gu_refining' AND level >= v_lvl;
    IF v_lvl > 98 THEN
        RAISE EXCEPTION 'the rank 9 gate at % is above the ceiling anybody has reached', v_lvl;
    END IF;

    -- The patch landed, and it reads the rank off the crest rather than
    -- naming the two species.
    IF pg_get_functiondef('claim_boss_reward(bigint,bigint)'::regprocedure)
       NOT LIKE '%boss_crest_rare_chance%' THEN
        RAISE EXCEPTION 'claim_boss_reward still hands over an apex crest for free';
    END IF;

    -- Nobody lost a worm they already had.
    SELECT count(*) INTO v_kept FROM player_gu pg
    JOIN gu_types gt USING (gu_type_id) WHERE gt.rank = 9;
    IF v_kept < 158 THEN
        RAISE EXCEPTION 'rank 9 worms in play fell to % from 158', v_kept;
    END IF;

    -- And the two crests that are now rolled for are the two that were the
    -- problem, not some third thing.
    SELECT count(*) INTO v_n
    FROM creature_species cs
    JOIN gu_types gt ON gt.gu_type_id = cs.signature_gu_type_id
    WHERE gt.rank >= game_config_value('boss_crest_rare_from');
    IF v_n <> 2 THEN
        RAISE EXCEPTION
            'the rare-crest rule now covers % species rather than the 2 measured', v_n;
    END IF;

    -- Every other boss in the game is untouched.
    SELECT count(*) INTO v_low
    FROM creature_species cs
    JOIN gu_types gt ON gt.gu_type_id = cs.signature_gu_type_id
    WHERE gt.rank < game_config_value('boss_crest_rare_from');
    SELECT count(*) INTO v_high FROM creature_species WHERE signature_gu_type_id IS NOT NULL;

    RAISE NOTICE
        'rank 9 costs % of a material at level %, % crest(s) now rolled at %%%, % left alone',
        v_cost, v_lvl, v_n,
        round(game_config_value('boss_crest_rare_chance') * 100), v_low;
END;
$probe$;
