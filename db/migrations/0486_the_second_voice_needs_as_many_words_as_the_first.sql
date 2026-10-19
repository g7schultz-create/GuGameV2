-- 0486_the_second_voice_needs_as_many_words_as_the_first
--
-- 0485's guarantee holds - no title says one thing twice any more. Reading
-- the twenty again turns up two faults it did not address.
--
-- ONE: THE SECOND VOICE IS THREADBARE. 0482 gave each path six adjectives and
-- six nouns and gave the bodies three and the crafts two, on the reasoning
-- that they "modify rather than lead, so they want fewer and sharper". Then
-- 0485 made the earned axes the ONLY source an adjective can come from, and
-- two words per craft stopped being sharp and became a rut:
--
--     The Dao of the Untracked Rule      Xue Wuzhi
--     The Dao of the Untracked Sage      chickenshavelegs
--     The Dao of the Untracked Aeon      octagram_
--
-- Three cultivators, three different paths, one adjective, because exploring
-- is a common top craft and exploring had exactly two adjectives to offer.
-- The reasoning in 0482 was sound for the design 0482 had; 0485 changed the
-- design and did not revisit it. So the earned axes get six and six, the same
-- as the paths - 3 bodies and 7 crafts, 120 words where there were 46.
--
-- Worth noting what 0485 made free: a source fills exactly one slot in a
-- title, so two words of one source can never meet. Worm-Wrought may sit
-- beside Worm-Craft in the vocabulary without any risk of sitting beside it
-- in a name, and these lists are written without tiptoeing around that.
--
-- TWO: THE LAST RESORT WAS COMPETING ON WEIGHT. 0485 added 'The Dao of
-- {noun1}' and 'The {noun1} Dao' for the cultivator with one source and
-- nothing to pair it with, then entered them in the same weighted draw as
-- every other shape at a combined 1.70 - more than any single shape. So they
-- won for people who had plenty to say:
--
--     The Hoar Dao     luckymate0_0 - three paths, a body and a craft
--     The Cut Dao      Voxt - a path and a craft
--
-- A one-word title for a cultivator with four sources is not a style, it is
-- the draw misfiring. A shape that names one source is now offered only when
-- no shape that names two is available at all.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Six and six for the bodies
-- ---------------------------------------------------------------------------

INSERT INTO dao_words (source_kind, source_code, word, role) VALUES
('body','taoist','Even-Tempered','adjective'),('body','taoist','Unhurried','adjective'),
('body','taoist','Wu-Wei','adjective'),
('body','taoist','Quietude','noun'),('body','taoist','Even Keel','noun'),
('body','taoist','Middle Way','noun'),

('body','demonic','Ravening','adjective'),('body','demonic','Unrepentant','adjective'),
('body','demonic','Blood-Mad','adjective'),
('body','demonic','Abandon','noun'),('body','demonic','Fury','noun'),
('body','demonic','Hunger Unending','noun'),

('body','buddhist','Unbreaking','adjective'),('body','buddhist','Stone-Still','adjective'),
('body','buddhist','Long-Suffering','adjective'),
('body','buddhist','Patience','noun'),('body','buddhist','Bulwark','noun'),
('body','buddhist','Vow','noun');


-- ---------------------------------------------------------------------------
-- Six and six for the seven crafts
-- ---------------------------------------------------------------------------

INSERT INTO dao_words (source_kind, source_code, word, role) VALUES
('craft','alchemy','Pill-Wrought','adjective'),('craft','alchemy','Nine-Brewed','adjective'),
('craft','alchemy','Simmering','adjective'),('craft','alchemy','Herb-Wise','adjective'),
('craft','alchemy','Pill','noun'),('craft','alchemy','Decoction','noun'),
('craft','alchemy','Furnace Mouth','noun'),('craft','alchemy','Alchemist','noun'),

('craft','blacksmithing','Anvil-Struck','adjective'),('craft','blacksmithing','Quenched','adjective'),
('craft','blacksmithing','Hard-Beaten','adjective'),('craft','blacksmithing','Smith-Wrought','adjective'),
('craft','blacksmithing','Hammer','noun'),('craft','blacksmithing','Bellows','noun'),
('craft','blacksmithing','Smith','noun'),('craft','blacksmithing','Ingot','noun'),

('craft','exploring','Road-Worn','adjective'),('craft','exploring','Wayfaring','adjective'),
('craft','exploring','Unmapped','adjective'),('craft','exploring','Ever-Departing','adjective'),
('craft','exploring','Horizon','noun'),('craft','exploring','Trail','noun'),
('craft','exploring','Explorer','noun'),('craft','exploring','Far Country','noun'),

('craft','foraging','Dew-Early','adjective'),('craft','foraging','Field-Wise','adjective'),
('craft','foraging','Stoop-Backed','adjective'),('craft','foraging','Root-Picking','adjective'),
('craft','foraging','Basket','noun'),('craft','foraging','Thicket','noun'),
('craft','foraging','Forager','noun'),('craft','foraging','Windfall','noun'),

('craft','gu_refining','Shell-Breaking','adjective'),('craft','gu_refining','Many-Handed','adjective'),
('craft','gu_refining','Aperture-Deep','adjective'),('craft','gu_refining','Chitin-Clad','adjective'),
('craft','gu_refining','Carapace','noun'),('craft','gu_refining','Mandible','noun'),
('craft','gu_refining','Brood','noun'),('craft','gu_refining','Nest','noun'),

('craft','mining','Seam-Reading','adjective'),('craft','mining','Pick-Handed','adjective'),
('craft','mining','Dust-Lunged','adjective'),('craft','mining','Lamp-Lit','adjective'),
('craft','mining','Pick','noun'),('craft','mining','Lode','noun'),
('craft','mining','Shaft','noun'),('craft','mining','Miner','noun'),

('craft','refinement','Slag-Burning','adjective'),('craft','refinement','Fire-Purged','adjective'),
('craft','refinement','Twice-Melted','adjective'),('craft','refinement','Impurity-Sieving','adjective'),
('craft','refinement','Slag','noun'),('craft','refinement','Dross','noun'),
('craft','refinement','Bar of Iron','noun'),('craft','refinement','Smelter','noun');


-- ---------------------------------------------------------------------------
-- A one-source shape is a last resort, not a contender
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dao_name_of(p_player_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_path1  TEXT;
    v_path2  TEXT;
    v_body   TEXT;
    v_craft  TEXT;
    v_sig    TEXT;

    v_kind   TEXT[] := ARRAY[]::TEXT[];
    v_code   TEXT[] := ARRAY[]::TEXT[];

    -- shapes that name two or more sources, and the fallbacks that name one
    v_shapes TEXT[] := ARRAY[]::TEXT[];
    v_weight NUMERIC[] := ARRAY[]::NUMERIC[];
    v_lone   TEXT[] := ARRAY[]::TEXT[];
    v_lonew  NUMERIC[] := ARRAY[]::NUMERIC[];

    v_shape  TEXT;
    v_slots  INTEGER;
    v_free   INTEGER;
    v_need   INTEGER;
    v_total  NUMERIC := 0;
    v_point  NUMERIC;
    v_acc    NUMERIC := 0;

    v_used   BOOLEAN[];
    v_taken  TEXT[] := ARRAY[]::TEXT[];
    v_adj1   TEXT;
    v_adj2   TEXT;
    v_noun1  TEXT;
    v_noun2  TEXT;
    v_badj   TEXT;
    v_cnoun  TEXT;
    v_slot   TEXT;
    v_word   TEXT;
    i        INTEGER;
    k        INTEGER;
    t        RECORD;
BEGIN
    SELECT string_agg(a.source_kind || ':' || a.source_code, '|' ORDER BY a.ordinal)
    INTO v_sig
    FROM dao_aspects(p_player_id) a;

    IF v_sig IS NULL THEN
        RETURN NULL;
    END IF;
    v_sig := p_player_id::TEXT || '/' || v_sig;

    SELECT max(source_code) FILTER (WHERE rn = 1),
           max(source_code) FILTER (WHERE rn = 2)
    INTO v_path1, v_path2
    FROM (SELECT source_code, row_number() OVER (ORDER BY ordinal) AS rn
          FROM dao_aspects(p_player_id) WHERE source_kind = 'path') s;

    IF v_path1 IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT source_code INTO v_body
    FROM dao_aspects(p_player_id) WHERE source_kind = 'body' LIMIT 1;
    SELECT source_code INTO v_craft
    FROM dao_aspects(p_player_id) WHERE source_kind = 'craft' LIMIT 1;

    v_kind := ARRAY['path'];        v_code := ARRAY[v_path1];
    IF v_path2 IS NOT NULL THEN
        v_kind := v_kind || 'path'::TEXT;  v_code := v_code || v_path2;
    END IF;
    IF v_body IS NOT NULL THEN
        v_kind := v_kind || 'body'::TEXT;  v_code := v_code || v_body;
    END IF;
    IF v_craft IS NOT NULL THEN
        v_kind := v_kind || 'craft'::TEXT; v_code := v_code || v_craft;
    END IF;

    FOR t IN SELECT code, shape, weight FROM dao_templates ORDER BY code LOOP
        IF strpos(t.shape, '{noun2}') > 0      AND v_path2 IS NULL THEN CONTINUE; END IF;
        IF strpos(t.shape, '{body_adj}') > 0   AND v_body  IS NULL THEN CONTINUE; END IF;
        IF strpos(t.shape, '{craft_noun}') > 0 AND v_craft IS NULL THEN CONTINUE; END IF;

        v_free  := array_length(v_code, 1);
        v_slots := 0;
        IF strpos(t.shape, '{noun1}') > 0      THEN v_free := v_free - 1; v_slots := v_slots + 1; END IF;
        IF strpos(t.shape, '{noun2}') > 0      THEN v_free := v_free - 1; v_slots := v_slots + 1; END IF;
        IF strpos(t.shape, '{body_adj}') > 0   THEN v_free := v_free - 1; v_slots := v_slots + 1; END IF;
        IF strpos(t.shape, '{craft_noun}') > 0 THEN v_free := v_free - 1; v_slots := v_slots + 1; END IF;

        v_need := CASE WHEN strpos(t.shape, '{adj1}') > 0 THEN 1 ELSE 0 END
                + CASE WHEN strpos(t.shape, '{adj2}') > 0 THEN 1 ELSE 0 END;

        IF v_free < v_need THEN CONTINUE; END IF;
        v_slots := v_slots + v_need;

        -- A shape naming one source is held back for the cultivator who has
        -- only one. Entered in the main draw it beat shapes that had four
        -- sources to work with.
        IF v_slots <= 1 THEN
            v_lone  := v_lone  || t.shape;
            v_lonew := v_lonew || t.weight;
        ELSE
            v_shapes := v_shapes || t.shape;
            v_weight := v_weight || t.weight;
            v_total  := v_total + t.weight;
        END IF;
    END LOOP;

    IF array_length(v_shapes, 1) IS NULL THEN
        v_shapes := v_lone;
        v_weight := v_lonew;
        SELECT COALESCE(sum(x), 0) INTO v_total FROM unnest(v_lonew) AS x;
    END IF;

    IF array_length(v_shapes, 1) IS NULL OR v_total <= 0 THEN
        RETURN NULL;
    END IF;

    v_point := (('x' || substr(md5(v_sig || '/shape'), 1, 8))::bit(32)::BIGINT % 100000)
               / 100000.0 * v_total;
    v_shape := v_shapes[array_length(v_shapes, 1)];
    FOR i IN 1 .. array_length(v_shapes, 1) LOOP
        v_acc := v_acc + v_weight[i];
        IF v_point < v_acc THEN
            v_shape := v_shapes[i];
            EXIT;
        END IF;
    END LOOP;

    v_used := array_fill(FALSE, ARRAY[array_length(v_code, 1)]);

    IF strpos(v_shape, '{noun1}') > 0 THEN
        v_used[1] := TRUE;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/n1', NULL)
        INTO v_noun1 FROM dao_words
        WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'noun';
        v_taken := v_taken || v_noun1;
    END IF;

    IF strpos(v_shape, '{noun2}') > 0 THEN
        v_used[2] := TRUE;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/n2', v_taken)
        INTO v_noun2 FROM dao_words
        WHERE source_kind = 'path' AND source_code = v_path2 AND role = 'noun';
        v_taken := v_taken || v_noun2;
    END IF;

    IF strpos(v_shape, '{body_adj}') > 0 THEN
        FOR i IN 1 .. array_length(v_code, 1) LOOP
            IF v_kind[i] = 'body' THEN v_used[i] := TRUE; END IF;
        END LOOP;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/b', v_taken)
        INTO v_badj FROM dao_words
        WHERE source_kind = 'body' AND source_code = v_body AND role = 'adjective';
        v_taken := v_taken || v_badj;
    END IF;

    IF strpos(v_shape, '{craft_noun}') > 0 THEN
        FOR i IN 1 .. array_length(v_code, 1) LOOP
            IF v_kind[i] = 'craft' THEN v_used[i] := TRUE; END IF;
        END LOOP;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/c', v_taken)
        INTO v_cnoun FROM dao_words
        WHERE source_kind = 'craft' AND source_code = v_craft AND role = 'noun';
        v_taken := v_taken || v_cnoun;
    END IF;

    FOREACH v_slot IN ARRAY ARRAY['adj1', 'adj2']::TEXT[] LOOP
        CONTINUE WHEN strpos(v_shape, '{' || v_slot || '}') = 0;

        k := NULL;
        FOR i IN 1 .. array_length(v_code, 1) LOOP
            IF NOT v_used[i] THEN k := i; EXIT; END IF;
        END LOOP;
        EXIT WHEN k IS NULL;

        v_used[k] := TRUE;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/' || v_slot, v_taken)
        INTO v_word FROM dao_words
        WHERE source_kind = v_kind[k] AND source_code = v_code[k]
          AND role = 'adjective';
        v_taken := v_taken || v_word;

        IF v_slot = 'adj1' THEN v_adj1 := v_word; ELSE v_adj2 := v_word; END IF;
    END LOOP;

    v_shape := replace(v_shape, '{adj1}',       COALESCE(v_adj1,  ''));
    v_shape := replace(v_shape, '{adj2}',       COALESCE(v_adj2,  ''));
    v_shape := replace(v_shape, '{noun1}',      COALESCE(v_noun1, ''));
    v_shape := replace(v_shape, '{noun2}',      COALESCE(v_noun2, ''));
    v_shape := replace(v_shape, '{body_adj}',   COALESCE(v_badj,  ''));
    v_shape := replace(v_shape, '{craft_noun}', COALESCE(v_cnoun, ''));

    RETURN btrim(regexp_replace(v_shape, '\s+', ' ', 'g'));
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Enough words, and nobody short-changed by the draw
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_thin   TEXT;
    v_name   TEXT;
    v_again  TEXT;
    v_hits   INTEGER;
    v_src    INTEGER;
    v_words  INTEGER;
    v_worst  INTEGER;
    v_rut    TEXT;
    v_n      INTEGER;
    v_sample TEXT;
    pl       RECORD;
BEGIN
    -- Every earned axis now carries as much as a path does. Written against
    -- player_skills and body_paths rather than professions, because the
    -- seventh craft does not appear in professions at all.
    SELECT string_agg(src || ' (' || n || ')', ', ')
    INTO v_thin
    FROM (
        SELECT w.source_kind || '/' || w.source_code AS src, w.role, count(*) AS n
        FROM dao_words w
        WHERE w.source_kind IN ('body', 'craft')
        GROUP BY 1, 2
    ) s
    WHERE n < 6;
    IF v_thin IS NOT NULL THEN
        RAISE EXCEPTION 'these earned axes still have fewer than six: %', v_thin;
    END IF;

    IF EXISTS (
        SELECT 1 FROM body_paths b WHERE 2 <> (
            SELECT count(DISTINCT role) FROM dao_words
            WHERE source_kind = 'body' AND source_code = b.code)
    ) THEN
        RAISE EXCEPTION 'a body is missing one of its two roles';
    END IF;

    IF EXISTS (
        SELECT 1 FROM (SELECT DISTINCT skill FROM player_skills) c
        WHERE 2 <> (
            SELECT count(DISTINCT role) FROM dao_words
            WHERE source_kind = 'craft' AND source_code = c.skill)
    ) THEN
        RAISE EXCEPTION 'a craft is missing one of its two roles';
    END IF;

    FOR pl IN
        SELECT p.player_id
        FROM players p
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_path_attainment pa
                      WHERE pa.player_id = p.player_id AND pa.insight > 0)
    LOOP
        v_name := dao_name_of(pl.player_id);
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'player % walked a path and has no name', pl.player_id;
        END IF;
        IF strpos(v_name, '{') > 0 OR strpos(v_name, '}') > 0
           OR v_name ~ '  ' OR v_name <> btrim(v_name) THEN
            RAISE EXCEPTION 'player % got a broken name: %', pl.player_id, v_name;
        END IF;

        v_again := dao_name_of(pl.player_id);
        IF v_name <> v_again THEN
            RAISE EXCEPTION 'player % read two Daos: % then %', pl.player_id, v_name, v_again;
        END IF;

        -- 0485's guarantee, unchanged.
        SELECT max(c) INTO v_hits
        FROM (
            SELECT w.source_kind || ':' || w.source_code AS src,
                   count(DISTINCT w.word) AS c
            FROM dao_words w
            JOIN dao_aspects(pl.player_id) a
              ON a.source_kind = w.source_kind AND a.source_code = w.source_code
            WHERE strpos(v_name, w.word) > 0
              AND NOT EXISTS (
                  SELECT 1 FROM dao_words w2
                  WHERE strpos(v_name, w2.word) > 0
                    AND w2.word <> w.word
                    AND strpos(w2.word, w.word) > 0)
              AND 1 = (
                  SELECT count(DISTINCT w3.source_kind || ':' || w3.source_code)
                  FROM dao_words w3
                  JOIN dao_aspects(pl.player_id) a3
                    ON a3.source_kind = w3.source_kind
                   AND a3.source_code = w3.source_code
                  WHERE w3.word = w.word)
            GROUP BY 1
        ) s;
        IF COALESCE(v_hits, 0) > 1 THEN
            RAISE EXCEPTION 'player % has one source lending % words of "%"',
                pl.player_id, v_hits, v_name;
        END IF;

        -- And the new one: a cultivator with more than one source is named
        -- for more than one source. The Hoar Dao passed every check above.
        SELECT count(*) INTO v_src
        FROM dao_aspects(pl.player_id)
        WHERE source_kind IN ('path', 'body', 'craft');

        SELECT count(*) INTO v_words
        FROM (SELECT DISTINCT w.word FROM dao_words w
              WHERE strpos(v_name, w.word) > 0
                AND NOT EXISTS (
                    SELECT 1 FROM dao_words w2
                    WHERE strpos(v_name, w2.word) > 0
                      AND w2.word <> w.word
                      AND strpos(w2.word, w.word) > 0)) s;

        IF v_src > 1 AND v_words < 2 THEN
            RAISE EXCEPTION
                'player % has % sources and a title naming one: %',
                pl.player_id, v_src, v_name;
        END IF;
    END LOOP;

    -- No single adjective carrying three cultivators the way Untracked did.
    SELECT max(n), string_agg(word || ' x' || n, ', ')
    INTO v_worst, v_rut
    FROM (
        SELECT w.word, count(*) AS n
        FROM dao_words w
        JOIN players p ON p.deleted_at IS NULL
        WHERE w.source_kind IN ('body', 'craft')
          AND strpos(COALESCE(dao_name_of(p.player_id), ''), w.word) > 0
        GROUP BY w.word
        HAVING count(*) >= 3
    ) s;
    IF COALESCE(v_worst, 0) >= 3 THEN
        RAISE EXCEPTION 'an earned word is still in a rut: %', v_rut;
    END IF;

    SELECT count(DISTINCT n) INTO v_n FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL) s;

    SELECT string_agg(s.n, ' / ') INTO v_sample FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL
        ORDER BY p.player_id LIMIT 3) s;

    SELECT count(*) INTO v_words FROM dao_words;
    RAISE NOTICE '% words; % distinct Daos; e.g. %', v_words, v_n, v_sample;
END;
$probe$;
