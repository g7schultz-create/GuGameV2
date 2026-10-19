-- 0519_every_gate_reads_standing_not_realm
--
-- 0504 built `player_standing` - realm rank, or Venerable rank once somebody
-- holds one - because `begin_travel` read `realms.rank`, which stops at 18,
-- and would have shut the Heavenly Court to the only people it is for. I
-- fixed travel and did not sweep the rest. Six readers still ask the realm:
--
--     gu_effect_cap        the crit and strike LIDS. A Venerable Rank 9
--                          cultivator would be pinned at rank 18's 12.6 and
--                          7.2 for ever, with no way to tell why.
--     delve_act            the rank a worm drop is drawn at
--     delve_step           the same
--     trial_party_open     what realm a Peer Trial is "one realm" OF
--     trial_party_invite   the peer check itself
--     trial_party_answer   the same, on joining
--
-- All six are wrong above rank 18 and all six are silent about it today,
-- because nobody is a Venerable yet. This is the fifth time this month that a
-- guard moved and a reader did not, so it gets swept now rather than found
-- by the first person to ascend.
--
-- THE TRIAL ONES ARE A JUDGEMENT, not a typo. A Peer Trial is one realm by
-- design - "a Peer Trial is one realm - this party stands at % and they stand
-- at %" - and a Venerable is not the peer of a Yellow Apricot Immortal. On
-- standing, they sort into their own parties, which is what the mechanic
-- already says in words.
--
-- AND `player_standing` SHORT-CIRCUITS, because `gu_effect_cap` is hot: it is
-- read by `player_gu_stats`, `player_equipment_stats`, `stat_source_cap` and
-- `player_stat`, so it runs several times per effect per player per fight.
-- Deriving a Venerable rung means walking that cultivator's aspects and
-- counting deeds, which is far too much to do there. The EXISTS on
-- `player_dao` is checked FIRST so an unstamped cultivator - which is
-- everybody - costs one index probe and nothing else.
--
-- Nothing moves today. The probe proves that rather than claiming it.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION player_standing(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- A Venerable rank IS a game-wide rank - venerable_ranks.rank runs 19 to
    -- 27 above the eighteen realms - so standing is whichever is higher.
    --
    -- The Venerable half is behind an EXISTS on `player_dao` so that an
    -- unstamped cultivator never pays for the understanding derivation. This
    -- is read from inside `gu_effect_cap`, which a single fight calls dozens
    -- of times.
    SELECT GREATEST(
        COALESCE(player_realm_rank(p_player_id), 1),
        COALESCE((
            SELECT venerable_rank_of(p_player_id)
            WHERE EXISTS (SELECT 1 FROM player_dao d
                          WHERE d.player_id = p_player_id)
        ), 0)
    )::SMALLINT;
$fn$;


-- ---------------------------------------------------------------------------
-- The six readers
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    one   TEXT;
    src   TEXT;
    hits  INTEGER;
    fixed INTEGER := 0;
BEGIN
    FOREACH one IN ARRAY ARRAY['gu_effect_cap', 'delve_act', 'delve_step',
                               'trial_party_open', 'trial_party_invite',
                               'trial_party_answer']::TEXT[]
    LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one));

        hits := (length(src) - length(replace(src, 'player_realm_rank(', '')))
                / length('player_realm_rank(');
        IF hits = 0 THEN
            RAISE EXCEPTION '% does not read player_realm_rank at all', one;
        END IF;

        EXECUTE replace(src, 'player_realm_rank(', 'player_standing(');
        fixed := fixed + hits;
    END LOOP;

    RAISE NOTICE 'moved % reads onto standing across six functions', fixed;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nothing above rank 18 is invisible, and nothing moved today
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
    one   RECORD;
BEGIN
    -- 1. `player_standing` is now the ONLY thing in the schema that reads the
    -- realm directly. Anything else asking the realm where it means standing
    -- is a gate that stops at 18.
    SELECT string_agg(p.proname, ', ') INTO v_bad
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosrc ~ 'player_realm_rank'
      AND p.proname <> 'player_standing';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these still read the realm where they mean standing: %', v_bad;
    END IF;

    -- 2. And every one of the six now reads standing, rather than having lost
    -- the read altogether to a careless replace.
    SELECT string_agg(x.name, ', ') INTO v_bad
    FROM (VALUES ('gu_effect_cap'), ('delve_act'), ('delve_step'),
                 ('trial_party_open'), ('trial_party_invite'),
                 ('trial_party_answer')) AS x(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = x.name
          AND p.prosrc ~ 'player_standing');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these lost their read entirely: %', v_bad;
    END IF;

    -- 3. NOTHING MOVES TODAY. Nobody is stamped, so standing is realm rank
    -- for every living cultivator and every lid reads what it read before.
    FOR one IN
        SELECT p.player_id, p.discord_name,
               COALESCE(player_realm_rank(p.player_id), 1) AS realm,
               player_standing(p.player_id) AS standing
        FROM players p WHERE p.deleted_at IS NULL
    LOOP
        IF one.realm <> one.standing THEN
            v_bad := COALESCE(v_bad, '') || one.discord_name || ' '
                     || one.realm || '->' || one.standing || ' ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'standing moved for somebody: %', v_bad;
    END IF;

    -- 4. The lids are where they were, which is the reader that matters most.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND gu_effect_cap(e.code, p.player_id)
          <> GREATEST(e.cap, e.cap_per_rank * COALESCE(player_realm_rank(p.player_id), 1));
    IF v_n > 0 THEN
        RAISE EXCEPTION '% lids moved for cultivators who have not ascended', v_n;
    END IF;

    -- 5. And the short circuit holds: an unstamped cultivator's standing must
    -- not depend on the understanding machinery at all. Checked by reading it
    -- for somebody with no Dao, no aspects and no cultivation row.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-998, 'standing-probe');
        IF player_standing((SELECT player_id FROM players WHERE discord_id = -998)) <> 1 THEN
            RAISE EXCEPTION
                'a cultivator with nothing at all does not stand at 1';
        END IF;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'every gate reads standing; the Venerable ladder is no longer invisible above 18';
END;
$probe$;
