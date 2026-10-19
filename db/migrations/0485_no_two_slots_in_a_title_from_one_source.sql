-- 0485_no_two_slots_in_a_title_from_one_source
--
-- 0484 stopped the stem stutters and the twenty read better. Then I read them
-- out loud again, which is apparently the only test that works:
--
--     The Dao of the Empyrean Heaven      SylvRime     heaven  + heaven
--     The Dao of the Lawful Rule          Xue Wuzhi    rule    + rule
--     The Dao of the Sanguine Lifeblood   .kayden      blood   + blood
--     The Dao of the Hourless Duration    Shad         time    + time
--     The Dao of the Empyrean Mandate     Miyu         heaven  + heaven
--
-- Not one of those pairs shares a stem, so dao_clashes passes every one of
-- them, and all five say the same thing twice. Empyrean IS heaven. Lawful IS
-- rule. The stem test was the right answer to the question I asked it and
-- the question was too small.
--
-- AND THE HEURISTIC CANNOT BE PATCHED INTO CORRECTNESS. The pairs that read
-- badly and the pairs that read well are the same shape:
--
--     Severing Blade    Waning Aeon    Coiled Breath     all fine
--     Lawful Rule       Empyrean Heaven                  both stutter
--
-- The difference is whether the adjective is a synonym of the noun, which is
-- a judgement about meaning across 34 paths times 36 adjective-noun pairs.
-- Any rule I write catches the five I just read and misses the next five from
-- a path I have not audited. I added one_of in 0484 at the highest weight of
-- any shape, which is why five of eleven single-path cultivators drew both
-- halves from one pool; patching its word list would leave the shape itself
-- still wrong.
--
-- SO THE GUARANTEE IS STRUCTURAL: NO TWO SLOTS IN A TITLE ARE FILLED FROM
-- THE SAME SOURCE. If the adjective comes from your body and the noun from
-- your strongest path, they cannot restate each other, whatever words the
-- vocabulary happens to hold. This needs no audit and does not rot when
-- somebody adds a path.
--
-- How a shape gets filled. Four slots are bound to one source each by what
-- they mean - {noun1} is your strongest path because that is what a Dao is
-- named for, {noun2} your second path, {body_adj} your body, {craft_noun}
-- your craft. Whatever sources those leave over are the pool the adjective
-- slots draw from, one each, none twice. A shape is offered only if its bound
-- slots exist and the leftovers cover its adjectives.
--
-- WHAT IT COSTS. 'The Elixir of the Severing Blade' is no longer reachable
-- for a sword cultivator whose only other source is the craft that supplied
-- Elixir - the shape wants three sources and they have two. A good title
-- lost to a rule that also refuses 'The Elixir of the Lawful Rule'. Worth it:
-- the shapes that survive are the ones that cannot stutter, and a cultivator
-- with nothing but one path now gets a bare title that says one true thing
-- instead of a padded one that says it twice.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Something for the cultivator who has only ever walked one path
-- ---------------------------------------------------------------------------

-- One source means one slot. These are the only honest shapes at that point,
-- and they are better than an adjective invented to fill a gap.
INSERT INTO dao_templates (code, shape, weight) VALUES
    ('bare_of',  'The Dao of {noun1}', 1.00),
    ('bare_the', 'The {noun1} Dao',    0.70);


-- ---------------------------------------------------------------------------
-- Compose it from distinct sources
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

    -- the sources this cultivator can be named from, in preference order
    v_kind   TEXT[] := ARRAY[]::TEXT[];
    v_code   TEXT[] := ARRAY[]::TEXT[];

    v_shapes TEXT[] := ARRAY[]::TEXT[];
    v_weight NUMERIC[] := ARRAY[]::NUMERIC[];
    v_shape  TEXT;
    v_free   INTEGER;
    v_need   INTEGER;
    v_total  NUMERIC := 0;
    v_point  NUMERIC;
    v_acc    NUMERIC := 0;

    v_used   BOOLEAN[];
    v_taken  TEXT[] := ARRAY[]::TEXT[];   -- words already in the title
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
        RETURN NULL;   -- the paths are what a Dao is named for
    END IF;

    SELECT source_code INTO v_body
    FROM dao_aspects(p_player_id) WHERE source_kind = 'body' LIMIT 1;
    SELECT source_code INTO v_craft
    FROM dao_aspects(p_player_id) WHERE source_kind = 'craft' LIMIT 1;

    -- Index 1 is always the strongest path. The order of the rest is the
    -- order an adjective slot prefers to draw from: a second path says more
    -- about a cultivator than their body, and their body more than their
    -- trade.
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

    -- Which shapes can this cultivator fill without using a source twice.
    FOR t IN SELECT code, shape, weight FROM dao_templates ORDER BY code LOOP
        IF strpos(t.shape, '{noun2}') > 0      AND v_path2 IS NULL THEN CONTINUE; END IF;
        IF strpos(t.shape, '{body_adj}') > 0   AND v_body  IS NULL THEN CONTINUE; END IF;
        IF strpos(t.shape, '{craft_noun}') > 0 AND v_craft IS NULL THEN CONTINUE; END IF;

        -- every bound slot spends one source; the adjectives want what is left
        v_free := array_length(v_code, 1);
        IF strpos(t.shape, '{noun1}') > 0      THEN v_free := v_free - 1; END IF;
        IF strpos(t.shape, '{noun2}') > 0      THEN v_free := v_free - 1; END IF;
        IF strpos(t.shape, '{body_adj}') > 0   THEN v_free := v_free - 1; END IF;
        IF strpos(t.shape, '{craft_noun}') > 0 THEN v_free := v_free - 1; END IF;

        v_need := CASE WHEN strpos(t.shape, '{adj1}') > 0 THEN 1 ELSE 0 END
                + CASE WHEN strpos(t.shape, '{adj2}') > 0 THEN 1 ELSE 0 END;

        IF v_free < v_need THEN CONTINUE; END IF;

        v_shapes := v_shapes || t.shape;
        v_weight := v_weight || t.weight;
        v_total  := v_total + t.weight;
    END LOOP;

    IF array_length(v_shapes, 1) IS NULL THEN
        RETURN NULL;   -- asserted unreachable below for anyone with a path
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

    -- Spend the bound slots first, marking their sources off.
    v_used := array_fill(FALSE, ARRAY[array_length(v_code, 1)]);

    IF strpos(v_shape, '{noun1}') > 0 THEN
        v_used[1] := TRUE;
        SELECT dao_pick_clear(array_agg(word), v_sig || '/n1', NULL)
        INTO v_noun1 FROM dao_words
        WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'noun';
        v_taken := v_taken || v_noun1;
    END IF;

    IF strpos(v_shape, '{noun2}') > 0 THEN
        v_used[2] := TRUE;   -- index 2 is the second path whenever there is one
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

    -- Then the adjectives, each from a source nothing else in this title has
    -- used. This is the whole guarantee: an adjective cannot restate the noun
    -- beside it, because it did not come from the same place.
    FOREACH v_slot IN ARRAY ARRAY['adj1', 'adj2']::TEXT[] LOOP
        CONTINUE WHEN strpos(v_shape, '{' || v_slot || '}') = 0;

        k := NULL;
        FOR i IN 1 .. array_length(v_code, 1) LOOP
            IF NOT v_used[i] THEN k := i; EXIT; END IF;
        END LOOP;
        EXIT WHEN k IS NULL;   -- eligibility already ruled this out

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
-- Prove the guarantee rather than reading the output again
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_name   TEXT;
    v_again  TEXT;
    v_hits   INTEGER;
    v_src    INTEGER;
    v_n      INTEGER;
    v_one    INTEGER;
    v_sample TEXT;
    pl       RECORD;
BEGIN
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
        IF strpos(v_name, '{') > 0 OR strpos(v_name, '}') > 0 THEN
            RAISE EXCEPTION 'player % got an unfilled name: %', pl.player_id, v_name;
        END IF;
        IF v_name ~ '  ' OR v_name <> btrim(v_name) THEN
            RAISE EXCEPTION 'player % got a name with a hole in it: %', pl.player_id, v_name;
        END IF;

        v_again := dao_name_of(pl.player_id);
        IF v_name <> v_again THEN
            RAISE EXCEPTION 'player % read two Daos: % then %', pl.player_id, v_name, v_again;
        END IF;

        -- THE GUARANTEE, checked against the finished string so it holds
        -- whatever route the composer took.
        --
        -- Attribution is not unique: 0482 deliberately shares words between
        -- paths whose fields overlap - Decreed belongs to both heaven and
        -- rule, Keen to both metal and sword - so 'The Dao of the Decreed
        -- Heaven' cannot be told from the string alone whether Decreed came
        -- from rule (correct, two sources) or from heaven (a stutter). That
        -- ambiguity failed my first version of this probe on a title that was
        -- in fact composed correctly.
        --
        -- What IS decidable: a word belonging to exactly one of this
        -- cultivator's sources can only have come from there. If one source
        -- lent two such words, a slot was filled twice from it. That catches
        -- every stutter 0484 shipped - Lawful and Rule are both rule-only,
        -- Empyrean and Heaven both heaven-only - and admits the shared-word
        -- titles that are honestly two-sourced.
        SELECT max(c), count(*) INTO v_hits, v_src
        FROM (
            -- DISTINCT because a word can hold two roles for one source:
            -- wisdom lists Sage as both its adjective and its noun, which
            -- made 'The Dao of the Untracked Sage' look doubly sourced.
            SELECT w.source_kind || ':' || w.source_code AS src,
                   count(DISTINCT w.word) AS c
            FROM dao_words w
            JOIN dao_aspects(pl.player_id) a
              ON a.source_kind = w.source_kind AND a.source_code = w.source_code
            WHERE strpos(v_name, w.word) > 0
              -- a word sitting inside a longer matched word is that word, not
              -- a second one
              AND NOT EXISTS (
                  SELECT 1 FROM dao_words w2
                  WHERE strpos(v_name, w2.word) > 0
                    AND w2.word <> w.word
                    AND strpos(w2.word, w.word) > 0)
              -- and only words this cultivator could have got from one place
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
            RAISE EXCEPTION
                'player % has one source lending % words of "%"',
                pl.player_id, v_hits, v_name;
        END IF;
    END LOOP;

    -- The eleven with one path are still named, and named without padding.
    SELECT count(*) INTO v_one
    FROM players p
    WHERE p.deleted_at IS NULL
      AND (SELECT count(*) FROM dao_aspects(p.player_id) WHERE source_kind = 'path') = 1
      AND dao_name_of(p.player_id) IS NOT NULL;
    IF v_one < 11 THEN
        RAISE EXCEPTION 'only % of the eleven single-path cultivators are named', v_one;
    END IF;

    SELECT count(DISTINCT n) INTO v_n FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL) s;

    SELECT string_agg(s.n, ' / ') INTO v_sample FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL
        ORDER BY p.player_id LIMIT 3) s;

    RAISE NOTICE
        '% distinct Daos, no source lending twice; e.g. %', v_n, v_sample;
END;
$probe$;
