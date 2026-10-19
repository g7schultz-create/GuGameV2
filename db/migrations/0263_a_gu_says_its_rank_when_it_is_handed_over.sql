-- 0263_a_gu_says_its_rank_when_it_is_handed_over
--
-- A Gu arrives as a name and nothing else. "You found a Frost Mite Gu" tells a
-- player nothing about whether to be pleased: rank 1 and rank 9 read
-- identically in the haul, and the only way to find out which you got is to
-- open /gu and compare it against what you are already wearing.
--
-- Rank is the answer to that question. It runs 1 to 9 against the same ladder
-- the realms use - a rank 4 Gu is Golden Core work - so it is a number players
-- already know how to read, unlike rarity, which varies within a rank.
--
-- Four places hand a Gu over and each built its own label out of `t.name`:
-- the dungeon's ordinary roll, the dungeon jackpot, the horde chest and the
-- King's chest. Four copies of one sentence is four places for the wording to
-- drift, so this adds `gu_label()` and points all four at it. The two places
-- that announce a Gu in Python - the hunt drop and the refining bench - say
-- the same thing in the same order.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION gu_label(p_gu_type_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT t.name || ' ' || chr(183) || ' rank ' || t.rank
    FROM gu_types t
    WHERE t.gu_type_id = p_gu_type_id;
$$;

COMMENT ON FUNCTION gu_label(BIGINT) IS
    'How a Gu names itself where it is handed over: name, then the rank that says whether to be pleased about it. One definition, because four copies of a sentence is four places for it to drift.';


-- ---------------------------------------------------------------------------
-- The dungeon: the ordinary roll and the jackpot
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'dungeon_spoils_for';

    old := '            got := got || jsonb_build_object(''gu'',
                (SELECT t.name FROM gu_types t WHERE t.gu_type_id = made));';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the dungeon no longer names its Gu the old way';
    END IF;
    src := replace(src, old,
'            got := got || jsonb_build_object(''gu'', gu_label(made));');

    old := '            got := got || jsonb_build_object(''jackpot'',
                (SELECT t.name FROM gu_types t WHERE t.gu_type_id = made));';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the dungeon no longer names its jackpot the old way';
    END IF;
    src := replace(src, old,
'            got := got || jsonb_build_object(''jackpot'', gu_label(made));');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- The horde: the wave chest and the King's
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'horde_chest_take';

    old := '                worms := worms || (SELECT t.name FROM gu_types t
                                   WHERE t.gu_type_id = made);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the horde chest no longer names its Gu the old way';
    END IF;
    src := replace(src, old, '                worms := worms || gu_label(made);');

    old := '            worms := worms || (SELECT t.name FROM gu_types t
                               WHERE t.gu_type_id = made);';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'the King''s chest no longer names its Gu the old way';
    END IF;
    src := replace(src, old, '            worms := worms || gu_label(made);');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- What the label actually says
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    lowest  BIGINT;
    highest BIGINT;
    label   TEXT;
BEGIN
    SELECT t.gu_type_id INTO lowest
    FROM gu_types t ORDER BY t.rank ASC, t.gu_type_id LIMIT 1;
    SELECT t.gu_type_id INTO highest
    FROM gu_types t ORDER BY t.rank DESC, t.gu_type_id LIMIT 1;

    label := gu_label(lowest);
    IF label IS NULL OR label NOT LIKE '%rank 1' THEN
        RAISE EXCEPTION 'the weakest Gu labels itself as %', label;
    END IF;

    label := gu_label(highest);
    IF label IS NULL OR label NOT LIKE '%rank 9' THEN
        RAISE EXCEPTION 'the strongest Gu labels itself as %', label;
    END IF;

    -- The name is still in there. A label that lost it would be worse than
    -- one that never carried a rank.
    IF position((SELECT t.name FROM gu_types t WHERE t.gu_type_id = highest)
                IN label) = 0 THEN
        RAISE EXCEPTION 'the label dropped the name: %', label;
    END IF;

    -- And every Gu in the game has one, so no haul can print a NULL.
    IF EXISTS (SELECT 1 FROM gu_types t WHERE gu_label(t.gu_type_id) IS NULL) THEN
        RAISE EXCEPTION 'some Gu cannot say what they are';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- And that the four sites now use it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    silent TEXT[];
BEGIN
    SELECT array_agg(p.proname ORDER BY p.proname) INTO silent
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('dungeon_spoils_for', 'horde_chest_take')
      AND p.prosrc NOT LIKE '%gu_label(%';

    IF silent IS NOT NULL THEN
        RAISE EXCEPTION 'these still name a Gu their own way: %',
            array_to_string(silent, ', ');
    END IF;

    -- Two call sites each, not one - both chests roll twice.
    IF (SELECT count(*) FROM regexp_matches(
            (SELECT prosrc FROM pg_proc WHERE proname = 'horde_chest_take'),
            'gu_label\(', 'g')) <> 2 THEN
        RAISE EXCEPTION 'the horde chest labels a different number of Gu than two';
    END IF;

    IF (SELECT count(*) FROM regexp_matches(
            (SELECT prosrc FROM pg_proc WHERE proname = 'dungeon_spoils_for'),
            'gu_label\(', 'g')) <> 2 THEN
        RAISE EXCEPTION 'the dungeon labels a different number of Gu than two';
    END IF;
END;
$$;
