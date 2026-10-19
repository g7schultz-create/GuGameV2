-- 0432_a_refinement_manual_stops_being_an_off_switch
--
-- `refinement_bonus` is the only manual bonus that multiplies a BOUNDED
-- quantity. Every other column feeds a stat that can keep climbing; this one
-- feeds harmony, which is a 0-150 roll read against fixed thresholds. The
-- shape that is right for the first is wrong for the second:
--
--     final_h := clamp(h * (1 + crafting_harmony_bonus(player)))
--
-- with no ceiling on the multiplier. The best manual in the game carries
-- 3.655, which is x4.655. The median Gu refinement is harmony 77, so that
-- manual turns every median refinement into 358, clamped to 150 - and 150 is
-- past the 120 a 5-star Gu needs. It does not improve refinements, it ENDS
-- them. Harmony stops being a thing you roll and becomes a thing you have.
--
-- WHAT IT SHOULD BE WORTH. About one grade band. The grades are 2-star at 40,
-- 3-star at 70, 4-star at 95 and 5-star at 120; a refinement manual that
-- carries a median press from 3-star to 4-star is a real reward, and one that
-- hands out 5-star unconditionally is not a reward at all, because nothing is
-- left to earn.
--
-- THE SHAPE, and why it is not a flat cap. A cap of C makes every manual at or
-- above C identical, which flattens exactly the top of the range where the
-- interesting manuals live - a tier 15 extreme would be worth no more than a
-- tier 8 common. This saturates instead:
--
--     effective(b) = b * C / (C + b)
--
-- which is about b when b is small, approaches C and never reaches it, and is
-- strictly increasing - so a better manual is always worth more, forever,
-- while none is ever worth more than C. C is `refinement_harmony_ceiling`.
--
-- At C = 0.50 the ladder reads:
--
--     tier 1 common         0.060 -> 0.054
--     tier 5 common         0.280 -> 0.179
--     tier 8 common         0.560 -> 0.264
--     tier 12 common        1.200 -> 0.353
--     tier 15 common        2.130 -> 0.405
--     the best that exists  3.655 -> 0.440
--     tier 15 extreme       6.090 -> 0.462
--
-- and what that does at a bench:
--
--     a pile that was failing    15 ->  21.6   forms (the threshold is 20)
--     median Gu press            77 -> 110.9   3-star becomes 4-star
--     median manual press        92 -> 132.5   clears 105, so a technique
--     an already-excellent Gu   110 -> 150     pins, which it has earned
--
-- The first line is the page type's own promise - "a thing that would have
-- failed sometimes forms" - and it is the one the OLD shape kept worst,
-- because a multiplier helps least exactly where harmony is lowest.
--
-- BOTH CHANNELS, ONE NUMBER. `refinement_bonus` is read twice: here, and
-- through `manual_effect_columns` as `refine_conflict_relief`. Both now read it
-- through the same curve, so the number on the manual card means one thing.
-- The relief channel keeps its own 0.75 ceiling in `gu_effects`, which is the
-- ceiling for ALL sources together - a manual at 0.462 now leaves room for the
-- destiny and the physique that also grant it to stack underneath it, rather
-- than one source swallowing the whole allowance.
--
-- NOBODY LOSES ANYTHING, and this is checked rather than asserted: not one of
-- the 30 live cultivators has a slotted manual carrying this bonus, so
-- `crafting_harmony_bonus` returns 0 for every player in the game today and
-- this migration changes no outcome that anybody has. The 32 manuals that do
-- carry it are all sitting unslotted. This lands before the first person
-- equips one rather than after, which is the only comfortable time to move a
-- number like this.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES (
    'refinement_harmony_ceiling', 0.50,
    'What a Refinement manual can be worth at a bench, as a share of harmony. The bonus saturates toward this and never reaches it, so a better manual is always worth more and none is ever an off-switch. Set in 0432, where an uncapped multiplier was handing out 5-star Gu unconditionally.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- The curve, in one place because two readers ask for it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION refinement_effective(p_bonus numeric)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- b * C / (C + b): about b while b is small, strictly increasing, and
    -- asymptotic to C. GREATEST keeps a negative out of the denominator,
    -- where it would divide by zero at b = -C.
    SELECT CASE WHEN GREATEST(0, p_bonus) = 0 THEN 0 ELSE
        GREATEST(0, p_bonus) * game_config_value('refinement_harmony_ceiling')
        / (game_config_value('refinement_harmony_ceiling') + GREATEST(0, p_bonus))
    END::numeric;
$fn$;

COMMENT ON FUNCTION refinement_effective(numeric) IS
    'What a manual refinement_bonus is actually worth, saturating toward refinement_harmony_ceiling. Read by crafting_harmony_bonus and by manual_stat, so the harmony multiplier and the conflict relief cannot come to disagree about one number.';


-- ---------------------------------------------------------------------------
-- The harmony multiplier reads it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'crafting_harmony_bonus' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'crafting_harmony_bonus is missing';
    END IF;

    anchor := concat(
'    SELECT COALESCE((SELECT b.refinement_bonus FROM player_manual_bonuses b', chr(10),
'                     WHERE b.player_id = p_player_id), 0);');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'crafting_harmony_bonus no longer reads the column where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- Through the curve since 0432. Raw, this multiplied a bounded harmony', chr(10),
'    -- roll by as much as 4.655 and handed out the top grade unconditionally.', chr(10),
'    SELECT refinement_effective(COALESCE(', chr(10),
'               (SELECT b.refinement_bonus FROM player_manual_bonuses b', chr(10),
'                WHERE b.player_id = p_player_id), 0));'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And so does the conflict relief, so one number means one thing
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'manual_stat' AND pronamespace = 'public'::regnamespace;

    anchor := '                   WHEN ''refinement_bonus''   THEN b.refinement_bonus';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'manual_stat no longer maps refinement_bonus where it did';
    END IF;

    EXECUTE replace(body, anchor,
'                   WHEN ''refinement_bonus''   THEN refinement_effective(b.refinement_bonus)');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A description that names a threshold the game does not have
-- ---------------------------------------------------------------------------

-- `technique_manual_harmony` says "The failure threshold is 45", and
-- `refinement_failure_threshold` is 20. Not a behaviour change - nothing reads
-- a description - but it is the number somebody reaches for when they want to
-- know whether a press was close, and it has been wrong by more than double.
UPDATE game_config SET description =
    'Harmony an attack refinement must reach for a killer move to fall out of it. The press fails below refinement_failure_threshold, which is 20, and clamps at 140 - so this is a good refinement rather than a lucky one. The 45 this line used to name was never a threshold in this game; corrected in 0432.'
WHERE key = 'technique_manual_harmony';


-- ---------------------------------------------------------------------------
-- The curve is a curve, the ceiling holds, and nobody is poorer for it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    C        NUMERIC;
    prev     NUMERIC := -1;
    v        NUMERIC;
    b        NUMERIC;
    v_bad    TEXT;
    v_moved  INTEGER;
    r        RECORD;
BEGIN
    C := game_config_value('refinement_harmony_ceiling');
    IF C IS NULL OR C <= 0 THEN
        RAISE EXCEPTION 'the ceiling is % rather than a positive share', C;
    END IF;

    -- Nothing, and nothing is worth nothing. A manual nobody has must not
    -- quietly become a manual everybody has.
    IF refinement_effective(0) <> 0 THEN
        RAISE EXCEPTION 'no manual is worth % rather than nothing',
            refinement_effective(0);
    END IF;

    -- Strictly increasing, and never at or above the ceiling. Both halves
    -- matter: the first is what keeps a better manual better, and the second
    -- is the whole point of the migration.
    FOR b IN SELECT generate_series(0, 200) * 0.05 LOOP
        v := refinement_effective(b);
        IF v <= prev AND b > 0 THEN
            RAISE EXCEPTION
                'the curve stops climbing at % (% then %)', b, prev, v;
        END IF;
        IF v >= C THEN
            RAISE EXCEPTION 'a bonus of % reaches the ceiling % (got %)', b, C, v;
        END IF;
        prev := v;
    END LOOP;

    -- Damping only. No manual may be worth MORE than it says on its face.
    SELECT string_agg(x.b::text, ', ') INTO v_bad
    FROM (SELECT generate_series(1, 400) * 0.025 AS b) x
    WHERE refinement_effective(x.b) > x.b;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the curve INFLATES these: %', v_bad;
    END IF;

    -- Both readers go through it, so the card and the bench agree.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'crafting_harmony_bonus'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%refinement_effective%' THEN
        RAISE EXCEPTION 'the harmony multiplier still reads the raw column';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'manual_stat'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%refinement_effective%' THEN
        RAISE EXCEPTION 'the conflict relief still reads the raw column';
    END IF;

    -- NOBODY LOSES ANYTHING: every live cultivator reads the same as before,
    -- because not one of them has this bonus at all. If that ever stops being
    -- true this line is the one that will say so, loudly, before it ships.
    SELECT count(*) INTO v_moved FROM players p
    WHERE p.deleted_at IS NULL AND crafting_harmony_bonus(p.player_id) <> 0;
    IF v_moved <> 0 THEN
        RAISE EXCEPTION
            '% cultivator(s) already hold a Refinement manual - this change moves a number under them, so price it before applying',
            v_moved;
    END IF;

    -- And the thing it was built to stop: a median press must NOT become a
    -- 5-star Gu on its own. 77 is the median harmony and 120 is 5 stars.
    IF 77 * (1 + refinement_effective(
             (SELECT max(refinement_bonus) FROM manuals))) >= 120 THEN
        RAISE EXCEPTION
            'the best manual still carries a median refinement to 5 stars (%)',
            77 * (1 + refinement_effective(
                  (SELECT max(refinement_bonus) FROM manuals)));
    END IF;

    -- But it must still rescue a pile that was failing, which is the page
    -- type's own promise. 15 is a failing roll and 20 is the threshold.
    IF 15 * (1 + refinement_effective(
             (SELECT max(refinement_bonus) FROM manuals))) < 20 THEN
        RAISE EXCEPTION
            'the best manual no longer saves a failing refinement (%)',
            15 * (1 + refinement_effective(
                  (SELECT max(refinement_bonus) FROM manuals)));
    END IF;

    RAISE NOTICE 'ceiling %, and the ladder to it:', C;
    FOR r IN
        SELECT t.tier, t.bonus_budget AS raw,
               round(refinement_effective(t.bonus_budget), 3) AS worth,
               round(77 * (1 + refinement_effective(t.bonus_budget))) AS median_gu
        FROM manual_tiers t ORDER BY t.tier
    LOOP
        RAISE NOTICE '  tier % : % -> %  (a median Gu press lands at %)',
            lpad(r.tier::text, 2), rpad(r.raw::text, 6), rpad(r.worth::text, 5),
            r.median_gu;
    END LOOP;
END;
$probe$;
