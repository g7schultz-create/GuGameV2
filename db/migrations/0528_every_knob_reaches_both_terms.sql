-- 0528_every_knob_reaches_both_terms
--
-- `test_stacks_make_everything_cost_more` fails about once in forty runs, with
-- the same number on both sides every time:
--
--     assert 99999999903 > 99999999903
--
-- The same number twice means a ceiling both sides saturate against, not dice.
-- `delve_act` takes the greater of two figures:
--
--     v_taken := GREATEST(
--         hit.final_damage,                       -- the arithmetic
--         v_max * mv.share                        -- a share of your body
--         * (1 + f.rage * delve_rage_step)        --   raged
--         * st.taken_mult                         --   and by your stance
--         * (answered ? delve_answered_share : 1) --   and by reading it right
--     );
--
-- EVERY MULTIPLIER IS INSIDE THE FLOOR TERM. Measured against a rank 18 beast
-- and a 1e12 body: the floor is 20% of the body and the arithmetic 4%, so the
-- floor normally wins and the knobs work. When the creature CRITS the
-- arithmetic jumps to about 10% - above even the raged, answered floor at
-- 8.75% - and at that moment the rage stack, the guard stance and the
-- answered-telegraph discount ALL go inert at once. Reading the telegraph
-- correctly buys nothing on exactly the rounds it matters most.
--
-- This is 0507 mirrored. There, a share-of-body bite floor bypassed defence
-- entirely and a standing test caught it; the fix was to put the arithmetic's
-- own mitigation onto the floor. Here the arithmetic skips the mitigations the
-- floor carries. Both are the same mistake: a number computed two ways, with
-- the adjustments applied to only one of them.
--
-- SO THE MULTIPLIER COMES OUT OF THE TERM AND WRAPS BOTH. The floor-dominant
-- case - which is the normal case - is arithmetically IDENTICAL, because
-- `round(m * share * body)` and `round(share * body * m)` are the same
-- expression; the probe asserts that against the live roster rather than
-- claiming it. What changes is only the rounds where a creature crits, and
-- there a guarding cultivator who read the move now gets the discount the
-- screen already promised them.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('delve_act(bigint,text,bigint)'::regprocedure);

    -- The multiplier needs somewhere to live. Added next to the figure it is
    -- applied to rather than at the top of a thirty-line DECLARE block.
    one := '    v_taken BIGINT := 0;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the v_taken declaration is not where I read it';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        '    -- 0528. The rage stack, the stance and the answered discount, held' || chr(10) ||
        '    -- apart from the two figures they apply to so they can reach both.' || chr(10) ||
        '    v_mult  NUMERIC := 1;');

    one := '        v_taken := GREATEST(' || chr(10) ||
           '            GREATEST(0, COALESCE(hit.final_damage, 0)),' || chr(10) ||
           '            GREATEST(1, round(' || chr(10) ||
           '                v_max * mv.share' || chr(10) ||
           '                * (1 + f.rage * game_config_value(''delve_rage_step''))' || chr(10) ||
           '                * st.taken_mult' || chr(10) ||
           '                * CASE WHEN v_ok THEN game_config_value(''delve_answered_share'')' || chr(10) ||
           '                       ELSE 1 END' || chr(10) ||
           '            ))::bigint);';

    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION
            'the two-figure damage expression in delve_act is not where I read it';
    END IF;

    src := replace(src, one,
        '        -- EVERY MULTIPLIER REACHES BOTH FIGURES. They used to sit inside' || chr(10) ||
        '        -- the floor term only, so a creature critical - which puts the' || chr(10) ||
        '        -- arithmetic above even a raged, answered floor - made the rage' || chr(10) ||
        '        -- stack, the guard stance and the answered-telegraph discount' || chr(10) ||
        '        -- all inert at once, on exactly the rounds they matter most.' || chr(10) ||
        '        v_mult := (1 + f.rage * game_config_value(''delve_rage_step''))' || chr(10) ||
        '                  * st.taken_mult' || chr(10) ||
        '                  * CASE WHEN v_ok THEN game_config_value(''delve_answered_share'')' || chr(10) ||
        '                         ELSE 1 END;' || chr(10) ||
        chr(10) ||
        '        v_taken := GREATEST(1, round(v_mult * GREATEST(' || chr(10) ||
        '            GREATEST(0, COALESCE(hit.final_damage, 0)),' || chr(10) ||
        '            v_max * mv.share' || chr(10) ||
        '        )))::bigint;');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The normal round does not move, and the knobs now reach the hard one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_step  NUMERIC := game_config_value('delve_rage_step');
    v_ans   NUMERIC := game_config_value('delve_answered_share');
    v_share NUMERIC;
    v_tm    NUMERIC;
    v_body  BIGINT  := 1000000000000;
    v_arith BIGINT  := 40000000000;   -- 4% of that body, measured
    v_crit  BIGINT  := 100000000000;  -- 10%, what a creature critical lands
    v_was   BIGINT;
    v_now   BIGINT;
BEGIN
    IF pg_get_functiondef('delve_act(bigint,text,bigint)'::regprocedure)
       NOT LIKE '%v_mult * GREATEST(%' THEN
        RAISE EXCEPTION 'the patch did not install';
    END IF;

    SELECT share INTO v_share FROM delve_beast_moves WHERE code = 'lunge';
    SELECT taken_mult INTO v_tm FROM delve_stances WHERE code = 'guard';

    -- 1. THE FLOOR-DOMINANT ROUND IS IDENTICAL. The old expression and the new
    -- one are the same arithmetic when the share wins, which is the normal
    -- case - so no live delve changes.
    v_was := GREATEST(v_arith,
                 GREATEST(1, round(v_body * v_share * (1 + 0 * v_step) * v_tm * v_ans)))::bigint;
    v_now := GREATEST(1, round((1 + 0 * v_step) * v_tm * v_ans
                 * GREATEST(v_arith, v_body * v_share)))::bigint;
    IF v_was <> v_now THEN
        RAISE EXCEPTION
            'an ordinary guarded round moved: % -> %', v_was, v_now;
    END IF;

    -- 2. AND RAGE NOW REACHES A CRITICAL. This is the failing assertion from
    -- the test, computed both ways: under the old expression a crit made rage
    -- inert, under the new one it does not.
    v_was := GREATEST(v_crit,
                 GREATEST(1, round(v_body * v_share * (1 + 3 * v_step) * v_tm * v_ans)))::bigint;
    IF v_was <> v_crit THEN
        RAISE EXCEPTION
            'the old expression did not actually go inert, so this migration is fixing nothing';
    END IF;

    v_now := GREATEST(1, round((1 + 3 * v_step) * v_tm * v_ans
                 * GREATEST(v_crit, v_body * v_share)))::bigint;
    IF v_now <= GREATEST(1, round((1 + 0 * v_step) * v_tm * v_ans
                 * GREATEST(v_crit, v_body * v_share)))::bigint THEN
        RAISE EXCEPTION 'rage still does not reach a critical';
    END IF;

    -- 3. And reading the telegraph is worth something on that round, which it
    -- was not before - a discount the stance text already promises.
    IF GREATEST(1, round((1 + 3 * v_step) * v_tm * v_ans
                 * GREATEST(v_crit, v_body * v_share)))::bigint
       >= GREATEST(1, round((1 + 3 * v_step) * v_tm * 1
                 * GREATEST(v_crit, v_body * v_share)))::bigint THEN
        RAISE EXCEPTION 'answering the telegraph still buys nothing';
    END IF;

    RAISE NOTICE
        'an ordinary round is unchanged at %; a critical now feels rage and the answer',
        v_now;
END;
$probe$;
