-- 0154_everybody_who_stood_in_the_ring
--
-- The free-for-all paid two people and nobody else. Eight of ten entrants
-- signed up, were beaten senseless by a roll they had no input into, and
-- walked away with nothing - which is a lottery you mostly lose, and with the
-- strongest cultivator winning nearly all of them it is the same two people
-- collecting every time.
--
-- Two changes, and they are the same change from both ends.
--
-- STONES FOR THE WHOLE FIELD, BY DAMAGE DEALT. The world beast's model, for
-- the world beast's reason: it pays for turning up, it scales with what you
-- actually did, and it cannot be gamed because damage is whatever the snapshot
-- could manage. A floor on top of it so somebody whose every swing was
-- shrugged off still leaves with something for entering.
--
-- LESS JADE, SPREAD FURTHER. Forty to the champion was the largest single
-- payout in the game - two settled days of /daily, landing every time three
-- people fancy a fight, against a world beast that pays four to thirty per
-- striker for a two-day group effort. Twenty-five, ten and five across three
-- places is less in total and reaches one more person.
--
--     before   40 champion, 12 runner-up            52 across 2
--     after    25 champion, 10 runner-up, 5 third   40 across 3, plus stones to all
--
-- What each entrant was paid is written down, so the standings can say it and
-- so "what did the ring pay out last week" is answerable.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 25,
    description = 'Spirit Jade to the champion. Deliberately under the world beast''s per-striker roll: this lands whenever three people want it to.'
WHERE key = 'tournament_jade_prize';

UPDATE game_config SET value = 10,
    description = 'Spirit Jade to whoever fell last.'
WHERE key = 'tournament_jade_runner_up';

INSERT INTO game_config (key, value, description) VALUES
    ('tournament_jade_third', 5,
     'Spirit Jade to third place, so the podium is three deep rather than two.'),
    ('tournament_stones_per_damage', 0.10,
     'Spirit Stones per point of damage an entrant dealt. The whole field is paid on this, not only the podium.'),
    ('tournament_stones_floor', 10,
     'Spirit Stones for entering at all, however the fight went. Somebody whose every swing was shrugged off still stood in the ring.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


ALTER TABLE tournament_entrants
    ADD COLUMN stones_paid BIGINT NOT NULL DEFAULT 0 CHECK (stones_paid >= 0),
    ADD COLUMN jade_paid   BIGINT NOT NULL DEFAULT 0 CHECK (jade_paid >= 0);

COMMENT ON COLUMN tournament_entrants.stones_paid IS
    'What the ring paid this entrant. Kept so the standings can say it and so a season''s payouts can be read back.';


CREATE OR REPLACE FUNCTION run_tournament(p_tournament_id BIGINT DEFAULT NULL)
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
    paid    RECORD;
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

    -- Everybody who stood in the ring is paid for what they did in it. Eight
    -- of ten entrants used to walk away with nothing at all, having been
    -- beaten senseless by a roll they had no input into - which is a lottery
    -- you mostly lose, and with the same person winning it every time.
    --
    -- Stones by damage, the world beast's model and for the same reason: it
    -- rewards turning up and it cannot be gamed, because damage is what the
    -- snapshot could do. The floor is for entering at all, so somebody who
    -- swung and missed the whole way through still leaves with something.
    FOR paid IN
        SELECT te.player_id, te.place, te.dealt,
               GREATEST(
                   game_config_value('tournament_stones_floor')::bigint,
                   round(te.dealt
                         * game_config_value('tournament_stones_per_damage'))::bigint
               ) AS stones,
               CASE te.place
                   WHEN 1 THEN game_config_value('tournament_jade_prize')::bigint
                   WHEN 2 THEN game_config_value('tournament_jade_runner_up')::bigint
                   WHEN 3 THEN game_config_value('tournament_jade_third')::bigint
                   ELSE 0
               END AS jade
        FROM tournament_entrants te
        WHERE te.tournament_id = meet
    LOOP
        PERFORM grant_material(paid.player_id, 'spirit_stone', paid.stones);
        IF paid.jade > 0 THEN
            PERFORM grant_jade(paid.player_id, paid.jade, 'tournament_placed');
        END IF;

        UPDATE tournament_entrants te
        SET stones_paid = paid.stones, jade_paid = paid.jade
        WHERE te.tournament_id = meet AND te.player_id = paid.player_id;
    END LOOP;

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


-- ---------------------------------------------------------------------------
-- Nobody leaves with nothing, and the podium is worth standing on
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    ghosts BIGINT[] := '{}';
    who    BIGINT;
    meet   BIGINT;
    got    RECORD;
    unpaid INTEGER;
    top    BIGINT;
    bottom BIGINT;
BEGIN
    FOR i IN 1..5 LOOP
        INSERT INTO players (discord_id, discord_name)
        VALUES (-999400 - i, 'reward probe ' || i)
        RETURNING player_id INTO who;

        INSERT INTO player_cultivation (player_id, cultivation, realm_id)
        VALUES (who, 0, 1);
        INSERT INTO player_physique
            (player_id, physique_id, body_level, max_hp, current_hp, defense)
        VALUES (who, (SELECT physique_id FROM physiques LIMIT 1), 1,
                200 + i * 40, 200 + i * 40, i * 4);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT who, technique_id FROM techniques
        WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0
        LIMIT 3;

        ghosts := ghosts || who;
    END LOOP;

    UPDATE tournaments SET status = 'abandoned', fought_at = now()
    WHERE status = 'signup';
    meet := open_tournament();
    FOREACH who IN ARRAY ghosts LOOP
        PERFORM join_tournament(who);
    END LOOP;

    SELECT * INTO got FROM run_tournament(meet);
    IF got.champion_id IS NULL THEN
        RAISE EXCEPTION 'five entrants and no champion';
    END IF;

    SELECT count(*) INTO unpaid FROM tournament_entrants te
    WHERE te.tournament_id = meet AND te.stones_paid <= 0;
    IF unpaid > 0 THEN
        RAISE EXCEPTION '% entrant(s) left the ring with nothing', unpaid;
    END IF;

    -- The champion must do better than the one who fell first, or placing
    -- means nothing.
    SELECT te.stones_paid + te.jade_paid * 10 INTO top
    FROM tournament_entrants te
    WHERE te.tournament_id = meet AND te.place = 1;
    SELECT te.stones_paid + te.jade_paid * 10 INTO bottom
    FROM tournament_entrants te
    WHERE te.tournament_id = meet AND te.place = 5;
    IF top <= bottom THEN
        RAISE EXCEPTION 'the champion was paid % and the first out %', top, bottom;
    END IF;

    -- Three places take Jade now, not two.
    IF (SELECT count(*) FROM tournament_entrants te
        WHERE te.tournament_id = meet AND te.jade_paid > 0) <> 3 THEN
        RAISE EXCEPTION 'the podium is % deep',
            (SELECT count(*) FROM tournament_entrants te
             WHERE te.tournament_id = meet AND te.jade_paid > 0);
    END IF;

    IF game_config_value('tournament_jade_prize') > 30 THEN
        RAISE EXCEPTION
            'the champion takes % Jade, which is back to being the biggest purse in the game',
            game_config_value('tournament_jade_prize');
    END IF;

    DELETE FROM tournament_blows WHERE tournament_id = meet;
    DELETE FROM tournament_entrants WHERE tournament_id = meet;
    DELETE FROM tournaments WHERE tournament_id = meet;
    DELETE FROM jade_ledger WHERE player_id = ANY (ghosts);
    DELETE FROM player_materials WHERE player_id = ANY (ghosts);
    DELETE FROM player_techniques WHERE player_id = ANY (ghosts);
    DELETE FROM player_physique WHERE player_id = ANY (ghosts);
    DELETE FROM player_cultivation WHERE player_id = ANY (ghosts);
    DELETE FROM players WHERE player_id = ANY (ghosts);
END;
$$;
