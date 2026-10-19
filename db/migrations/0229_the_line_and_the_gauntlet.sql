-- 0229_the_line_and_the_gauntlet
--
-- The Beast Horde becomes two lanes into one tide.
--
-- THE CHANNEL BECOMES A WORLD BOSS. Three beasts loose at a time, each felled
-- by one click from one cultivator, made the channel a queue rather than a
-- fight - a strong defender cleared every spawn before anybody else opened
-- Discord, and the "shared" event belonged to whoever was fastest. So the
-- channel now holds FEWER beasts and each is far bigger: something nobody
-- drops alone, standing long enough that everybody who wanders in gets a swing
-- on the same body. That is what the click-to-strike button was always for.
--
-- THE LINE BECOMES /fight horde. A cultivator who wants to fight the tide
-- rather than wait for a spawn now walks the line themselves: weaker beasts,
-- one at a time, each wave harder than the last, until they are put down. How
-- deep they got is what they contributed. It is private, it costs nothing to
-- lose, and it can be run again and again until the tide has no beasts left to
-- send.
--
-- THEY SHARE ONE POOL, WHICH IS THE POINT. Every beast felled either way comes
-- off `beasts_total`, so the gauntlet is not a side activity with its own
-- scoreboard - it is how the sea gets emptied, and emptying the sea is what
-- brings the King out. Two lanes, one tide, one verdict.
--
-- A CHANNEL BEAST IS A PACK, so `worth` is on the encounter. A world beast
-- that counted as one would mean the sea could never be emptied through the
-- channel, and the tide would come down entirely to how many gauntlets got
-- run. It is worth what it looks like: felling it takes that many beasts out
-- of the tide, and letting it past puts that many into the region.
--
-- THE GAUNTLET CANNOT COST YOU ANYTHING. The body it uses is the run's, seeded
-- from the physique and thrown away at the end - real health is untouched
-- whether they reach wave two or wave forty. 0225 made the same call about
-- life steal in a channel, for the same reason: a public event that could set
-- a cultivator back is a trap, and nobody turns up twice to a trap. The one
-- thing a run spends is beasts, and those belong to the tide.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A beast in the channel is a pack
-- ---------------------------------------------------------------------------

ALTER TABLE horde_encounters
    ADD COLUMN worth SMALLINT NOT NULL DEFAULT 1 CHECK (worth > 0);

COMMENT ON COLUMN horde_encounters.worth IS
    'How many beasts of the tide this one encounter stands for. A gauntlet wave is one; a world beast in the channel is a pack, and felling it or losing it moves the tide by that much.';


-- ---------------------------------------------------------------------------
-- The dials
-- ---------------------------------------------------------------------------

-- Fewer on the board, and each one a fight.
UPDATE game_config SET value = 1,
    description = 'Beasts loose in the channel at once per hand. One, because '
                  'a channel beast is now a world beast - the room shares it '
                  'rather than racing for it.'
WHERE key = 'horde_live_per_hand';

UPDATE game_config SET value = 1,
    description = 'Beasts loose at once when nobody has swung yet. One is '
                  'enough to find.'
WHERE key = 'horde_live_floor';

UPDATE game_config SET value = 3,
    description = 'Beasts loose at once, whatever the turnout. Three world '
                  'beasts is already more than one room can focus on.'
WHERE key = 'horde_live_ceiling';

UPDATE game_config SET value = 15,
    description = 'How long a world beast stands in the channel before it '
                  'breaks through. Long, because it takes a crowd and the '
                  'crowd arrives at its own pace.'
WHERE key = 'horde_beast_minutes';

-- A breach now costs what the pack was worth, so the rope has to be longer.
UPDATE game_config SET value = 30,
    description = 'How many beasts may break through per hand before the line '
                  'does. Counted in beasts rather than breaches - one world '
                  'beast getting past is a pack getting past.'
WHERE key = 'horde_line_per_hand';

INSERT INTO game_config (key, value, description) VALUES
    ('horde_world_hp', 9,
     'How much more health a beast in the channel carries than the same beast '
     'would in a gauntlet wave. This is the number that makes it a world beast '
     'rather than a click.'),
    ('horde_world_worth', 12,
     'How many beasts of the tide one channel beast stands for. A world beast '
     'is a pack, and the sea has to be emptiable through the channel.'),

    ('horde_gauntlet_start', 0.35,
     'The first wave, as a fraction of what one beast of this tide would '
     'carry. Wave one is meant to be a warm-up nobody loses to.'),
    ('horde_gauntlet_step', 1.18,
     'How much harder each wave is than the one before - health and the bite '
     'both. Compounding, so a run ends on its own without a wave limit.'),
    ('horde_gauntlet_bite', 0.55,
     'How hard a gauntlet beast hits compared to meeting it in the wild, '
     'before the wave step. The early waves have to be survivable for the ramp '
     'to mean anything.'),
    ('horde_gauntlet_depth', 40,
     'Extra contribution for clearing a wave, times the wave number. Depth is '
     'the whole score in this lane, so it pays more than linearly.'),
    ('horde_gauntlet_exchanges', 40,
     'The most blows traded in one wave before it is left standing. A guard '
     'against a wall neither side can break, not a rule of the fight.');


-- ---------------------------------------------------------------------------
-- What the channel sends now
-- ---------------------------------------------------------------------------
-- Replaced whole rather than patched: the health, the worth and the stopping
-- condition all change together, and three separate anchors into one function
-- would be harder to read than the function.

CREATE OR REPLACE FUNCTION horde_spawn(p_horde_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide    RECORD;
    loose   INTEGER;
    packed  INTEGER;
    species RECORD;
    elite   BOOLEAN;
    pool    BIGINT;
    pack    SMALLINT;
    made    BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id;

    IF NOT FOUND OR tide.status <> 'fighting' THEN
        RETURN NULL;
    END IF;

    -- Never more on the board than the room can read, and never more than
    -- there are beasts left to send. `loose` counts bodies, because that is
    -- what the cap is about; `packed` counts beasts, because that is what the
    -- tide is about.
    SELECT count(*)::integer, COALESCE(sum(e.worth), 0)::integer
    INTO loose, packed
    FROM horde_encounters e
    WHERE e.horde_id = p_horde_id AND e.status = 'alive';

    IF loose >= horde_live_cap(p_horde_id) THEN
        RETURN NULL;
    END IF;
    IF tide.beasts_slain + packed >= tide.beasts_total THEN
        RETURN NULL;
    END IF;

    elite := random() < game_config_value('horde_elite_chance');

    -- The region's own, weighted the way a hunt weights it.
    SELECT cs.* INTO species
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = tide.region_code
      AND cs.kind = CASE WHEN elite THEN 'elite' ELSE 'beast' END
    ORDER BY -ln(random()) / cr.weight
    LIMIT 1;

    -- A region with no elites in it still gets a tide.
    IF species IS NULL THEN
        elite := FALSE;
        SELECT cs.* INTO species
        FROM creature_regions cr
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cr.region_code = tide.region_code AND cs.kind = 'beast'
        ORDER BY -ln(random()) / cr.weight
        LIMIT 1;
    END IF;

    IF species IS NULL THEN
        RETURN NULL;
    END IF;

    -- Pitched at the tide's rank rather than the beast's, and then at the size
    -- of the thing it now is. `horde_world_hp` is the whole difference between
    -- a spawn one person clears and a body a channel has to gang up on.
    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * game_config_value('horde_world_hp')
                              * CASE WHEN elite
                                     THEN game_config_value('horde_elite_hp')
                                     ELSE 1 END))::bigint;

    pack := GREATEST(1, round(game_config_value('horde_world_worth')
                              * CASE WHEN elite THEN 1.5 ELSE 1 END))::smallint;

    -- Never more of the tide than is left in it, so a pack arriving late
    -- cannot overdraw the sea.
    pack := LEAST(pack,
                  GREATEST(1, tide.beasts_total - tide.beasts_slain - packed))::smallint;

    INSERT INTO horde_encounters
        (horde_id, species_id, kind, hp, max_hp, worth, expires_at)
    VALUES (p_horde_id, species.species_id,
            CASE WHEN elite THEN 'elite' ELSE 'normal' END,
            pool, pool, pack,
            now() + make_interval(
                mins => game_config_value('horde_beast_minutes')::integer))
    RETURNING encounter_id INTO made;

    RETURN made;
END;
$$;


-- A pack felled takes the pack out of the tide.
DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := '        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + 1
        WHERE h.horde_id = met.horde_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer counts a kill the old way';
    END IF;

    EXECUTE replace(src, old,
        '        -- One body, but as many beasts as it stood for.
        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + met.worth
        WHERE h.horde_id = met.horde_id;');
END;
$$;


-- And a pack that got past put the pack into the region.
CREATE OR REPLACE FUNCTION horde_sweep(p_horde_id BIGINT)
RETURNS TABLE (escaped INTEGER, beast_names TEXT[])
LANGUAGE plpgsql
AS $$
DECLARE
    got  INTEGER := 0;
    away INTEGER := 0;
    said TEXT[]  := '{}';
BEGIN
    WITH gone AS (
        UPDATE horde_encounters e
        SET status = 'escaped', settled_at = now()
        WHERE e.horde_id = p_horde_id
          AND e.status = 'alive'
          AND e.expires_at <= now()
        RETURNING e.species_id, e.worth
    )
    SELECT count(*)::integer,
           COALESCE(sum(gone.worth), 0)::integer,
           COALESCE(array_agg(DISTINCT cs.name), '{}')
    INTO got, away, said
    FROM gone
    JOIN creature_species cs ON cs.species_id = gone.species_id;

    IF got > 0 THEN
        -- Counted in beasts, not bodies: the line is about what reached the
        -- region, and a pack reaching it is worse than a straggler.
        UPDATE beast_hordes h
        SET beasts_lost = h.beasts_lost + away
        WHERE h.horde_id = p_horde_id;
    END IF;

    RETURN QUERY SELECT got, said;
END;
$$;


-- ---------------------------------------------------------------------------
-- The gauntlet
-- ---------------------------------------------------------------------------

CREATE TABLE horde_gauntlets (
    gauntlet_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    horde_id     BIGINT NOT NULL REFERENCES beast_hordes (horde_id) ON DELETE CASCADE,
    player_id    BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    wave         INTEGER NOT NULL DEFAULT 0 CHECK (wave >= 0),
    felled       INTEGER NOT NULL DEFAULT 0 CHECK (felled >= 0),

    -- The run's own body. Not `player_physique`, on purpose: losing here is
    -- meant to cost the run and nothing else.
    hp           BIGINT NOT NULL CHECK (hp >= 0),
    max_hp       BIGINT NOT NULL CHECK (max_hp > 0),

    species_id   BIGINT REFERENCES creature_species (species_id) ON DELETE RESTRICT,
    beast_hp     BIGINT NOT NULL DEFAULT 0 CHECK (beast_hp >= 0),
    beast_max_hp BIGINT NOT NULL DEFAULT 0 CHECK (beast_max_hp >= 0),

    damage_dealt BIGINT NOT NULL DEFAULT 0,
    healing_done BIGINT NOT NULL DEFAULT 0,
    damage_taken BIGINT NOT NULL DEFAULT 0,

    status       TEXT NOT NULL DEFAULT 'fighting'
                 CHECK (status IN ('fighting', 'fallen', 'cleared')),

    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at     TIMESTAMPTZ,

    CONSTRAINT horde_gauntlet_ended_matches_status CHECK (
        (status = 'fighting') = (ended_at IS NULL)),
    CONSTRAINT horde_gauntlet_hp_in_range CHECK (hp <= max_hp),
    CONSTRAINT horde_gauntlet_beast_in_range CHECK (beast_hp <= beast_max_hp)
);

COMMENT ON TABLE horde_gauntlets IS
    'One walk down the line: waves of beasts from the tide, each harder than the last, until the cultivator is put down. How deep they got is what they contributed.';

CREATE UNIQUE INDEX horde_gauntlets_one_live_idx ON horde_gauntlets (player_id)
    WHERE status = 'fighting';
CREATE INDEX horde_gauntlets_horde_idx   ON horde_gauntlets (horde_id);
CREATE INDEX horde_gauntlets_player_idx  ON horde_gauntlets (player_id);
CREATE INDEX horde_gauntlets_species_idx ON horde_gauntlets (species_id);


-- What the tide has left to send, counting what is already standing.
CREATE FUNCTION horde_sea_left(p_horde_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(0, h.beasts_total - h.beasts_slain
        - COALESCE((SELECT sum(e.worth)::integer FROM horde_encounters e
                    WHERE e.horde_id = h.horde_id AND e.status = 'alive'), 0))
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_sea_left(BIGINT) IS
    'Beasts the tide has not sent yet. Both lanes draw from this, and it is what the King is waiting behind.';


-- Roll the next wave onto a run. FALSE when the sea has nothing left to send.
CREATE FUNCTION horde_gauntlet_next(p_gauntlet_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    run     RECORD;
    tide    RECORD;
    species RECORD;
    step    NUMERIC;
    pool    BIGINT;
BEGIN
    SELECT * INTO run FROM horde_gauntlets WHERE gauntlet_id = p_gauntlet_id;
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = run.horde_id;

    IF tide.status <> 'fighting' OR horde_sea_left(run.horde_id) <= 0 THEN
        RETURN FALSE;
    END IF;

    -- Beasts only. The gauntlet is the weaker lane by design; the elites and
    -- the packs stand in the channel where a crowd can meet them.
    SELECT cs.* INTO species
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = tide.region_code AND cs.kind = 'beast'
    ORDER BY -ln(random()) / cr.weight
    LIMIT 1;

    IF species IS NULL THEN
        RETURN FALSE;
    END IF;

    step := power(game_config_value('horde_gauntlet_step'), run.wave);
    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * game_config_value('horde_gauntlet_start')
                              * step))::bigint;

    UPDATE horde_gauntlets g
    SET wave = g.wave + 1,
        species_id = species.species_id,
        beast_hp = pool,
        beast_max_hp = pool
    WHERE g.gauntlet_id = p_gauntlet_id;

    RETURN TRUE;
END;
$$;


CREATE FUNCTION horde_gauntlet_open(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide RECORD;
    body BIGINT;
    made BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes
    WHERE status = 'fighting' ORDER BY horde_id DESC LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no tide to walk into'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM horde_gauntlets g
               WHERE g.player_id = p_player_id AND g.status = 'fighting') THEN
        RAISE EXCEPTION 'you are already on the line'
            USING ERRCODE = 'check_violation';
    END IF;

    IF dungeon_default_move(p_player_id) IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    IF horde_sea_left(tide.horde_id) <= 0 THEN
        RAISE EXCEPTION 'the sea is empty - what is left of it is in the channel'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.max_hp INTO body FROM player_physique pp
    WHERE pp.player_id = p_player_id;

    IF body IS NULL THEN
        RAISE EXCEPTION 'you have no body to walk it with'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Full, unlike a dungeon, where you go in as you are. A dungeon costs a
    -- key and wounds you for real; this costs nothing and cannot, so starting
    -- at anything but full would measure the last fight instead of the build.
    INSERT INTO horde_gauntlets (horde_id, player_id, hp, max_hp)
    VALUES (tide.horde_id, p_player_id, GREATEST(1, body), GREATEST(1, body))
    RETURNING gauntlet_id INTO made;

    IF NOT horde_gauntlet_next(made) THEN
        UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
        WHERE gauntlet_id = made;
    END IF;

    RETURN made;
END;
$$;


CREATE FUNCTION horde_gauntlet_fight(p_gauntlet_id BIGINT)
RETURNS TABLE (
    wave        INTEGER,
    beast_name  TEXT,
    dealt       BIGINT,
    taken       BIGINT,
    healed      BIGINT,
    beast_down  BOOLEAN,
    you_down    BOOLEAN,
    hp_left     BIGINT,
    hp_max      BIGINT,
    beast_left  BIGINT,
    earned      BIGINT,
    run_status  TEXT,
    sea_left    INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    run       RECORD;
    species   RECORD;
    move      BIGINT;
    swung     RECORD;
    bit       RECORD;
    guard     INTEGER;
    swaps     INTEGER := 0;
    out_dmg   BIGINT := 0;
    out_heal  BIGINT := 0;
    out_taken BIGINT := 0;
    body      BIGINT;
    pool      BIGINT;
    hurt      BIGINT;
    down      BOOLEAN := FALSE;
    paid      BIGINT := 0;
    bite      NUMERIC;
    was_wave  INTEGER;
BEGIN
    SELECT * INTO run FROM horde_gauntlets
    WHERE gauntlet_id = p_gauntlet_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such run' USING ERRCODE = 'check_violation';
    END IF;
    IF run.status <> 'fighting' THEN
        RAISE EXCEPTION 'that run is over' USING ERRCODE = 'check_violation';
    END IF;
    IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = run.horde_id)
       <> 'fighting' THEN
        UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
        WHERE gauntlet_id = p_gauntlet_id;
        RAISE EXCEPTION 'the tide has broken off' USING ERRCODE = 'check_violation';
    END IF;

    SELECT cs.* INTO species FROM creature_species cs
    WHERE cs.species_id = run.species_id;

    move := dungeon_default_move(run.player_id);
    IF move IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    guard    := game_config_value('horde_gauntlet_exchanges')::integer;
    bite     := game_config_value('horde_gauntlet_bite')
                * power(game_config_value('horde_gauntlet_step'), run.wave - 1);
    body     := run.hp;
    pool     := run.beast_hp;
    was_wave := run.wave;

    -- One press is the whole wave: blows are traded until somebody drops. A
    -- wave at a time rather than a swing at a time is what keeps a twenty wave
    -- run to twenty clicks.
    LOOP
        swaps := swaps + 1;
        EXIT WHEN swaps > guard;

        SELECT * INTO swung FROM player_swing(
            run.player_id, move, run.species_id, pool,
            species.base_defense::bigint, body, run.max_hp, swaps);

        out_dmg  := out_dmg + swung.dealt;
        pool     := swung.hp_left;
        out_heal := out_heal + swung.healed;
        body     := LEAST(run.max_hp, body + swung.healed);

        EXIT WHEN pool <= 0;

        SELECT * INTO bit FROM compute_creature_damage(
            run.species_id, run.player_id, bite,
            (SELECT pp.defense FROM player_physique pp
             WHERE pp.player_id = run.player_id)::bigint);

        hurt      := GREATEST(0, bit.final_damage);
        out_taken := out_taken + hurt;
        body      := GREATEST(0, body - hurt);

        EXIT WHEN body <= 0;
    END LOOP;

    down := pool <= 0;

    IF down THEN
        -- The bounty a channel kill pays, and the depth bonus that is the
        -- whole point of this lane: it is times the wave, so the sum over a
        -- run grows faster than the run is long.
        paid := round(game_config_value('horde_slay_bounty')
                      * GREATEST(1, species.rank))::bigint
              + round(game_config_value('horde_gauntlet_depth') * was_wave)::bigint;

        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + 1
        WHERE h.horde_id = run.horde_id;
    END IF;

    -- Credited every wave rather than at the end, so a run somebody walks away
    -- from still counted, and so the board moves while they are still on it.
    INSERT INTO horde_contributions
        (horde_id, player_id, damage_dealt, healing_done, beasts_slain,
         last_swing_at)
    VALUES (run.horde_id, run.player_id, out_dmg + paid, out_heal,
            CASE WHEN down THEN 1 ELSE 0 END, now())
    ON CONFLICT (horde_id, player_id) DO UPDATE
        SET damage_dealt  = horde_contributions.damage_dealt + out_dmg + paid,
            healing_done  = horde_contributions.healing_done + out_heal,
            beasts_slain  = horde_contributions.beasts_slain
                            + CASE WHEN down THEN 1 ELSE 0 END,
            last_swing_at = now();

    UPDATE horde_gauntlets g
    SET hp = body,
        beast_hp = GREATEST(0, pool),
        felled = g.felled + CASE WHEN down THEN 1 ELSE 0 END,
        damage_dealt = g.damage_dealt + out_dmg,
        healing_done = g.healing_done + out_heal,
        damage_taken = g.damage_taken + out_taken
    WHERE g.gauntlet_id = p_gauntlet_id;

    IF body <= 0 THEN
        UPDATE horde_gauntlets SET status = 'fallen', ended_at = now()
        WHERE gauntlet_id = p_gauntlet_id;
    ELSIF down THEN
        -- Straight into the next one. A run ends by being ended, not by being
        -- asked whether to continue.
        IF NOT horde_gauntlet_next(p_gauntlet_id) THEN
            UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
            WHERE gauntlet_id = p_gauntlet_id;
        END IF;
    END IF;

    SELECT * INTO run FROM horde_gauntlets WHERE gauntlet_id = p_gauntlet_id;

    RETURN QUERY SELECT
        was_wave, species.name, out_dmg, out_taken, out_heal,
        down, (run.status = 'fallen'),
        run.hp, run.max_hp, run.beast_hp, paid, run.status,
        horde_sea_left(run.horde_id);
END;
$$;

COMMENT ON FUNCTION horde_gauntlet_fight(BIGINT) IS
    'One wave, fought to its end. The cultivator swings with `player_swing` like everywhere else, the beast answers, and it repeats until one of them is down.';


CREATE VIEW horde_gauntlet_board AS
SELECT g.gauntlet_id, g.horde_id, g.player_id, g.wave, g.felled,
       g.hp, g.max_hp, g.beast_hp, g.beast_max_hp, g.status,
       g.damage_dealt, g.healing_done, g.damage_taken,
       cs.name AS beast_name, cs.rank AS beast_rank, cs.description,
       p.discord_name,
       h.region_code, h.rank AS tide_rank,
       horde_sea_left(g.horde_id) AS sea_left,
       horde_contribution(g.horde_id, g.player_id) AS contribution
FROM horde_gauntlets g
JOIN beast_hordes h ON h.horde_id = g.horde_id
JOIN players p      ON p.player_id = g.player_id
LEFT JOIN creature_species cs ON cs.species_id = g.species_id;

COMMENT ON VIEW horde_gauntlet_board IS
    'A run as a screen reads it: where they are, what is in front of them, and what the whole tide has left.';
