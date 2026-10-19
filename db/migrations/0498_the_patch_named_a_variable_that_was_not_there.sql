-- 0498_the_patch_named_a_variable_that_was_not_there
--
-- 0497 patched `dungeon_begin` to size its boss from a rehearsal and wrote
-- the call as `dungeon_boss_pool(v_run_id)`. There is no `v_run_id`. The
-- function's run id is its first PARAMETER, `p_run_id`, and its DECLARE block
-- holds run, party, unarmed, one and pool - nothing else.
--
--     column "v_run_id" does not exist
--     CONTEXT: PL/pgSQL function dungeon_begin(bigint,bigint) line 62
--
-- plpgsql resolves identifiers at run time, not at CREATE time, so the broken
-- body installed cleanly and the migration's own probe passed - it asserted
-- that the SOURCE contained the new call, which it did. Every dungeon then
-- failed to start. Ten tests caught it immediately, which is the only reason
-- this is a five minute fault rather than a live one.
--
-- The lesson is specific: a probe that greps a patched body proves the text
-- changed, not that the function still runs. 0497 should have called
-- `dungeon_begin` and it did not, because setting up a startable run looked
-- like more work than the patch. It was less work than this.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src  TEXT;
    hits INTEGER;
BEGIN
    src := pg_get_functiondef('dungeon_begin(bigint,bigint)'::regprocedure);

    hits := (length(src) - length(replace(src, 'dungeon_boss_pool(v_run_id)', '')))
            / length('dungeon_boss_pool(v_run_id)');
    IF hits <> 1 THEN
        RAISE EXCEPTION
            'expected one broken call to fix, found %', hits;
    END IF;

    EXECUTE replace(src, 'dungeon_boss_pool(v_run_id)', 'dungeon_boss_pool(p_run_id)');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Proved by starting a run, not by reading the source
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_run   BIGINT;
    v_dg    SMALLINT;
    v_pid   BIGINT;
    v_begun RECORD;
    v_swing BIGINT;
BEGIN
    SELECT dg.dungeon_id INTO v_dg FROM dungeons dg
    JOIN creature_species s ON s.species_id = dg.species_id
    ORDER BY s.base_hp DESC LIMIT 1;

    SELECT p.player_id INTO v_pid FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
      AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
    ORDER BY player_blow_multiple(p.player_id) DESC LIMIT 1;

    BEGIN
        -- The entry cost is real: 42 jade and 3.6e9 spirit stones for the
        -- deepest room. Topped up here rather than dodged, because charging
        -- it is part of the path being proved - and all of this is rolled
        -- back. 0497's probe never found this out, having never made the call.
        PERFORM grant_jade(v_pid, 1000, 'probe');
        INSERT INTO player_materials (player_id, material_code, quantity)
        SELECT v_pid, m.code, 9000000000 FROM materials m
        ON CONFLICT (player_id, material_code)
        DO UPDATE SET quantity = player_materials.quantity + 9000000000;

        INSERT INTO dungeon_runs (dungeon_id, difficulty, leader_id, status)
        VALUES (v_dg, 'insane', v_pid, 'forming') RETURNING run_id INTO v_run;
        INSERT INTO dungeon_raiders (run_id, player_id) VALUES (v_run, v_pid);

        -- THE CALL 0497 SHOULD HAVE MADE. Running the function is the only
        -- thing that proves a plpgsql body resolves.
        SELECT * INTO v_begun FROM dungeon_begin(v_run, v_pid);

        IF v_begun.boss_hp IS NULL OR v_begun.boss_hp <= 1 THEN
            RAISE EXCEPTION 'a run began with a boss holding %', v_begun.boss_hp;
        END IF;
        IF v_begun.raiders < 1 THEN
            RAISE EXCEPTION 'a run began with % raiders', v_begun.raiders;
        END IF;
        IF (SELECT status FROM dungeon_runs WHERE run_id = v_run) <> 'fighting' THEN
            RAISE EXCEPTION 'the run did not start fighting';
        END IF;

        -- And the pool it opened with is the rehearsed one, not the formula.
        IF v_begun.boss_hp <= dungeon_boss_hp(v_dg, 'insane', 1) * 5 THEN
            RAISE EXCEPTION
                'the run opened at % which is formula-sized, not rehearsed',
                v_begun.boss_hp;
        END IF;

        SELECT GREATEST(1, (player_swing(
                   v_pid, dungeon_default_move(v_pid),
                   (SELECT species_id FROM dungeons WHERE dungeon_id = v_dg),
                   9223372036854775807::bigint, 0::bigint)).dealt)
        INTO v_swing;
        IF v_begun.boss_hp <= v_swing THEN
            RAISE EXCEPTION
                'the deepest room opened at % and one swing is %',
                v_begun.boss_hp, v_swing;
        END IF;

        RAISE NOTICE
            'a run of 1 opened at % against a single swing of %',
            v_begun.boss_hp, v_swing;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing from either the run or its rehearsal survived.
    IF EXISTS (SELECT 1 FROM battle_effects WHERE scope = 'rehearsal') THEN
        RAISE EXCEPTION 'rehearsal effects survived a rollback';
    END IF;
END;
$probe$;
