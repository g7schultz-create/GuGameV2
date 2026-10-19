-- 0390_a_dungeon_you_cannot_lose_is_not_a_dungeon
--
-- Every deep clear in this game's history is a solo run on Insane. Not one of
-- them is a party:
--
--     pashu0        rank 16  Insane  solo   61 rounds   (three realms above him)
--     m_i_y_u_k_i   rank 15  Insane  solo   50 rounds
--     pashu0        rank 15  Insane  solo   29 rounds
--     pashu0        rank 11  Insane  solo  172 rounds
--     shinonn       rank 10  Insane  solo  104 rounds
--
-- Sixteen deep runs, sixteen raiders, one each. That is not players preferring
-- to play alone. That is three separate rules pointing the same way.
--
-- WHY NOBODY BRINGS ANYBODY. `dungeon_boss_hp` multiplies the boss by
-- `1 + 0.6 x (raiders - 1)`, so the boss is at its SMALLEST when you are
-- alone. The stone and jade pot is split by damage dealt, so a solo raider
-- takes all of it. And `dungeon_spoils_for` rolls per raider, so a companion
-- adds nothing to your own roll. Alone is the cheapest boss, the whole pot,
-- and the same loot.
--
-- WHY IT IS ALWAYS INSANE. Reward scale over health scale: Normal 1.00, Hard
-- 1.22, Hell 1.41, Insane 1.69. The hardest setting is the best value per
-- point of boss health at every depth, so there is never a reason to pick
-- another one.
--
-- WHY THREE REALMS ABOVE HIM. `dungeon_open` checks that the door exists and
-- that you are not already in a room. It has never checked your realm.
--
-- AND WHY NONE OF THAT COSTS ANYTHING. A run ends when the boss dies or when
-- every raider is down. There is no third ending. A cultivator whose Life on
-- Hit outruns what the room deals - which at 40 per cent of maximum health per
-- landing strike is every deep build in the game - cannot be put down, so the
-- run cannot be lost, so the only thing depth costs is rounds. 172 of them,
-- once.
--
-- TWO RULES, AND THE SECOND IS THE REAL ONE.
--
-- A REALM GATE ON THE DOOR. The LEADER must stand at or above the rank of the
-- room they open. Not the joiners - a deep cultivator bringing shallower
-- friends is the thing this game should want, and gating the join would make
-- the only group content in it require everybody to already be past it.
--
-- A ROUND CAP, WHICH IS WHERE THE DIFFICULTY ACTUALLY COMES FROM. A room that
-- is not broken in `dungeon_round_cap` rounds wins. This is the same axis 0363
-- named for the immortal dungeons and 0387 settled on for tribulations - hard
-- is a race, not a loss - and it is the only axis that works, because nothing
-- in this game can out-damage a lifesteal build's sustain and a "survive it"
-- difficulty is therefore not a difficulty at all.
--
-- FORTY, MEASURED AGAINST WHAT PEOPLE ACTUALLY DO. Rounds to break their OWN
-- realm's room, solo, today:
--
--                       Normal   Hell   Insane     five-handed Normal
--     pashu0    (13)         6     19       37                      4
--     m_i_y_u_k_i(12)        4     13       25                      3
--     sylvrime  (12)         9     28       54                      6
--     shinonn   (10)        28     93      176                     19
--     clearwest (10)        34    113      215                     23
--
-- So at forty: your own realm on Normal is a solo run for anybody, Hell wants
-- real gear, and Insane is left to the one cultivator who has genuinely earned
-- it - with three rounds of margin and a fight that varies by more than that.
-- The rank 10 crowd, who crossed recently and are the thinnest in the game,
-- get their room five-handed in nineteen to twenty-three rounds. Which is the
-- first time in this game's life that bringing somebody has been the answer.
--
-- The difficulty scales are deliberately left alone. Insane being the best
-- value per point of health stops mattering the moment you can only pick the
-- setting you can actually burn down in time.
--
-- WHAT THIS COSTS THE PEOPLE WHO DID IT. Nothing already banked. Sixteen deep
-- clears stay cleared, and a run that times out refunds its key exactly as any
-- other loss does - `dungeon_key_refund_on_loss` has been 1 since it existed,
-- and running out of time should cost the stake rather than the day.
--
-- No run is in flight as this applies.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_round_cap', 40,
     'Rounds a room allows before it wins. The whole difficulty of a dungeon: nothing in this game out-damages a deep build''s sustain, so a room that can only be lost by dying cannot be lost at all. Measured so that your own realm on Normal is a solo run, Hell wants gear, and Insane wants to have earned it.'),
    ('dungeon_realm_reach', 0,
     'How many ranks above their own realm a cultivator may OPEN a room. At 0 the door is your realm or below. Joining is not gated - a deep cultivator bringing shallower friends is the thing this game should want.');


-- ---------------------------------------------------------------------------
-- The door asks what realm you are
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_open';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_open is missing';
    END IF;

    anchor := concat(
'    -- One run at a time. Being in two rooms at once is not a state this can', chr(10),
'    -- resolve rounds for.');

    swap := concat(
'    -- Your realm or below. The leader only: `dungeon_join` stays open so a', chr(10),
'    -- deep cultivator can bring shallower friends, which is the whole point', chr(10),
'    -- of the only group content in the game.', chr(10),
'    IF (SELECT dg.realm_rank FROM dungeons dg', chr(10),
'        WHERE dg.dungeon_id = p_dungeon_id)', chr(10),
'       > COALESCE((SELECT r.rank FROM player_cultivation pc', chr(10),
'                   JOIN realms r ON r.realm_id = pc.realm_id', chr(10),
'                   WHERE pc.player_id = p_player_id), 0)', chr(10),
'         + game_config_value(''dungeon_realm_reach'') THEN', chr(10),
'        RAISE EXCEPTION', chr(10),
'            ''% is written for a realm you have not reached''', chr(10),
'            '' - somebody who has can open it and bring you in'',', chr(10),
'            (SELECT dg.name FROM dungeons dg', chr(10),
'             WHERE dg.dungeon_id = p_dungeon_id)', chr(10),
'            USING ERRCODE = ''check_violation'';', chr(10),
'    END IF;', chr(10),
'', chr(10),
anchor);

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_open no longer guards against two rooms at once';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the room runs out of patience
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_resolve_round';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_resolve_round is missing';
    END IF;

    anchor := concat(
'    ending := CASE', chr(10),
'        WHEN pool <= 0 THEN ''won''', chr(10),
'        WHEN NOT EXISTS (SELECT 1 FROM dungeon_raiders x', chr(10),
'                         WHERE x.run_id = p_run_id AND x.current_hp > 0)', chr(10),
'             THEN ''lost''', chr(10),
'        ELSE ''fighting''', chr(10),
'    END;');

    swap := concat(
'    -- Three endings now. The third is the one that makes the other two mean', chr(10),
'    -- anything: nothing in this game out-damages a deep build''s Life on Hit,', chr(10),
'    -- so a room that can only be lost by being killed in it cannot be lost,', chr(10),
'    -- and depth stops costing anything but rounds. It is read AFTER the win,', chr(10),
'    -- so a blow that breaks the room on the last allowed round breaks it.', chr(10),
'    ending := CASE', chr(10),
'        WHEN pool <= 0 THEN ''won''', chr(10),
'        WHEN NOT EXISTS (SELECT 1 FROM dungeon_raiders x', chr(10),
'                         WHERE x.run_id = p_run_id AND x.current_hp > 0)', chr(10),
'             THEN ''lost''', chr(10),
'        WHEN run.round_no >= game_config_value(''dungeon_round_cap'')', chr(10),
'             THEN ''lost''', chr(10),
'        ELSE ''fighting''', chr(10),
'    END;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'dungeon_resolve_round no longer decides its ending where it did';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Your own realm is a solo run and Insane is not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r     RECORD;
    v_cap NUMERIC := game_config_value('dungeon_round_cap');
    v_bad TEXT;
    v_who BIGINT;
    v_n   INTEGER := 0;
BEGIN
    IF v_cap < 1 THEN
        RAISE EXCEPTION 'a cap below one round ends every run before it starts';
    END IF;

    -- Nothing in flight is stranded past a cap it never agreed to.
    SELECT string_agg(r2.run_id::text, ', ') INTO v_bad
    FROM dungeon_runs r2
    WHERE r2.status = 'fighting' AND r2.round_no >= v_cap;
    IF v_bad IS NOT NULL THEN
        RAISE NOTICE
            'these runs are already past the cap and will end next round: %',
            v_bad;
    END IF;

    -- THE POINT, measured on the people who are actually here. Every
    -- cultivator's OWN room, solo, at every setting - and the same room
    -- five-handed, which is the route that has to exist for the thinnest of
    -- them.
    FOR r IN
        WITH own AS (
            SELECT p.player_id, p.discord_name, rr.rank, d.dungeon_id,
                   d.species_id, cs.base_defense
            FROM players p
            JOIN player_cultivation pc ON pc.player_id = p.player_id
            JOIN realms rr ON rr.realm_id = pc.realm_id
            JOIN dungeons d ON d.realm_rank = rr.rank
            JOIN creature_species cs ON cs.species_id = d.species_id
            WHERE p.deleted_at IS NULL
        )
        SELECT o.discord_name, o.rank,
               max(cd.final_damage) AS per_round,
               o.dungeon_id
        FROM own o
        JOIN player_usable_techniques u ON u.player_id = o.player_id
        CROSS JOIN LATERAL compute_technique_damage(
            o.player_id, u.technique_id, o.species_id,
            player_external_multiplier(o.player_id, u.technique_id),
            o.base_defense) cd
        GROUP BY o.discord_name, o.rank, o.dungeon_id
        HAVING max(cd.final_damage) > 0
        ORDER BY o.rank DESC
    LOOP
        v_n := v_n + 1;

        -- A room nobody can clear at its easiest setting, five-handed, is a
        -- wall rather than a difficulty. This is the floor the cap must not
        -- cross.
        IF ceil(dungeon_boss_hp(r.dungeon_id, 'normal', 5)::numeric
                / (r.per_round * 5)) > v_cap THEN
            RAISE EXCEPTION
                '% cannot clear their own room five-handed on Normal inside % rounds',
                r.discord_name, v_cap;
        END IF;

        RAISE NOTICE
            '% (realm %) : solo normal %, hell %, insane % - five-handed normal %',
            rpad(r.discord_name, 14), r.rank,
            ceil(dungeon_boss_hp(r.dungeon_id, 'normal', 1)::numeric / r.per_round),
            ceil(dungeon_boss_hp(r.dungeon_id, 'hell',   1)::numeric / r.per_round),
            ceil(dungeon_boss_hp(r.dungeon_id, 'insane', 1)::numeric / r.per_round),
            ceil(dungeon_boss_hp(r.dungeon_id, 'normal', 5)::numeric
                 / (r.per_round * 5));
    END LOOP;

    IF v_n = 0 THEN
        RAISE NOTICE 'nobody to measure; the tests carry this';
    END IF;

    -- And the door refuses a room above the realm of whoever opens it.
    SELECT p.player_id INTO v_who
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms rr ON rr.realm_id = pc.realm_id
    WHERE p.deleted_at IS NULL AND rr.rank < (SELECT max(realm_rank) FROM dungeons)
    ORDER BY rr.rank DESC LIMIT 1;

    IF v_who IS NOT NULL THEN
        BEGIN
            PERFORM dungeon_open(v_who,
                (SELECT dg.dungeon_id FROM dungeons dg
                 ORDER BY dg.realm_rank DESC LIMIT 1), 'normal');
            RAISE EXCEPTION
                'the deepest room in the game opened for somebody below it';
        EXCEPTION
            WHEN check_violation THEN
                IF SQLERRM LIKE '%already in a dungeon%' THEN
                    RAISE NOTICE 'could not test the door - that player is in a room';
                END IF;
        END;

        -- Whatever that attempt did, it does not survive this migration.
        DELETE FROM dungeon_raiders x
        USING dungeon_runs r2
        WHERE r2.run_id = x.run_id AND r2.status = 'forming'
          AND r2.opened_at >= now() - interval '1 minute';
        DELETE FROM dungeon_runs r2
        WHERE r2.status = 'forming'
          AND r2.opened_at >= now() - interval '1 minute';
    END IF;
END;
$probe$;
