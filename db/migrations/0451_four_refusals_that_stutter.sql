-- 0451_four_refusals_that_stutter
--
-- Inviting a cultivator of the wrong realm says:
--
--     a Peer Trial is one realm - this party stands at 18s and they stand at 12s
--
-- `RAISE` in PL/pgSQL takes a bare `%` as its placeholder, not `%s`. Four
-- messages in 0450 were written with `%s`, so each one prints the number and
-- then a stray letter. Nothing is broken and every refusal refuses correctly;
-- they just read as though the game has a stammer.
--
-- Worth a migration of its own rather than waiting to be carried along by the
-- next change to these functions: these are the lines a player sees at the
-- exact moment they are told no, and "18s" in the middle of one is the sort of
-- thing that reads as a bug in the rule rather than in the sentence.
--
-- The functions are lifted and patched rather than retyped, so this cannot
-- quietly revert anything else in them.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    r    RECORD;
    body TEXT;
    hits INTEGER;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('trial_party_invite',
             'this party stands at %s and they stand at %s',
             'this party stands at % and they stand at %'),
            ('trial_party_invite',
             'a Peer Trial holds %s',
             'a Peer Trial holds %'),
            ('trial_party_answer',
             'you stand at %s now and that party is a trial of %s',
             'you stand at % now and that party is a trial of %'),
            ('trial_party_seal',
             'a Peer Trial wants %s peers and you are %s',
             'a Peer Trial wants % peers and you are %')
        ) AS t (fn, anchor, becomes)
    LOOP
        SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
        WHERE proname = r.fn AND pronamespace = 'public'::regnamespace;
        IF body IS NULL THEN
            RAISE EXCEPTION '% is missing', r.fn;
        END IF;

        hits := (length(body) - length(replace(body, r.anchor, '')))
                / length(r.anchor);
        IF hits <> 1 THEN
            RAISE EXCEPTION
                '% says that line % time(s), expected 1', r.fn, hits;
        END IF;

        EXECUTE replace(body, r.anchor, r.becomes);
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every refusal reads as a sentence
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_a   BIGINT;
    v_c   BIGINT;
    v_p   BIGINT;
    v_said TEXT;
BEGIN
    -- No message in any of the party functions still carries the wrong
    -- placeholder. Asked of the source rather than of the four I noticed.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname LIKE 'trial_party%'
      -- strpos, not LIKE: chr(37) IS the wildcard, so a pattern built from
      -- it matches any function containing the letter s - which is all of
      -- them, and is what the first run of this probe accused.
      AND strpos(p.prosrc, chr(37) || 's') > 0;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still stutter: %', v_bad;
    END IF;

    -- And the one that was reported now reads properly, checked by making it
    -- happen rather than by reading the source back.
    BEGIN
        SELECT p.player_id INTO v_a FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;

        SELECT p.player_id INTO v_c FROM players p
        WHERE p.deleted_at IS NULL AND p.player_id <> v_a
          AND player_realm_rank(p.player_id) <> player_realm_rank(v_a)
          AND trial_party_of(p.player_id) IS NULL
        LIMIT 1;

        IF v_a IS NULL OR v_c IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_p := trial_party_open(v_a);
        BEGIN
            PERFORM trial_party_invite(v_a, v_c);
            RAISE EXCEPTION 'a stranger realm was let in';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;

        IF v_said LIKE '%s and they%' THEN
            RAISE EXCEPTION 'the refusal still stutters: %', v_said;
        END IF;
        IF v_said NOT LIKE '%stands at ' || player_realm_rank(v_a) || ' %' THEN
            RAISE EXCEPTION
                'the refusal no longer names the party''s realm: %', v_said;
        END IF;

        RAISE NOTICE 'it now reads: %', v_said;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
