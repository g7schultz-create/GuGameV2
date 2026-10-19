-- 0219_a_tide_that_comes_to_the_channel
--
-- The Beast Horde: a region under attack, in a channel, for everyone at once.
--
-- Everything in this game so far is solo with a shared database - you could
-- play all of it alone and never notice anybody else. The dungeon is the only
-- co-op and it is invite-only, so you have to already know who is around. This
-- is the first thing that happens whether you asked for it or not.
--
-- SCALED TO WHO IS THERE, NOT TO A THREAT LEVEL. This is the change that makes
-- it work on a sixteen-player server. A fixed horde of 2,846 beasts spawning
-- every forty seconds is a wall three people cannot hold, and the failure
-- state would be the default. So the size of the tide, the number of beasts
-- loose at once and what it takes to hold the line all come from how many
-- hands are actually on it. Three people get a horde three people can hold.
--
-- A BEAST THAT NOBODY MEETS BREAKS THROUGH. That is the clock: there is no
-- separate pressure meter, because two failure meters is one too many. Beasts
-- slain and beasts escaped are the same number counted from both ends, and
-- when enough have got past you the line is gone.
--
-- CONTRIBUTION IS NOT ONLY DAMAGE. A support build that never lands a killing
-- blow is not a spectator: healing counts, and so does being the one who
-- finished something. If damage were the only currency half the Paths in this
-- game would have nothing to do here.
--
-- THE KING IS A DUNGEON. `dungeon_runs` already knows how to run synchronous
-- rounds against a boss with a party, a sixty second clock and spoils split by
-- damage. The finale opens one of those rather than growing a second opinion
-- about what a boss fight is.
--
-- WHAT THIS DOES NOT HAVE, deliberately, and each of them was in the design it
-- came from: horde pressure as its own meter, phases, five horde variants,
-- rare mutations, pack encounters, sect rankings, and a Merit currency with a
-- shop. The event has to be good with three people in the room before any of
-- that is worth building.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What a region carries afterwards
-- ---------------------------------------------------------------------------
-- The only part of this that touches the world outside the event. A horde that
-- changes nothing is a slot machine with a story on it.

CREATE TABLE region_effects (
    effect_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    region_code TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    kind        TEXT NOT NULL,
    magnitude   NUMERIC(6, 4) NOT NULL,

    reason      TEXT NOT NULL DEFAULT '',
    began_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    until       TIMESTAMPTZ NOT NULL
);

CREATE INDEX region_effects_region_idx ON region_effects (region_code);
CREATE INDEX region_effects_live_idx   ON region_effects (until);

COMMENT ON TABLE region_effects IS
    'Temporary things true of a place. Written by the Beast Horde; read by anything that wants to know whether a region is blessed or overrun.';

CREATE FUNCTION region_effect(p_region TEXT, p_kind TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(e.magnitude), 0)
    FROM region_effects e
    WHERE e.region_code = p_region AND e.kind = p_kind AND e.until > now();
$$;


-- ---------------------------------------------------------------------------
-- The tide
-- ---------------------------------------------------------------------------

CREATE TABLE beast_hordes (
    horde_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    region_code  TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    rank         SMALLINT NOT NULL CHECK (rank BETWEEN 1 AND 9),

    status       TEXT NOT NULL DEFAULT 'fighting'
                 CHECK (status IN ('fighting', 'king', 'won', 'lost')),

    beasts_total INTEGER NOT NULL CHECK (beasts_total > 0),
    beasts_slain INTEGER NOT NULL DEFAULT 0 CHECK (beasts_slain >= 0),
    beasts_lost  INTEGER NOT NULL DEFAULT 0 CHECK (beasts_lost >= 0),
    line_holds   INTEGER NOT NULL CHECK (line_holds > 0),

    channel_id   BIGINT,
    board_id     BIGINT,
    king_run_id  BIGINT REFERENCES dungeon_runs (run_id) ON DELETE SET NULL,

    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ends_at      TIMESTAMPTZ NOT NULL,
    ended_at     TIMESTAMPTZ
);

CREATE INDEX beast_hordes_live_idx ON beast_hordes (status)
    WHERE status IN ('fighting', 'king');
CREATE INDEX beast_hordes_region_idx ON beast_hordes (region_code);
CREATE INDEX beast_hordes_king_idx   ON beast_hordes (king_run_id);

COMMENT ON COLUMN beast_hordes.line_holds IS
    'How many beasts may get past before the line breaks. Scaled to the hands available when the tide opened, so a small server is not handed a wall.';


CREATE TABLE horde_encounters (
    encounter_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    horde_id     BIGINT NOT NULL REFERENCES beast_hordes (horde_id) ON DELETE CASCADE,
    species_id   BIGINT NOT NULL REFERENCES creature_species (species_id)
                                  ON DELETE RESTRICT,

    kind         TEXT NOT NULL DEFAULT 'normal'
                 CHECK (kind IN ('normal', 'elite')),

    hp           BIGINT NOT NULL CHECK (hp >= 0),
    max_hp       BIGINT NOT NULL CHECK (max_hp > 0),

    status       TEXT NOT NULL DEFAULT 'alive'
                 CHECK (status IN ('alive', 'slain', 'escaped')),
    slain_by     BIGINT REFERENCES players (player_id) ON DELETE SET NULL,

    message_id   BIGINT,
    spawned_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL,
    settled_at   TIMESTAMPTZ
);

CREATE INDEX horde_encounters_horde_idx  ON horde_encounters (horde_id);
CREATE INDEX horde_encounters_alive_idx  ON horde_encounters (horde_id, status)
    WHERE status = 'alive';
CREATE INDEX horde_encounters_species_idx ON horde_encounters (species_id);
CREATE INDEX horde_encounters_slayer_idx  ON horde_encounters (slain_by);


CREATE TABLE horde_contributions (
    horde_id      BIGINT NOT NULL REFERENCES beast_hordes (horde_id) ON DELETE CASCADE,
    player_id     BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    damage_dealt  BIGINT NOT NULL DEFAULT 0,
    healing_done  BIGINT NOT NULL DEFAULT 0,
    beasts_slain  INTEGER NOT NULL DEFAULT 0,
    elites_slain  INTEGER NOT NULL DEFAULT 0,

    chest_taken   SMALLINT NOT NULL DEFAULT 0,
    last_swing_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (horde_id, player_id)
);

CREATE INDEX horde_contributions_player_idx ON horde_contributions (player_id);
CREATE INDEX horde_contributions_recent_idx ON horde_contributions (horde_id, last_swing_at);


-- ---------------------------------------------------------------------------
-- The dials
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('horde_hours', 2,
     'How long a tide runs before it is decided one way or the other.'),
    ('horde_recent_minutes', 20,
     'A hand is somebody who swung within this many minutes. Everything that '
     'scales to the room scales to that number.'),
    ('horde_beasts_per_hand', 40,
     'Beasts in the tide per hand on the line, before rank. A tide is meant '
     'to be finishable by the people actually in the channel.'),
    ('horde_line_per_hand', 8,
     'How many beasts may break through per hand before the line does. Fewer '
     'defenders is a shorter rope, not an impossible one.'),
    ('horde_live_per_hand', 3,
     'Beasts loose in the channel at once per hand, so the board is busy '
     'without becoming unreadable.'),
    ('horde_live_floor', 2,
     'Beasts loose at once when nobody has swung yet. Something has to be on '
     'the board for the first person to find.'),
    ('horde_live_ceiling', 10,
     'Beasts loose at once, whatever the turnout. Discord has to stay '
     'readable and edits have to stay under the rate limit.'),
    ('horde_beast_minutes', 6,
     'How long a beast stands in the channel before it breaks through.'),
    ('horde_elite_chance', 0.18,
     'Chance a spawn is an elite rather than a common beast.'),
    ('horde_elite_hp', 3.5,
     'How much more health an elite carries.'),
    ('horde_heal_weight', 2,
     'What a point of healing is worth against a point of damage. Support '
     'lands less of it, and none of it is wasted on overkill.'),
    ('horde_slay_bounty', 60,
     'Contribution for the blow that finishes a beast, times its rank. The '
     'finisher is not always the one who did the most, and turning up to a '
     'fight somebody else started is worth something.');


-- ---------------------------------------------------------------------------
-- How many hands are on the line
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_hands(p_horde_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, count(*))::integer
    FROM horde_contributions c
    WHERE c.horde_id = p_horde_id
      AND c.last_swing_at > now() - make_interval(
              mins => game_config_value('horde_recent_minutes')::integer);
$$;

COMMENT ON FUNCTION horde_hands(BIGINT) IS
    'Who has swung lately. The one number the whole event scales to - a fixed threat level on a sixteen-player server is a wall nobody can hold.';


CREATE FUNCTION horde_contribution(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        c.damage_dealt
        + c.healing_done * game_config_value('horde_heal_weight')::bigint,
        0)::bigint
    FROM horde_contributions c
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;
$$;


CREATE VIEW horde_board AS
SELECT h.horde_id, h.region_code, r.name AS region_name, r.emoji AS region_emoji,
       h.rank, h.status, h.beasts_total, h.beasts_slain, h.beasts_lost,
       h.line_holds, h.channel_id, h.board_id, h.king_run_id,
       h.opened_at, h.ends_at, h.ended_at,
       GREATEST(0, h.beasts_total - h.beasts_slain) AS beasts_left,
       horde_hands(h.horde_id) AS hands,
       (SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = h.horde_id AND e.status = 'alive') AS loose,
       (SELECT count(*) FROM horde_contributions c
        WHERE c.horde_id = h.horde_id) AS defenders
FROM beast_hordes h
JOIN regions r ON r.code = h.region_code;
