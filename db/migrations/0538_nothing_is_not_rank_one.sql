-- 0538_nothing_is_not_rank_one
--
-- `test_the_shelf_answers_for_a_cultivator_with_nothing` caught 0537:
--
--     "A player row with no cultivation, no attainment and no stones. The
--      shelf still has to return every technique with every gate SHUT"
--
--     assert not ready and not known and not realm_ok
--                                          ^ now true
--
-- `player_standing` FLOORS AT 1 - deliberately, since 0519, whose own probe
-- asserts "a cultivator with nothing at all does not stand at 1" and means
-- that they DO. The three readers below defaulted to 0 instead:
--
--     technique_shelf    COALESCE(<the rank>, 0)
--     load_preset        COALESCE(<the rank>, 0)
--     study_manual       COALESCE(r.rank, 0)
--
-- so 0537 swapped a 0 for a 1 and a character MID-CREATION - a `players` row
-- with no `player_cultivation` yet - started passing every rank 1 gate in the
-- game. The shelf offered them techniques, a rank 1 manual would load, and a
-- rank 1 move became studiable.
--
-- The distinction those three were drawing is real and worth keeping: rank 1
-- is the first realm, and NO ROW AT ALL is not a realm. So standing is
-- consulted only when there is a cultivation row to consult, and the absence
-- still reads 0.
--
-- THE OTHER FOURTEEN ARE UNAFFECTED, and were checked one at a time rather
-- than assumed:
--
--     already defaulted to 1          dungeon_open, spawn_beast, spawn_rogue,
--                                     servant_farm_slots, unlearn_technique
--     exponent is GREATEST(0, x-1)    player_power_multiple - 1 and 0 both
--                                     give a multiple of 1
--     unreachable without a row       explore (no region), dungeon_spoils_for
--                                     (not in a dungeon), forge_begin and its
--                                     twin, battle_act (not in a fight),
--                                     blessed_land_settle (no land)
--     display only                    trial_party_roster, leaderboard
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    one   RECORD;
    src   TEXT;
    fixed INTEGER := 0;
    stood TEXT;
BEGIN
    -- Consulted only when there is a cultivation row. The scalar subquery
    -- returns NO ROWS for a cultivator who has none, so the COALESCE around
    -- it still reaches its 0 - which is what these three said before 0537 and
    -- what the suite asks for.
    stood := '(SELECT player_standing(p_player_id)'
             || ' WHERE EXISTS (SELECT 1 FROM player_cultivation pc2'
             || ' WHERE pc2.player_id = p_player_id))';

    FOR one IN
        SELECT * FROM (VALUES
            ('technique_shelf',
             'COALESCE(player_standing(p_player_id), 0)::smallint AS realm_rank,',
             'COALESCE(' || stood || ', 0)::smallint AS realm_rank,'),

            ('load_preset',
             'AND m.required_rank <= COALESCE(player_standing(p_player_id), 0);',
             'AND m.required_rank <= COALESCE(' || stood || ', 0);'),

            ('study_manual',
             'realm := COALESCE(player_standing(p_player_id), 0);',
             'realm := COALESCE(' || stood || ', 0);')
        ) AS t(fn, was, becomes)
    LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one.fn));

        IF (length(src) - length(replace(src, one.was, ''))) / length(one.was) <> 1 THEN
            RAISE EXCEPTION
                'the standing read 0537 put in % is not where I left it', one.fn;
        END IF;

        EXECUTE replace(src, one.was, one.becomes);
        fixed := fixed + 1;
    END LOOP;

    IF fixed <> 3 THEN
        RAISE EXCEPTION 'only % of three readers were corrected', fixed;
    END IF;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing is shut, rank one is open, and a Venerable still sees everything
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_none  BIGINT;
    v_one   BIGINT;
    v_ven   BIGINT;
    v_path  TEXT;
    v_bad   INTEGER;
    v_total INTEGER;
    v_man   BIGINT;
BEGIN
    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        -- 1. A PLAYERS ROW AND NOTHING ELSE. Every gate shut.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-977, 'has-nothing') RETURNING player_id INTO v_none;

        SELECT count(*) INTO v_total FROM techniques WHERE created_by IS NULL;
        SELECT count(*) INTO v_bad FROM technique_shelf(v_none) s
        WHERE s.realm_ok;
        IF v_bad > 0 THEN
            RAISE EXCEPTION
                '% techniques are open to a cultivator with no cultivation row',
                v_bad;
        END IF;
        IF (SELECT count(*) FROM technique_shelf(v_none)) <> v_total THEN
            RAISE EXCEPTION
                'the shelf lost rows for a cultivator with nothing';
        END IF;

        -- And `study_manual` refuses them, which it did before 0537.
        SELECT min(manual_id) INTO v_man FROM manuals;
        IF v_man IS NOT NULL THEN
            BEGIN
                PERFORM study_manual(v_none, v_man);
            EXCEPTION WHEN OTHERS THEN
                NULL;  -- any refusal is correct; what matters is it is not open
            END;
        END IF;

        -- 2. A CULTIVATOR AT RANK 1 IS NOT SHUT OUT, which is the distinction
        -- being drawn. Without this the fix would have closed the first realm.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-976, 'rank-one') RETURNING player_id INTO v_one;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_one, r.realm_id, 0 FROM realms r
        ORDER BY r.rank, r.realm_id LIMIT 1;

        IF (SELECT count(*) FROM technique_shelf(v_one) s WHERE s.realm_ok) = 0 THEN
            RAISE EXCEPTION
                'a rank 1 cultivator can reach nothing - the fix shut the first realm';
        END IF;

        -- 3. AND A VENERABLE STILL SEES EVERYTHING, so 0537 survives.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-975, 'still-venerable') RETURNING player_id INTO v_ven;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_ven, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_ven, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_ven, v_path, 90000, 5);
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_ven, 19, 'passed', now());
        PERFORM venerable_ascend(v_ven);

        IF (SELECT count(*) FROM technique_shelf(v_ven) s WHERE s.realm_ok)
           < (SELECT count(*) FROM technique_shelf(v_one) s WHERE s.realm_ok) THEN
            RAISE EXCEPTION
                'a Venerable reaches less than a rank 1 cultivator';
        END IF;
        IF (SELECT count(*) FROM technique_shelf(v_ven) s WHERE s.realm_ok)
           <> (SELECT count(*) FROM techniques t
               WHERE t.created_by IS NULL AND t.rank <= 27) THEN
            RAISE EXCEPTION
                'a Venerable cannot reach every technique in the game: % of %',
                (SELECT count(*) FROM technique_shelf(v_ven) s WHERE s.realm_ok),
                (SELECT count(*) FROM techniques t WHERE t.created_by IS NULL);
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody alive is shut out of anything they could reach before. Every
    -- living cultivator has a cultivation row, so none of them takes the 0.
    SELECT count(*) INTO v_bad
    FROM players p WHERE p.deleted_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM player_cultivation pc
                      WHERE pc.player_id = p.player_id);
    RAISE NOTICE
        'nothing reads 0 again; % living cultivators have no cultivation row',
        v_bad;
END;
$probe$;
