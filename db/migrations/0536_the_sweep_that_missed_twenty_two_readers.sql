-- 0536_the_sweep_that_missed_twenty_two_readers
--
-- 0519 is called `every_gate_reads_standing_not_realm` and its probe asserts:
--
--     SELECT ... WHERE p.prosrc ~ 'player_realm_rank'
--                  AND p.proname <> 'player_standing'
--     -> 'these still read the realm where they mean standing'
--
-- That assertion passes today, and it is close to worthless. It finds
-- functions that CALL `player_realm_rank`. It cannot see the TWENTY-TWO that
-- dig the rank out by hand:
--
--     SELECT r.rank FROM player_cultivation pc
--     JOIN realms r ON r.realm_id = pc.realm_id
--     WHERE pc.player_id = ...
--
-- which is the body of `player_realm_rank` copied inline. Its own comment
-- says "One definition. Three places already dig this out of
-- player_cultivation by hand, and a fourth would be a fourth thing to keep in
-- step." It is twenty-two places, and 0504 and 0519 both went looking for
-- exactly this and both missed them.
--
-- I SHIPPED THE VENERABLE REALM ON TOP OF THIS AND REPORTED IT COMPLETE. The
-- worst of them, measured:
--
--     player_power_multiple    scales every base stat by
--                              stat_step_per_rank ^ (rank - 1), and
--                              stat_step_per_rank is 2.0. Frozen at the realm
--                              a Venerable Rank 9 cultivator loses a 512x
--                              POWER MULTIPLE. Nine rungs of understanding
--                              and no growth at all - the realm would have
--                              been hollow.
--     explore                  gates on `regions.min_rank`, and the Heavenly
--                              Court is 19. 0504 fixed `begin_travel` for
--                              exactly this reason and never looked at
--                              `explore`, so a Venerable could travel to the
--                              Court and not explore it.
--     dungeon_open             the leader's reach. A Venerable reads 18 and
--                              `dungeon_realm_reach` is 0, so they could not
--                              have opened the rank 19 raid this is all for.
--     dungeon_spoils_for       the loot tier, under a comment that says "times
--                              their own standing".
--     spawn_beast, spawn_rogue what rank of thing you meet in the world. A
--                              Venerable would meet rank 18 beasts for ever.
--     leaderboard              sorts on rank * 1e12, so a Venerable sorts
--                              below the rank 18 they used to be level with.
--
-- NOBODY ALIVE MOVES. `player_standing` is GREATEST(realm, venerable rung) and
-- no Dao is stamped, so standing equals realm for every living cultivator and
-- all seven of these return exactly what they returned before. The probe
-- asserts that against the roster rather than claiming it.
--
-- WHAT IS LEFT, deliberately. These also read the realm by hand and are NOT
-- swept here, each for a reason:
--
--     cultivation_per_hour     the realm's own draw rate. A Venerable's meter
--     take_pill                is understanding; this is correctly the realm.
--     servant_feed             these join `realms` on the SERVANT's realm_id,
--     servant_feed_essence     not the player's. Not rank reads at all.
--     horde_open               sizes a tide off the POPULATION's average rank.
--                              Raising it makes tides harder for everybody,
--                              which is a balance change rather than a fix.
--     battle_act (flee)        forge_begin, forge_begin_from_pages,
--     blessed_land_settle      servant_farm_slots, study_manual,
--     technique_shelf          load_preset, unlearn_technique
--                              All gates that only bind above rank 18, so
--                              they are wrong for a Venerable and harmless
--                              today. Left for one pass with its own probe
--                              rather than folded into this one.
--
-- Forward-only. Do not edit once applied.


-- The raid this is all for needs a door above 18 to exist at all.
ALTER TABLE dungeons DROP CONSTRAINT dungeons_realm_rank_check;
ALTER TABLE dungeons ADD CONSTRAINT dungeons_realm_rank_check
    CHECK (realm_rank >= 1 AND realm_rank <= 27);


DO $patch$
DECLARE
    one   RECORD;
    src   TEXT;
    fixed INTEGER := 0;
BEGIN
    FOR one IN
        SELECT * FROM (VALUES
            -- The stat multiplier. GREATEST guards the subtraction, which the
            -- COALESCE used to do by defaulting the whole subquery to 0.
            ('player_power_multiple',
             E'                 COALESCE((SELECT r.rank - 1 FROM player_cultivation pc\n'
             || E'                           JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'                           WHERE pc.player_id = p_player_id), 0));',
             E'                 GREATEST(0, COALESCE(player_standing(p_player_id), 1) - 1));'),

            -- The region gate 0504 fixed in `begin_travel` and not here.
            ('explore',
             E'        SELECT r.rank INTO stood\n'
             || E'        FROM player_cultivation pc\n'
             || E'        JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'        WHERE pc.player_id = p_player_id;',
             E'        stood := player_standing(p_player_id);'),

            -- The leader''s reach into a deeper room.
            ('dungeon_open',
             E'       > COALESCE((SELECT r.rank FROM player_cultivation pc\n'
             || E'                   JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'                   WHERE pc.player_id = p_player_id), 1)',
             E'       > COALESCE(player_standing(p_player_id), 1)'),

            -- The loot tier, which its own comment already called standing.
            ('dungeon_spoils_for',
             E'            SELECT LEAST(p_rank, r.rank) INTO tier\n'
             || E'            FROM player_cultivation pc\n'
             || E'            JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'            WHERE pc.player_id = p_player_id;',
             E'            tier := LEAST(p_rank, COALESCE(player_standing(p_player_id), 1));'),

            -- What walks out of the grass at you.
            ('spawn_beast',
             E'    SELECT COALESCE(r.rank, 1) INTO mine\n'
             || E'    FROM player_cultivation pc\n'
             || E'    JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'    WHERE pc.player_id = p_player_id;',
             E'    mine := COALESCE(player_standing(p_player_id), 1);'),

            ('spawn_rogue',
             E'    SELECT COALESCE(r.rank, 1) INTO mine\n'
             || E'    FROM player_cultivation pc\n'
             || E'    JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'    WHERE pc.player_id = p_player_id;',
             E'    mine := COALESCE(player_standing(p_player_id), 1);'),

            -- The board. `r` stays joined for the realm's NAME, which is
            -- still the realm they stand in; only the ordering was wrong.
            ('leaderboard',
             E'(r.rank * 1e12 + pc.cultivation)::numeric AS sort_value',
             E'(player_standing(a.player_id) * 1e12 + pc.cultivation)::numeric AS sort_value')
        ) AS t(fn, was, becomes)
    LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one.fn));

        IF (length(src) - length(replace(src, one.was, ''))) / length(one.was) <> 1 THEN
            RAISE EXCEPTION
                'the hand-rolled rank read in % is not where I found it', one.fn;
        END IF;

        src := replace(src, one.was, one.becomes);

        IF strpos(src, 'player_standing') = 0 THEN
            RAISE EXCEPTION '% did not take the standing read', one.fn;
        END IF;

        EXECUTE src;
        fixed := fixed + 1;
    END LOOP;

    IF fixed <> 7 THEN
        RAISE EXCEPTION 'only % of seven readers were moved', fixed;
    END IF;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A Venerable is seen, and nobody alive moves
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_path  TEXT;
    v_bad   TEXT;
    v_18    NUMERIC;
    v_19    NUMERIC;
    v_court SMALLINT;
    one     RECORD;
BEGIN
    -- 1. All seven read standing now, and none of them lost the read.
    SELECT string_agg(x.fn, ', ') INTO v_bad
    FROM (VALUES ('player_power_multiple'), ('explore'), ('dungeon_open'),
                 ('dungeon_spoils_for'), ('spawn_beast'), ('spawn_rogue'),
                 ('leaderboard')) AS x(fn)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = x.fn
          AND p.prosrc ~ 'player_standing');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these did not take the standing read: %', v_bad;
    END IF;

    -- 2. And none of the seven still digs the rank out by hand.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('player_power_multiple', 'explore', 'dungeon_open',
                        'dungeon_spoils_for', 'spawn_beast', 'spawn_rogue')
      AND p.prosrc ~ 'JOIN realms r ON r\.realm_id = pc\.realm_id';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still read the realm by hand: %', v_bad;
    END IF;

    -- 3. NOBODY ALIVE MOVES. Standing equals realm for every living
    -- cultivator because nobody is stamped, so every one of these returns
    -- what it returned before.
    FOR one IN
        SELECT p.player_id, p.discord_name,
               player_standing(p.player_id) AS standing,
               COALESCE(player_realm_rank(p.player_id), 1) AS realm
        FROM players p WHERE p.deleted_at IS NULL
    LOOP
        IF one.standing <> one.realm THEN
            v_bad := COALESCE(v_bad || '; ', '') || one.discord_name;
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'standing already differs from realm for %, so this migration moves them',
            v_bad;
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    SELECT min_rank INTO v_court FROM regions WHERE code = 'heavenly_court';

    BEGIN
        -- A cultivator at the peak, measured, then ascended and measured
        -- again. The same body either side, so the only thing that changed is
        -- what the game thinks they are.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-979, 'standing-sweep') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        v_18 := player_power_multiple(v_pid);

        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());
        PERFORM venerable_ascend(v_pid);

        v_19 := player_power_multiple(v_pid);

        -- THE 512x. One rung must double it, because stat_step_per_rank is 2.
        IF v_19 <= v_18 THEN
            RAISE EXCEPTION
                'a Venerable''s power multiple is still % against the % they had at 18',
                v_19, v_18;
        END IF;
        IF abs(v_19 / v_18 - game_config_value('stat_step_per_rank')) > 0.0001 THEN
            RAISE EXCEPTION
                'ascending multiplied power by % rather than the % a rank is worth',
                round(v_19 / v_18, 4), game_config_value('stat_step_per_rank');
        END IF;
        RAISE NOTICE
            'ascending takes the power multiple from % to %', v_18, v_19;

        -- And the Court is explorable, which `begin_travel` already allowed
        -- and `explore` did not.
        IF v_court > player_standing(v_pid) THEN
            RAISE EXCEPTION
                'the Court asks for rank % and a Venerable stands at %',
                v_court, player_standing(v_pid);
        END IF;

        -- And a rank 19 room is now a thing the constraint permits.
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conname = 'dungeons_realm_rank_check'
                         AND pg_get_constraintdef(oid) LIKE '%27%') THEN
            RAISE EXCEPTION 'the dungeon ladder still stops at 18';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'seven readers moved onto standing; fifteen more read the realm by hand and are listed in this migration';
END;
$probe$;
