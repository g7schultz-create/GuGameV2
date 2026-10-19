-- 0220_the_tide_comes_in_and_is_held
--
-- What a Beast Horde actually does: open, spawn, be hit, lose beasts through
-- the line, and be settled one way or the other.
--
-- ONE TIDE AT A TIME. `horde_open` refuses while another is live. Two hordes
-- on a sixteen-player server would split a room that is already small, and the
-- whole point of the event is that everybody is in the same place.
--
-- A BEAST IS THE REGION'S OWN. It is drawn from `creature_regions`, weighted
-- the way `/hunt` weights it, so the Western Desert tide is scorpions and the
-- Eastern Sea tide is not. No new bestiary, no second opinion about what lives
-- where.
--
-- THE DAMAGE IS THE DATABASE'S. `horde_strike` calls the same
-- `compute_technique_damage` a duel, a hunt and a dungeon round call. A horde
-- is not a place where hitting things works differently.
--
-- NOBODY DIES IN THE CHANNEL. A tide is a public event that runs for two hours
-- and a death that cost you your cultivation would make it a trap rather than
-- an invitation. The beast does not swing back; the cost of failing to kill it
-- is that it gets past you, and enough of those ends the event for everybody.
-- That is a shared price rather than a personal one, which is what a world
-- event should charge.
--
-- SETTLING IS DEMAND-DRIVEN, like everything else here: `horde_sweep` is what
-- a screen calls before it draws, and it is what decides that beasts have
-- broken through while nobody was looking.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Opening one
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_open(
    p_region  TEXT,
    p_rank    SMALLINT DEFAULT NULL,
    p_channel BIGINT   DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    hands INTEGER;
    band  SMALLINT;
    total INTEGER;
    line  INTEGER;
    made  BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM beast_hordes WHERE status IN ('fighting', 'king')) THEN
        RAISE EXCEPTION 'a tide is already running'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM regions WHERE code = p_region) THEN
        RAISE EXCEPTION 'there is no region called %', p_region
            USING ERRCODE = 'check_violation';
    END IF;

    -- Who has been about lately, since nobody has swung at a tide that does
    -- not exist yet. A day is generous on purpose: a tide sized for the three
    -- people online right now would be over before the rest woke up.
    SELECT GREATEST(1, count(*))::integer INTO hands
    FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND p.last_seen_at > now() - interval '1 day';

    -- Pitched at the middle of the room rather than at its best cultivator, so
    -- the tide is something most people can hit.
    band := COALESCE(p_rank, GREATEST(1, LEAST(9, (
        SELECT round(avg(r.rank))::smallint
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND p.discord_id <> 0
          AND p.last_seen_at > now() - interval '1 day'
    ))), 1)::smallint;

    total := GREATEST(10,
        round(hands * game_config_value('horde_beasts_per_hand')
              * (1 + band * 0.15)))::integer;
    line  := GREATEST(4,
        round(hands * game_config_value('horde_line_per_hand')))::integer;

    INSERT INTO beast_hordes
        (region_code, rank, beasts_total, line_holds, channel_id, ends_at)
    VALUES (p_region, band, total, line, p_channel,
            now() + make_interval(hours => game_config_value('horde_hours')::integer))
    RETURNING beast_hordes.horde_id INTO made;

    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- What is loose, and what may be
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_live_cap(p_horde_id BIGINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('horde_live_ceiling')::integer,
        GREATEST(
            game_config_value('horde_live_floor')::integer,
            (horde_hands(p_horde_id)
             * game_config_value('horde_live_per_hand'))::integer))
$$;


CREATE FUNCTION horde_spawn(p_horde_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide    RECORD;
    loose   INTEGER;
    species RECORD;
    elite   BOOLEAN;
    pool    BIGINT;
    made    BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id;

    IF NOT FOUND OR tide.status <> 'fighting' THEN
        RETURN NULL;
    END IF;

    -- Never more on the board than the room can read, and never more than
    -- there are beasts left to send.
    SELECT count(*) INTO loose FROM horde_encounters e
    WHERE e.horde_id = p_horde_id AND e.status = 'alive';

    IF loose >= horde_live_cap(p_horde_id) THEN
        RETURN NULL;
    END IF;
    IF tide.beasts_slain + loose >= tide.beasts_total THEN
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

    -- Pitched at the tide's rank rather than the beast's, so a rank 1 boar in
    -- a rank 4 tide is worth walking over to.
    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * CASE WHEN elite
                                     THEN game_config_value('horde_elite_hp')
                                     ELSE 1 END))::bigint;

    INSERT INTO horde_encounters
        (horde_id, species_id, kind, hp, max_hp, expires_at)
    VALUES (p_horde_id, species.species_id,
            CASE WHEN elite THEN 'elite' ELSE 'normal' END,
            pool, pool,
            now() + make_interval(
                mins => game_config_value('horde_beast_minutes')::integer))
    RETURNING horde_encounters.encounter_id INTO made;

    RETURN made;
END;
$$;


-- ---------------------------------------------------------------------------
-- Hitting one
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_strike(p_encounter_id BIGINT, p_player_id BIGINT)
RETURNS TABLE (
    dealt      BIGINT,
    hp_left    BIGINT,
    max_hp     BIGINT,
    killed     BOOLEAN,
    beast_name TEXT,
    kind       TEXT,
    bounty     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    met    RECORD;
    move   BIGINT;
    hit    RECORD;
    hurt   BIGINT;
    down   BOOLEAN := FALSE;
    paid   BIGINT := 0;
BEGIN
    SELECT e.*, cs.name AS species_name, cs.base_defense, cs.rank AS species_rank,
           h.status AS tide_status
    INTO met
    FROM horde_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    JOIN beast_hordes h ON h.horde_id = e.horde_id
    WHERE e.encounter_id = p_encounter_id
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing there' USING ERRCODE = 'check_violation';
    END IF;
    IF met.status <> 'alive' THEN
        RAISE EXCEPTION 'that one is already down' USING ERRCODE = 'check_violation';
    END IF;
    IF met.tide_status <> 'fighting' THEN
        RAISE EXCEPTION 'the tide has broken off' USING ERRCODE = 'check_violation';
    END IF;
    IF met.expires_at <= now() THEN
        RAISE EXCEPTION 'it is already through the line'
            USING ERRCODE = 'check_violation';
    END IF;

    move := dungeon_default_move(p_player_id);
    IF move IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same damage a duel, a hunt and a dungeon round compute.
    SELECT * INTO hit FROM compute_technique_damage(
        p_player_id, move, met.species_id,
        player_external_multiplier(p_player_id, move),
        met.base_defense::bigint);

    hurt := GREATEST(1, hit.final_damage);
    down := hurt >= met.hp;

    UPDATE horde_encounters e
    SET hp = GREATEST(0, e.hp - hurt),
        status = CASE WHEN down THEN 'slain' ELSE e.status END,
        slain_by = CASE WHEN down THEN p_player_id ELSE e.slain_by END,
        settled_at = CASE WHEN down THEN now() ELSE e.settled_at END
    WHERE e.encounter_id = p_encounter_id;

    IF down THEN
        paid := round(game_config_value('horde_slay_bounty')
                      * GREATEST(1, met.species_rank))::bigint;

        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + 1
        WHERE h.horde_id = met.horde_id;
    END IF;

    INSERT INTO horde_contributions
        (horde_id, player_id, damage_dealt, beasts_slain, elites_slain,
         last_swing_at)
    VALUES (met.horde_id, p_player_id, hurt + paid,
            CASE WHEN down AND met.kind = 'normal' THEN 1 ELSE 0 END,
            CASE WHEN down AND met.kind = 'elite'  THEN 1 ELSE 0 END,
            now())
    ON CONFLICT (horde_id, player_id) DO UPDATE
        SET damage_dealt  = horde_contributions.damage_dealt + hurt + paid,
            beasts_slain  = horde_contributions.beasts_slain
                            + CASE WHEN down AND met.kind = 'normal' THEN 1 ELSE 0 END,
            elites_slain  = horde_contributions.elites_slain
                            + CASE WHEN down AND met.kind = 'elite' THEN 1 ELSE 0 END,
            last_swing_at = now();

    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid;
END;
$$;


-- ---------------------------------------------------------------------------
-- What got past while nobody was looking
-- ---------------------------------------------------------------------------
-- Demand-driven, like the passive cultivation settle and the world boss spawn.
-- A screen calls this before it draws, and that is when a beast that has been
-- standing there for six minutes is finally recorded as through the line.

CREATE FUNCTION horde_sweep(p_horde_id BIGINT)
RETURNS TABLE (escaped INTEGER, beast_names TEXT[])
LANGUAGE plpgsql
AS $$
DECLARE
    got  INTEGER := 0;
    said TEXT[]  := '{}';
BEGIN
    WITH gone AS (
        UPDATE horde_encounters e
        SET status = 'escaped', settled_at = now()
        WHERE e.horde_id = p_horde_id
          AND e.status = 'alive'
          AND e.expires_at <= now()
        RETURNING e.species_id
    )
    SELECT count(*)::integer,
           COALESCE(array_agg(DISTINCT cs.name), '{}')
    INTO got, said
    FROM gone
    JOIN creature_species cs ON cs.species_id = gone.species_id;

    IF got > 0 THEN
        UPDATE beast_hordes h
        SET beasts_lost = h.beasts_lost + got
        WHERE h.horde_id = p_horde_id;
    END IF;

    RETURN QUERY SELECT got, said;
END;
$$;


-- ---------------------------------------------------------------------------
-- Deciding it
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_verdict(p_horde_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        WHEN h.status IN ('won', 'lost') THEN h.status
        -- The line is the only failure. Beasts through it, and enough of them.
        WHEN h.beasts_lost >= h.line_holds THEN 'lost'
        -- Out of time with the tide unbroken is a loss too: they walked past.
        WHEN h.ends_at <= now() AND h.beasts_slain < h.beasts_total THEN 'lost'
        WHEN h.beasts_slain >= h.beasts_total THEN 'king'
        ELSE 'fighting'
    END
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_verdict(BIGINT) IS
    'Where the tide stands, computed rather than stored, so a screen that has not swept yet cannot show a stale answer.';
