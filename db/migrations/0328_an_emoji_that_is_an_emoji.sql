-- 0328_an_emoji_that_is_an_emoji
--
-- clearwest could not add a beast material to the anvil. Pressing "Add part"
-- returned "GuV2 didn't respond in time" every time, on a Blacksmith of 137
-- with a hundred and twelve pieces forged.
--
-- Nothing was slow. `fetch_parts` runs in 1.9ms and returns forty rows, and
-- `PagedPicker` slices them to twenty-five before any select is built. The
-- handler never got as far as answering, because building the menu threw:
--
--     emoji=r["emoji"][:1] if r["emoji"] else None
--
-- and two of the materials it was drawing carry this as their emoji:
--
--     immortal_soul_ember    \U0001f505
--     sovereign_fang         \U0001f9b7
--
-- Ten characters of literal escape text, not an emoji. Sliced to one
-- character that is a single backslash, which Discord will not accept as a
-- component emoji - so the interaction died before it could be answered, and
-- the only thing the player saw was the bot failing to respond.
--
-- I WROTE BOTH OF THESE. 0316 put eight beast parts in with '\U0001f...' in
-- the emoji column and 0317 put in four ores the same way. A standard SQL
-- string literal does not interpret backslash escapes - that needs E'' - so
-- Postgres stored exactly the characters it was given, which is the correct
-- thing for it to have done with what it was handed.
--
-- Why it surfaced now: the rarest parts sort first. `fetch_parts` orders by
-- `material_grade(m.rarity) DESC`, so a legendary and an epic sit on page one
-- of the picker. Anybody who had hunted the deep country since 0316 could not
-- open the parts menu at all, and the four ores would have done the same to
-- the metal menu the moment somebody mined tier 8.
--
-- The repair reads the escape rather than retyping the emoji. Hand-copying
-- twelve code points is twelve more chances to make the same class of
-- mistake; decoding '\U0001f505' into its character cannot disagree with what
-- the migration meant, because it IS what the migration meant.
--
-- Forward-only. Do not edit once applied.


-- `left()` rather than LIKE: in a LIKE pattern the backslash is itself the
-- escape character, so 'chr(92) || U%' reads as a literal 'U' and matches
-- nothing that starts with a backslash at all. The first attempt at this
-- migration updated zero rows and its own probe caught it.
UPDATE materials
SET emoji = chr(('x' || substr(emoji, 3))::bit(32)::int)
WHERE left(emoji, 2) = chr(92) || 'U'
  AND substr(emoji, 3) ~ '^[0-9a-fA-F]{8}$';


-- ---------------------------------------------------------------------------
-- No emoji column holds anything that is not one
-- ---------------------------------------------------------------------------

-- Sixteen tables carry an `emoji` column and every one of them feeds a
-- Discord component sooner or later, where a bad value is not a cosmetic
-- problem - it is a button that kills the interaction it is attached to. A
-- backslash is never part of an emoji, so it is a cheap and exact tell.
DO $probe$
DECLARE
    bad TEXT;
    sql TEXT;
BEGIN
    SELECT string_agg(format(
        'SELECT %L || %L AS where_at, %I AS value FROM %I'
        ' WHERE strpos(%I, chr(92)) > 0',
        c.table_name, '.' || c.column_name, c.column_name,
        c.table_name, c.column_name), ' UNION ALL ')
    INTO sql
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND c.column_name = 'emoji';

    EXECUTE 'SELECT string_agg(where_at || ' || quote_literal(' = ')
            || ' || value, ' || quote_literal(', ') || ') FROM (' || sql || ') z'
    INTO bad;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are escape text rather than emoji: %', bad;
    END IF;

    RAISE NOTICE 'every emoji column holds an emoji';
END;
$probe$;


-- And the twelve are specifically gone: one character each, no backslash.
DO $probe$
DECLARE
    n INTEGER;
BEGIN
    SELECT count(*) INTO n FROM materials
    WHERE code IN ('titan_hide', 'void_fang', 'phoenix_down', 'abyssal_core',
                   'dragon_whale_heart', 'immortal_soul_ember',
                   'primordial_blood', 'sovereign_fang',
                   'glacier_heart_adamant', 'sun_core_adamant',
                   'leviathan_spine_ore', 'plague_sovereign_ore')
      AND length(emoji) = 1;

    IF n <> 12 THEN
        RAISE EXCEPTION 'only % of the twelve now carry a single character', n;
    END IF;

    RAISE NOTICE 'all twelve of 0316 and 0317 now carry a real emoji';
END;
$probe$;
