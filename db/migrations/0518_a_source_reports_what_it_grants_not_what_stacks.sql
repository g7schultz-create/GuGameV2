-- 0518_a_source_reports_what_it_grants_not_what_stacks
--
-- 0517 clamped `physique_stat` and `root_stat` to the SOURCE share, to stop a
-- Divine body reporting 0.300 dodge while a blow used 0.240. That reasoning
-- came from 0492, where a screen and a fight disagreed and it took four
-- migrations to notice. Applying it here was wrong, and two standing tests
-- between them say exactly why:
--
--     test_a_body_and_a_sword_share_one_ceiling
--         wants physique_stat to be what the FIGHT uses
--     test_only_the_right_body_carries_refining_tolerance
--         wants physique_stat to be what the BODY GRANTS - 0.5 from a
--         Supreme Dao physique, which 0517 clipped to 0.45
--
-- They cannot both be satisfied, and the second one is right. `physique_stat`
-- means "what this body gives", bounded by the effect's own ceiling. The
-- source share is a STACKING rule - it is about how eight sources combine -
-- and it belongs in `player_stat`, which is the only place that combines
-- them.
--
-- The screen-versus-fight worry does not apply either: nothing in the bot
-- reads `physique_stat` or `root_stat`. The one per-source read anywhere is
-- `gu_stat(player, 'cultivation_rate')` on the cultivation screen, and
-- `player_gu_stats` is a view that does clamp, because worms are the source a
-- player actually assembles and shops for.
--
-- So both functions go back to the effect cap, and the stacking rule stays
-- where stacking happens. `player_stat` is unchanged - it has clamped each
-- term since 0516 - so no fight moves.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src  TEXT;
    one  TEXT;
    hits INTEGER;
BEGIN
    FOREACH one IN ARRAY ARRAY['physique_stat', 'root_stat']::TEXT[] LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one));

        hits := (length(src)
                 - length(replace(src, 'LEAST(stat_source_cap(p_effect, p_player_id)', '')))
                / length('LEAST(stat_source_cap(p_effect, p_player_id)');
        IF hits <> 1 THEN
            RAISE EXCEPTION
                '% does not carry 0517''s clamp exactly once', one;
        END IF;

        EXECUTE replace(src,
            'LEAST(stat_source_cap(p_effect, p_player_id)',
            'LEAST(e.cap');
    END LOOP;
END;
$patch$;


DO $probe$
DECLARE
    v_n   INTEGER;
    v_bad TEXT;
BEGIN
    -- A body reports what it grants again.
    IF pg_get_functiondef('physique_stat(bigint,text)'::regprocedure)
       LIKE '%stat_source_cap%' THEN
        RAISE EXCEPTION 'physique_stat still reports the stacking share';
    END IF;
    IF pg_get_functiondef('root_stat(bigint,text)'::regprocedure)
       LIKE '%stat_source_cap%' THEN
        RAISE EXCEPTION 'root_stat still reports the stacking share';
    END IF;

    -- And neither reports more than the effect's own ceiling, which is what
    -- 0053 put the clamp there for in the first place.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND (physique_stat(p.player_id, e.code) > e.cap + 0.0001
        OR root_stat(p.player_id, e.code) > e.cap + 0.0001);
    IF v_n > 0 THEN
        RAISE EXCEPTION '% source readings exceed the effect cap', v_n;
    END IF;

    -- THE RULE 0516 EXISTS FOR IS UNTOUCHED: no source gets more than its
    -- share into a fight, which is `player_stat`'s job and always was.
    SELECT string_agg(x.who || ' ' || x.code, ', ') INTO v_bad
    FROM (
        SELECT p.discord_name AS who, e.code
        FROM players p CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND player_stat(p.player_id, e.code)
              > LEAST(gu_effect_cap(e.code, p.player_id),
                      8 * stat_source_cap(e.code, p.player_id)) + 0.0001
        LIMIT 5
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'player_stat lost its bound: %', v_bad;
    END IF;

    -- A body that grants more than its share still only contributes its
    -- share, which is the whole mechanic - checked by finding one.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND physique_stat(p.player_id, e.code)
          > stat_source_cap(e.code, p.player_id) + 0.0001;
    RAISE NOTICE
        '% body readings now exceed their stacking share and are clamped where it matters',
        v_n;
END;
$probe$;
