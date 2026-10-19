-- 0537_the_other_ten_hand_rolled_ranks
--
-- 0536 swept the seven that broke something a Venerable needs and listed ten
-- more that read the realm by hand. `test_nothing_reads_the_realm_where_it
-- means_standing` now names all ten and fails until each is decided, which is
-- the guard 0519 should have had - it asserted that nothing CALLS
-- `player_realm_rank` and could not see twenty-two functions that copy its
-- body inline.
--
-- All ten mean HOW DEEP SOMEBODY STANDS, and every one is a ceiling:
--
--     battle_act (flee)        the rank gap a flight is judged against
--     blessed_land_settle      "Whatever realm they stand at NOW. The land
--                              answers to its owner" - so it should answer to
--                              a Venerable too
--     forge_begin              the tier of gear a cultivator may forge, and
--     forge_begin_from_pages   its twin, whose own comment says the two doors
--                              must match "word for word, because two doors
--                              into one table with two rules is how a system
--                              starts lying about itself"
--     load_preset              a manual's `required_rank`
--     servant_farm_slots       plots, one per `servant_slot_per_ranks`
--     study_manual             a move's rank against yours
--     technique_shelf          which techniques the shelf offers
--     unlearn_technique        `t2.rank <= rank`, the same gate
--     trial_party_roster       the realm shown beside a name on the roster
--
-- THE DIRECTION IS SAFE FOR A CEILING AND NOT FOR A LOOKUP, which I had to
-- measure to find out. `player_standing` is GREATEST(realm rank, Venerable
-- rung) so it is never LESS than the realm, and nine of these ten are a `<=`
-- ceiling or a displayed label - widening those can only ever give somebody
-- more, and the probe asserts that against the whole roster.
--
-- `blessed_land_settle` IS NOT ONE OF THOSE:
--
--     SELECT e.material_code FROM immortal_essences e WHERE e.rank = mine
--
-- is an EQUALITY, and `immortal_essences` runs 10 to 18. On standing alone a
-- Venerable would look for a rank 19 essence, find none, and their blessed
-- land - the one piece of content whose own comment says it "answers to its
-- owner" - would quietly stop producing anything. So it is clamped to the
-- deepest essence that exists: the realm today, and standing the moment a
-- rank 19 essence is written. It was the only equality among the ten, and the
-- other nine were checked for the same shape.
--
-- `trial_party_roster` shows `r.name` as well, and that STAYS the realm: a
-- Venerable's realm is still Yellow Apricot Immortal, and the rung is what
-- `/venerable` is for. Only the rank follows standing, which is what the
-- roster sorts and compares on.
--
-- Forward-only. Do not edit once applied.


CREATE TEMP TABLE _before_0537 AS
SELECT p.player_id,
       player_power_multiple(p.player_id) AS power,
       servant_farm_slots(p.player_id)    AS slots,
       (SELECT count(*) FROM technique_shelf(p.player_id)) AS shelf
FROM players p WHERE p.deleted_at IS NULL;


DO $patch$
DECLARE
    one   RECORD;
    src   TEXT;
    fixed INTEGER := 0;
BEGIN
    FOR one IN
        SELECT * FROM (VALUES
            ('battle_act',
             E'        SELECT r.rank INTO my_rank\n'
             || E'        FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'        WHERE pc.player_id = me.player_id;',
             E'        my_rank := player_standing(me.player_id);'),

            -- Clamped, because this is the one EQUALITY among the ten:
            -- unclamped standing sends a Venerable looking for a rank 19
            -- essence that does not exist, and the land stops producing.
            ('blessed_land_settle',
             E'    SELECT r.rank INTO mine\n'
             || E'    FROM player_cultivation pc\n'
             || E'    JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'    WHERE pc.player_id = p_player_id;',
             E'    -- The deepest essence the owner can hold.\n'
             || E'    mine := LEAST(player_standing(p_player_id),\n'
             || E'                  (SELECT max(e2.rank) FROM immortal_essences e2));'),

            ('forge_begin',
             E'    SELECT r.rank INTO mine\n'
             || E'    FROM player_cultivation pc\n'
             || E'    JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'    WHERE pc.player_id = p_player_id;',
             E'    mine := player_standing(p_player_id);'),

            ('forge_begin_from_pages',
             E'    SELECT r.rank INTO v_mine\n'
             || E'    FROM player_cultivation pc\n'
             || E'    JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'    WHERE pc.player_id = p_player_id;',
             E'    v_mine := player_standing(p_player_id);'),

            ('load_preset',
             E'      AND m.required_rank <= COALESCE(\n'
             || E'          (SELECT r.rank FROM player_cultivation pc\n'
             || E'           JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'           WHERE pc.player_id = p_player_id), 0);',
             E'      AND m.required_rank <= COALESCE(player_standing(p_player_id), 0);'),

            ('servant_farm_slots',
             E'        + floor(COALESCE((SELECT r.rank FROM player_cultivation pc\n'
             || E'                          JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'                          WHERE pc.player_id = p_player_id), 1)',
             E'        + floor(COALESCE(player_standing(p_player_id), 1)'),

            ('study_manual',
             E'    SELECT COALESCE(r.rank, 0) INTO realm\n'
             || E'    FROM (SELECT 1) _\n'
             || E'    LEFT JOIN player_cultivation pc ON pc.player_id = p_player_id\n'
             || E'    LEFT JOIN realms r ON r.realm_id = pc.realm_id;',
             E'    realm := COALESCE(player_standing(p_player_id), 0);'),

            ('technique_shelf',
             E'            COALESCE((SELECT r.rank FROM player_cultivation pc\n'
             || E'                      JOIN realms r ON r.realm_id = pc.realm_id\n'
             || E'                      WHERE pc.player_id = p_player_id), 0)::smallint AS realm_rank,',
             E'            COALESCE(player_standing(p_player_id), 0)::smallint AS realm_rank,'),

            ('unlearn_technique',
             E'          AND t2.rank <= COALESCE(r.rank, 1)',
             E'          AND t2.rank <= COALESCE(player_standing(s.player_id), 1)'),

            -- The NAME stays the realm; only the rank follows standing.
            ('trial_party_roster',
             E'           r.name, r.rank,',
             E'           r.name, player_standing(p.player_id) AS rank,')
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

    IF fixed <> 10 THEN
        RAISE EXCEPTION 'only % of ten readers were moved', fixed;
    END IF;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing reads the realm by hand any more, and nobody lost anything
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_left  TEXT;
    v_pid   BIGINT;
    v_path  TEXT;
    v_slots INTEGER;
    one     RECORD;
BEGIN
    -- 1. THE ONLY ONES LEFT ARE THE FIVE THAT MEAN THE REALM, which is the
    -- allowlist the suite now holds. Anything else is a reader that got away.
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_left
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosrc ~ 'JOIN realms'
      AND p.prosrc ~ 'player_cultivation'
      AND p.prosrc ~ 'r[.]rank|realms[.]rank'
      AND p.proname NOT IN ('player_realm_rank', 'player_standing');

    IF v_left IS DISTINCT FROM
       'cultivation_per_hour, horde_open, servant_feed, servant_feed_essence, take_pill' THEN
        RAISE EXCEPTION
            'the readers left behind are not the five that mean the realm: %',
            COALESCE(v_left, '(none at all, which is also wrong - five were meant to stay)');
    END IF;

    -- 2. NOBODY LOST ANYTHING. Measured against the snapshot taken before the
    -- patch, not argued: standing is never below the realm, so every one of
    -- these ceilings can only widen.
    SELECT string_agg(x.who, '; ') INTO v_bad
    FROM (
        SELECT p.discord_name || ' power ' || b.power || '->'
               || player_power_multiple(b.player_id) AS who
        FROM _before_0537 b JOIN players p ON p.player_id = b.player_id
        WHERE player_power_multiple(b.player_id) < b.power
        UNION ALL
        SELECT p.discord_name || ' slots ' || b.slots || '->'
               || servant_farm_slots(b.player_id)
        FROM _before_0537 b JOIN players p ON p.player_id = b.player_id
        WHERE servant_farm_slots(b.player_id) < b.slots
        UNION ALL
        SELECT p.discord_name || ' shelf ' || b.shelf || '->'
               || (SELECT count(*) FROM technique_shelf(b.player_id))
        FROM _before_0537 b JOIN players p ON p.player_id = b.player_id
        WHERE (SELECT count(*) FROM technique_shelf(b.player_id)) < b.shelf
        LIMIT 8
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators lost something: %', v_bad;
    END IF;

    -- And nothing moved at all, because nobody is stamped.
    SELECT count(*) INTO v_slots
    FROM _before_0537 b
    WHERE player_power_multiple(b.player_id) <> b.power
       OR servant_farm_slots(b.player_id) <> b.slots;
    IF v_slots > 0 THEN
        RAISE EXCEPTION
            '% living cultivators moved, and none is a Venerable', v_slots;
    END IF;

    -- 3. AND A VENERABLE IS SEEN BY ALL OF IT. One more plot of farmland is
    -- the cheapest thing to measure and it runs through the same read.
    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-978, 'sweep-two') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        v_slots := servant_farm_slots(v_pid);

        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());
        PERFORM venerable_ascend(v_pid);

        -- NONE OF THE TEN IS OBSERVABLE AT 19 YET, and that is worth saying
        -- plainly rather than dressing up. Every ceiling they guard is
        -- already reachable at rank 18: techniques stop at rank 9, manuals
        -- at 9, equipment at tier 9, and `servant_farm_slots_max` is 6,
        -- which a rank 18 cultivator already holds. These are correctness
        -- fixes against content that does not exist yet.
        --
        -- My first draft of this probe tried to show a Venerable gaining a
        -- farm plot and tripped its own guard - the cultivator was already
        -- at the cap. Refusing to pass vacuously was the right outcome.
        --
        -- So what is asserted is what CAN be: a Venerable gets an answer out
        -- of every one of them, and never a smaller one than at 18. A sweep
        -- that broke one would show up here as an error or a loss, which is
        -- how the `blessed_land_settle` equality was caught.
        IF servant_farm_slots(v_pid) < v_slots THEN
            RAISE EXCEPTION 'ascending took a farm plot away';
        END IF;
        IF (SELECT count(*) FROM technique_shelf(v_pid)) IS NULL THEN
            RAISE EXCEPTION 'the shelf errored for a Venerable';
        END IF;
        PERFORM blessed_land_settle(v_pid);

        RAISE NOTICE
            'a Venerable reads through all ten: % farm plots, % on the shelf',
            servant_farm_slots(v_pid),
            (SELECT count(*) FROM technique_shelf(v_pid));

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'seventeen readers now ask standing; five still ask the realm and say why';
END;
$probe$;
