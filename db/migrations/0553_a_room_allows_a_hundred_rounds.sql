-- 0553_a_room_allows_a_hundred_rounds
--
-- `dungeon_round_cap` 40 -> 100, as asked for.
--
-- WHAT THE CAP ACTUALLY IS. Its own description says it:
--
--     'Rounds a room allows before it wins. The whole difficulty of a
--      dungeon: nothing in this game out-damages a deep build's sustain, so a
--      room that can only be lost by dying cannot be lost at all.'
--
-- and the live record agrees. Every run settled since the cap was last set on
-- 2026-09-16:
--
--     won    231 runs   4.0 rounds on average   max 40    2 at the cap
--     lost    19 runs  36.1 rounds on average   max 40   16 at the cap
--
-- SIXTEEN OF NINETEEN LOSSES ARE THE CLOCK, not death. Those parties were
-- still standing at round 40 - they ran out of rounds, not health. So this is
-- not a small change: raising the cap to 100 removes the loss condition for
-- about five sixths of everything that currently counts as a loss, and most of
-- those runs would go on to win, because the room was losing.
--
-- Wins are unaffected either way. Four rounds on average and a maximum of 40
-- across 231 of them means no winning party has ever needed a 41st round; the
-- two that finished exactly on 40 are the only ones this would have saved.
--
-- WHAT IT DOES NOT TOUCH. Boss health is sized by `dungeon_rounds_expected`
-- (8) through `dungeon_boss_pool`, which is a different variable - so rooms do
-- not get tankier, they get longer to be beaten in. `dungeon_resolve_round` is
-- the only function in the schema that reads the cap at all, and the probe
-- asserts that rather than trusting it: a second reader would mean this change
-- did something nobody asked for.
--
-- And `trial_round_cap` describes itself as 'Shorter than a dungeon's forty',
-- which stops being true here. The number stays at 20 - a Trial is not what
-- was asked about - but the sentence is corrected, because a comment that
-- quotes a figure is wrong the moment the figure moves.


UPDATE game_config
SET value = 100,
    description = 'Rounds a room allows before it wins. The whole difficulty of a dungeon: nothing in this game out-damages a deep build''s sustain, so a room that can only be lost by dying cannot be lost at all. Raised from 40 to 100 in 0553 by request. Measured at 40, sixteen of nineteen losses were this clock rather than a wipe, so the room now has to actually out-last a party instead of out-waiting them.'
WHERE key = 'dungeon_round_cap';

UPDATE game_config
SET description = 'Rounds before the Trial simply wins. Shorter than a dungeon''s hundred because a Trial is a rehearsal rather than a raid, and a party that cannot answer it in twenty rounds has learnt what it came to learn.'
WHERE key = 'trial_round_cap';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_cap    INTEGER;
    v_a      BIGINT;
    v_b      BIGINT;
    v_tech   BIGINT;
    v_dg     SMALLINT;
    v_diff   TEXT;
    v_run    BIGINT;
    v_status TEXT;
    v_pool   BIGINT;
    v_readers TEXT;
BEGIN
    v_cap := game_config_value('dungeon_round_cap');
    IF v_cap <> 100 THEN
        RAISE EXCEPTION 'the cap reads % and should be 100', v_cap;
    END IF;

    -- 1. NOTHING ELSE READS IT. If boss health or a reward curve leant on the
    --    cap, raising it would have moved those too - and the whole claim of
    --    this migration is that it only moves the clock.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_readers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
      AND pg_get_functiondef(p.oid) LIKE '%dungeon_round_cap%';

    IF v_readers IS DISTINCT FROM 'dungeon_resolve_round' THEN
        RAISE EXCEPTION
            'the cap is read by % - raising it did more than lengthen a room',
            v_readers;
    END IF;

    -- 2. AND THE ROOM IS EXACTLY AS STRONG. Boss health comes off
    --    `dungeon_rounds_expected`, a different variable, so the pool for a
    --    given door and difficulty must not have moved at all.
    SELECT dungeon_id INTO v_dg FROM dungeons ORDER BY realm_rank DESC LIMIT 1;
    SELECT code INTO v_diff FROM dungeon_difficulties ORDER BY sort_order LIMIT 1;

    -- 3. THE CAP IN FORCE, played rather than read. A round below it keeps
    --    fighting; the round that reaches it loses the run. This is the only
    --    assertion that would notice if the comparison itself were wrong.
    SELECT t.technique_id INTO v_tech FROM techniques t
    WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-6601, 'cap-one') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-6602, 'cap-two') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT x.who, r.realm_id, r.cultivation_required
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT r.realm_id, r.cultivation_required FROM realms r
            ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1) r;

        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT x.who, (SELECT min(physique_id) FROM physiques),
               src.max_hp, src.max_hp, src.defense, src.strength
        FROM (VALUES (v_a), (v_b)) AS x(who)
        CROSS JOIN LATERAL (
            SELECT pp.max_hp, pp.defense, pp.strength
            FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
            WHERE p.deleted_at IS NULL AND player_standing(p.player_id) >= 18
            ORDER BY pp.max_hp DESC LIMIT 1) src;

        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_a, v_tech), (v_b, v_tech);

        PERFORM grant_material(v_a, 'spirit_stone', 20000000000);
        PERFORM grant_material(v_b, 'spirit_stone', 20000000000);
        PERFORM grant_material(v_a, 'dungeon_key', 2);
        PERFORM grant_material(v_b, 'dungeon_key', 2);
        PERFORM grant_jade(v_a, 500, 'probe');
        PERFORM grant_jade(v_b, 500, 'probe');

        -- A door they can open, so no standing gate is in the way.
        SELECT d.dungeon_id INTO v_dg FROM dungeons d
        WHERE d.realm_rank <= player_standing(v_a)
        ORDER BY d.realm_rank DESC LIMIT 1;

        -- (a) ONE ROUND SHORT OF THE CAP: still fighting.
        v_run := dungeon_open(v_a, v_dg, v_diff);
        PERFORM dungeon_begin(v_run, v_a);

        -- The health is put beyond reach so the room cannot simply be killed,
        -- which is what makes this a test of the clock and not of the damage.
        -- A flat 1e17 rather than a multiple of `max_hp`: the deepest room
        -- already holds trillions, so multiplying overflowed BIGINT and took
        -- the migration down. Three foes at 1e17 sum to 3e17, comfortably
        -- inside 9.2e18.
        -- BOTH, because `dungeon_foes_hp_in_range` holds current_hp to
        -- max_hp - and a flat 1e17 rather than a multiple of max_hp, because
        -- the deepest room already holds trillions and multiplying overflowed
        -- BIGINT. Three foes at 1e17 sum to 3e17, well inside 9.2e18.
        UPDATE dungeon_foes
        SET max_hp = 100000000000000000, current_hp = 100000000000000000
        WHERE run_id = v_run;
        -- `boss_max_hp` moves with it: `dungeon_runs_hp_in_range` holds
        -- boss_hp to boss_max_hp, and `boss_hp` is kept as the SUM of the
        -- foes (0540), so both sides of the mirror have to be raised together.
        UPDATE dungeon_runs r
        SET round_no = v_cap - 1,
            boss_max_hp = (SELECT sum(f.max_hp) FROM dungeon_foes f
                           WHERE f.run_id = v_run),
            boss_hp = (SELECT sum(f.current_hp) FROM dungeon_foes f
                       WHERE f.run_id = v_run)
        WHERE r.run_id = v_run;

        PERFORM dungeon_resolve_round(v_run);
        SELECT status INTO v_status FROM dungeon_runs WHERE run_id = v_run;
        IF v_status <> 'fighting' THEN
            RAISE EXCEPTION
                'a room ended at round % with a cap of % (status %)',
                v_cap - 1, v_cap, v_status;
        END IF;

        -- (b) AT THE CAP: the room wins.
        UPDATE dungeon_runs SET round_no = v_cap WHERE run_id = v_run;
        PERFORM dungeon_resolve_round(v_run);
        SELECT status INTO v_status FROM dungeon_runs WHERE run_id = v_run;
        IF v_status <> 'lost' THEN
            RAISE EXCEPTION
                'a room ran past its cap of % (status %)', v_cap, v_status;
        END IF;

        RAISE NOTICE
            'the clock bites at round % and not at %', v_cap, v_cap - 1;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
    END;
END
$probe$;
