-- 0542_the_caller_resolves_the_round
--
-- 0541 made `dungeon_choose` resolve the round itself once everybody had
-- chosen. That is not the contract, and the bot proves it:
--
--     left = await db.fetch_value("SELECT dungeon_choose(...)")
--     # The round resolves the moment the last raider speaks. Nothing ticks
--     # in this game, so this is the tick.
--     if left == 0:
--         done = await db.fetch_one("SELECT * FROM dungeon_resolve_round(...)")
--
-- `dungeon_choose` returns HOW MANY ARE STILL CHOOSING and the caller resolves
-- when that reaches zero. With 0541's auto-resolve the round ran twice: once
-- inside the choice, and then the bot's own call found the fight already over
-- and raised "that fight is not running". Every final choice in a raid would
-- have failed, and two standing tests said so within the hour.
--
-- I added that on my own initiative while changing the signature for targets.
-- The signature needed changing; the behaviour did not.
--
-- AND `dungeon_runs.boss_hp` IS NOW A MIRROR, which is worth stating plainly
-- because two tests were wounding it directly to put a boss at death's door:
--
--     UPDATE dungeon_runs SET boss_hp = 1 WHERE run_id = ...
--
-- Since 0540 the room's health lives in `dungeon_foes`, one row per thing
-- standing, and `boss_hp` is recomputed from the sum at the end of every
-- round so the bot's bar, `dungeon_run_state` and the `pool <= 0` that wins
-- a room keep working. A write to the mirror is simply overwritten. Anything
-- wanting to wound a room wounds `dungeon_foes`; the two tests now do.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef(
        'dungeon_choose(bigint,bigint,bigint,smallint,bigint)'::regprocedure);

    one := '    IF still = 0 THEN' || chr(10) ||
           '        PERFORM dungeon_resolve_round(p_run_id);' || chr(10) ||
           '    END IF;' || chr(10) ||
           chr(10);

    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION
            'the auto-resolve 0541 added to dungeon_choose is not where I left it';
    END IF;

    src := replace(src, one,
        '    -- The CALLER resolves. `dungeon_choose` reports how many are still' || chr(10) ||
        '    -- choosing and nothing more: the cog reads that, and calls' || chr(10) ||
        '    -- `dungeon_resolve_round` itself when it reaches zero. 0541 did it' || chr(10) ||
        '    -- here as well, so the round ran twice and the cog''s own call then' || chr(10) ||
        '    -- raised "that fight is not running" on every final choice.' || chr(10) ||
        chr(10));

    EXECUTE src;

    IF strpos(pg_get_functiondef(
            'dungeon_choose(bigint,bigint,bigint,smallint,bigint)'::regprocedure),
            'PERFORM dungeon_resolve_round') > 0 THEN
        RAISE EXCEPTION 'dungeon_choose still resolves the round';
    END IF;
END;
$patch$;


COMMENT ON COLUMN dungeon_runs.boss_hp IS
    'A MIRROR of what is still standing, recomputed from dungeon_foes at the end of every round. Kept because the bot draws a bar from it, dungeon_run_state exposes it and `pool <= 0` wins the room - but the room''s health lives in dungeon_foes since 0540, and a write here is overwritten. To wound a room, wound the foes.';


-- ---------------------------------------------------------------------------
-- Choose, then resolve, and have it work once
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_run  BIGINT;
    v_move BIGINT;
    v_dg   SMALLINT;
    v_left INTEGER;
    v_done RECORD;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-968, 'resolve-probe') RETURNING player_id INTO v_who;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_who, r.realm_id, r.cultivation_required
        FROM realms r WHERE r.rank = 4 ORDER BY r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense)
        VALUES (v_who, (SELECT min(physique_id) FROM physiques),
                50000, 50000, 300);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_who, t.technique_id FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack' AND t.rank = 1
        ORDER BY t.base_power DESC LIMIT 1;
        PERFORM grant_material(v_who, 'spirit_stone', 90000000);
        PERFORM grant_material(v_who, 'dungeon_key', 3);
        PERFORM grant_jade(v_who, 100, 'probe');

        SELECT dungeon_id INTO v_dg FROM dungeons WHERE realm_rank = 4;
        v_run := dungeon_open(v_who, v_dg, 'normal');
        PERFORM dungeon_begin(v_run, v_who);

        SELECT dungeon_default_move(v_who) INTO v_move;

        -- 1. CHOOSING DOES NOT RESOLVE. The lone raider has chosen, nobody is
        -- left to choose, and the round must still be waiting for the caller.
        v_left := dungeon_choose(v_run, v_who, v_move);
        IF v_left <> 0 THEN
            RAISE EXCEPTION
                'the only raider chose and % are still choosing', v_left;
        END IF;
        IF (SELECT r.round_no FROM dungeon_runs r WHERE r.run_id = v_run) <> 1 THEN
            RAISE EXCEPTION
                'the round advanced inside the choice - it resolved itself';
        END IF;

        -- 2. AND THE CALLER'S RESOLVE WORKS, once, the way the cog does it.
        SELECT * INTO v_done FROM dungeon_resolve_round(v_run);
        IF v_done IS NULL THEN
            RAISE EXCEPTION 'the caller''s resolve returned nothing';
        END IF;
        IF v_done.round_no <> 2 AND v_done.status = 'fighting' THEN
            RAISE EXCEPTION
                'a resolved round left the fight on round %', v_done.round_no;
        END IF;

        -- 3. WOUNDING THE FOES IS WHAT KILLS A ROOM, not the mirror.
        IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run)
           = 'fighting' THEN
            UPDATE dungeon_runs SET boss_hp = 1 WHERE run_id = v_run;
            PERFORM dungeon_choose(v_run, v_who, v_move);
            PERFORM dungeon_resolve_round(v_run);

            IF (SELECT r.boss_hp FROM dungeon_runs r WHERE r.run_id = v_run) = 1
               AND (SELECT sum(f.current_hp) FROM dungeon_foes f
                    WHERE f.run_id = v_run) <> 1 THEN
                RAISE EXCEPTION
                    'a write to the mirror stuck, so there are two truths';
            END IF;

            -- And wounding the truth does end it.
            UPDATE dungeon_foes SET current_hp = 1
            WHERE run_id = v_run AND current_hp > 0;
            PERFORM dungeon_choose(v_run, v_who, v_move);
            PERFORM dungeon_resolve_round(v_run);

            IF (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run)
               <> 'won' THEN
                RAISE EXCEPTION
                    'the room survived every foe being on 1 health: %',
                    (SELECT r.status FROM dungeon_runs r WHERE r.run_id = v_run);
            END IF;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'the caller resolves, and the foes are the room''s health';
END;
$probe$;
