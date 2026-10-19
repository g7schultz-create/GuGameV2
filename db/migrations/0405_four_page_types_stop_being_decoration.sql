-- 0405_four_page_types_stop_being_decoration
--
-- Twenty-six per cent of every page the world hands out is a placeholder:
--
--     Speed          "Action speed. No turn-order system exists yet."
--     Refinement     "Refinement bonuses. No refinement skill exists yet."
--     Breakthrough   "Breakthrough chance. Realms advance on totals, not rolls."
--     Essence        "Primeval essence capacity. Nothing spends essence yet."
--
-- All four roll, all four are summed by `player_manual_bonuses`, all four are
-- printed on `/manuals`, and nothing whatsoever reads them. There are 2,275
-- unspent pages of these kinds sitting in bags right now, and three of the
-- four are already equipped on somebody - pashu0 is carrying +37 per cent
-- Breakthrough and has been getting nothing for it.
--
-- Each is given the job its NAME already promises, rather than a new system:
--
--   SPEED lands on defence. A fast cultivator is a hard one to hit, and this
--     game settles that with damage reduction rather than a turn order, so
--     speed joins `mult_def` beside the manual, Path and foundation terms it
--     belongs with. No new stat, no new screen.
--
--   REFINEMENT lands on harmony, in all three crafts at once - the Gu bench,
--     the cauldron and the page refinery. Harmony is what decides whether a
--     thing forms at all and how much of its tier's budget it carries, so
--     this is "you are better at making things" said in the only currency all
--     three already share. It is self-limiting: harmony clamps at 150 (140 for
--     pages), so a deep Refinement build buys consistency rather than a
--     ceiling nobody else can reach.
--
--   BREAKTHROUGH and ESSENCE both land on what a mouthful of essence and a
--     cultivation pill are WORTH. They stack, deliberately: they are the two
--     kinds nobody has had a reason to keep, and a build that hoards both
--     should feel it. This is the one place in the game where a stat makes
--     the immortal ladder shorter, so it is worth saying plainly that it
--     partly offsets 0396's drag for whoever builds for it - which is the
--     point of building for it.
--
-- WHAT IT DOES NOT DO. It does not touch the roll weights, so the world hands
-- out exactly what it did. It does not add a screen. And it does not rename
-- anything - a Speed page still says Speed, because "the page that quietly
-- means defence" is worse than a page whose flavour and effect merely rhyme.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Two names for the two new jobs
-- ---------------------------------------------------------------------------

CREATE FUNCTION crafting_harmony_bonus(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Refinement, read once so the Gu bench, the cauldron and the page
    -- refinery cannot come to disagree about what it is worth.
    SELECT COALESCE((SELECT b.refinement_bonus FROM player_manual_bonuses b
                     WHERE b.player_id = p_player_id), 0);
$$;

COMMENT ON FUNCTION crafting_harmony_bonus(BIGINT) IS
    'What a cultivator''s Refinement is worth to the harmony of anything they make. One definition for all three crafts.';


CREATE FUNCTION cultivation_intake_bonus(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Breakthrough and Essence together. Two page kinds that had no job, both
    -- pointed at the same one, and stacking on purpose.
    SELECT COALESCE((SELECT b.breakthrough_bonus + b.essence_bonus
                     FROM player_manual_bonuses b
                     WHERE b.player_id = p_player_id), 0);
$$;

COMMENT ON FUNCTION cultivation_intake_bonus(BIGINT) IS
    'How much more cultivation a mouthful of essence or a cultivation pill is worth to this body. Breakthrough and Essence, summed.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- speed becomes defence --------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'apply_physique_xp';

    IF body IS NULL THEN
        RAISE EXCEPTION 'apply_physique_xp is missing';
    END IF;

    anchor := '    man_def     NUMERIC := 0;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer declares man_def once';
    END IF;
    body := replace(body, anchor, concat(
        '    man_def     NUMERIC := 0;', chr(10),
        '    man_spd     NUMERIC := 0;'));

    anchor := concat(
'    SELECT b.hp_bonus, b.defense_bonus, b.strength_bonus', chr(10),
'    INTO man_hp, man_def, man_str', chr(10),
'    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer reads its manual bonuses there';
    END IF;
    body := replace(body, anchor, concat(
'    SELECT b.hp_bonus, b.defense_bonus, b.strength_bonus, b.speed_bonus', chr(10),
'    INTO man_hp, man_def, man_str, man_spd', chr(10),
'    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;'));

    anchor := concat(
'    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0)', chr(10),
'                + COALESCE(path_def, 0)', chr(10),
'                + foundation_bonus(p_player_id, ''defense'');');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'apply_physique_xp no longer sums its defence there';
    END IF;
    body := replace(body, anchor, concat(
'    -- Speed joins the defence pile since 0405. This game has no turn order', chr(10),
'    -- to spend it on and settles "hard to hit" with reduction, so a Speed', chr(10),
'    -- page reads as what it always meant.', chr(10),
'    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0)', chr(10),
'                + COALESCE(man_spd, 0)', chr(10),
'                + COALESCE(path_def, 0)', chr(10),
'                + foundation_bonus(p_player_id, ''defense'');'));

    EXECUTE body;

    -- ---- refinement becomes harmony, in all three crafts ------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'refine_gu';
    anchor := '    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine_gu no longer settles its harmony there';
    END IF;
    EXECUTE replace(body, anchor, concat(
'    -- Refinement, which until 0405 was a page kind that did nothing.', chr(10),
'    final_h := GREATEST(0, LEAST(150, round(', chr(10),
'        h * (1 + crafting_harmony_bonus(p_player_id)))))::smallint;'));

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'brew';
    anchor := '    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'brew no longer settles its harmony there';
    END IF;
    EXECUTE replace(body, anchor, concat(
'    -- The same Refinement the Gu bench reads, for the same reason.', chr(10),
'    final_h := GREATEST(0, LEAST(150, round(', chr(10),
'        h * (1 + crafting_harmony_bonus(p_player_id)))))::smallint;'));

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'refine';
    anchor := '    final_h := GREATEST(0, LEAST(140, round(look.base_harmony + (random() * 8 - 4))))::smallint;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'refine no longer settles its harmony there';
    END IF;
    EXECUTE replace(body, anchor, concat(
'    -- And the page refinery. 140 here rather than 150, which is the', chr(10),
'    -- refinery''s own ceiling and not something this line changed.', chr(10),
'    final_h := GREATEST(0, LEAST(140, round(', chr(10),
'        (look.base_harmony + (random() * 8 - 4))', chr(10),
'        * (1 + crafting_harmony_bonus(p_player_id)))))::smallint;'));

    -- ---- breakthrough and essence become intake ---------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'absorb_essence';
    anchor := concat(
'    worth := p_quantity::numeric * ess.unit_value', chr(10),
repeat(' ', 13), '* game_config_value(''essence_cultivation_rate'')', chr(10),
repeat(' ', 13), '/ realm_climb_drag((SELECT r2.rank FROM realms r2', chr(10),
repeat(' ', 32), 'WHERE r2.realm_id = standing));');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'absorb_essence no longer values its essence where 0396 left it';
    END IF;
    EXECUTE replace(body, anchor, concat(
'    -- Breakthrough and Essence, which were two page kinds that did nothing', chr(10),
'    -- until 0405. This is the one place a stat shortens the immortal ladder,', chr(10),
'    -- and it is meant to - it partly answers 0396''s drag for whoever built', chr(10),
'    -- for it.', chr(10),
'    worth := p_quantity::numeric * ess.unit_value', chr(10),
repeat(' ', 13), '* game_config_value(''essence_cultivation_rate'')', chr(10),
repeat(' ', 13), '* (1 + cultivation_intake_bonus(p_player_id))', chr(10),
repeat(' ', 13), '/ realm_climb_drag((SELECT r2.rank FROM realms r2', chr(10),
repeat(' ', 32), 'WHERE r2.realm_id = standing));'));

    -- ---- and a cultivation pill ------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'pill_cultivation_worth';
    -- Wrapping the whole expression takes an opening paren AND a closing one.
    -- Patching only the front would have left the function unbalanced, which
    -- is the sort of thing an assertion on the anchor cannot catch for you.
    anchor := '    SELECT GREATEST(';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'pill_cultivation_worth no longer opens with its GREATEST';
    END IF;
    body := replace(body, anchor, concat(
'    -- The same intake bonus a mouthful of essence pays. A pill and an', chr(10),
'    -- essence are the two things this build is for.', chr(10),
'    SELECT round((1 + cultivation_intake_bonus(p_player_id)) * GREATEST('));

    anchor := '    )::bigint;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'pill_cultivation_worth no longer closes the way it did';
    END IF;
    EXECUTE replace(body, anchor, '    ))::bigint;');
END;
$patch$;
