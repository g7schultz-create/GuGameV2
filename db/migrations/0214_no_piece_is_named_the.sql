-- 0214_no_piece_is_named_the
--
-- 0213 names a found piece after whatever was guarding it, by taking the first
-- word of the boss. Four of the nine bosses are called "The something" - The
-- Severed Star, The Lacquered Tyrant, The Hour That Did Not Pass, The First Gu
-- - so the word it took was "The", and the rank 5 room turned out a
-- "Heavenly Mirage The Robe".
--
-- The article is dropped before the word is taken. Severed, Lacquered, Hour,
-- First: all four say what killed you, which is the whole point of naming a
-- piece after it.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_spoils_for';

    old := 'split_part(
                                           (SELECT cs.name FROM dungeons d';
    new := 'split_part(regexp_replace(
                                           (SELECT cs.name FROM dungeons d';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_spoils_for no longer names a piece the old way';
    END IF;
    src := replace(src, old, new);

    old := 'WHERE d.realm_rank = p_rank), '' '', 1), ''''), ''Dungeon''));';
    new := 'WHERE d.realm_rank = p_rank), ''^The '', ''''), '' '', 1), ''''), ''Dungeon''));';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_spoils_for no longer takes the first word the old way';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    who BIGINT;
    r   SMALLINT;
    n   INTEGER;
BEGIN
    -- The four that were wrong, read straight off the table rather than
    -- trusted: every boss must give up a word that is not an article.
    SELECT count(*) INTO n FROM dungeons d
    JOIN creature_species cs ON cs.species_id = d.species_id
    WHERE split_part(regexp_replace(cs.name, '^The ', ''), ' ', 1) IN ('The', '');
    IF n > 0 THEN
        RAISE EXCEPTION '% bosses still name a piece after an article', n;
    END IF;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to loot for; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- And nothing that comes out of a room is called The anything.
        FOR r IN 1..9 LOOP
            FOR i IN 1..8 LOOP
                PERFORM dungeon_spoils_for(who, r::smallint, 11.0);
            END LOOP;
        END LOOP;

        SELECT count(*) INTO n FROM player_equipment e
        WHERE e.owner_id = who AND e.name LIKE '% The %';
        IF n > 0 THEN
            RAISE EXCEPTION '% pieces are named after an article', n;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
