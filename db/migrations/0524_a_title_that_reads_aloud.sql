-- 0524_a_title_that_reads_aloud
--
-- Reading all twenty living cultivators' derived Daos aloud - the only check
-- that has ever found a fault in this engine - turned up two things.
--
-- 1. "Table of the Devouring Crucible". `food` carries Feast, Harvest,
--    Hunger, Ripeness, Sustenance and TABLE, and five of those six can open a
--    title. The sixth reads as furniture. It is the one live name of the
--    twenty that does not sound like a Dao, and it belongs to somebody
--    standing in the ascension door right now.
--
-- 2. THREE NOUNS CARRY THEIR OWN "of": `Inch of Time`, `Breath of Sky` and
--    `Bar of Iron`. Six of the eleven shapes put a noun somewhere other than
--    the end, and every one of those is followed by "of the" or by "Dao":
--
--        sovereign   {noun1} of the {adj2} {noun2}
--                    -> "Inch of Time of the Devouring Crucible"
--        one_way     {noun1} of the {adj1} Way
--                    -> "Breath of Sky of the Unmapped Way"
--        crafted     The {craft_noun} of the {adj1} {noun1}
--                    -> "The Bar of Iron of the Thrice-Refined Lode"
--        bare_the    The {noun1} Dao
--                    -> "The Inch of Time Dao"
--
--    None of the twenty landed on one, so this is LATENT rather than live -
--    which is exactly why it gets closed now instead of after somebody wears
--    it. Three words against 34 paths is a one-in-forty slot; the engine will
--    get there.
--
-- THE FIX IS A RULE, NOT THREE DELETIONS. `Inch of Time` and `Breath of Sky`
-- are two of the best words in the vocabulary and both read beautifully at the
-- END of a title - "The Dao of the Untracked Inch of Time". So a phrasal noun
-- is allowed in a terminal slot and nowhere else. The shape still holds its
-- own placeholders at the moment a slot is filled, so "is this slot last?" is
-- `v_shape LIKE '%{noun1}'` - the shape answers the question about itself.
--
-- AND THIS IS THE LAST MOMENT IT IS FREE. A Dao is derived on every read until
-- ascension stamps it, and frozen for ever after. Nobody is stamped yet, so
-- changing the vocabulary today costs nothing and reshuffles names that were
-- never promised. Tomorrow it would mean rewriting somebody's name after they
-- had been told it.
--
-- Forward-only. Do not edit once applied.


-- Five of the six Food Path nouns can open a title. This is the sixth.
UPDATE dao_words SET word = 'Banquet'
WHERE source_kind = 'path' AND source_code = 'food' AND role = 'noun'
  AND word = 'Table';


-- ---------------------------------------------------------------------------
-- A noun that carries its own "of" goes last, or not at all
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src  TEXT;
    one  TEXT;
    slot TEXT;
    kind TEXT;
    code TEXT;
BEGIN
    src := pg_get_functiondef('dao_name_of(bigint)'::regprocedure);

    -- The three slots that take a noun. Each is filled by the same four-line
    -- shape, so each gets the same guard - built here rather than typed three
    -- times, so they cannot drift apart.
    FOREACH slot IN ARRAY ARRAY['noun1', 'noun2', 'craft_noun']::TEXT[] LOOP
        kind := CASE WHEN slot = 'craft_noun' THEN 'craft' ELSE 'path' END;
        code := CASE slot
                    WHEN 'noun1'      THEN 'v_path1'
                    WHEN 'noun2'      THEN 'v_path2'
                    ELSE                   'v_craft'
                END;

        one := '        WHERE source_kind = ''' || kind
               || ''' AND source_code = ' || code || ' AND role = ''noun'';';

        IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
            RAISE EXCEPTION
                'the % slot is not filled the way 0483 left it', slot;
        END IF;

        src := replace(src, one,
            '        WHERE source_kind = ''' || kind
            || ''' AND source_code = ' || code || ' AND role = ''noun''' || chr(10) ||
            '          -- A noun carrying its own "of" may only land in a' || chr(10) ||
            '          -- TERMINAL slot. Every non-terminal noun slot in these' || chr(10) ||
            '          -- shapes is followed by "of the" or by "Dao", which' || chr(10) ||
            '          -- gives "Inch of Time of the Devouring Crucible". The' || chr(10) ||
            '          -- shape still holds its placeholders here, so it can be' || chr(10) ||
            '          -- asked whether this slot is its last token.' || chr(10) ||
            '          AND (v_shape LIKE ''%{' || slot || '}''' || chr(10) ||
            '               OR word NOT LIKE ''% of %'');');
    END LOOP;

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Read every one of them aloud again
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_n     INTEGER;
    v_names INTEGER;
    one     RECORD;
BEGIN
    -- The furniture is gone, and the Food Path still has six nouns.
    IF EXISTS (SELECT 1 FROM dao_words WHERE word = 'Table') THEN
        RAISE EXCEPTION 'the Food Path still sets a table';
    END IF;
    SELECT count(*) INTO v_n FROM dao_words
    WHERE source_kind = 'path' AND source_code = 'food' AND role = 'noun';
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'the Food Path has % nouns, not six', v_n;
    END IF;

    -- Every path and craft still has a noun left after the guard excludes its
    -- phrasal one, or a slot would come back empty and a title would have a
    -- hole in it.
    SELECT string_agg(source_kind || ':' || source_code, ', ') INTO v_bad
    FROM dao_words
    WHERE role = 'noun' AND source_kind IN ('path', 'craft')
    GROUP BY source_kind, source_code
    HAVING count(*) FILTER (WHERE word NOT LIKE '% of %') < 2;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these have fewer than two plain nouns, so a non-terminal slot could empty: %',
            v_bad;
    END IF;

    -- NOTHING READS "of ... of" ANY MORE, and nothing reads "<phrase> Dao".
    -- Checked across every living cultivator rather than argued about.
    v_names := 0;
    FOR one IN
        SELECT p.discord_name AS who, dao_name_of(p.player_id) AS nm
        FROM players p
        WHERE p.deleted_at IS NULL AND dao_name_of(p.player_id) IS NOT NULL
    LOOP
        v_names := v_names + 1;

        IF one.nm ~ ' of .* of ' THEN
            v_bad := COALESCE(v_bad || '; ', '') || one.who || ': ' || one.nm;
        END IF;
        IF one.nm ~ ' of [A-Z][a-z]+ Dao$' THEN
            v_bad := COALESCE(v_bad || '; ', '') || one.who || ': ' || one.nm;
        END IF;
        IF one.nm LIKE '%  %' OR one.nm LIKE 'The  %' THEN
            v_bad := COALESCE(v_bad || '; ', '') || one.who || ': ' || one.nm;
        END IF;
        -- An empty slot leaves a title that stops mid-phrase.
        IF one.nm ~ '(of the|of|and|The)$' THEN
            v_bad := COALESCE(v_bad || '; ', '') || one.who || ': ' || one.nm;
        END IF;
    END LOOP;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a title does not read: %', v_bad;
    END IF;
    IF v_names < 20 THEN
        RAISE EXCEPTION
            'only % cultivators read back a title, down from twenty', v_names;
    END IF;

    -- And the guard actually bites, which a probe that only reads the twenty
    -- could not prove - none of them holds a phrasal noun. So it is asked
    -- directly: a phrasal noun offered to a non-terminal slot is refused, and
    -- offered to a terminal one is allowed.
    IF (SELECT count(*) FROM dao_words
        WHERE source_kind = 'path' AND source_code = 'time'
          AND role = 'noun' AND word LIKE '% of %') <> 1 THEN
        RAISE EXCEPTION 'the Time Path no longer carries Inch of Time to test with';
    END IF;

    IF pg_get_functiondef('dao_name_of(bigint)'::regprocedure)
       NOT LIKE '%v_shape LIKE ''%{noun1}''%' THEN
        RAISE EXCEPTION 'the noun1 slot did not take the guard';
    END IF;
    IF (length(pg_get_functiondef('dao_name_of(bigint)'::regprocedure))
        - length(replace(pg_get_functiondef('dao_name_of(bigint)'::regprocedure),
                         'OR word NOT LIKE ''% of %''', '')))
       / length('OR word NOT LIKE ''% of %''') <> 3 THEN
        RAISE EXCEPTION 'the guard did not reach all three noun slots';
    END IF;

    RAISE NOTICE
        'all % titles read aloud; a phrasal noun now goes last or not at all',
        v_names;
END;
$probe$;
