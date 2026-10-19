-- 0139_a_beast_the_whole_world_fights
--
-- The first piece of group content. Everything in this game so far is one
-- cultivator alone in a region; this is the thing they all stand in front of
-- at once.
--
-- IT ALREADY HALF EXISTED, AND WRONGLY. `Heaven Scourge Leviathan` is a rank 9
-- world beast with five million HP, and it has been sitting in the Eastern
-- Sea's hunt table at weight 1.0 since 0010 - so about one hunt in a hundred
-- and twenty-five threw a Qi Condensation cultivator at an unkillable wall,
-- and `player_active_battle` being one-per-player meant they were stuck in
-- front of it until they fled. `Void Ash Revenant` is the same at rank 7. Both
-- stop being random encounters here and become the only thing they were ever
-- shaped to be.
--
-- HOW BIG. Not `base_hp`. Five million against this roster - ten cultivators
-- at ranks 1 and 2, whose best techniques hit for a few hundred - is four
-- hundred days of continuous striking. A pool has to be derived from the
-- people who will actually swing at it, or it is decoration:
--
--     pool = sum over active cultivators of (their best technique's power)
--            x strikes each x how much of that the beast is worth
--
-- which scales on its own as the server grows and as its players do, and
-- cannot be wrong by an order of magnitude the way a written number can.
--
-- WHAT A STRIKE IS. `compute_technique_damage`, the same pipeline a hunt runs.
-- Attainment, matchup, Gu, equipment and physique all count, because they all
-- count everywhere else and a boss that ignored them would be a second combat
-- model to keep in step. The beast hits back through `compute_creature_damage`
-- for the same reason, so HP and /rest matter and a strike is a real risk.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('boss_strikes_each', 5,
     'Strikes one cultivator gets at one world beast. The encounter is the window, not the day.'),
    ('boss_effort', 0.55,
     'What fraction of the roster''s full strength the beast is worth. Below 1 so a turnout that is not everybody can still bring it down.'),
    ('boss_hp_floor', 4000,
     'Smallest a world beast can be however thin the server is, so a lone cultivator still meets something worth the name.'),
    ('boss_hours', 24,
     'How long a world beast stands before it leaves.'),
    ('boss_rest_hours', 12,
     'Quiet between one beast leaving and the next arriving.'),
    ('boss_stones_per_hp', 0.02,
     'Spirit Stones paid per point of damage dealt, split by contribution.'),
    ('boss_jade_slayer', 15,
     'Spirit Jade to whoever lands the killing strike.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- boss_encounters
-- ---------------------------------------------------------------------------
-- One instance of a world beast standing somewhere. The species is a
-- `creature_species` row, so the beast's rank, defense, Paths and drop table
-- are the ones the bestiary already documents.

CREATE TABLE boss_encounters (
    encounter_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    species_id   BIGINT NOT NULL REFERENCES creature_species (species_id)
                 ON DELETE RESTRICT,
    region_code  TEXT   NOT NULL REFERENCES regions (code) ON DELETE RESTRICT,

    max_hp       BIGINT NOT NULL CHECK (max_hp > 0),
    current_hp   BIGINT NOT NULL CHECK (current_hp >= 0),

    status       TEXT   NOT NULL DEFAULT 'open'
                 CHECK (status IN ('open', 'slain', 'escaped')),

    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    closes_at    TIMESTAMPTZ NOT NULL,
    ended_at     TIMESTAMPTZ,

    slayer_id    BIGINT REFERENCES players (player_id) ON DELETE SET NULL,

    CONSTRAINT boss_ended_matches_status
        CHECK ((status = 'open') = (ended_at IS NULL)),
    CONSTRAINT boss_slayer_only_when_slain
        CHECK (slayer_id IS NULL OR status = 'slain'),
    CONSTRAINT boss_hp_within_pool CHECK (current_hp <= max_hp)
);

-- One beast at a time in the whole world. A partial unique index on a
-- constant is how "at most one row satisfying this" is said in Postgres, and
-- it means two commands racing to open one cannot both succeed.
CREATE UNIQUE INDEX boss_only_one_open ON boss_encounters ((TRUE))
    WHERE status = 'open';

CREATE INDEX boss_encounters_species_idx ON boss_encounters (species_id);
CREATE INDEX boss_encounters_ended_idx ON boss_encounters (ended_at DESC)
    WHERE status <> 'open';

COMMENT ON TABLE boss_encounters IS
    'A world beast standing somewhere, with a shared pool of HP. At most one is open at a time, enforced by a partial unique index rather than by whoever remembers to check.';


-- ---------------------------------------------------------------------------
-- boss_strikes
-- ---------------------------------------------------------------------------
-- One row per cultivator per encounter: how many strikes they have spent and
-- how much they did with them. This is the ledger the rewards are split from,
-- so it is a running total rather than a row per blow - a boss that stood for
-- a week would otherwise be a table of tens of thousands of rows nobody reads.

CREATE TABLE boss_strikes (
    encounter_id BIGINT NOT NULL REFERENCES boss_encounters (encounter_id)
                 ON DELETE CASCADE,
    player_id    BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    strikes      INTEGER NOT NULL DEFAULT 0 CHECK (strikes >= 0),
    damage       BIGINT  NOT NULL DEFAULT 0 CHECK (damage >= 0),
    taken        BIGINT  NOT NULL DEFAULT 0 CHECK (taken >= 0),

    first_struck TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_struck  TIMESTAMPTZ NOT NULL DEFAULT now(),
    rewarded_at  TIMESTAMPTZ,

    PRIMARY KEY (encounter_id, player_id)
);

CREATE INDEX boss_strikes_player_idx ON boss_strikes (player_id);
CREATE INDEX boss_strikes_damage_idx ON boss_strikes (encounter_id, damage DESC);

COMMENT ON TABLE boss_strikes IS
    'What each cultivator spent and did against one world beast. The ledger rewards are split from; `rewarded_at` is what stops a share being claimed twice.';


-- ---------------------------------------------------------------------------
-- How big the beast is
-- ---------------------------------------------------------------------------
-- Derived from the people who will swing at it. `player_usable_techniques`
-- already knows what everybody is holding, which makes this the one figure in
-- the game that retunes itself as the roster grows.
--
-- Best technique rather than average: a cultivator brings their strongest
-- move, and summing their weakest would size the beast for a fight nobody
-- fights.

CREATE FUNCTION boss_hp_pool()
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(
        game_config_value('boss_hp_floor'),
        round(COALESCE((
            SELECT sum(best.power)
            FROM players p
            JOIN LATERAL (
                SELECT max(t.base_power) AS power
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.power IS NOT NULL
            WHERE p.deleted_at IS NULL
              AND p.last_seen_at >= now() - interval '7 days'
        ), 0)
        * game_config_value('boss_strikes_each')
        * game_config_value('boss_effort'))
    )::bigint;
$$;

COMMENT ON FUNCTION boss_hp_pool() IS
    'How much HP the next world beast gets: what the active roster could deal in a full set of strikes, times how much of that the beast is worth.';


-- ---------------------------------------------------------------------------
-- Opening one, without a scheduler
-- ---------------------------------------------------------------------------
-- This bot runs no task loop, so nothing wakes up to spawn a beast. It does
-- not need to: the screens that would show one call this first, and a beast
-- that nobody is looking at does not need to have arrived yet.
--
-- It also closes an expired one on the way past, which is the same trick and
-- the reason no state can be left stale by a quiet night.

CREATE FUNCTION boss_open_if_due()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live    BIGINT;
    rested  BOOLEAN;
    chosen  BIGINT;
    made    BIGINT;
    pool    BIGINT;
BEGIN
    -- A beast that stood out its welcome leaves, and it leaves before we ask
    -- whether one is standing.
    UPDATE boss_encounters
    SET status = 'escaped', ended_at = now()
    WHERE status = 'open' AND closes_at <= now();

    SELECT encounter_id INTO live
    FROM boss_encounters WHERE status = 'open';

    IF live IS NOT NULL THEN
        RETURN live;
    END IF;

    SELECT COALESCE(max(ended_at), 'epoch'::timestamptz)
           <= now() - make_interval(hours => game_config_value('boss_rest_hours')::int)
    INTO rested
    FROM boss_encounters;

    IF NOT rested THEN
        RETURN NULL;
    END IF;

    -- Any world beast or boss. They are the two kinds that were never meant
    -- to be walked into alone.
    SELECT cs.species_id INTO chosen
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
    ORDER BY random()
    LIMIT 1;

    IF chosen IS NULL THEN
        RETURN NULL;
    END IF;

    pool := boss_hp_pool();

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, closes_at)
    SELECT chosen,
           COALESCE((SELECT cr.region_code FROM creature_regions cr
                     WHERE cr.species_id = chosen ORDER BY random() LIMIT 1),
                    (SELECT r.code FROM regions r ORDER BY r.code LIMIT 1)),
           pool, pool,
           now() + make_interval(hours => game_config_value('boss_hours')::int)
    -- Two players calling this in the same instant both get here; the partial
    -- unique index lets exactly one through and the other reads what it made.
    ON CONFLICT DO NOTHING
    RETURNING encounter_id INTO made;

    IF made IS NULL THEN
        SELECT encounter_id INTO made
        FROM boss_encounters WHERE status = 'open';
    END IF;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION boss_open_if_due() IS
    'Retires an expired beast and opens the next one if the world has rested long enough. Called by the screens rather than by a scheduler, because this bot has none.';


-- ---------------------------------------------------------------------------
-- What the screens read
-- ---------------------------------------------------------------------------

CREATE FUNCTION boss_state(p_player_id BIGINT)
RETURNS TABLE (
    encounter_id  BIGINT,
    species_id    BIGINT,
    name          TEXT,
    beast_rank    SMALLINT,
    kind          TEXT,
    region_code   TEXT,
    region_name   TEXT,
    max_hp        BIGINT,
    current_hp    BIGINT,
    status        TEXT,
    seconds_left  NUMERIC,
    fighters      INTEGER,
    total_damage  BIGINT,
    my_strikes    INTEGER,
    my_damage     BIGINT,
    my_taken      BIGINT,
    strikes_left  INTEGER,
    my_share      NUMERIC,
    rewarded      BOOLEAN,
    slayer        TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT
        e.encounter_id, e.species_id, cs.name, cs.rank, cs.kind,
        e.region_code, r.name,
        e.max_hp, e.current_hp, e.status,
        GREATEST(0, EXTRACT(EPOCH FROM (e.closes_at - now()))),
        (SELECT count(*)::integer FROM boss_strikes bs
         WHERE bs.encounter_id = e.encounter_id),
        (SELECT COALESCE(sum(bs.damage), 0)::bigint FROM boss_strikes bs
         WHERE bs.encounter_id = e.encounter_id),
        COALESCE(mine.strikes, 0),
        COALESCE(mine.damage, 0),
        COALESCE(mine.taken, 0),
        GREATEST(0, game_config_value('boss_strikes_each')::integer
                    - COALESCE(mine.strikes, 0)),
        CASE WHEN e.max_hp - e.current_hp > 0
             THEN round(COALESCE(mine.damage, 0)::numeric
                        / (e.max_hp - e.current_hp), 4)
             ELSE 0 END,
        mine.rewarded_at IS NOT NULL,
        slayer.discord_name
    FROM boss_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    JOIN regions r ON r.code = e.region_code
    LEFT JOIN boss_strikes mine
           ON mine.encounter_id = e.encounter_id AND mine.player_id = p_player_id
    LEFT JOIN players slayer ON slayer.player_id = e.slayer_id
    -- The one that is standing, else the last one that was, so a player who
    -- arrives after the kill still sees what happened and can claim a share.
    ORDER BY (e.status = 'open') DESC, e.opened_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION boss_state(BIGINT) IS
    'The world beast that is standing, or the last one that stood, judged against one cultivator: what it is, what they did to it, and what they have left.';


CREATE FUNCTION boss_leaderboard(p_encounter_id BIGINT)
RETURNS TABLE (
    player_id    BIGINT,
    discord_name TEXT,
    strikes      INTEGER,
    damage       BIGINT,
    share        NUMERIC
)
LANGUAGE sql STABLE
AS $$
    SELECT bs.player_id, p.discord_name, bs.strikes, bs.damage,
           round(bs.damage::numeric
                 / NULLIF(sum(bs.damage) OVER (), 0), 4)
    FROM boss_strikes bs
    JOIN players p ON p.player_id = bs.player_id
    WHERE bs.encounter_id = p_encounter_id
    ORDER BY bs.damage DESC, bs.strikes, p.discord_name;
$$;

COMMENT ON FUNCTION boss_leaderboard(BIGINT) IS
    'Who hit a world beast and how hard. The share is of damage actually dealt, so it sums to 1 whether or not the beast died.';
