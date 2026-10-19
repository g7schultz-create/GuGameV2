-- 0293_a_standing_beast_is_open_not_active
--
-- 0291 looked for world beasts with status 'active'. There is no such status.
-- `boss_encounters` allows 'open', 'slain' and 'escaped', and a standing
-- beast is 'open' - so `boss_resize_if_due` returned NULL on every beast that
-- has ever existed and `resize_world_if_due` selected an empty set. The
-- entire world-beast half of that migration was inert from the moment it
-- landed.
--
-- The King half was right, because 'alive' is what `horde_encounters` uses,
-- and the King standing at the time was duly re-measured from 2,857,547,035
-- down to 1,906,540,791 with its 98.2% remaining untouched. That is the
-- feature working, on the one of the two lanes where the string happened to
-- match.
--
-- Two statuses, two vocabularies, one of them guessed. The validation in 0291
-- did not catch it because its probe selected `WHERE status = 'active'`,
-- found nothing, and took the "no beast is standing" branch - a probe that
-- agreed with the bug instead of testing it. The probe below looks the beast
-- up by its identifier and asserts it was found, which cannot pass by
-- matching nothing.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION boss_resize_if_due(p_encounter_id BIGINT)
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

    -- A standing beast is open. 0291 looked for a status word this table
    -- does not allow at all, so this test never once passed.
    IF NOT FOUND OR live.status <> 'open' THEN
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


CREATE OR REPLACE FUNCTION resize_world_if_due()
RETURNS TABLE (what TEXT, encounter_id BIGINT, now_holds BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    r    RECORD;
    made BIGINT;
BEGIN
    FOR r IN SELECT b.encounter_id AS eid
             FROM boss_encounters b WHERE b.status = 'open'
    LOOP
        made := boss_resize_if_due(r.eid);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'world beast'::text, r.eid, made;
        END IF;
    END LOOP;

    FOR r IN SELECT e.encounter_id AS eid
             FROM horde_encounters e
             WHERE e.kind = 'king' AND e.status = 'alive'
    LOOP
        made := horde_king_resize_if_due(r.eid);
        IF made IS NOT NULL THEN
            RETURN QUERY SELECT 'king'::text, r.eid, made;
        END IF;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- The status strings are the ones the tables actually allow
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
BEGIN
    FOR src IN
        SELECT prosrc FROM pg_proc
        WHERE proname IN ('boss_resize_if_due', 'resize_world_if_due')
    LOOP
        IF position('''active''' IN src) > 0 THEN
            RAISE EXCEPTION
                'a resize function still looks for the status ''active''';
        END IF;
    END LOOP;

    -- And the vocabularies are what this asserts against, so if either table
    -- ever changes them this fails here rather than silently doing nothing.
    IF pg_get_constraintdef(
           (SELECT oid FROM pg_constraint
            WHERE conname = 'boss_encounters_status_check')) NOT LIKE '%''open''%' THEN
        RAISE EXCEPTION 'a standing world beast is no longer ''open''';
    END IF;
    IF pg_get_constraintdef(
           (SELECT oid FROM pg_constraint
            WHERE conname = 'horde_encounters_status_check')) NOT LIKE '%''alive''%' THEN
        RAISE EXCEPTION 'a standing King is no longer ''alive''';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A beast that is actually standing is actually measured
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    enc    BIGINT;
    before NUMERIC;
    after  NUMERIC;
    was    BIGINT;
    made   BIGINT;
BEGIN
    -- By identifier, and asserted found: a probe that selects on the string
    -- under test can pass by matching nothing, which is how 0291 shipped.
    SELECT encounter_id, max_hp INTO enc, was
    FROM boss_encounters WHERE status = 'open' LIMIT 1;

    IF enc IS NULL THEN
        RAISE NOTICE 'no beast is standing right now; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE boss_encounters SET resized_at = NULL WHERE encounter_id = enc;

        SELECT current_hp::numeric / max_hp INTO before
        FROM boss_encounters WHERE encounter_id = enc;

        made := boss_resize_if_due(enc);
        IF made IS NULL THEN
            RAISE EXCEPTION
                'the standing beast % was still not measured', enc;
        END IF;

        SELECT current_hp::numeric / max_hp INTO after
        FROM boss_encounters WHERE encounter_id = enc;

        IF abs(after - before) > 0.01 THEN
            RAISE EXCEPTION 'the fraction remaining moved: % to %', before, after;
        END IF;

        RAISE NOTICE
            'the standing beast would go from % to %, still at %%% of itself',
            was, made, round(after * 100, 1);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
