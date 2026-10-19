-- 0489_a_cast_is_finally_counted
--
-- Phase 3 of the Venerable spec needs deeds. "Acting in accordance accrues
-- understanding" only works if the game records the acts, so before building
-- anything on top I went looking for the counters. What is actually there:
--
--     player_path_attainment.insight      alive, 192 rows
--     player_path_attainment.seconds_trained  alive, 154 rows
--     player_skills.exp                   alive, 103 rows
--     player_physique.physique_xp         alive, 24 rows
--     player_bestiary.times_defeated      alive, 841 of 859 rows
--     player_gu_carried.seconds_carried   alive as of 0487
--
--     player_path_attainment.dao_marks    DEAD - 0 in all 192 rows
--     player_techniques.times_used        DEAD - 0 everywhere, no writer
--     a lifetime damage-taken total       DOES NOT EXIST
--
-- `times_used` is the one that matters, because it is the only counter that
-- distinguishes the deed the path aspect names - casting a technique of that
-- path in a real fight - from buying insight with pills and training hours.
-- Without it, understanding of a Path would accrue to whoever spent the most
-- quickening, which is the meter the Venerable ranks exist to replace.
--
-- Third dead column found this week, after `dao_marks` and the damage total.
-- The pattern is a column added with the table that reads well and that
-- nothing ever wired up.
--
-- WHERE A CAST HAPPENS. Not in `technique_cast_effects`, which is the
-- obvious-sounding place and the wrong one: it returns 0 in its first four
-- lines unless there is a battle scope, and again if the technique carries no
-- effects, so most casts never reach its body. `player_swing` is the
-- function, and it has nine callers:
--
--     battle_act  delve_act  dungeon_resolve_round  horde_gauntlet_swing
--     horde_strike  strike_boss  trial_resolve_round          - real swings
--     trial_rehearse  delve_rehearse                          - rehearsals
--
-- The two rehearsals run inside subtransactions they deliberately abort, so a
-- forecast does not count as a cast. One edit, in one place, reaching all
-- seven lanes.
--
-- UPDATE AND NOT UPSERT. `player_techniques` is the learned shelf. A
-- technique swung straight off a manual without being learned has no row
-- there and ticks nothing, which is the right answer - understanding of a
-- Path comes from what you have made your own - but it does mean a cultivator
-- who fights entirely out of borrowed books accrues nothing from it. Worth
-- knowing before phase 3 leans on this.
--
-- Lifted and patched rather than retyped. The stored body is CRLF, so the
-- anchor is a single line.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
    body   TEXT;
BEGIN
    src := pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint)'::regprocedure);

    anchor := '    PERFORM technique_cast_effects(p_player_id, p_technique_id,';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the anchor in player_swing is not there exactly once';
    END IF;

    body :=
        '    -- A cast, counted. The only record that separates swinging a' || chr(10) ||
        '    -- Path technique in a fight from buying insight with pills, which' || chr(10) ||
        '    -- is what the Venerable ranks accrue understanding from. UPDATE' || chr(10) ||
        '    -- only: a technique swung off a manual was never made your own.' || chr(10) ||
        '    UPDATE player_techniques' || chr(10) ||
        '       SET times_used = times_used + 1, updated_at = now()' || chr(10) ||
        '     WHERE player_id = p_player_id AND technique_id = p_technique_id;' || chr(10) ||
        chr(10) ||
        anchor;

    src := replace(src, anchor, body);
    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- How much of a cultivator's casting stood on each Path
-- ---------------------------------------------------------------------------

-- A technique can stand on more than one Path, and `technique_paths.weight`
-- already says in what proportion - 0.5/0.5 for a two-Path forged technique.
-- So a cast is shared out rather than counted once per Path, and the totals
-- add up to the number of casts instead of to a multiple of it.
CREATE FUNCTION path_casts_of(p_player_id BIGINT, p_path_code TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(sum(pt.times_used * tp.weight), 0)::NUMERIC
    FROM player_techniques pt
    JOIN technique_paths tp ON tp.technique_id = pt.technique_id
    WHERE pt.player_id = p_player_id
      AND tp.path_code = p_path_code;
$fn$;

COMMENT ON FUNCTION path_casts_of(BIGINT, TEXT) IS
    'Casts a cultivator has made on a Path, shared out by technique_paths.weight so a two-Path technique counts half to each. The deed the Path aspect of a Dao names.';


CREATE INDEX player_techniques_used_idx
    ON player_techniques (player_id, times_used DESC)
    WHERE times_used > 0;


-- ---------------------------------------------------------------------------
-- The aspect says what actually feeds it
-- ---------------------------------------------------------------------------

-- 0483 copied these strings out of the spec and two of them described deeds
-- the game does not record. The Gu one was corrected in 0487 once there was
-- something to correct it to; the body one said "damage taken and lived
-- through", and `physique_xp` is fed by `temper_body`, `resolve_training_session`
-- and `take_pill` - tempering, not surviving. There is no lifetime
-- damage-taken counter to point at, so the string tells the truth instead.
CREATE OR REPLACE FUNCTION dao_aspects(p_player_id BIGINT)
RETURNS TABLE (
    ordinal     INTEGER,
    source_kind TEXT,
    source_code TEXT,
    label       TEXT,
    weight      NUMERIC,
    feeds       TEXT
)
LANGUAGE sql STABLE AS $fn$
WITH lead_path AS (
    SELECT max(insight) AS top
    FROM player_path_attainment
    WHERE player_id = p_player_id
),
craft_total AS (
    SELECT sum(level)::NUMERIC AS total
    FROM player_skills
    WHERE player_id = p_player_id AND level > 0
),
carried AS (
    SELECT t.gu_type_id, gu_carried_seconds(p_player_id, t.gu_type_id) AS secs
    FROM (
        SELECT gu_type_id FROM player_gu_carried WHERE player_id = p_player_id
        UNION
        SELECT e.gu_type_id FROM player_gu_equipped e WHERE e.player_id = p_player_id
    ) t
),
carried_total AS (
    SELECT sum(secs)::NUMERIC AS total FROM carried
),
a_path AS (
    SELECT 1 AS kind_rank,
           row_number() OVER (ORDER BY pa.insight DESC, pa.path_code) AS within,
           'path'::TEXT AS source_kind, pa.path_code AS source_code,
           p.name AS label,
           round(pa.insight::NUMERIC / lp.top, 3) AS weight,
           'swinging a technique of this Path in a real fight'::TEXT AS feeds
    FROM player_path_attainment pa
    JOIN paths p ON p.code = pa.path_code
    CROSS JOIN lead_path lp
    WHERE pa.player_id = p_player_id
      AND lp.top > 0
      AND pa.insight >= lp.top * 0.10
    ORDER BY pa.insight DESC, pa.path_code
    LIMIT 3
),
a_body AS (
    SELECT 2, 1::BIGINT, 'body'::TEXT, pp.body_path, b.name, 1.000::NUMERIC,
           'tempering the body'::TEXT
    FROM player_physique pp
    JOIN body_paths b ON b.code = pp.body_path
    WHERE pp.player_id = p_player_id AND pp.body_path IS NOT NULL
),
a_craft AS (
    SELECT 3, 1::BIGINT, 'craft'::TEXT, ps.skill, ps.name,
           round(ps.level::NUMERIC / ct.total, 3),
           'working the craft'::TEXT
    FROM player_skills ps
    CROSS JOIN craft_total ct
    WHERE ps.player_id = p_player_id AND ps.level > 0 AND ct.total > 0
    ORDER BY ps.level DESC, ps.skill
    LIMIT 1
),
a_root AS (
    SELECT 4, 1::BIGINT, 'root'::TEXT, r.code, r.name,
           COALESCE(rw.weight, 0.200)::NUMERIC,
           'nothing - a root is what you were born with'::TEXT
    FROM player_character pc
    JOIN roots r ON r.code = pc.root_code
    LEFT JOIN dao_rarity_weight rw ON rw.rarity = r.rarity
    WHERE pc.player_id = p_player_id AND pc.root_code IS NOT NULL
),
a_destiny AS (
    SELECT 5,
           row_number() OVER (
               ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code),
           'destiny'::TEXT, d.code, d.name,
           round(least(1.0, (1 - d.roll_weight) * (1 + d.min_rank / 18.0)), 3),
           'nothing yet - no deed is recorded against a destiny'::TEXT
    FROM player_destinies pdx
    JOIN destinies d ON d.code = pdx.code
    WHERE pdx.player_id = p_player_id AND pdx.chosen_at IS NOT NULL
    ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code
    LIMIT 2
),
a_gu AS (
    SELECT 6, 1::BIGINT, 'gu'::TEXT, gt.code, gt.name,
           round(c.secs::NUMERIC / NULLIF(ct.total, 0), 3),
           'wearing the worm rather than keeping it in a jar'::TEXT
    FROM carried c
    JOIN gu_types gt ON gt.gu_type_id = c.gu_type_id
    CROSS JOIN carried_total ct
    WHERE c.secs >= 86400 AND ct.total > 0
    ORDER BY c.secs DESC, gt.code
    LIMIT 1
),
all_parts AS (
    SELECT * FROM a_path
    UNION ALL SELECT * FROM a_body
    UNION ALL SELECT * FROM a_craft
    UNION ALL SELECT * FROM a_root
    UNION ALL SELECT * FROM a_destiny
    UNION ALL SELECT * FROM a_gu
)
SELECT (row_number() OVER (ORDER BY kind_rank, within))::INTEGER,
       source_kind, source_code, label, weight, feeds
FROM all_parts
ORDER BY kind_rank, within;
$fn$;


-- ---------------------------------------------------------------------------
-- A swing counts, a forecast does not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_tid   BIGINT;
    v_spec  BIGINT;
    v_used  BIGINT;
    v_casts NUMERIC;
    v_n     INTEGER;
BEGIN
    -- The patch landed and nothing else in the body moved.
    IF pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint)'::regprocedure)
       NOT LIKE '%SET times_used = times_used + 1%' THEN
        RAISE EXCEPTION 'player_swing does not count a cast';
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-994, 'cast-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        VALUES (v_pid, (SELECT min(realm_id) FROM realms), 0);
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));

        SELECT technique_id INTO v_tid FROM techniques
        WHERE EXISTS (SELECT 1 FROM technique_paths WHERE technique_id = techniques.technique_id)
        ORDER BY technique_id LIMIT 1;
        SELECT species_id INTO v_spec FROM creature_species ORDER BY species_id LIMIT 1;

        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_pid, v_tid);

        PERFORM player_swing(v_pid, v_tid, v_spec, 1000000::BIGINT, 0::BIGINT);
        PERFORM player_swing(v_pid, v_tid, v_spec, 1000000::BIGINT, 0::BIGINT);

        SELECT times_used INTO v_used FROM player_techniques
        WHERE player_id = v_pid AND technique_id = v_tid;
        IF v_used <> 2 THEN
            RAISE EXCEPTION 'two swings counted as %', v_used;
        END IF;

        -- Shared out by weight, so the Paths of a technique sum to its casts
        -- rather than to a multiple of them.
        SELECT sum(path_casts_of(v_pid, tp.path_code)) INTO v_casts
        FROM technique_paths tp WHERE tp.technique_id = v_tid;
        IF round(v_casts, 2) <> 2.00 THEN
            RAISE EXCEPTION 'two casts shared out to %', v_casts;
        END IF;

        -- A technique nobody learned ticks nothing rather than erroring.
        DELETE FROM player_techniques WHERE player_id = v_pid;
        PERFORM player_swing(v_pid, v_tid, v_spec, 1000000::BIGINT, 0::BIGINT);
        IF EXISTS (SELECT 1 FROM player_techniques WHERE player_id = v_pid) THEN
            RAISE EXCEPTION 'swinging a borrowed technique invented a shelf row';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing was retyped into the body, so every other lane still works.
    SELECT count(*) INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosrc ~ 'player_swing' AND p.proname <> 'player_swing';
    IF v_n < 9 THEN
        RAISE EXCEPTION 'player_swing lost callers: % left', v_n;
    END IF;

    RAISE NOTICE 'a cast is counted in one place for all seven fighting lanes';
END;
$probe$;
