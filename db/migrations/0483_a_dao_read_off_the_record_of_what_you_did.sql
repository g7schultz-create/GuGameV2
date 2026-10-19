-- 0483_a_dao_read_off_the_record_of_what_you_did
--
-- Phase 2 of the Venerable spec, second half: the derivation. Given a
-- cultivator, produce their Dao - the aspects, and the name composed from
-- them. Read-only, derived fresh every call, and reachable only through an
-- owner-gated command until the realm ships.
--
-- A Dao is not chosen from a menu. It is read off what the character already
-- did, from six records that already exist:
--
--     player_path_attainment    the paths walked
--     player_physique          the body forged
--     player_skills            the craft levelled
--     player_character         the root born with
--     player_destinies         the destinies taken
--     player_gu                the worms kept
--
-- WHAT I MEASURED BEFORE CHOOSING ANY OF THIS, because three of the six
-- columns I expected to use turned out to be dead or misleading:
--
--   dao_marks is zero for all 192 attainment rows. Nothing writes it. It is
--   the obvious-looking measure of "how much is this path yours" and it is
--   not a measure of anything. insight is: across player 5365's 34 paths it
--   runs 2,741,486 down to 4,776, a spread of 574x, and tier is derived from
--   it. So insight orders the paths and tier is ignored - tier caps at 10 and
--   four of 5365's paths are tied there.
--
--   Everyone holds seventeen destinies and the sets largely agree -
--   killing_intent, sea_of_bitterness, heaven_defying appear on nearly every
--   cultivator. Seventeen rolls against a pool of sixty is 28% of the pool,
--   so a destiny being rare by design does not make it rare in practice.
--   Destinies are therefore the WEAKEST of the six axes, not the strongest,
--   and they are scored by how hard the destiny was to reach rather than
--   merely held: (1 - roll_weight) * (1 + min_rank/18). Two at most.
--
--   player_gu records gu_id, owner_id, gu_type_id, stars, harmony, found_in,
--   got_at. There is no usage counter anywhere. The spec says this axis is
--   "fed by using them rather than hoarding them" and the game does not
--   record using them. So the gu aspect names the strongest worm held, which
--   is a statement about hoarding, and this is the one axis of the six that
--   is standing on a measure it was not meant to have. Flagged rather than
--   papered over: it wants a cast counter before the realm ships.
--
-- WEIGHT MEANS ONE THING: how far this aspect dominates its own axis. A path
-- at the top of your insight scores 1.0; one at a tenth of it scores 0.1. A
-- craft is its share of your total craft levels, so a specialist scores high
-- and a generalist low. An axis with one occupant - body, root - is fully
-- dominated by it. Without a single definition the number would be six
-- different numbers wearing one column name.
--
-- THE NAME IS COMPOSED, NEVER TYPED. It is also STABLE: every choice is made
-- by md5 of a signature built from the player and their own aspect codes, so
-- reading a Dao twice reads the same Dao. It changes only when the aspects
-- change - which is the open question the spec flagged, and the answer when
-- ascension ships is to stamp the name at that moment rather than keep
-- deriving it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The seventh craft, and how much a rarity is worth
-- ---------------------------------------------------------------------------

-- player_skills is a view: six rows from player_professions UNION ALL a
-- synthetic 'refinement' row from player_refinement. So the game has seven
-- crafts and the professions table has six, and 0482 seeded words against
-- professions. Reading player_professions instead would silently drop
-- refinement from every refiner's Dao; seeding the gap and reading the view
-- keeps one definition of "a craft and its level".
--
-- Note 'refinement' is also a path code. source_kind is what keeps them apart.
INSERT INTO dao_words (source_kind, source_code, word, role) VALUES
    ('craft','refinement','Crucible-Tending','adjective'),
    ('craft','refinement','Thrice-Refined','adjective'),
    ('craft','refinement','Refiner','noun'),
    ('craft','refinement','Crucible','noun');


CREATE TABLE dao_rarity_weight (
    rarity TEXT PRIMARY KEY,
    weight NUMERIC(4,3) NOT NULL,
    CHECK (weight > 0 AND weight <= 1)
);

COMMENT ON TABLE dao_rarity_weight IS
    'How defining a rarity is. A table rather than a CASE inside a function, because the next thing that needs to rank rarities should read it here instead of writing a second ladder.';

INSERT INTO dao_rarity_weight (rarity, weight) VALUES
    ('common',    0.200),
    ('uncommon',  0.350),
    ('rare',      0.500),
    ('epic',      0.650),
    ('legendary', 0.800),
    ('mythic',    0.900),
    ('unique',    0.950),
    ('divine',    1.000);


-- ---------------------------------------------------------------------------
-- A choice that is made the same way every time
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_pick(p_items TEXT[], p_seed TEXT, p_avoid TEXT DEFAULT NULL)
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

    -- Dropping the avoided word is what stops "the Dao of Edge and Edge"
    -- when both halves of a name are drawn from the same path. If avoiding it
    -- would empty the pool, the collision is better than nothing.
    SELECT array_agg(x ORDER BY x) INTO v_pool
    FROM unnest(p_items) AS x
    WHERE p_avoid IS NULL OR x <> p_avoid;

    IF v_pool IS NULL OR array_length(v_pool, 1) IS NULL THEN
        v_pool := p_items;
    END IF;

    v_n := array_length(v_pool, 1);
    v_idx := (('x' || substr(md5(p_seed), 1, 8))::bit(32)::BIGINT % v_n)::INTEGER + 1;
    RETURN v_pool[v_idx];
END;
$fn$;

COMMENT ON FUNCTION dao_pick(TEXT[], TEXT, TEXT) IS
    'Deterministic choice from a word list. The pool is sorted before indexing so the result does not depend on the order the caller happened to aggregate in.';


-- ---------------------------------------------------------------------------
-- The aspects
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_aspects(p_player_id BIGINT)
RETURNS TABLE (
    ordinal     INTEGER,
    source_kind TEXT,
    source_code TEXT,
    label       TEXT,
    weight      NUMERIC,
    feeds       TEXT
)
LANGUAGE sql STABLE AS $fn$
-- One CTE per axis, because an ORDER BY ... LIMIT written against the last
-- branch of a UNION ALL binds to the whole union instead - which is exactly
-- how this function failed the first time it ran.
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
a_path AS (
    -- The paths walked. Top three by insight, and nothing below a tenth of
    -- the leader: a path at 0.2% of your best is a path you dabbled in, not
    -- an aspect of your Dao. Player 5365 holds all thirty-four; this takes
    -- food, refinement and heaven and leaves the other thirty-one out.
    SELECT 1 AS kind_rank,
           row_number() OVER (ORDER BY pa.insight DESC, pa.path_code) AS within,
           'path'::TEXT AS source_kind, pa.path_code AS source_code,
           p.name AS label,
           round(pa.insight::NUMERIC / lp.top, 3) AS weight,
           'casting techniques of this path in a real fight'::TEXT AS feeds
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
    -- The body forged. One axis, one occupant.
    SELECT 2, 1::BIGINT, 'body'::TEXT, pp.body_path, b.name, 1.000::NUMERIC,
           'damage taken and lived through'::TEXT
    FROM player_physique pp
    JOIN body_paths b ON b.code = pp.body_path
    WHERE pp.player_id = p_player_id AND pp.body_path IS NOT NULL
),
a_craft AS (
    -- The craft levelled, weighted by how much of your craft is this craft.
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
    -- The root born with, weighted by how rare a thing it is to be born.
    SELECT 4, 1::BIGINT, 'root'::TEXT, r.code, r.name,
           COALESCE(rw.weight, 0.200)::NUMERIC,
           'whatever the root was always for'::TEXT
    FROM player_character pc
    JOIN roots r ON r.code = pc.root_code
    LEFT JOIN dao_rarity_weight rw ON rw.rarity = r.rarity
    WHERE pc.player_id = p_player_id AND pc.root_code IS NOT NULL
),
a_destiny AS (
    -- The destinies taken - the two that were hardest to reach, scored by
    -- design rarity and the rank that gates them. The weakest axis of the
    -- six: everybody holds seventeen and the sets largely agree.
    SELECT 5,
           row_number() OVER (
               ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code),
           'destiny'::TEXT, d.code, d.name,
           round(least(1.0, (1 - d.roll_weight) * (1 + d.min_rank / 18.0)), 3),
           'the deeds the destiny names'::TEXT
    FROM player_destinies pdx
    JOIN destinies d ON d.code = pdx.code
    WHERE pdx.player_id = p_player_id AND pdx.chosen_at IS NOT NULL
    ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code
    LIMIT 2
),
a_gu AS (
    -- The worm kept. Standing on stars because nothing counts casts - see
    -- the header. This axis is provisional and knows it.
    SELECT 6, 1::BIGINT, 'gu'::TEXT, gt.code, gt.name,
           round(pg.stars::NUMERIC / 5, 3),
           'using the worm rather than keeping it'::TEXT
    FROM player_gu pg
    JOIN gu_types gt ON gt.gu_type_id = pg.gu_type_id
    WHERE pg.owner_id = p_player_id
    ORDER BY gt.rank DESC, pg.stars DESC, gt.code
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

COMMENT ON FUNCTION dao_aspects(BIGINT) IS
    'The aspects of a cultivator Dao, read off six existing records. weight is dominance within the aspect own axis, on one scale for all six kinds. Derived fresh - nothing is stored until ascension stamps it.';


-- ---------------------------------------------------------------------------
-- The name
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_name_of(p_player_id BIGINT)
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
    t        RECORD;
BEGIN
    -- The signature. Built from the player and their own aspect codes, so the
    -- name is stable across reads and still differs between cultivators who
    -- arrived at the same pair of paths by different routes.
    SELECT string_agg(a.source_kind || ':' || a.source_code, '|' ORDER BY a.ordinal)
    INTO v_sig
    FROM dao_aspects(p_player_id) a;

    IF v_sig IS NULL THEN
        RETURN NULL;   -- nothing walked, nothing forged: no Dao to read
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

    -- One path is enough: the second half of the name draws from the same
    -- path, and dao_pick refuses to repeat the word it is given to avoid.
    v_path2 := COALESCE(v_path2, v_path1);

    SELECT source_code INTO v_body
    FROM dao_aspects(p_player_id) WHERE source_kind = 'body' LIMIT 1;
    SELECT source_code INTO v_craft
    FROM dao_aspects(p_player_id) WHERE source_kind = 'craft' LIMIT 1;

    -- Pick the shape before the words, and only from shapes this cultivator
    -- can actually fill. A bodyless character offered 'The {body_adj} Dao of
    -- ...' would render the placeholder, which is the classic way a composed
    -- name betrays itself.
    SELECT sum(weight) INTO v_total
    FROM dao_templates
    WHERE (strpos(shape, '{body_adj}') = 0 OR v_body IS NOT NULL)
      AND (strpos(shape, '{craft_noun}') = 0 OR v_craft IS NOT NULL);

    v_point := (('x' || substr(md5(v_sig || '/shape'), 1, 8))::bit(32)::BIGINT % 100000)
               / 100000.0 * v_total;

    FOR t IN
        SELECT shape, weight FROM dao_templates
        WHERE (strpos(shape, '{body_adj}') = 0 OR v_body IS NOT NULL)
          AND (strpos(shape, '{craft_noun}') = 0 OR v_craft IS NOT NULL)
        ORDER BY code
    LOOP
        v_acc := v_acc + t.weight;
        IF v_point < v_acc OR v_shape IS NULL THEN
            v_shape := t.shape;
            EXIT WHEN v_point < v_acc;
        END IF;
    END LOOP;

    SELECT dao_pick(array_agg(word), v_sig || '/a1')
    INTO v_adj1 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'adjective';

    SELECT dao_pick(array_agg(word), v_sig || '/n1')
    INTO v_noun1 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path1 AND role = 'noun';

    SELECT dao_pick(array_agg(word), v_sig || '/a2', v_adj1)
    INTO v_adj2 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path2 AND role = 'adjective';

    SELECT dao_pick(array_agg(word), v_sig || '/n2', v_noun1)
    INTO v_noun2 FROM dao_words
    WHERE source_kind = 'path' AND source_code = v_path2 AND role = 'noun';

    IF v_body IS NOT NULL THEN
        SELECT dao_pick(array_agg(word), v_sig || '/b')
        INTO v_badj FROM dao_words
        WHERE source_kind = 'body' AND source_code = v_body AND role = 'adjective';
    END IF;

    IF v_craft IS NOT NULL THEN
        SELECT dao_pick(array_agg(word), v_sig || '/c')
        INTO v_cnoun FROM dao_words
        WHERE source_kind = 'craft' AND source_code = v_craft AND role = 'noun';
    END IF;

    v_shape := replace(v_shape, '{adj1}',  v_adj1);
    v_shape := replace(v_shape, '{adj2}',  v_adj2);
    v_shape := replace(v_shape, '{noun1}', v_noun1);
    v_shape := replace(v_shape, '{noun2}', v_noun2);
    v_shape := replace(v_shape, '{body_adj}',   COALESCE(v_badj, ''));
    v_shape := replace(v_shape, '{craft_noun}', COALESCE(v_cnoun, ''));

    RETURN v_shape;
END;
$fn$;

COMMENT ON FUNCTION dao_name_of(BIGINT) IS
    'The composed name of a cultivator Dao. Stable: every choice is md5 of a signature built from the player and their aspect codes. Returns NULL for a character who has walked no path.';


-- ---------------------------------------------------------------------------
-- Run it against the people who actually exist
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n      INTEGER;
    v_names  INTEGER;
    v_first  TEXT;
    v_second TEXT;
    v_sample TEXT;
    pl       RECORD;
BEGIN
    -- Nobody with a history reads back as having no Dao, and nobody's name
    -- comes back with a placeholder still in it.
    FOR pl IN
        SELECT p.player_id
        FROM players p
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_path_attainment pa
                      WHERE pa.player_id = p.player_id AND pa.insight > 0)
    LOOP
        SELECT count(*) INTO v_n FROM dao_aspects(pl.player_id);
        IF v_n = 0 THEN
            RAISE EXCEPTION 'player % walked a path and has no aspects', pl.player_id;
        END IF;

        -- At most three paths, one body, one craft, one root, two destinies,
        -- one worm. A Dao with eleven aspects is a list, not a Dao.
        IF v_n > 9 THEN
            RAISE EXCEPTION 'player % read back % aspects', pl.player_id, v_n;
        END IF;

        v_first := dao_name_of(pl.player_id);
        IF v_first IS NULL THEN
            RAISE EXCEPTION 'player % has aspects and no name', pl.player_id;
        END IF;
        IF strpos(v_first, '{') > 0 OR strpos(v_first, '}') > 0 THEN
            RAISE EXCEPTION 'player % got an unfilled name: %', pl.player_id, v_first;
        END IF;
        IF v_first ~ '  ' OR v_first <> btrim(v_first) THEN
            RAISE EXCEPTION 'player % got a name with a hole in it: %',
                pl.player_id, v_first;
        END IF;

        -- Stability is the whole premise. Read it twice.
        v_second := dao_name_of(pl.player_id);
        IF v_first <> v_second THEN
            RAISE EXCEPTION 'player % read two Daos: % then %',
                pl.player_id, v_first, v_second;
        END IF;

        -- No weight outside the one scale every kind shares.
        IF EXISTS (SELECT 1 FROM dao_aspects(pl.player_id)
                   WHERE weight <= 0 OR weight > 1) THEN
            RAISE EXCEPTION 'player % has an aspect weighted off the scale', pl.player_id;
        END IF;

        -- The leading aspect is the path you are strongest in, at weight 1.
        IF NOT EXISTS (SELECT 1 FROM dao_aspects(pl.player_id)
                       WHERE ordinal = 1 AND source_kind = 'path' AND weight = 1.000) THEN
            RAISE EXCEPTION 'player % does not lead with their strongest path', pl.player_id;
        END IF;
    END LOOP;

    -- And the vocabulary reaches every path somebody actually leads with.
    IF EXISTS (
        SELECT 1 FROM player_path_attainment pa
        WHERE pa.insight > 0
          AND NOT EXISTS (SELECT 1 FROM dao_words w
                          WHERE w.source_kind = 'path' AND w.source_code = pa.path_code)
    ) THEN
        RAISE EXCEPTION 'a path somebody has walked has no words';
    END IF;

    -- Likewise every craft the view can report, including the seventh one
    -- that lives outside the professions table.
    IF EXISTS (
        SELECT 1 FROM player_skills ps
        WHERE ps.level > 0
          AND NOT EXISTS (SELECT 1 FROM dao_words w
                          WHERE w.source_kind = 'craft' AND w.source_code = ps.skill)
    ) THEN
        RAISE EXCEPTION 'a craft somebody has levelled has no words';
    END IF;

    SELECT count(*) INTO v_names FROM (
        SELECT DISTINCT dao_name_of(p.player_id) AS n
        FROM players p WHERE p.deleted_at IS NULL
          AND dao_name_of(p.player_id) IS NOT NULL) s;

    SELECT string_agg(s.n, ' / ') INTO v_sample FROM (
        SELECT dao_name_of(p.player_id) AS n
        FROM players p WHERE p.deleted_at IS NULL
          AND dao_name_of(p.player_id) IS NOT NULL
        ORDER BY p.player_id LIMIT 4) s;

    RAISE NOTICE '% distinct Daos among the living; e.g. %', v_names, v_sample;
END;
$probe$;
