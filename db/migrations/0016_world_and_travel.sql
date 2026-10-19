-- 0016_world_and_travel
--
-- Puts the game on a map. Five regions, the distances between them, and where
-- each player is standing.
--
-- Travel is a claim on a span of time, resolved on arrival - the same shape
-- `training_sessions` has, and the reason 0013 kept that table rather than
-- dropping it. It is stored as intent plus an arrival time rather than being
-- paid out by a job, exactly like passive cultivation: nothing ticks, and a
-- player who closes Discord mid-journey still arrives.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- regions
-- ---------------------------------------------------------------------------

CREATE TABLE regions (
    code         TEXT PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,

    -- Roughly how hard the local wildlife hits. Descriptive, derived from the
    -- creatures actually placed here - it is not a multiplier on anything.
    -- Two sources of truth for difficulty is how a roster and its label drift
    -- apart.
    danger_level SMALLINT NOT NULL DEFAULT 1 CHECK (danger_level BETWEEN 1 AND 10),

    description  TEXT NOT NULL DEFAULT '',
    emoji        TEXT NOT NULL DEFAULT '\N{ROUND PUSHPIN}',
    sort_order   SMALLINT NOT NULL DEFAULT 0
);

COMMENT ON COLUMN regions.danger_level IS
    'Display only. Difficulty lives in the stats of the creatures placed here, not in this number.';

INSERT INTO regions (code, name, danger_level, emoji, description, sort_order) VALUES
    ('central', 'Central Continent', 2, '🏯',
     'Fertile plains ruled by ancient sects under the Heavenly Court. The richest primeval energy in the air, and the most refined cultivation system to spend it on.', 10),
    ('western', 'Western Desert', 4, '🏜️',
     'Scorching sand, old tombs and worse merchants. The Treasure Yellow Heaven trades here with all five regions, and the Dragonman clans hold what is left.', 20),
    ('eastern', 'Eastern Sea', 3, '🌊',
     'An endless misty sea dotted with island holdings. Fierce clan wars over anything that grows, and currents that do not care who is winning.', 30),
    ('northern', 'Northern Plains', 5, '🏔️',
     'Grassland under cruel blizzards, walked by nomads who fight better than anyone. The most Gu Masters and the shortest tempers.', 40),
    ('southern', 'Southern Border', 4, '🌴',
     'Mountains, jungle, and miasma that kills slower than the wildlife does. Righteous clans under the Wu, and the heaviest Earth Path dao marks anywhere.', 50);


-- ---------------------------------------------------------------------------
-- region_routes
-- ---------------------------------------------------------------------------
-- Travel time between two regions, in hours before the speed multiplier.
--
-- Each pair is stored ONCE, with a CHECK forcing the canonical order. Storing
-- both directions would be twenty rows that must agree, and the day they stop
-- agreeing is the day travelling north takes longer than travelling back.
-- Distance is symmetric; the table says so rather than hoping.
--
-- The geography is a cross with Central at the middle, so Central is close to
-- everything and the outer regions are far from each other - and the two
-- opposite pairs, north/south and east/west, are the longest journeys in the
-- game.

CREATE TABLE region_routes (
    origin       TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    destination  TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,

    travel_hours NUMERIC(6, 2) NOT NULL CHECK (travel_hours > 0),

    PRIMARY KEY (origin, destination),

    -- Canonical ordering, so a pair cannot be entered twice in two directions.
    CONSTRAINT region_routes_canonical_pair CHECK (origin < destination)
);

CREATE INDEX region_routes_destination_idx ON region_routes (destination);

INSERT INTO region_routes (origin, destination, travel_hours) VALUES
    -- Central sits in the middle: one short hop from anywhere.
    ('central',  'northern', 2),
    ('central',  'southern', 2),
    ('central',  'eastern',  2),
    ('central',  'western',  2),

    -- Corner to corner, going around the middle.
    ('eastern',  'northern', 4),
    ('northern', 'western',  4),
    ('eastern',  'southern', 4),
    ('southern', 'western',  4),

    -- Straight across. The long hauls.
    ('northern', 'southern', 6),
    ('eastern',  'western',  6);

INSERT INTO game_config (key, value, description) VALUES
    ('travel_speed_multiplier', 1,
     'Scales every route''s travel_hours. Lower is faster; the single dial for making the world feel smaller.');


-- ---------------------------------------------------------------------------
-- travel_hours
-- ---------------------------------------------------------------------------
-- The one place that knows the pair is stored in canonical order. Every caller
-- asks "how far is A from B" without caring which way round the row went in.

CREATE FUNCTION travel_hours(p_from TEXT, p_to TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    base NUMERIC;
BEGIN
    IF p_from = p_to THEN
        RETURN 0;
    END IF;

    SELECT r.travel_hours INTO base
    FROM region_routes r
    WHERE r.origin = LEAST(p_from, p_to)
      AND r.destination = GREATEST(p_from, p_to);

    IF base IS NULL THEN
        RAISE EXCEPTION 'no route between % and %', p_from, p_to;
    END IF;

    RETURN base * game_config_value('travel_speed_multiplier');
END;
$$;

COMMENT ON FUNCTION travel_hours(TEXT, TEXT) IS
    'Hours between two regions, in either order. Raises if no route exists rather than returning NULL into arithmetic.';


-- ---------------------------------------------------------------------------
-- player_location
-- ---------------------------------------------------------------------------
-- Where a player is, and where they are going.
--
-- The three journey columns are all-or-nothing, the same discipline
-- training_sessions uses for its payout: a half-set journey is the kind of row
-- that strands somebody between regions forever.
--
-- Note there is no "in transit" flag. Being in transit IS having a
-- destination, so the two cannot disagree.

CREATE TABLE player_location (
    player_id     BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    region_code   TEXT NOT NULL REFERENCES regions (code) ON DELETE RESTRICT,

    travelling_to TEXT REFERENCES regions (code) ON DELETE RESTRICT,
    departed_at   TIMESTAMPTZ,
    arrives_at    TIMESTAMPTZ,

    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT player_location_journey_is_whole CHECK (
        (travelling_to IS NULL AND departed_at IS NULL AND arrives_at IS NULL)
        OR
        (travelling_to IS NOT NULL AND departed_at IS NOT NULL AND arrives_at IS NOT NULL)
    ),
    -- You cannot travel to where you already are.
    CONSTRAINT player_location_journey_goes_somewhere CHECK (
        travelling_to IS NULL OR travelling_to <> region_code
    ),
    CONSTRAINT player_location_arrives_after_departure CHECK (
        arrives_at IS NULL OR arrives_at > departed_at
    )
);

CREATE TRIGGER player_location_set_updated_at
    BEFORE UPDATE ON player_location
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX player_location_region_idx ON player_location (region_code);

-- The FK index for travelling_to. Unindexed, retiring a region would
-- seq-scan every player on the road.
CREATE INDEX player_location_destination_idx ON player_location (travelling_to);

-- "Who is on the road" and the arrival sweep, if one is ever wanted.
CREATE INDEX player_location_arriving_idx
    ON player_location (arrives_at)
    WHERE arrives_at IS NOT NULL;

COMMENT ON TABLE player_location IS
    'Where each player stands. A non-NULL travelling_to IS being in transit - there is no separate flag to disagree with it.';

-- Everyone who already exists starts in the Central Continent, which is the
-- region the setting treats as the middle of the world.
INSERT INTO player_location (player_id, region_code)
SELECT player_id, 'central' FROM players
ON CONFLICT (player_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- arrive
-- ---------------------------------------------------------------------------
-- Lands a journey whose time has come. Called at the top of anything that
-- cares where a player is, the same way settle_passive_cultivation is called
-- before anything that shows progress - so arrival happens the moment somebody
-- looks, with no scheduler to miss it.
--
-- Returns TRUE only when it actually moved somebody, so a caller can say
-- "you have arrived" without a second query.

CREATE FUNCTION arrive(p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    moved INTEGER;
BEGIN
    UPDATE player_location
    SET region_code   = travelling_to,
        travelling_to = NULL,
        departed_at   = NULL,
        arrives_at    = NULL
    WHERE player_id = p_player_id
      AND travelling_to IS NOT NULL
      AND arrives_at <= now();

    -- ROW_COUNT is an integer; there is no implicit cast to boolean, so the
    -- comparison is written out rather than assigned straight into one.
    GET DIAGNOSTICS moved = ROW_COUNT;
    RETURN moved > 0;
END;
$$;

COMMENT ON FUNCTION arrive(BIGINT) IS
    'Lands a due journey. Safe to call on every command; returns TRUE only when it moved someone.';


-- ---------------------------------------------------------------------------
-- begin_travel
-- ---------------------------------------------------------------------------
-- Sets off, and refuses every way this can go wrong: already travelling,
-- already there, or nowhere to go. Doing the checks inside one statement means
-- two /travel commands racing cannot both set a departure.

CREATE FUNCTION begin_travel(p_player_id BIGINT, p_destination TEXT)
RETURNS TABLE (
    origin       TEXT,
    destination  TEXT,
    hours        NUMERIC,
    arrives_at   TIMESTAMPTZ
)
LANGUAGE plpgsql
AS $$
DECLARE
    here     player_location%ROWTYPE;
    duration NUMERIC;
BEGIN
    -- Land anything already due before deciding where they are.
    PERFORM arrive(p_player_id);

    SELECT * INTO here FROM player_location
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;
    IF here.travelling_to IS NOT NULL THEN
        RAISE EXCEPTION 'already travelling to %', here.travelling_to
            USING ERRCODE = 'check_violation';
    END IF;
    IF here.region_code = p_destination THEN
        RAISE EXCEPTION 'already in %', p_destination
            USING ERRCODE = 'check_violation';
    END IF;

    duration := travel_hours(here.region_code, p_destination);

    UPDATE player_location
    SET travelling_to = p_destination,
        departed_at   = now(),
        arrives_at    = now() + make_interval(secs => duration * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY
    SELECT here.region_code, p_destination, duration,
           (now() + make_interval(secs => duration * 3600));
END;
$$;

COMMENT ON FUNCTION begin_travel(BIGINT, TEXT) IS
    'Departs for a region. Raises check_violation when already travelling or already there.';
