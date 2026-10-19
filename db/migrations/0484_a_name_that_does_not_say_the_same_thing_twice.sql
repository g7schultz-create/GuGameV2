-- 0484_a_name_that_does_not_say_the_same_thing_twice
--
-- 0483 composed a name for all twenty living cultivators, none of them with
-- an unfilled placeholder and all of them stable across reads. Then I read
-- the twenty out loud, which the probes could not do:
--
--     Decree of the Decreed Mandate            luo.rin
--     Lifeblood of the Sanguine Heartsblood    .kayden.break_
--     The Dao of Qi and Vitality               Yiling
--     The Dao of the Statute-Bound Rule        Xue Wuzhi
--     The Dao of the Everlasting Aeon          octagram_
--
-- Eight of the twenty say one thing twice. The guard I wrote refuses to
-- repeat a word; it has nothing to say about Decree beside Decreed, or
-- Lifeblood beside Heartsblood, or Qi beside Vitality. Two separate causes:
--
-- ONE: THE SHARED STEM. Blood's six nouns include Lifeblood, Heartsblood and
-- Crimson Flow; its adjectives include Sanguine and Exsanguine. Any two of
-- those in one title is a stutter. Equality was never the right test - the
-- test is whether two words share a stem, which is a string comparison I
-- simply did not write.
--
-- TWO, AND THE LARGER ONE: ELEVEN OF THE TWENTY HAVE EXACTLY ONE PATH.
--
--     path aspects  1 -> 11 cultivators    2 -> 3    3 -> 6
--
-- Not an edge case - the majority case. Xue Wuzhi holds rule at 23,217
-- insight and food at 0, so this is not the ten-percent floor being strict;
-- there is genuinely one path. Every template in 0482 was written for two
-- voices, so for eleven people both voices came from the same path and the
-- name turned into a tautology. The templates were designed around the
-- cultivators I imagined rather than the ones in the table.
--
-- WHERE THE SECOND VOICE ACTUALLY COMES FROM. Of those eleven: ten have a
-- craft, two have a body, and all eleven have a root. The root is the
-- universal one and it is the wrong one - a root is rolled, not chosen, and
-- the brief was a Dao unique to the choices a character has made. So the
-- root stays an aspect, because it does feed understanding, and it does not
-- feed the name. The second voice is drawn from what was earned:
--
--     a second path   ->  both its adjective and its noun
--     else a body     ->  its adjective only
--     else a craft    ->  its adjective only
--     else            ->  one voice, and only the shapes that need one
--
-- Only a second PATH supplies a second noun. A craft's nouns are agent nouns
-- and tools - Delver, Refiner, Anvil, Gleaning - and 'The Dao of Law and
-- Delver' is not a title. They read correctly in the one position 0482 built
-- for them, which is the shape that opens with the craft.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Two words too close to stand in one title
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_clashes(p_a TEXT, p_b TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $fn$
WITH n AS (
    SELECT lower(translate(p_a, '-'' ', '')) AS a,
           lower(translate(p_b, '-'' ', '')) AS b
)
SELECT CASE
    WHEN p_a IS NULL OR p_b IS NULL THEN FALSE
    -- the same word
    WHEN n.a = n.b THEN TRUE
    -- the same stem: decree / decreed, refined / refinement
    WHEN left(n.a, 4) = left(n.b, 4) THEN TRUE
    -- a shared root buried anywhere: lifeblood / heartsblood, frost / hoarfrost
    ELSE EXISTS (
        SELECT 1
        FROM generate_series(1, greatest(length(n.a) - 4, 0)) AS g
        WHERE strpos(n.b, substr(n.a, g, 5)) > 0
    )
END
FROM n;
$fn$;

COMMENT ON FUNCTION dao_clashes(TEXT, TEXT) IS
    'Whether two vocabulary words are too close to appear in one Dao name. Equality is not enough: Decree beside Decreed and Lifeblood beside Heartsblood both passed an equality test and both read as a stutter.';


CREATE FUNCTION dao_pick_clear(p_items TEXT[], p_seed TEXT, p_avoid TEXT[])
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v_pool TEXT[];
    v_n    INTEGER;
    v_idx  INTEGER;
BEGIN
    IF p_items IS NULL OR array_length(p_items, 1) IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT array_agg(x ORDER BY x) INTO v_pool
    FROM unnest(p_items) AS x
    WHERE NOT EXISTS (
        SELECT 1 FROM unnest(COALESCE(p_avoid, ARRAY[]::TEXT[])) AS av
        WHERE av IS NOT NULL AND dao_clashes(x, av)
    );

    -- Every word clashed. Better a stutter than a hole in the title, and the
    -- probe below asserts this branch is never reached by anyone real.
    IF v_pool IS NULL OR array_length(v_pool, 1) IS NULL THEN
        SELECT array_agg(x ORDER BY x) INTO v_pool FROM unnest(p_items) AS x;
    END IF;

    v_n := array_length(v_pool, 1);
    v_idx := (('x' || substr(md5(p_seed), 1, 8))::bit(32)::BIGINT % v_n)::INTEGER + 1;
    RETURN v_pool[v_idx];
END;
$fn$;

COMMENT ON FUNCTION dao_pick_clear(TEXT[], TEXT, TEXT[]) IS
    'dao_pick against a set of words to stay clear of, by stem rather than by equality. Supersedes dao_pick for name composition.';


-- ---------------------------------------------------------------------------
-- Shapes for a cultivator with one path
-- ---------------------------------------------------------------------------

-- The eleven were being handed two-voice shapes and filling both halves from
-- one path. These need one path and read as titles rather than as templates.
INSERT INTO dao_templates (code, shape, weight) VALUES
    ('one_of',     'The Dao of the {adj1} {noun1}', 1.30),
    ('one_way',    '{noun1} of the {adj1} Way',     0.80),
    ('one_bodied', 'The {body_adj} {noun1} Dao',    0.60);


-- ---------------------------------------------------------------------------
-- Compose it again, knowing how many voices there are
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
    v_shape  TEXT;
    v_adj1   TEXT;
    v_adj2   TEXT;
    v_noun1  TEXT;
    v_noun2  TEXT;
    v_badj   TEXT;
    v_cnoun  TEXT;
    v_point  NUMERIC;
    v_total  NUMERIC;
    v_acc    NUMERIC := 0;
    v_two    BOOLEAN;      -- is there a second noun to be had
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

    -- A second noun exists only where a second path does. Everything else
    -- lends an adjective at most.
    v_two := v_path2 IS NOT NULL;

    -- Choose the shape from the shapes this cultivator can fill: a {noun2}
    -- needs a second path, a {body_adj} needs a body, a {craft_noun} needs a
    -- craft, and an {adj2} needs any one of the three.
    SELECT sum(weight) INTO v_total
    FROM dao_templates
    WHERE (strpos(shape, '{noun2}') = 0 OR v_two)
      AND (strpos(shape, '{body_adj}') = 0 OR v_body IS NOT NULL)
      AND (strpos(shape, '{craft_noun}') = 0 OR v_craft IS NOT NULL)
      AND (strpos(shape, '{adj2}') = 0
           OR v_two OR v_body IS NOT NULL OR v_craft IS NOT NULL);

    v_point := (('x' || substr(md5(v_sig || '/shape'), 1, 8))::bit(32)::BIGINT % 100000)
               / 100000.0 * v_total;

    FOR t IN
        SELECT shape, weight FROM dao_templates
        WHERE (strpos(shape, '{noun2}') = 0 OR v_two)
          AND (strpos(shape, '{body_adj}') = 0 OR v_body IS NOT NULL)
          AND (strpos(shape, '{craft_noun}') = 0 OR v_craft IS NOT NULL)
          AND (strpos(shape, '{adj2}') = 0
               OR v_two OR v_body IS NOT NULL OR v_craft IS NOT NULL)
        ORDER BY code
    LOOP
        v_acc := v_acc + t.weight;
        IF v_point < v_acc OR v_shape IS NULL THEN
            v_shape := t.shape;
            EXIT WHEN v_point < v_acc;
        END IF;
    END LOOP;

    -- The leading voice.
    SELECT dao_pick_clear(array_agg(word), v_sig || '/n1', NULL)
    INTO v_noun1 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'noun';

    SELECT dao_pick_clear(array_agg(word), v_sig || '/a1', ARRAY[v_noun1])
    INTO v_adj1 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'adjective';

    -- The second, from a second path if there is one, and otherwise from the
    -- body or the craft - both of which were earned, which is the point.
    IF v_two THEN
        SELECT dao_pick_clear(array_agg(word), v_sig || '/n2', ARRAY[v_noun1, v_adj1])
        INTO v_noun2 FROM dao_words
        WHERE source_kind = 'path' AND source_code = v_path2 AND role = 'noun';

        SELECT dao_pick_clear(array_agg(word), v_sig || '/a2',
                              ARRAY[v_noun1, v_adj1, v_noun2])
        INTO v_adj2 FROM dao_words
        WHERE source_kind = 'path' AND source_code = v_path2 AND role = 'adjective';
    ELSIF v_body IS NOT NULL THEN
        SELECT dao_pick_clear(array_agg(word), v_sig || '/a2b', ARRAY[v_noun1, v_adj1])
        INTO v_adj2 FROM dao_words
        WHERE source_kind = 'body' AND source_code = v_body AND role = 'adjective';
    ELSIF v_craft IS NOT NULL THEN
        SELECT dao_pick_clear(array_agg(word), v_sig || '/a2c', ARRAY[v_noun1, v_adj1])
        INTO v_adj2 FROM dao_words
        WHERE source_kind = 'craft' AND source_code = v_craft AND role = 'adjective';
    END IF;

    IF v_body IS NOT NULL THEN
        SELECT dao_pick_clear(array_agg(word), v_sig || '/b',
                              ARRAY[v_noun1, v_adj1, v_noun2, v_adj2])
        INTO v_badj FROM dao_words
        WHERE source_kind = 'body' AND source_code = v_body AND role = 'adjective';
    END IF;

    IF v_craft IS NOT NULL THEN
        SELECT dao_pick_clear(array_agg(word), v_sig || '/c',
                              ARRAY[v_noun1, v_adj1, v_noun2, v_adj2])
        INTO v_cnoun FROM dao_words
        WHERE source_kind = 'craft' AND source_code = v_craft AND role = 'noun';
    END IF;

    v_shape := replace(v_shape, '{adj1}',  COALESCE(v_adj1, ''));
    v_shape := replace(v_shape, '{adj2}',  COALESCE(v_adj2, ''));
    v_shape := replace(v_shape, '{noun1}', COALESCE(v_noun1, ''));
    v_shape := replace(v_shape, '{noun2}', COALESCE(v_noun2, ''));
    v_shape := replace(v_shape, '{body_adj}',   COALESCE(v_badj, ''));
    v_shape := replace(v_shape, '{craft_noun}', COALESCE(v_cnoun, ''));

    RETURN btrim(regexp_replace(v_shape, '\s+', ' ', 'g'));
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Read the twenty out loud, this time in SQL
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_name   TEXT;
    v_again  TEXT;
    v_words  TEXT[];
    v_bad    TEXT;
    v_n      INTEGER;
    v_sample TEXT;
    pl       RECORD;
    i        INTEGER;
    j        INTEGER;
BEGIN
    -- First the stem test itself, on the five titles that prompted it.
    IF NOT dao_clashes('Decree', 'Decreed')          THEN RAISE EXCEPTION 'decree/decreed'; END IF;
    IF NOT dao_clashes('Lifeblood', 'Heartsblood')   THEN RAISE EXCEPTION 'lifeblood/heartsblood'; END IF;
    IF NOT dao_clashes('Sanguine', 'Sanguine Tide')  THEN RAISE EXCEPTION 'sanguine/sanguine tide'; END IF;
    IF NOT dao_clashes('Frost', 'Hoarfrost')         THEN RAISE EXCEPTION 'frost/hoarfrost'; END IF;
    IF NOT dao_clashes('Refined', 'Refinement')      THEN RAISE EXCEPTION 'refined/refinement'; END IF;
    -- And that it is not so eager it rejects a good title.
    IF dao_clashes('Celestial Vault', 'Leash')       THEN RAISE EXCEPTION 'vault/leash'; END IF;
    IF dao_clashes('Governing', 'Heaven')            THEN RAISE EXCEPTION 'governing/heaven'; END IF;
    IF dao_clashes('Keen', 'Edge')                   THEN RAISE EXCEPTION 'keen/edge'; END IF;
    IF dao_clashes('Immovable', 'Severance')         THEN RAISE EXCEPTION 'immovable/severance'; END IF;

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

        -- No two vocabulary words inside one title share a stem. This is the
        -- check 0483 was missing, run over the finished name rather than over
        -- the pools it drew from.
        SELECT array_agg(w.word ORDER BY w.word) INTO v_words
        FROM dao_words w
        WHERE strpos(v_name, w.word) > 0;

        IF v_words IS NOT NULL AND array_length(v_words, 1) > 1 THEN
            FOR i IN 1 .. array_length(v_words, 1) - 1 LOOP
                FOR j IN i + 1 .. array_length(v_words, 1) LOOP
                    -- A longer word containing a shorter one is one word in
                    -- the title, not two: Edge inside Keen Steel's neighbour.
                    CONTINUE WHEN strpos(v_words[j], v_words[i]) > 0
                               OR strpos(v_words[i], v_words[j]) > 0;
                    IF dao_clashes(v_words[i], v_words[j]) THEN
                        RAISE EXCEPTION
                            'player % stutters: "%" holds both % and %',
                            pl.player_id, v_name, v_words[i], v_words[j];
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
    END LOOP;

    -- Every cultivator with one path now gets a one-voice shape, so nobody
    -- is left filling two halves from the same pool.
    SELECT count(*) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL
      AND (SELECT count(*) FROM dao_aspects(p.player_id) WHERE source_kind = 'path') = 1
      AND dao_name_of(p.player_id) IS NOT NULL;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'the eleven single-path cultivators stopped getting names';
    END IF;

    SELECT count(DISTINCT n) INTO v_n FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL) s;

    SELECT string_agg(s.n, ' / ') INTO v_sample FROM (
        SELECT dao_name_of(p.player_id) AS n FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL
        ORDER BY p.player_id LIMIT 3) s;

    RAISE NOTICE '% distinct Daos, none of them stuttering; e.g. %', v_n, v_sample;
END;
$probe$;
