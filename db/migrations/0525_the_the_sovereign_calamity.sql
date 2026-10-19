-- 0525_the_the_sovereign_calamity
--
-- Driving the live ascension door for a cultivator standing in it:
--
--     /ascend says: the The Sovereign Calamity has not been survived
--
-- Seventeen of the eighteen tribulations are named "The <something> Calamity"
-- and the eighteenth is "Nine Bolts of the Azure Sky", so every one of them is
-- already definite. Two messages add an article in front anyway:
--
--     tribulation_face   'you have already survived the %. The door is open - %'
--     venerable_ascend   'the % has not been survived - /tribulation'
--
-- The first has been doing it since 0386 for every rank, not just rank 19 -
-- "you have already survived the The Ninth Calamity" - and nobody caught it
-- because the only way to see it is to fail a tribulation and then read the
-- sentence. The second is mine, from 0521, three migrations old.
--
-- The article goes rather than the name changing, because the name is right:
-- it is a proper noun and it reads as one in every other sentence these two
-- functions produce ("% is not open to you yet - you are short of %").
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one RECORD;
BEGIN
    FOR one IN
        SELECT * FROM (VALUES
            ('tribulation_face',
             '''you have already survived the %. The door is open - %'',',
             '''you have already survived %. The door is open - %'','),
            ('venerable_ascend',
             '''the % has not been survived - /tribulation'', v_door.trial_name',
             '''% has not been survived - /tribulation'', v_door.trial_name')
        ) AS t(fn, was, becomes)
    LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one.fn));

        IF (length(src) - length(replace(src, one.was, ''))) / length(one.was) <> 1 THEN
            RAISE EXCEPTION
                'the doubled article in % is not where I read it', one.fn;
        END IF;

        EXECUTE replace(src, one.was, one.becomes);
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Say it to somebody and read what comes back
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid  BIGINT;
    v_path TEXT;
    v_said TEXT;
    v_n    INTEGER;
BEGIN
    -- Every sky is already definite, which is why the article is redundant
    -- rather than merely doubled in one place.
    SELECT count(*) INTO v_n
    FROM tribulations tb JOIN creature_species cs USING (species_id)
    WHERE cs.name ~ '^[a-z]';
    IF v_n > 0 THEN
        RAISE EXCEPTION
            '% tribulations are named in lower case and did want an article', v_n;
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-995, 'article-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        -- 1. The ascension door, which is where this was found.
        BEGIN
            PERFORM venerable_ascend(v_pid);
            RAISE EXCEPTION 'crossed without surviving anything';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;
        IF v_said LIKE '%the The %' OR v_said LIKE '%the Nine Bolts%' THEN
            RAISE EXCEPTION 'the ascension door still stutters: %', v_said;
        END IF;
        IF v_said NOT LIKE 'The Sovereign Calamity has not been survived%' THEN
            RAISE EXCEPTION
                'the ascension door says something else now: %', v_said;
        END IF;

        -- 2. And the one that has been stuttering since 0386, at the rank
        -- where it was written rather than only at the new one.
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());
        BEGIN
            PERFORM tribulation_face(v_pid);
            RAISE EXCEPTION 'faced a sky already survived';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;
        IF v_said LIKE '%survived the The %' THEN
            RAISE EXCEPTION 'the door-is-open message still stutters: %', v_said;
        END IF;
        IF v_said NOT LIKE '%survived The Sovereign Calamity%'
           OR v_said NOT LIKE '%/ascend%' THEN
            RAISE EXCEPTION 'the door-is-open message changed meaning: %', v_said;
        END IF;

        RAISE NOTICE 'the door now says: %', v_said;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- And no message in the schema puts an article in front of a trial name
    -- any more, so this cannot come back in the third place.
    SELECT string_agg(p.proname, ', ') INTO v_said
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosrc ~ '(the|The) %\.?[^,]*'',[^;]*trial_name';
    IF v_said IS NOT NULL THEN
        RAISE EXCEPTION
            'these still article a trial name: %', v_said;
    END IF;
END;
$probe$;
