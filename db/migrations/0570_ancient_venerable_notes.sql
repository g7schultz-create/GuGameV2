-- 0570_ancient_venerable_notes
--
-- A Venerable rung is slow, and the only lever on it is deeds: casts, body
-- levels, craft levels, hours carried. Measured for clearwest, the floor for
-- ONE aspect of rank 20 is 1,778 body levels or 4,860 casts, and six aspects
-- have to clear it. There is nothing a cultivator can find that moves it.
--
-- So: Ancient Venerable Notes, left behind by somebody who walked this ladder
-- before. Found while exploring and in the deepest rooms, and studied into
-- ONE aspect of your own Dao - the aspect being the choice, because a Dao is
-- six or so meters and which one you pour a find into is the decision worth
-- having.
--
-- UNDERSTANDING IS DERIVED, NOT STORED, which is the whole difficulty here.
-- `dao_understanding` reads the live deed counters every time it is asked, so
-- there is no pool to add to - and crediting the counters themselves would
-- mean handing out body levels and Path casts, which are read by a dozen other
-- things that have nothing to do with this.
--
-- So the notes are their own term. `player_dao_study` holds what has been
-- studied into each aspect, and `dao_understanding` adds it to what the deeds
-- earned. Deeds stay derived; the notes sit beside them and are banked.
--
-- WHAT ONE IS WORTH: 25 points, flat, whatever aspect it goes into. Not scaled
-- by weight, deliberately - a weight already decides how many casts a point
-- costs, and scaling the notes by it as well would make them worth six times
-- more in a strong aspect than a weak one, which is backwards. The weak aspect
-- is the one somebody is stuck on.
--
--     rank 20 wants 200 on an aspect   ->   8 notes
--     rank 27 wants 1,200              ->  48 notes
--
-- Against a 12% explore roll gated on standing, and a chance in the deepest
-- rooms, that is a meaningful shortcut and not a replacement for the climb.
--
-- Only a cultivator who has crossed can find them. An item nobody below rank
-- 19 can use is clutter in their bags, and the essence block in `explore`
-- already gates the same way.


INSERT INTO materials (code, name, category, rarity, description, emoji) VALUES
    ('ancient_venerable_notes', 'Ancient Venerable Notes', 'gathering', 'extreme',
     'Somebody walked this ladder before you and wrote down what it cost them. The hand is steady, the paper is not. Studied into one aspect of your own Dao - and the choosing is the hard part.',
     '📜');

INSERT INTO game_config (key, value, description) VALUES
    ('venerable_notes_understanding', 25,
     'Understanding one set of Ancient Venerable Notes adds to the aspect it is studied into. Flat rather than scaled by the aspect''s weight: the weight already decides what a point costs in deeds, and scaling the notes by it too would make them worth least exactly where somebody is stuck.'),
    ('explore_notes_chance', 0.06,
     'The chance an explore turns up Ancient Venerable Notes, for a cultivator who has crossed out of the realms. Rolled separately from the ordinary outcome table, like the essence find, so it does not thin the ordinary draws.'),
    ('dungeon_notes_chance', 0.35,
     'The chance a cleared room past the realm ladder holds Ancient Venerable Notes.');


CREATE TABLE player_dao_study (
    player_id BIGINT  NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    ordinal   INTEGER NOT NULL,
    points    NUMERIC NOT NULL DEFAULT 0 CHECK (points >= 0),
    PRIMARY KEY (player_id, ordinal)
);

COMMENT ON TABLE player_dao_study IS
    'Understanding studied into an aspect out of Ancient Venerable Notes, as opposed to earned from deeds. Banked, because unlike a deed counter there is nothing live to derive it from - the notes are gone once read. 0570.';


-- ---------------------------------------------------------------------------
-- The deeds, plus what was read
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dao_understanding(p_player_id BIGINT)
RETURNS TABLE (
    ordinal       INTEGER,
    source_kind   TEXT,
    source_code   TEXT,
    label         TEXT,
    weight        NUMERIC,
    unit_name     TEXT,
    baseline      NUMERIC,
    deed_now      NUMERIC,
    gained        NUMERIC,
    understanding NUMERIC
)
LANGUAGE sql STABLE AS $fn$
    SELECT a.ordinal, a.source_kind, a.source_code, a.label, a.weight::NUMERIC,
           r.unit_name,
           a.baseline,
           dao_deed_of(p_player_id, a.source_kind, a.source_code) AS deed_now,
           GREATEST(0, dao_deed_of(p_player_id, a.source_kind, a.source_code)
                       - a.baseline) AS gained,
           round(
               GREATEST(0, dao_deed_of(p_player_id, a.source_kind, a.source_code)
                           - a.baseline)
               * a.weight / r.units_per_point
               -- WHAT WAS READ RATHER THAN DONE (0570). Added after the weight
               -- rather than through it: a note is worth the same wherever it
               -- is studied, and the weight has already had its say about what
               -- a deed is worth.
               + COALESCE(s.points, 0),
           3) AS understanding
    FROM player_dao_aspects a
    JOIN dao_deed_rates r ON r.source_kind = a.source_kind
    LEFT JOIN player_dao_study s
           ON s.player_id = a.player_id AND s.ordinal = a.ordinal
    WHERE a.player_id = p_player_id
    ORDER BY a.ordinal;
$fn$;


-- ---------------------------------------------------------------------------
-- Reading them
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION study_venerable_notes(
    p_player_id BIGINT, p_ordinal INTEGER, p_quantity BIGINT DEFAULT 1
)
RETURNS TABLE (label TEXT, gained NUMERIC, understanding_after NUMERIC,
               total_after NUMERIC, rung_before SMALLINT, rung_after SMALLINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_label TEXT;
    v_add   NUMERIC;
    v_was   SMALLINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id) THEN
        RAISE EXCEPTION
            'these are no use to you until a Dao of your own is stamped'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'read how many?' USING ERRCODE = 'check_violation';
    END IF;

    -- The aspect has to be one of THEIRS, and one that can hold understanding
    -- at all - a root or a destiny records no deed and cannot be studied into
    -- either, or the notes would vanish into an aspect that never moves.
    SELECT a.label INTO v_label
    FROM player_dao_aspects a
    JOIN dao_deed_rates r ON r.source_kind = a.source_kind
    WHERE a.player_id = p_player_id AND a.ordinal = p_ordinal;

    IF v_label IS NULL THEN
        RAISE EXCEPTION
            'that is not an aspect of your Dao that understanding can reach'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refuses rather than going negative, so a short bag costs nothing.
    PERFORM spend_material(p_player_id, 'ancient_venerable_notes', p_quantity);

    v_was := venerable_rank_of(p_player_id);
    v_add := p_quantity * game_config_value('venerable_notes_understanding');

    INSERT INTO player_dao_study (player_id, ordinal, points)
    VALUES (p_player_id, p_ordinal, v_add)
    ON CONFLICT (player_id, ordinal)
        DO UPDATE SET points = player_dao_study.points + EXCLUDED.points;

    RETURN QUERY
    SELECT v_label, v_add,
           (SELECT u.understanding FROM dao_understanding(p_player_id) u
            WHERE u.ordinal = p_ordinal),
           dao_understanding_total(p_player_id),
           v_was, venerable_rank_of(p_player_id);
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Finding them
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'    IF mat IS NULL THEN
        gained := game_config_value(''exploring_exp_empty'');';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'explore' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'explore does not fall through to nothing where it did';
    END IF;

    patched := replace(src, anchor,
'    -- ANCIENT VENERABLE NOTES (0570). Rolled after everything else and only
    -- for somebody who has crossed, the same shape the essence find uses - it
    -- does not thin the ordinary outcome table, and it does not put an item in
    -- a bag that cannot read it. Takes the slot only if nothing else did, so a
    -- find is never silently replaced.
    IF mat IS NULL
       AND EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
       AND random() < game_config_value(''explore_notes_chance'') THEN
        mat    := ''ancient_venerable_notes'';
        amount := 1;
        pick   := ''notes'';
    END IF;

' || anchor);

    IF patched = src THEN
        RAISE EXCEPTION 'the explore patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT := '    -- ---- essence -------------------------------------------------------';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_spoils_for' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_spoils_for does not pay essence where it did';
    END IF;

    patched := replace(src, anchor,
'    -- ---- the notes somebody left -----------------------------------------
    -- Only past the realm ladder, and only to somebody who can read them.
    IF p_rank > (SELECT max(r.rank) FROM realms r)
       AND EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
       AND random() < game_config_value(''dungeon_notes_chance'') THEN
        PERFORM grant_material(p_player_id, ''ancient_venerable_notes'', 1);
        got := got || jsonb_build_object(''notes'',
            ''Ancient Venerable Notes'');
    END IF;

' || anchor);

    IF patched = src THEN
        RAISE EXCEPTION 'the dungeon_spoils_for patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_ord   INTEGER;
    v_got   RECORD;
    v_before NUMERIC;
    v_after  NUMERIC;
    v_n     INTEGER;
BEGIN
    -- 1. NOBODY'S UNDERSTANDING MOVED. The new term is a LEFT JOIN onto an
    --    empty table, so every stamped cultivator must read exactly what they
    --    read a moment ago.
    IF EXISTS (SELECT 1 FROM player_dao_study) THEN
        RAISE EXCEPTION 'somebody already has notes studied into them';
    END IF;

    SELECT count(*) INTO v_n FROM player_dao d
    CROSS JOIN LATERAL dao_understanding(d.player_id) u
    WHERE u.understanding IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% aspects read NULL understanding', v_n;
    END IF;

    -- 2. READING THEM MOVES THE RIGHT ASPECT, and only it.
    BEGIN
        SELECT d.player_id INTO v_who FROM player_dao d LIMIT 1;
        IF v_who IS NULL THEN
            RAISE NOTICE 'nobody has ascended, so the notes were not read';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT u.ordinal INTO v_ord FROM dao_understanding(v_who) u
        ORDER BY u.understanding LIMIT 1;

        SELECT u.understanding INTO v_before
        FROM dao_understanding(v_who) u WHERE u.ordinal = v_ord;

        PERFORM grant_material(v_who, 'ancient_venerable_notes', 4);
        SELECT * INTO v_got FROM study_venerable_notes(v_who, v_ord, 4);

        SELECT u.understanding INTO v_after
        FROM dao_understanding(v_who) u WHERE u.ordinal = v_ord;

        IF v_after - v_before
           <> 4 * game_config_value('venerable_notes_understanding') THEN
            RAISE EXCEPTION
                'four notes moved "%" by % and should have moved it by %',
                v_got.label, v_after - v_before,
                4 * game_config_value('venerable_notes_understanding');
        END IF;
        RAISE NOTICE
            'four notes took "%" from % to %', v_got.label, v_before, v_after;

        -- 3. AND A ROOT OR DESTINY CANNOT BE STUDIED INTO. They record no
        --    deed, so notes poured there would simply vanish.
        SELECT a.ordinal INTO v_ord FROM player_dao_aspects a
        WHERE a.player_id = v_who
          AND a.source_kind NOT IN (SELECT source_kind FROM dao_deed_rates)
        LIMIT 1;

        IF v_ord IS NOT NULL THEN
            PERFORM grant_material(v_who, 'ancient_venerable_notes', 1);
            BEGIN
                PERFORM study_venerable_notes(v_who, v_ord, 1);
                RAISE EXCEPTION
                    'notes were read into an aspect that records no deed';
            EXCEPTION WHEN check_violation THEN
                NULL;
            END;
        END IF;

        -- 4. AND SOMEBODY WHO HAS NOT CROSSED CANNOT READ THEM AT ALL.
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 5. THE ITEM IS NOT GEAR FOOD. It has no tier and is not a beast part,
    --    so `equipment_food_value` must refuse it - otherwise the rarest thing
    --    in the game is an anvil snack.
    IF COALESCE(equipment_food_value('ancient_venerable_notes', 100), 0) <> 0 THEN
        RAISE EXCEPTION 'the notes can be poured into a sword';
    END IF;
END
$probe$;
