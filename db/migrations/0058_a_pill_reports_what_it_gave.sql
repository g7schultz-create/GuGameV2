-- 0058_a_pill_reports_what_it_gave
--
-- Two of the five pill kinds were reporting their own dose rather than what
-- landed.
--
-- Health is capped at `max_hp` and battle Qi at the realm's capacity, so both
-- can be handed a five-hundred-point pill and absorb none of it. Both said
-- "500" anyway. At full health that is a card claiming a number while the bar
-- underneath it does not move, and the pill is gone.
--
-- This is exactly the bug 0045 fixed in `settle_passive_cultivation`, which
-- reported the cultivation it CALCULATED rather than the cultivation that was
-- STORED, and it is the same fix: read the total, apply, read it again. The
-- cultivation branch of `take_pill` was already written that way - because the
-- bottleneck had already taught that lesson once - and the other four were not.
--
-- Physique XP and insight are genuinely uncapped, so those two were telling
-- the truth. They are measured now anyway: a branch that happens to be honest
-- because nothing clamps it yet is one clamp away from lying, and there is no
-- reason for five branches to use two different disciplines.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION take_pill(p_player_id BIGINT, p_pill_id BIGINT)
RETURNS TABLE (
    pill_name  TEXT,
    kind       TEXT,
    granted    BIGINT,
    detail     TEXT,
    remaining  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     player_pills%ROWTYPE;
    before BIGINT;
    after  BIGINT;
    said   TEXT;
    left_n SMALLINT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    -- Every branch: read, apply, read again. What the player is told is the
    -- difference between two numbers that were actually in the column.
    IF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        said := CASE WHEN after - before < it.magnitude
                     THEN 'The bottleneck refused the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        SELECT pp.physique_xp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        SELECT pp.physique_xp INTO after FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        SELECT COALESCE(a.insight, 0) INTO before
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        PERFORM grant_path_insight(p_player_id, it.path_code, it.magnitude, 0, 0);
        SELECT COALESCE(a.insight, 0) INTO after
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = it.path_code;
        said := 'Insight into ' || it.path_code || '.';

    ELSIF it.kind = 'healing' THEN
        SELECT pp.current_hp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO after;
        said := CASE WHEN after - before < it.magnitude
                     THEN 'The body could not hold all of it.'
                     ELSE 'Health, at once.' END;

    ELSE
        SELECT pc.qi INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        UPDATE player_cultivation pc
        SET qi = LEAST(
                (SELECT r.qi_capacity FROM realms r WHERE r.realm_id = pc.realm_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id
        RETURNING pc.qi INTO after;
        said := CASE WHEN after - before < it.magnitude
                     THEN 'The aperture would not hold the rest.'
                     ELSE 'Battle Qi, at once.' END;
    END IF;

    IF it.quantity > 1 THEN
        UPDATE player_pills SET quantity = quantity - 1 WHERE pill_id = p_pill_id
        RETURNING quantity INTO left_n;
    ELSE
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
        left_n := 0;
    END IF;

    RETURN QUERY SELECT it.name, it.kind,
                        GREATEST(0, COALESCE(after, 0) - COALESCE(before, 0)),
                        said, left_n;
END;
$$;
