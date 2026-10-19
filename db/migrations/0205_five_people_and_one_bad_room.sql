-- 0205_five_people_and_one_bad_room
--
-- The run: a party of one to five, invited by name, fighting in rounds where
-- everybody chooses at once.
--
-- IT DOES NOT USE `battle_act`. That function is hardcoded to combatant 0 and
-- combatant 1 - it reads them by number in eight places - and 3,424 solo
-- battles have gone through it. Widening it to N-vs-1 would put every one of
-- those at risk to deliver a different game mode.
--
-- What IS reused is the part that matters: `compute_technique_damage` and
-- `compute_creature_damage` take a player, a technique and a species and
-- answer with a number. They know about Path matchups, attainment, gear, Gu,
-- manuals and armour. A dungeon round calls them exactly as a duel does, so
-- there is one damage pipeline in this game and dungeons are not a second
-- opinion about how hard anybody hits.
--
-- ROUNDS RESOLVE WHEN EVERYONE HAS CHOSEN OR THE CLOCK RUNS OUT. Sixty
-- seconds, and a raider who says nothing swings with their first attack
-- technique - the same thing the reference screens do. Nobody is held hostage
-- by a friend who walked away, and nobody is skipped for being slow.
--
-- THE PARTY SHARES A HEALTH POOL ON THE BOSS AND NOTHING ELSE. Each raider
-- has their own HP and takes their own hits. The boss strikes one raider a
-- round, chosen at random among the living, so a five-person party is not
-- five times the incoming damage - it is the same damage spread thinner,
-- which is the entire reason to bring people.
--
-- Downed raiders stay in the room. They stop acting and stop being targeted;
-- the run ends when the boss falls or the last raider does.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE dungeon_runs (
    run_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dungeon_id    SMALLINT NOT NULL REFERENCES dungeons (dungeon_id),
    difficulty    TEXT NOT NULL REFERENCES dungeon_difficulties (code),
    leader_id     BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    status        TEXT NOT NULL DEFAULT 'forming'
        CHECK (status IN ('forming', 'fighting', 'won', 'lost', 'abandoned')),
    boss_max_hp   BIGINT NOT NULL DEFAULT 0,
    boss_hp       BIGINT NOT NULL DEFAULT 0,
    round_no      SMALLINT NOT NULL DEFAULT 0,
    round_ends_at TIMESTAMPTZ,
    opened_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    began_at      TIMESTAMPTZ,
    ended_at      TIMESTAMPTZ,
    CONSTRAINT dungeon_runs_hp_in_range CHECK (boss_hp <= boss_max_hp)
);

CREATE INDEX dungeon_runs_leader_idx ON dungeon_runs (leader_id);
CREATE INDEX dungeon_runs_dungeon_idx ON dungeon_runs (dungeon_id);
CREATE INDEX dungeon_runs_difficulty_idx ON dungeon_runs (difficulty);
CREATE INDEX dungeon_runs_live_idx ON dungeon_runs (status)
    WHERE status IN ('forming', 'fighting');


CREATE TABLE dungeon_raiders (
    run_id       BIGINT NOT NULL REFERENCES dungeon_runs (run_id) ON DELETE CASCADE,
    player_id    BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    max_hp       BIGINT NOT NULL DEFAULT 1,
    current_hp   BIGINT NOT NULL DEFAULT 1,
    damage_dealt BIGINT NOT NULL DEFAULT 0,
    damage_taken BIGINT NOT NULL DEFAULT 0,
    -- What they picked for the round that has not resolved yet. NULL means
    -- they have not chosen, which is what the clock is for.
    intent_id    BIGINT REFERENCES techniques (technique_id),
    chose_at     TIMESTAMPTZ,
    keys_paid    INTEGER NOT NULL DEFAULT 0,
    stones_paid  BIGINT NOT NULL DEFAULT 0,
    jade_paid    BIGINT NOT NULL DEFAULT 0,
    spoils       JSONB,
    PRIMARY KEY (run_id, player_id)
);

CREATE INDEX dungeon_raiders_player_idx ON dungeon_raiders (player_id);
CREATE INDEX dungeon_raiders_intent_idx ON dungeon_raiders (intent_id);


-- Invited by name, and only the invited may join.
CREATE TABLE dungeon_invites (
    run_id     BIGINT NOT NULL REFERENCES dungeon_runs (run_id) ON DELETE CASCADE,
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    invited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, player_id)
);

CREATE INDEX dungeon_invites_player_idx ON dungeon_invites (player_id);


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_round_seconds', 60,
     'How long a raider has to choose. Past it they swing with their first '
     'attack technique rather than holding the room up.'),
    ('dungeon_forming_minutes', 10,
     'How long a party may stand in the doorway before the run is abandoned '
     'and the door closes.');


-- A run nobody has to reconstruct: everything a screen needs about the room.
CREATE VIEW dungeon_run_state AS
SELECT r.run_id, r.status, r.round_no, r.round_ends_at, r.difficulty,
       r.leader_id, r.boss_hp, r.boss_max_hp,
       d.dungeon_id, d.name AS dungeon_name, d.realm_rank,
       d.stone_cost, d.jade_cost,
       s.species_id, s.name AS boss_name, s.rank AS boss_rank,
       df.name AS difficulty_name, df.reward_scale,
       (SELECT count(*) FROM dungeon_raiders x WHERE x.run_id = r.run_id)
           ::integer AS raiders,
       (SELECT count(*) FROM dungeon_raiders x
        WHERE x.run_id = r.run_id AND x.current_hp > 0)::integer AS standing,
       (SELECT count(*) FROM dungeon_raiders x
        WHERE x.run_id = r.run_id AND x.current_hp > 0 AND x.intent_id IS NULL)
           ::integer AS still_choosing
FROM dungeon_runs r
JOIN dungeons d ON d.dungeon_id = r.dungeon_id
JOIN creature_species s ON s.species_id = d.species_id
JOIN dungeon_difficulties df ON df.code = r.difficulty;


-- ---------------------------------------------------------------------------
-- Standing in the doorway
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_open(
    p_player_id BIGINT, p_dungeon_id SMALLINT, p_difficulty TEXT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dungeons WHERE dungeon_id = p_dungeon_id) THEN
        RAISE EXCEPTION 'there is no such door' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM dungeon_difficulties WHERE code = p_difficulty)
    THEN
        RAISE EXCEPTION 'there is no % difficulty', p_difficulty
            USING ERRCODE = 'check_violation';
    END IF;

    -- One run at a time. Being in two rooms at once is not a state this can
    -- resolve rounds for.
    IF EXISTS (
        SELECT 1 FROM dungeon_raiders x
        JOIN dungeon_runs r ON r.run_id = x.run_id
        WHERE x.player_id = p_player_id
          AND r.status IN ('forming', 'fighting')
    ) THEN
        RAISE EXCEPTION 'you are already in a dungeon'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO dungeon_runs (dungeon_id, difficulty, leader_id)
    VALUES (p_dungeon_id, p_difficulty, p_player_id)
    RETURNING run_id INTO made;

    -- The leader is a raider, not a spectator.
    INSERT INTO dungeon_raiders (run_id, player_id) VALUES (made, p_player_id);

    RETURN made;
END;
$$;


CREATE FUNCTION dungeon_invite(
    p_run_id BIGINT, p_leader_id BIGINT, p_invited_id BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    who TEXT;
    room INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dungeon_runs
        WHERE run_id = p_run_id AND leader_id = p_leader_id
          AND status = 'forming'
    ) THEN
        RAISE EXCEPTION 'that is not a run of yours that is still forming'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_invited_id = p_leader_id THEN
        RAISE EXCEPTION 'you are already going' USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.discord_name INTO who FROM players p
    WHERE p.player_id = p_invited_id AND p.deleted_at IS NULL;

    IF who IS NULL THEN
        RAISE EXCEPTION 'no such cultivator' USING ERRCODE = 'check_violation';
    END IF;

    -- Invites are counted against the party size with the raiders, so a
    -- leader cannot promise six people a place and disappoint one.
    SELECT game_config_value('dungeon_party_max')::integer
           - (SELECT count(*) FROM dungeon_raiders WHERE run_id = p_run_id)
           - (SELECT count(*) FROM dungeon_invites i
              WHERE i.run_id = p_run_id
                AND NOT EXISTS (SELECT 1 FROM dungeon_raiders x
                                WHERE x.run_id = i.run_id
                                  AND x.player_id = i.player_id))
    INTO room;

    IF room <= 0 THEN
        RAISE EXCEPTION 'the party is full' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO dungeon_invites (run_id, player_id)
    VALUES (p_run_id, p_invited_id)
    ON CONFLICT DO NOTHING;

    RETURN who;
END;
$$;


CREATE FUNCTION dungeon_join(p_run_id BIGINT, p_player_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    joined INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dungeon_invites
        WHERE run_id = p_run_id AND player_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'you were not invited to that one'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM dungeon_runs WHERE run_id = p_run_id AND status = 'forming'
    ) THEN
        RAISE EXCEPTION 'that party has already gone in'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (
        SELECT 1 FROM dungeon_raiders x
        JOIN dungeon_runs r ON r.run_id = x.run_id
        WHERE x.player_id = p_player_id AND r.status IN ('forming', 'fighting')
    ) THEN
        RAISE EXCEPTION 'you are already in a dungeon'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO joined FROM dungeon_raiders WHERE run_id = p_run_id;
    IF joined >= game_config_value('dungeon_party_max') THEN
        RAISE EXCEPTION 'the party is full' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO dungeon_raiders (run_id, player_id) VALUES (p_run_id, p_player_id);
    RETURN joined + 1;
END;
$$;


-- ---------------------------------------------------------------------------
-- Through the door
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_begin(p_run_id BIGINT, p_leader_id BIGINT)
RETURNS TABLE (raiders INTEGER, boss_hp BIGINT, boss_name TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    run   RECORD;
    party INTEGER;
    one   RECORD;
    pool  BIGINT;
BEGIN
    SELECT * INTO run FROM dungeon_run_state s
    WHERE s.run_id = p_run_id AND s.leader_id = p_leader_id
      AND s.status = 'forming';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not a run of yours that is still forming'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO party FROM dungeon_raiders WHERE run_id = p_run_id;

    -- Everybody pays at the door, and the whole party fails together if one
    -- of them cannot. `spend_material` refuses rather than going negative, so
    -- a party that cannot afford it never gets a half-charged run.
    FOR one IN SELECT x.player_id FROM dungeon_raiders x WHERE x.run_id = p_run_id
    LOOP
        PERFORM spend_material(one.player_id, 'dungeon_key', 1);
        IF run.stone_cost > 0 THEN
            PERFORM spend_material(one.player_id, 'spirit_stone', run.stone_cost);
        END IF;
        IF run.jade_cost > 0 THEN
            PERFORM spend_jade(one.player_id, run.jade_cost, 'dungeon_entry');
        END IF;

        UPDATE dungeon_raiders x
        SET keys_paid = 1,
            stones_paid = run.stone_cost,
            jade_paid = run.jade_cost,
            max_hp = pp.max_hp,
            -- You go in as you are. Somebody who walked in wounded is
            -- wounded, which is what /rest is for.
            current_hp = GREATEST(1, pp.current_hp)
        FROM player_physique pp
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id
          AND pp.player_id = one.player_id;
    END LOOP;

    pool := dungeon_boss_hp(run.dungeon_id, run.difficulty, party);

    UPDATE dungeon_runs r
    SET status = 'fighting',
        boss_max_hp = pool,
        boss_hp = pool,
        round_no = 1,
        began_at = now(),
        round_ends_at = now()
            + make_interval(secs => game_config_value('dungeon_round_seconds'))
    WHERE r.run_id = p_run_id;

    RETURN QUERY SELECT party, pool, run.boss_name;
END;
$$;


-- What a raider will swing with if they say nothing. Their first attack
-- technique, which is what the reference screens do - the numbered list is in
-- this order and the timeout takes number one.
CREATE FUNCTION dungeon_default_move(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT t.technique_id
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    WHERE u.player_id = p_player_id AND t.category = 'attack'
    ORDER BY t.rank DESC, t.base_power DESC, t.technique_id
    LIMIT 1;
$$;


CREATE FUNCTION dungeon_choose(
    p_run_id BIGINT, p_player_id BIGINT, p_technique_id BIGINT
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dungeon_runs WHERE run_id = p_run_id AND status = 'fighting'
    ) THEN
        RAISE EXCEPTION 'that fight is not running'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM dungeon_raiders
        WHERE run_id = p_run_id AND player_id = p_player_id AND current_hp > 0
    ) THEN
        RAISE EXCEPTION 'you are not standing in that room'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM player_usable_techniques
        WHERE player_id = p_player_id AND technique_id = p_technique_id
    ) THEN
        RAISE EXCEPTION 'you cannot use that technique'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE dungeon_raiders
    SET intent_id = p_technique_id, chose_at = now()
    WHERE run_id = p_run_id AND player_id = p_player_id;

    RETURN (SELECT still_choosing FROM dungeon_run_state WHERE run_id = p_run_id);
END;
$$;
