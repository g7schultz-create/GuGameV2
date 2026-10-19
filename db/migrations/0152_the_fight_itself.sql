-- 0152_the_fight_itself
--
-- Opening a tournament, joining one, and resolving it.
--
-- THE WHOLE FIGHT HAPPENS IN ONE CALL. Every round, every entrant still
-- standing swings once at another entrant still standing, chosen at random,
-- with a technique chosen at random from the ones they froze at signup. Blows
-- land in order within a round, so somebody felled early in a round does not
-- swing later in it - which is the only place turn order can matter and is
-- worth being deliberate about rather than accidental.
--
-- Resolving it all at once rather than a round at a time is what lets this
-- work with no scheduler. There is nothing to come back to.
--
-- PLACES ARE COUNTED FROM THE BOTTOM. The first to fall is last, and the one
-- left standing is first. A tournament that hits the round ceiling with
-- several alive ranks the survivors by the health they have left, so a pack of
-- cautious bodies cannot loop forever and cannot go unjudged either.
--
-- (The counter is `next_place` rather than the obvious `placing`: PLACING is
-- reserved in Postgres, the keyword in overlay(x placing y from n). Third
-- reserved word this week - `both` twice before it.)
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION open_tournament()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live BIGINT;
BEGIN
    SELECT tournament_id INTO live FROM tournaments WHERE status = 'signup';
    IF live IS NOT NULL THEN
        RETURN live;
    END IF;

    INSERT INTO tournaments (closes_at)
    VALUES (now() + make_interval(
        mins => game_config_value('tournament_signup_minutes')::int))
    -- Two commands racing both get here; the partial unique index lets one
    -- through and the other reads what it made.
    ON CONFLICT DO NOTHING
    RETURNING tournament_id INTO live;

    IF live IS NULL THEN
        SELECT tournament_id INTO live FROM tournaments WHERE status = 'signup';
    END IF;

    RETURN live;
END;
$$;


CREATE FUNCTION join_tournament(p_player_id BIGINT)
RETURNS TABLE (
    tournament_id BIGINT,
    entrants      INTEGER,
    closes_at     TIMESTAMPTZ,
    max_hp        BIGINT,
    techniques    INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    meet BIGINT;
    shot JSONB;
    ends TIMESTAMPTZ;
BEGIN
    meet := open_tournament();
    IF meet IS NULL THEN
        RAISE EXCEPTION 'no tournament could be opened'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT t.closes_at INTO ends FROM tournaments t WHERE t.tournament_id = meet;
    IF ends <= now() THEN
        RAISE EXCEPTION 'the entry list has closed'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM tournament_entrants te
               WHERE te.tournament_id = meet AND te.player_id = p_player_id) THEN
        RAISE EXCEPTION 'you are already entered'
            USING ERRCODE = 'check_violation';
    END IF;

    shot := tournament_snapshot(p_player_id);

    -- A cultivator with nothing that hurts would stand in the ring and be hit.
    IF jsonb_array_length(shot -> 'techniques') = 0 THEN
        RAISE EXCEPTION
            'you know no technique that could hurt anybody - **/techniques**'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO tournament_entrants
        (tournament_id, player_id, snapshot, max_hp, current_hp)
    VALUES (meet, p_player_id, shot,
            (shot ->> 'max_hp')::bigint, (shot ->> 'max_hp')::bigint);

    RETURN QUERY
    SELECT meet,
           (SELECT count(*)::integer FROM tournament_entrants te
            WHERE te.tournament_id = meet),
           ends,
           (shot ->> 'max_hp')::bigint,
           jsonb_array_length(shot -> 'techniques');
END;
$$;

COMMENT ON FUNCTION join_tournament(BIGINT) IS
    'Enters the open tournament, freezing the entrant as they are. Opens one if none is taking entries.';


-- ---------------------------------------------------------------------------
-- run_tournament
-- ---------------------------------------------------------------------------

CREATE FUNCTION run_tournament(p_tournament_id BIGINT DEFAULT NULL)
RETURNS TABLE (
    tournament_id BIGINT,
    entrants      INTEGER,
    rounds        INTEGER,
    champion_id   BIGINT,
    champion      TEXT,
    blows         INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    meet    BIGINT;
    field   INTEGER;
    least_n INTEGER := game_config_value('tournament_min_entrants')::integer;
    cap     INTEGER := game_config_value('tournament_max_rounds')::integer;
    round_n INTEGER := 0;
    seq_n   INTEGER;
    swing   RECORD;
    target  RECORD;
    move    JSONB;
    hurt    BIGINT;
    down    BOOLEAN;
    alive   INTEGER;
    champ   BIGINT;
    struck  INTEGER := 0;
    next_place INTEGER;
BEGIN
    IF p_tournament_id IS NULL THEN
        SELECT t.tournament_id INTO meet FROM tournaments t
        WHERE t.status = 'signup' AND t.closes_at <= now();
    ELSE
        meet := p_tournament_id;
    END IF;

    IF meet IS NULL THEN
        RETURN;
    END IF;

    PERFORM 1 FROM tournaments t
    WHERE t.tournament_id = meet AND t.status = 'signup'
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that tournament has already been fought'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO field FROM tournament_entrants te
    WHERE te.tournament_id = meet;

    IF field < least_n THEN
        -- Not enough turned up. Abandoned rather than fought, and the next
        -- call to open one starts a fresh list.
        UPDATE tournaments SET status = 'abandoned', fought_at = now()
        WHERE tournaments.tournament_id = meet;
        RETURN QUERY SELECT meet, field, 0, NULL::bigint, NULL::text, 0;
        RETURN;
    END IF;

    next_place := field;

    WHILE round_n < cap LOOP
        SELECT count(*) INTO alive FROM tournament_entrants te
        WHERE te.tournament_id = meet AND te.current_hp > 0;
        EXIT WHEN alive <= 1;

        round_n := round_n + 1;
        seq_n := 0;

        FOR swing IN
            SELECT te.player_id, te.snapshot
            FROM tournament_entrants te
            WHERE te.tournament_id = meet AND te.current_hp > 0
            ORDER BY random()
        LOOP
            -- Felled earlier in this same round, so they do not swing. Read
            -- fresh rather than trusting the cursor's copy.
            CONTINUE WHEN (SELECT te.current_hp FROM tournament_entrants te
                           WHERE te.tournament_id = meet
                             AND te.player_id = swing.player_id) <= 0;

            SELECT te.player_id, te.snapshot, te.current_hp
            INTO target
            FROM tournament_entrants te
            WHERE te.tournament_id = meet
              AND te.current_hp > 0
              AND te.player_id <> swing.player_id
            ORDER BY random()
            LIMIT 1;

            CONTINUE WHEN target IS NULL;

            move := swing.snapshot -> 'techniques'
                    -> floor(random()
                             * jsonb_array_length(swing.snapshot -> 'techniques'))::int;

            hurt := snapshot_blow(move, target.snapshot);
            down := target.current_hp - hurt <= 0;

            UPDATE tournament_entrants te
            SET current_hp = GREATEST(0, te.current_hp - hurt),
                taken      = te.taken + hurt,
                fell_round = CASE WHEN down THEN round_n ELSE te.fell_round END,
                place      = CASE WHEN down THEN next_place ELSE te.place END
            WHERE te.tournament_id = meet AND te.player_id = target.player_id;

            UPDATE tournament_entrants te
            SET dealt  = te.dealt + hurt,
                felled = te.felled + CASE WHEN down THEN 1 ELSE 0 END
            WHERE te.tournament_id = meet AND te.player_id = swing.player_id;

            seq_n  := seq_n + 1;
            struck := struck + 1;

            INSERT INTO tournament_blows
                (tournament_id, round, seq, actor_id, target_id, technique,
                 damage, felled)
            VALUES (meet, round_n, seq_n, swing.player_id, target.player_id,
                    move ->> 'name', hurt, down);

            IF down THEN
                next_place := next_place - 1;
            END IF;
        END LOOP;
    END LOOP;

    -- Whoever is left. If the ceiling stopped it with several standing they
    -- are ranked by the health they have left, so nobody goes unjudged.
    WITH standing AS (
        SELECT te.player_id,
               row_number() OVER (ORDER BY te.current_hp DESC, te.dealt DESC,
                                           te.player_id) AS rank
        FROM tournament_entrants te
        WHERE te.tournament_id = meet AND te.current_hp > 0
    )
    UPDATE tournament_entrants te
    SET place = standing.rank
    FROM standing
    WHERE te.tournament_id = meet AND te.player_id = standing.player_id;

    SELECT te.player_id INTO champ FROM tournament_entrants te
    WHERE te.tournament_id = meet AND te.place = 1;

    IF champ IS NOT NULL THEN
        PERFORM grant_jade(champ, game_config_value('tournament_jade_prize')::bigint,
                           'tournament_champion');
    END IF;

    PERFORM grant_jade(te.player_id,
                       game_config_value('tournament_jade_runner_up')::bigint,
                       'tournament_runner_up')
    FROM tournament_entrants te
    WHERE te.tournament_id = meet AND te.place = 2;

    UPDATE tournaments t
    SET status = 'fought', fought_at = now(), rounds = round_n,
        champion_id = champ
    WHERE t.tournament_id = meet;

    RETURN QUERY
    SELECT meet, field, round_n, champ,
           (SELECT p.discord_name FROM players p WHERE p.player_id = champ),
           struck;
END;
$$;

COMMENT ON FUNCTION run_tournament(BIGINT) IS
    'Resolves a whole free-for-all in one call: every entrant swings at a random other every round until one is left. Reads only the snapshots taken at signup.';


CREATE FUNCTION tournament_standings(p_tournament_id BIGINT)
RETURNS TABLE (
    place        INTEGER,
    player_id    BIGINT,
    discord_name TEXT,
    current_hp   BIGINT,
    max_hp       BIGINT,
    dealt        BIGINT,
    taken        BIGINT,
    felled       INTEGER,
    fell_round   INTEGER
)
LANGUAGE sql STABLE
AS $$
    SELECT te.place, te.player_id, p.discord_name, te.current_hp, te.max_hp,
           te.dealt, te.taken, te.felled, te.fell_round
    FROM tournament_entrants te
    JOIN players p ON p.player_id = te.player_id
    WHERE te.tournament_id = p_tournament_id
    ORDER BY te.place NULLS LAST, te.dealt DESC;
$$;


-- ---------------------------------------------------------------------------
-- It has to run, and it has to end
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    ghosts BIGINT[] := '{}';
    who    BIGINT;
    meet   BIGINT;
    got    RECORD;
    places INTEGER;
BEGIN
    FOR i IN 1..6 LOOP
        INSERT INTO players (discord_id, discord_name)
        VALUES (-999200 - i, 'tournament probe ' || i)
        RETURNING player_id INTO who;

        INSERT INTO player_cultivation (player_id, cultivation, realm_id)
        VALUES (who, 0, 1);
        INSERT INTO player_physique
            (player_id, physique_id, body_level, max_hp, current_hp, defense)
        VALUES (who, (SELECT physique_id FROM physiques LIMIT 1), 1,
                200 + i * 40, 200 + i * 40, i * 5);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT who, technique_id FROM techniques
        WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0
        LIMIT 3;

        ghosts := ghosts || who;
        PERFORM join_tournament(who);
    END LOOP;

    SELECT t.tournament_id INTO meet FROM tournaments t WHERE t.status = 'signup';
    SELECT * INTO got FROM run_tournament(meet);

    IF got.champion_id IS NULL THEN
        RAISE EXCEPTION 'six entrants and no champion';
    END IF;
    IF got.rounds < 1 OR got.blows < 1 THEN
        RAISE EXCEPTION 'the fight resolved without anybody swinging';
    END IF;
    IF got.rounds >= game_config_value('tournament_max_rounds')::integer THEN
        RAISE EXCEPTION 'six entrants took the whole round ceiling to settle';
    END IF;

    -- Everybody placed, exactly once each.
    SELECT count(DISTINCT place) INTO places
    FROM tournament_entrants WHERE tournament_id = meet;
    IF places <> 6 THEN
        RAISE EXCEPTION 'six entrants took % distinct places', places;
    END IF;
    IF EXISTS (SELECT 1 FROM tournament_entrants
               WHERE tournament_id = meet AND place IS NULL) THEN
        RAISE EXCEPTION 'somebody went unplaced';
    END IF;

    -- The champion is the one still standing.
    IF (SELECT current_hp FROM tournament_entrants
        WHERE tournament_id = meet AND place = 1) <= 0 THEN
        RAISE EXCEPTION 'the champion is lying down';
    END IF;

    -- Too few is abandoned, not fought.
    PERFORM open_tournament();
    SELECT t.tournament_id INTO meet FROM tournaments t WHERE t.status = 'signup';
    PERFORM join_tournament(ghosts[1]);
    SELECT * INTO got FROM run_tournament(meet);
    IF got.champion_id IS NOT NULL THEN
        RAISE EXCEPTION 'a tournament of one named a champion';
    END IF;
    IF (SELECT status FROM tournaments WHERE tournament_id = meet) <> 'abandoned' THEN
        RAISE EXCEPTION 'a tournament nobody entered was fought anyway';
    END IF;

    DELETE FROM tournament_blows WHERE actor_id = ANY (ghosts);
    DELETE FROM tournament_entrants WHERE player_id = ANY (ghosts);
    DELETE FROM tournaments WHERE champion_id = ANY (ghosts)
                               OR tournament_id = meet;
    DELETE FROM jade_ledger WHERE player_id = ANY (ghosts);
    DELETE FROM player_materials WHERE player_id = ANY (ghosts);
    DELETE FROM player_techniques WHERE player_id = ANY (ghosts);
    DELETE FROM player_physique WHERE player_id = ANY (ghosts);
    DELETE FROM player_cultivation WHERE player_id = ANY (ghosts);
    DELETE FROM players WHERE player_id = ANY (ghosts);
END;
$$;
