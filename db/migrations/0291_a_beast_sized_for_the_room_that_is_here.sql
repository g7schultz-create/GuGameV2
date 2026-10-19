-- 0291_a_beast_sized_for_the_room_that_is_here
--
-- `boss_hp_pool` counts everybody seen in the last SEVEN DAYS. That was the
-- right call when it was written - it stopped a beast being sized off whoever
-- happened to be typing in the minute it spawned - but it means the two
-- deepest cultivators on the server are counted whether or not they are
-- anywhere near it.
--
-- Right now that is the difference between a fight and a wall:
--
--     seen in 20 minutes    4 people      75,307,280
--     seen in 45 minutes    5 people   1,134,117,013
--     seen in 7 days       18 people   1,708,442,400   <- what it uses
--
-- So when m_i_y_u_k_i. and clearwest are offline, everyone else is swinging
-- at a beast built for m_i_y_u_k_i. and clearwest. It cannot be brought down,
-- and nothing on the screen explains why.
--
-- PRESENCE, AND WHY IT IS NOT THE SAME NUMBER AS THE RECHECK. `last_seen_at`
-- is touched by every command and by simply talking, so it already answers
-- "who is about" - `horde_watchers` has used it to decide whether a tide
-- breaks since 0275. A beast measures a wider window than a tide does:
-- fifteen minutes is right for deciding whether a room is busy, and too tight
-- for deciding whether somebody is still in a fight they are taking breaks
-- during. So presence is forty-five minutes, rechecked every twenty.
--
-- STRIKERS ARE PINNED. Anybody who has actually hit this beast counts as
-- present for the rest of its life, however long they then go quiet. Without
-- that, the whole thing is an exploit with extra steps: log off, let the
-- beast shrink to something a quiet room built, come back and take a pot
-- sized for everybody. Hitting it once buys you in.
--
-- IT MOVES IN STEPS. The roster here is two very deep cultivators and a long
-- tail, so one person entering the window swings the honest pool by fifteen
-- times. Allowing a single recheck to do that would be its own kind of
-- broken, so a recheck may move the pool by `boss_resize_step` and no more.
-- It converges over a few ticks instead of lurching.
--
-- AND NOBODY LOSES PROGRESS. What is stored is the fraction remaining, not
-- the number: a beast at 60% is at 60% before and after. Damage already dealt
-- is recorded in `boss_strikes` and pays out from there, so a beast that
-- shrank never un-earns anybody's share.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('boss_presence_minutes', 45,
     'How recently somebody must have acted or spoken to be counted when a '
     'beast is measured. Wider than horde_watch_minutes: that decides whether '
     'a room is busy, this decides whether somebody is still in the fight.'),
    ('boss_resize_minutes', 20,
     'How often a standing beast is measured against the room again.'),
    ('boss_resize_step', 0.35,
     'The most one recheck may move a beast''s health, as a fraction of what '
     'it had. The roster is two deep cultivators and a long tail, so an '
     'honest re-measure can swing fifteenfold; this makes it converge over a '
     'few rechecks instead of lurching in one.');


ALTER TABLE boss_encounters  ADD COLUMN resized_at TIMESTAMPTZ;
ALTER TABLE horde_encounters ADD COLUMN resized_at TIMESTAMPTZ;

COMMENT ON COLUMN boss_encounters.resized_at IS
    'When this beast was last measured against the room. NULL means never, which is due.';
COMMENT ON COLUMN horde_encounters.resized_at IS
    'When this King was last measured against the room. NULL means never, which is due.';


-- ---------------------------------------------------------------------------
-- The measure itself, now with a window and a guest list
-- ---------------------------------------------------------------------------

DROP FUNCTION boss_hp_pool(BIGINT);

CREATE FUNCTION boss_hp_pool(
    p_species_id BIGINT, p_pinned BIGINT[] DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        game_config_value('boss_hp_floor'),
        round(COALESCE((
            -- Plus whatever walks in beside them. A pet's blow is not in
            -- `player_usable_techniques`, so without this a beast would be
            -- sized against the roster's techniques alone and come out short
            -- by exactly what the pets add - invisibly, because the pool
            -- would still look right.
            SELECT sum(best.dealt * player_blow_multiple(p.player_id)
                       + COALESCE(pet_blow(pet_at_heel(p.player_id),
                                           p_species_id, 0), 0))
            FROM players p
            JOIN LATERAL (
                -- The same pick `strike_boss` makes: the move that actually
                -- lands hardest, not the one with the biggest number on it.
                SELECT max(would.final_damage) AS dealt
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, t.technique_id, p_species_id,
                    player_external_multiplier(p.player_id, t.technique_id),
                    0) AS would
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.dealt IS NOT NULL AND best.dealt > 0
            WHERE p.deleted_at IS NULL
              AND (
                  -- Here now...
                  p.last_seen_at >= now() - make_interval(
                      mins => game_config_value('boss_presence_minutes')::integer)
                  -- ...or already in this fight, which buys you in for the
                  -- rest of it however quiet you then go.
                  OR (p_pinned IS NOT NULL AND p.player_id = ANY (p_pinned))
              )
        ), 0)
        * game_config_value('boss_swings_expected')
        * game_config_value('boss_effort'))
    )::bigint;
$$;

COMMENT ON FUNCTION boss_hp_pool(BIGINT, BIGINT[]) IS
    'What a beast should hold, measured against the cultivators actually about plus anybody already in the fight.';


-- ---------------------------------------------------------------------------
-- Moving a standing beast toward that measure, a step at a time
-- ---------------------------------------------------------------------------

CREATE FUNCTION boss_step_toward(p_have BIGINT, p_want BIGINT)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
AS $$
    -- Never more than one step of what it currently has, in either direction.
    SELECT GREATEST(1, round(LEAST(
        GREATEST(p_want::numeric,
                 p_have * (1 - game_config_value('boss_resize_step'))),
        p_have * (1 + game_config_value('boss_resize_step'))
    )))::bigint;
$$;

COMMENT ON FUNCTION boss_step_toward(BIGINT, BIGINT) IS
    'One rechecks worth of movement from what a beast has toward what the room says it should have.';


CREATE FUNCTION boss_resize_if_due(p_encounter_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live RECORD;
    want BIGINT;
    made BIGINT;
    part NUMERIC;
BEGIN
    SELECT * INTO live FROM boss_encounters
    WHERE encounter_id = p_encounter_id FOR UPDATE;

    IF NOT FOUND OR live.status <> 'active' THEN
        RETURN NULL;
    END IF;
    IF live.resized_at IS NOT NULL
       AND live.resized_at > now() - make_interval(
               mins => game_config_value('boss_resize_minutes')::integer) THEN
        RETURN NULL;
    END IF;

    want := boss_hp_pool(live.species_id, ARRAY(
        SELECT bs.player_id FROM boss_strikes bs
        WHERE bs.encounter_id = p_encounter_id));
    made := boss_step_toward(live.max_hp, want);

    -- The fraction is what carries over, so nobody's progress moves.
    part := CASE WHEN live.max_hp > 0
                 THEN live.current_hp::numeric / live.max_hp ELSE 1 END;

    UPDATE boss_encounters
    SET max_hp     = made,
        current_hp = LEAST(made, GREATEST(1, round(made * part))),
        resized_at = now()
    WHERE encounter_id = p_encounter_id;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION boss_resize_if_due(BIGINT) IS
    'Measures a standing world beast against the room again, at most once every boss_resize_minutes.';


CREATE FUNCTION horde_king_resize_if_due(p_encounter_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live RECORD;
    want BIGINT;
    made BIGINT;
    part NUMERIC;
BEGIN
    SELECT * INTO live FROM horde_encounters
    WHERE encounter_id = p_encounter_id AND kind = 'king' FOR UPDATE;

    IF NOT FOUND OR live.status <> 'alive' THEN
        RETURN NULL;
    END IF;
    IF live.resized_at IS NOT NULL
       AND live.resized_at > now() - make_interval(
               mins => game_config_value('boss_resize_minutes')::integer) THEN
        RETURN NULL;
    END IF;

    -- The King's own two dials still apply on top of the roster measure, the
    -- same as when it rose. Its strikers are counted in horde_contributions
    -- rather than boss_strikes, which is the only thing that differs here.
    want := GREATEST(1, round(
        boss_hp_pool(live.species_id, ARRAY(
            SELECT c.player_id FROM horde_contributions c
            WHERE c.horde_id = live.horde_id AND c.king_damage > 0))
        * game_config_value('horde_king_effort')
        * (1 + game_config_value('horde_king_rank_step')
               * GREATEST(0, COALESCE(
                     (SELECT h.rank FROM beast_hordes h
                      WHERE h.horde_id = live.horde_id), 1) - 1))))::bigint;

    made := boss_step_toward(live.max_hp, want);
    part := CASE WHEN live.max_hp > 0
                 THEN live.hp::numeric / live.max_hp ELSE 1 END;

    UPDATE horde_encounters
    SET max_hp     = made,
        hp         = LEAST(made, GREATEST(1, round(made * part))),
        resized_at = now()
    WHERE encounter_id = p_encounter_id;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION horde_king_resize_if_due(BIGINT) IS
    'Measures a standing King against the room again, at most once every boss_resize_minutes.';


CREATE FUNCTION resize_world_if_due()
RETURNS TABLE (what TEXT, encounter_id BIGINT, now_holds BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    r    RECORD;
    made BIGINT;
BEGIN
    -- One call the clock can make. Both halves are throttled in SQL, so this
    -- is a timestamp comparison on a quiet tick and a real measure every
    -- twenty minutes.
    FOR r IN SELECT encounter_id FROM boss_encounters WHERE status = 'active'
    LOOP
        made := boss_resize_if_due(r.encounter_id);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'world beast'::text, r.encounter_id, made;
        END IF;
    END LOOP;

    FOR r IN SELECT e.encounter_id FROM horde_encounters e
             WHERE e.kind = 'king' AND e.status = 'alive'
    LOOP
        made := horde_king_resize_if_due(r.encounter_id);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'king'::text, r.encounter_id, made;
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION resize_world_if_due() IS
    'Re-measures every standing world beast and King against the room. Safe to call often; it throttles itself.';


-- ---------------------------------------------------------------------------
-- The window actually narrows the measure
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    sp   BIGINT;
    wide BIGINT;
    slim BIGINT;
BEGIN
    SELECT species_id INTO sp FROM creature_species WHERE kind = 'world' LIMIT 1;
    IF sp IS NULL THEN
        RAISE NOTICE 'no world beast in the book; the tests carry this';
        RETURN;
    END IF;

    slim := boss_hp_pool(sp);
    wide := boss_hp_pool(sp, ARRAY(
        SELECT player_id FROM players WHERE deleted_at IS NULL));

    IF wide < slim THEN
        RAISE EXCEPTION
            'pinning the whole roster made the beast smaller: % against %',
            wide, slim;
    END IF;

    RAISE NOTICE 'measured against the room: %; against everybody: %', slim, wide;
END;
$$;


-- ---------------------------------------------------------------------------
-- A step is a step, and the fraction survives it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    step NUMERIC := game_config_value('boss_resize_step');
BEGIN
    -- Never further than one step, either way.
    IF boss_step_toward(1000, 1000000) <> round(1000 * (1 + step)) THEN
        RAISE EXCEPTION 'a recheck jumped further up than one step';
    END IF;
    IF boss_step_toward(1000, 1) <> round(1000 * (1 - step)) THEN
        RAISE EXCEPTION 'a recheck jumped further down than one step';
    END IF;
    -- And lands exactly when the target is within reach.
    IF boss_step_toward(1000, 1100) <> 1100 THEN
        RAISE EXCEPTION 'a recheck overshot a target it could reach';
    END IF;
    IF boss_step_toward(1000, 1000) <> 1000 THEN
        RAISE EXCEPTION 'a recheck moved a beast that was already right';
    END IF;
END;
$$;


DO $$
DECLARE
    live   RECORD;
    before NUMERIC;
    after  NUMERIC;
    made   BIGINT;
BEGIN
    SELECT * INTO live FROM boss_encounters WHERE status = 'active' LIMIT 1;

    IF NOT FOUND THEN
        RAISE NOTICE 'no beast is standing; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE boss_encounters
        SET current_hp = GREATEST(1, max_hp / 2), resized_at = NULL
        WHERE encounter_id = live.encounter_id;

        SELECT current_hp::numeric / max_hp INTO before
        FROM boss_encounters WHERE encounter_id = live.encounter_id;

        made := boss_resize_if_due(live.encounter_id);
        IF made IS NULL THEN
            RAISE EXCEPTION 'a beast that had never been measured was not due';
        END IF;

        SELECT current_hp::numeric / max_hp INTO after
        FROM boss_encounters WHERE encounter_id = live.encounter_id;

        IF abs(after - before) > 0.01 THEN
            RAISE EXCEPTION
                'the fraction remaining moved: % to %', before, after;
        END IF;

        -- And it will not do it again straight away.
        IF boss_resize_if_due(live.encounter_id) IS NOT NULL THEN
            RAISE EXCEPTION 'a beast was measured twice inside the window';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
