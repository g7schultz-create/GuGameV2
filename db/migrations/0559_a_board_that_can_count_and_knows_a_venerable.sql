-- 0559_a_board_that_can_count_and_knows_a_venerable
--
-- Two faults on the same screen, both reported from looking at it.
--
-- 1. THE BOARD PRINTS HASHES INSTEAD OF NUMBERS.
--
--        4  shinonn._.   Yellow Apricot Immortal - Mid
--                        #,###,###,### of #,###,###,###
--
--    Not a missing value and not a template that failed to fill. `to_char`
--    fills the WHOLE field with '#' when the number does not fit the mask,
--    and every mask on this board is ten digits:
--
--        to_char(pc.cultivation, 'FM9,999,999,999')
--
--    Rank 18 cultivation is 4,065,570,501,064,126,969 - nineteen digits. It
--    has not fitted for a long time, and the failure is silent by design:
--    `to_char` does not raise, it hashes. How far it has spread, measured:
--
--        wealth        10 of 10 rows
--        techniques     7 of 10 rows
--        cultivation    5 of 10 rows
--
--    The wealth board has been entirely unreadable.
--
--    Widening the five masks would fix today and break again at the next
--    realm, so this adds the formatter the schema never had. `thousands_of`
--    takes NUMERIC and carries enough digits to exceed what a BIGINT can
--    hold, so it cannot hash out - and it is one definition rather than five
--    literals to keep in step.
--
-- 2. NO VENERABLE SHOWS AS ONE.
--
--        1  sylvrime    Yellow Apricot Immortal - Peak
--        3  clearwest   Yellow Apricot Immortal - Peak
--
--    Both stand at 19. The headline joins `realms` by
--    `player_cultivation.realm_id`, and a Venerable never leaves realm_id 71
--    - so the board reads their body's realm, which is true and is not what
--    the column is for.
--
--    The same realm-for-standing confusion 0519 and 0536-0538 swept out of
--    the database and 0555's cog pass swept out of eight screens. This one
--    sat in a function and was missed by both, which is worth noting: the
--    SORT on this very board already reads `player_standing`, three lines
--    below the headline that does not. Venerables have been sorting to the
--    top of a board that calls them Yellow Apricots.


-- ---------------------------------------------------------------------------
-- 1. A number the board can always print
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION thousands_of(p_value NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    -- Twenty-seven digits, against a BIGINT maximum of nineteen. `to_char`
    -- hashes the whole field rather than truncating or raising, so the mask
    -- has to be generous or the failure is silent - which is exactly how
    -- `FM9,999,999,999` survived long enough to make a whole board unreadable.
    SELECT CASE
        WHEN p_value IS NULL THEN NULL
        ELSE trim(to_char(round(p_value), 'FM999,999,999,999,999,999,999,999,999'))
    END;
$fn$;

COMMENT ON FUNCTION thousands_of(NUMERIC) IS
    'A number with thousands separators, wide enough that `to_char` cannot hash the field. Use this rather than writing a mask: a literal mask is a ceiling, and this schema has repeatedly outgrown them silently.';


-- ---------------------------------------------------------------------------
-- 2. A headline that reads standing
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    n       INTEGER;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'leaderboard' AND pronamespace = 'public'::regnamespace;

    patched := src;

    -- The headline. `r.name` stays as the fallback, because a cultivator who
    -- has not crossed still reads their realm and that is correct.
    IF position('               r.name AS headline,' IN patched) = 0 THEN
        RAISE EXCEPTION 'the cultivation headline is not where it was';
    END IF;
    patched := replace(patched,
'               r.name AS headline,',
'               -- STANDING, not the realm beneath it. A Venerable never
               -- leaves realm_id 71, so this read "Yellow Apricot Immortal"
               -- for somebody standing at 19 - while `sort_value` three lines
               -- down already used `player_standing`, so they sorted to the
               -- top of a board that would not name them. See 0559.
               COALESCE(
                   (SELECT v.name FROM venerable_ranks v
                    WHERE v.rank = player_standing(a.player_id)),
                   r.name
               ) AS headline,');

    -- Every mask, in one sweep. Counted rather than assumed: a mask left
    -- behind is a column that hashes out again at the next realm.
    n := (length(patched) - length(replace(patched, '''FM9,999,999,999''', '')))
         / length('''FM9,999,999,999''');
    IF n <> 5 THEN
        RAISE EXCEPTION
            'expected 5 ten-digit masks on the board and found %', n;
    END IF;

    patched := replace(patched,
        'to_char(pc.cultivation, ''FM9,999,999,999'')',
        'thousands_of(pc.cultivation)');
    patched := replace(patched,
        'to_char(cultivation_ceiling(a.player_id), ''FM9,999,999,999'')',
        'thousands_of(cultivation_ceiling(a.player_id))');
    patched := replace(patched,
        'to_char(sum(s.damage), ''FM9,999,999,999'')',
        'thousands_of(sum(s.damage))');
    patched := replace(patched,
        'to_char(COALESCE(stones.quantity, 0), ''FM9,999,999,999'')',
        'thousands_of(COALESCE(stones.quantity, 0))');
    patched := replace(patched,
        'to_char(jade_held(a.player_id), ''FM9,999,999,999'')',
        'thousands_of(jade_held(a.player_id))');
    patched := replace(patched,
        'to_char(max(t.base_power), ''FM9,999,999'')',
        'thousands_of(max(t.base_power))');

    IF position('FM9,999,999' IN patched) > 0 THEN
        RAISE EXCEPTION 'a ten-digit mask survived the sweep';
    END IF;
    IF patched = src THEN
        RAISE EXCEPTION 'the leaderboard patch changed nothing';
    END IF;

    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_board TEXT;
    v_n     INTEGER;
    v_row   RECORD;
    v_seen  INTEGER := 0;
BEGIN
    -- 1. THE FORMATTER CANNOT HASH, at the largest number the game can hold.
    IF thousands_of(9223372036854775807::numeric) <> '9,223,372,036,854,775,807' THEN
        RAISE EXCEPTION
            'the formatter gave % for a bigint maximum',
            thousands_of(9223372036854775807::numeric);
    END IF;
    IF thousands_of(0) <> '0' OR thousands_of(NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'the formatter mishandles zero or null';
    END IF;

    -- 2. NO BOARD PRINTS A HASH ANY MORE. Every board, against the live world,
    --    which is the only place the overflow was visible.
    FOREACH v_board IN ARRAY ARRAY['cultivation', 'damage', 'wealth',
                                   'crafting', 'techniques'] LOOP
        EXECUTE format(
            'SELECT count(*) FROM leaderboard(%L) '
            'WHERE headline LIKE ''%%#%%'' OR detail LIKE ''%%#%%''', v_board)
        INTO v_n;
        IF v_n > 0 THEN
            RAISE EXCEPTION '% rows of the % board still hash out', v_n, v_board;
        END IF;
    END LOOP;
    RAISE NOTICE 'five boards, no hashed fields';

    -- 3. AND A VENERABLE IS NAMED AS ONE. Asserted against whoever actually
    --    stands above the realm ladder rather than a name written here.
    FOR v_row IN
        SELECT b.discord_name, b.headline, player_standing(b.player_id) AS std
        FROM leaderboard('cultivation') b
        WHERE player_standing(b.player_id) > (SELECT max(rank) FROM realms)
    LOOP
        v_seen := v_seen + 1;
        IF NOT EXISTS (SELECT 1 FROM venerable_ranks v
                       WHERE v.name = v_row.headline) THEN
            RAISE EXCEPTION
                '% stands at % and the board calls them "%"',
                v_row.discord_name, v_row.std, v_row.headline;
        END IF;
    END LOOP;

    IF v_seen = 0 THEN
        RAISE NOTICE
            'nobody stands above the realm ladder, so the headline was not tested';
    ELSE
        RAISE NOTICE '% Venerable(s) named by their rung', v_seen;
    END IF;

    -- 4. AND EVERYBODY ELSE STILL READS THEIR REALM.
    FOR v_row IN
        SELECT b.discord_name, b.headline
        FROM leaderboard('cultivation') b
        WHERE player_standing(b.player_id) <= (SELECT max(rank) FROM realms)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM realms r WHERE r.name = v_row.headline) THEN
            RAISE EXCEPTION
                '% is not a Venerable and the board calls them "%"',
                v_row.discord_name, v_row.headline;
        END IF;
    END LOOP;
END
$probe$;
