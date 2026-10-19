-- 0151_a_free_for_all_and_the_shape_it_is_frozen_in
--
-- A tournament: sign up, and when it runs every entrant swings at another
-- entrant chosen at random, round after round, until one is left standing.
--
-- THE SNAPSHOT IS THE WHOLE DESIGN. A cultivator who signs up and then spends
-- an hour breaking through must not arrive at the fight stronger than the one
-- who signed up and went to bed. So signing up freezes what you are, and the
-- fight reads nothing else - not your health, not your gear, not the
-- techniques you learned since.
--
-- Freezing it properly means freezing BOTH sides of a blow. Health and defense
-- are obvious; the two that are easy to miss:
--
--   * a technique's ATTACK RATING - its base power already multiplied by
--     attainment and by the Race, Root and Physique hook - because all three
--     of those move.
--   * the entrant's RESISTANCE PER PATH, because `player_path_resistance`
--     reads attainment too, and a defender who trained overnight would
--     otherwise shrug off a blow that was aimed at who they used to be.
--
-- With both frozen the whole tournament is arithmetic over stored numbers.
-- Nothing it does can be changed by anything that happens after the entry
-- list closes, which is the property the word "snapshot" is promising.
--
-- WHY NOT `compute_technique_damage`. That takes a defender SPECIES and reads
-- the creature matchup chart. There is no chart between two cultivators - what
-- stands in for it is the defender's own resistance, which is why this is a
-- second small pipeline rather than a fourth argument on the first.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('tournament_min_entrants', 3,
     'Fewest cultivators a free-for-all will run with. Two would be a duel, which is a different thing.'),
    ('tournament_signup_minutes', 30,
     'How long the entry list stands open.'),
    ('tournament_max_rounds', 40,
     'A hard stop. If nobody has won by here the field is judged on what is left, so a pack of cautious bodies cannot loop forever.'),
    ('tournament_jade_prize', 40,
     'Spirit Jade to the champion.'),
    ('tournament_jade_runner_up', 12,
     'Spirit Jade to whoever fell last.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- tournament_snapshot
-- ---------------------------------------------------------------------------
-- Everything the fight will read, as it stands right now.

CREATE FUNCTION tournament_snapshot(p_player_id BIGINT)
RETURNS JSONB
LANGUAGE sql STABLE
AS $$
    SELECT jsonb_build_object(
        'max_hp', COALESCE((SELECT pp.max_hp FROM player_physique pp
                            WHERE pp.player_id = p_player_id), 100),
        'defense', COALESCE((SELECT pp.defense FROM player_physique pp
                             WHERE pp.player_id = p_player_id), 0),

        -- Base power through attainment and the trait hook, so the rating is
        -- what this cultivator hits for today and not what the technique is
        -- worth in the abstract.
        'techniques', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', t.technique_id,
                'name', t.name,
                'rating', round(
                    t.base_power
                    * (1 + technique_attainment_bonus(p_player_id, t.technique_id))
                    * player_external_multiplier(p_player_id, t.technique_id), 2),
                'paths', COALESCE((
                    SELECT jsonb_object_agg(tp.path_code, tp.weight)
                    FROM technique_paths tp WHERE tp.technique_id = t.technique_id
                ), '{}'::jsonb)
            ))
            FROM player_usable_techniques u
            JOIN techniques t ON t.technique_id = u.technique_id
            WHERE u.player_id = p_player_id AND t.base_power > 0
        ), '[]'::jsonb),

        -- Only the Paths they actually resist. A map of thirty-four zeroes
        -- would be the same information and forty times the bytes.
        'resist', COALESCE((
            SELECT jsonb_object_agg(p.code, round(r.amount, 4))
            FROM paths p
            CROSS JOIN LATERAL (
                SELECT player_path_resistance(p_player_id, p.code) AS amount
            ) r
            WHERE r.amount > 0
        ), '{}'::jsonb)
    );
$$;

COMMENT ON FUNCTION tournament_snapshot(BIGINT) IS
    'A cultivator frozen: health, defense, every technique already multiplied by attainment and traits, and the Paths they resist. What a tournament reads instead of the living player.';


-- ---------------------------------------------------------------------------
-- snapshot_blow
-- ---------------------------------------------------------------------------
-- One technique out of one snapshot against another. Pure arithmetic over
-- stored numbers - no table is read, so a fight is reproducible from the
-- entry list alone.

CREATE FUNCTION snapshot_blow(p_attack JSONB, p_defender JSONB)
RETURNS BIGINT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT GREATEST(1, round(
        (p_attack ->> 'rating')::numeric
        -- Resistance is weighted by the technique's own typing, the same way
        -- the matchup chart weights a dual-Path move against a creature.
        * GREATEST(0, 1 - COALESCE((
            SELECT sum(w.weight::numeric
                       * COALESCE((p_defender -> 'resist' ->> w.path)::numeric, 0))
            FROM jsonb_each_text(p_attack -> 'paths') AS w (path, weight)
        ), 0))
        * game_config_value('defense_scale')
        / (game_config_value('defense_scale')
           + GREATEST(0, (p_defender ->> 'defense')::numeric))
    ))::bigint;
$$;

COMMENT ON FUNCTION snapshot_blow(JSONB, JSONB) IS
    'What one frozen technique does to one frozen cultivator. Reads no table, so a tournament is reproducible from its entry list.';


-- ---------------------------------------------------------------------------
-- The tables
-- ---------------------------------------------------------------------------

CREATE TABLE tournaments (
    tournament_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    status      TEXT NOT NULL DEFAULT 'signup'
                CHECK (status IN ('signup', 'fought', 'abandoned')),

    opened_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    closes_at   TIMESTAMPTZ NOT NULL,
    fought_at   TIMESTAMPTZ,

    rounds      INTEGER NOT NULL DEFAULT 0 CHECK (rounds >= 0),
    champion_id BIGINT REFERENCES players (player_id) ON DELETE SET NULL,

    CONSTRAINT tournament_fought_is_whole
        CHECK ((status = 'signup') = (fought_at IS NULL))
);

CREATE UNIQUE INDEX tournaments_one_open ON tournaments ((TRUE))
    WHERE status = 'signup';
CREATE INDEX tournaments_champion_idx ON tournaments (champion_id)
    WHERE champion_id IS NOT NULL;
CREATE INDEX tournaments_when_idx ON tournaments (opened_at DESC);

COMMENT ON TABLE tournaments IS
    'A free-for-all. At most one takes entries at a time, enforced by a partial unique index rather than by whoever remembers to check.';


CREATE TABLE tournament_entrants (
    tournament_id BIGINT NOT NULL REFERENCES tournaments (tournament_id)
                  ON DELETE CASCADE,
    player_id     BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    snapshot      JSONB  NOT NULL,
    max_hp        BIGINT NOT NULL CHECK (max_hp > 0),
    current_hp    BIGINT NOT NULL CHECK (current_hp >= 0),

    joined_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    place         INTEGER CHECK (place >= 1),
    fell_round    INTEGER,
    felled        INTEGER NOT NULL DEFAULT 0 CHECK (felled >= 0),
    dealt         BIGINT  NOT NULL DEFAULT 0 CHECK (dealt >= 0),
    taken         BIGINT  NOT NULL DEFAULT 0 CHECK (taken >= 0),

    PRIMARY KEY (tournament_id, player_id)
);

CREATE INDEX tournament_entrants_player_idx ON tournament_entrants (player_id);
CREATE INDEX tournament_entrants_place_idx
    ON tournament_entrants (tournament_id, place);

COMMENT ON COLUMN tournament_entrants.snapshot IS
    'What this cultivator was when they signed up. The fight reads this and never the living player, so an hour of cultivating between signing up and fighting changes nothing.';


CREATE TABLE tournament_blows (
    tournament_id BIGINT   NOT NULL REFERENCES tournaments (tournament_id)
                  ON DELETE CASCADE,
    round         INTEGER  NOT NULL CHECK (round >= 1),
    seq           INTEGER  NOT NULL CHECK (seq >= 1),

    actor_id      BIGINT   NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    target_id     BIGINT   NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    technique     TEXT     NOT NULL,
    damage        BIGINT   NOT NULL CHECK (damage >= 0),
    felled        BOOLEAN  NOT NULL DEFAULT FALSE,

    PRIMARY KEY (tournament_id, round, seq)
);

CREATE INDEX tournament_blows_actor_idx ON tournament_blows (actor_id);
CREATE INDEX tournament_blows_target_idx ON tournament_blows (target_id);

COMMENT ON TABLE tournament_blows IS
    'Every swing, in order. The fight resolves in one call and this is what lets it be read back a round at a time afterwards.';
