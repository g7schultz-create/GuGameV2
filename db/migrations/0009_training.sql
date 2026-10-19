-- 0009_training
--
-- Makes training sessions payable. 0006 built the table - the claim on a span
-- of time - but nothing that turns an elapsed span into progress, because the
-- numbers did not exist yet.
--
-- Two halves:
--
--   1. Placeholder rates in `game_config`. Every figure here is invented. The
--      design doc gives no training curve, so these are picked to make an hour
--      feel like it did something and the first breakthrough reachable in an
--      evening. Retuning them is an UPDATE in a later migration, not a code
--      change - which is the whole reason they are rows.
--
--   2. The resolution logic, as SQL functions next to the data they read. Same
--      call as the damage pipeline in 0008: the bot, an ad-hoc psql balance
--      query and the tests all get one implementation instead of three that
--      drift. It also lets a payout be a single atomic statement, which is
--      what the all-or-nothing CHECK on training_sessions actually wants.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Rates
-- ---------------------------------------------------------------------------
-- PLACEHOLDER, all of it. At 100/hour the rank 1 middle breakthrough (1,000
-- cumulative) lands after ten hours of pure cultivation.

INSERT INTO game_config (key, value, description) VALUES
    ('cultivation_xp_per_hour', 100,
     'PLACEHOLDER - base cultivation gained per hour of training.'),
    ('physique_xp_per_hour', 80,
     'PLACEHOLDER - base physique XP gained per hour of body training.'),
    ('path_insight_per_hour', 60,
     'PLACEHOLDER - Path insight per hour, for a focused (path_code set) session only.'),
    ('dao_mark_chance_per_hour', 0.02,
     'PLACEHOLDER - probability of a Dao Mark per whole hour of focused training.'),
    ('training_max_hours', 12,
     'Longest session a player may open, in hours. A cap, not a balance figure.'),
    ('training_aptitude_baseline', 50,
     'Aptitude that yields the base rate; player_cultivation.aptitude scales against this.'),
    ('physique_xp_per_level', 500,
     'PLACEHOLDER - physique XP per body level. Levels are linear, not a curve.'),
    ('physique_base_hp', 100,
     'PLACEHOLDER - max HP at body level 1, before the physique multiplier.'),
    ('physique_hp_per_level', 20,
     'PLACEHOLDER - max HP per body level above 1, before the physique multiplier.'),
    ('physique_defense_per_level', 4,
     'PLACEHOLDER - defense per body level above 1, before the physique multiplier.'),
    ('physique_strength_per_level', 6,
     'PLACEHOLDER - strength per body level above 1, before the physique multiplier.');


-- ---------------------------------------------------------------------------
-- game_config_value
-- ---------------------------------------------------------------------------
-- Every function below reads two or three tunables. Without this, each one
-- carries its own SELECT ... INTO and a mistyped key silently reads NULL,
-- which then propagates through the arithmetic as NULL rather than failing.

CREATE FUNCTION game_config_value(p_key TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v NUMERIC;
BEGIN
    SELECT value INTO v FROM game_config WHERE key = p_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'game_config has no key %', p_key;
    END IF;
    RETURN v;
END;
$$;

COMMENT ON FUNCTION game_config_value(TEXT) IS
    'One tunable by key. Raises rather than returning NULL, so a mistyped key fails loudly instead of zeroing a formula.';


-- ---------------------------------------------------------------------------
-- Derived ladders
-- ---------------------------------------------------------------------------
-- Both of these turn a running total into the rung it has reached. They are
-- the definition of the denormalised `tier` and `realm_id` columns, so those
-- columns are only ever written from here and cannot drift from their source.
--
-- Tier 0 (Uninitiated) and tier 1 (Ordinary) both require 0 insight, so this
-- returns 1 for anyone who has a row at all. That is deliberate: per 0002 it
-- is the absence of the row, not a stored 0, that means Uninitiated.

CREATE FUNCTION attainment_tier_for_insight(p_insight BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT max(tier)::smallint
    FROM attainment_tiers
    WHERE insight_required <= p_insight;
$$;

CREATE FUNCTION realm_for_cultivation(p_cultivation BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT max(realm_id)::smallint
    FROM realms
    WHERE cultivation_required <= p_cultivation;
$$;

COMMENT ON FUNCTION attainment_tier_for_insight(BIGINT) IS
    'The tier a lifetime insight total has reached. The definition of player_path_attainment.tier.';
COMMENT ON FUNCTION realm_for_cultivation(BIGINT) IS
    'The realm a cumulative cultivation total has reached. The definition of player_cultivation.realm_id.';


-- ---------------------------------------------------------------------------
-- grant_path_insight
-- ---------------------------------------------------------------------------
-- Adds insight to one Path and keeps `tier` in step in the same statement, so
-- the denormalised column cannot be left behind by a caller that forgot.
-- Creating the row on first touch is what keeps player_path_attainment sparse.

CREATE FUNCTION grant_path_insight(
    p_player_id  BIGINT,
    p_path_code  TEXT,
    p_insight    BIGINT,
    p_seconds    BIGINT  DEFAULT 0,
    p_dao_marks  INTEGER DEFAULT 0
) RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_tier SMALLINT;
BEGIN
    INSERT INTO player_path_attainment
        (player_id, path_code, insight, tier, dao_marks, seconds_trained)
    VALUES
        (p_player_id, p_path_code, p_insight,
         attainment_tier_for_insight(p_insight), p_dao_marks, p_seconds)
    ON CONFLICT (player_id, path_code) DO UPDATE SET
        insight         = player_path_attainment.insight + EXCLUDED.insight,
        tier            = attainment_tier_for_insight(
                              player_path_attainment.insight + EXCLUDED.insight),
        dao_marks       = player_path_attainment.dao_marks + EXCLUDED.dao_marks,
        seconds_trained = player_path_attainment.seconds_trained + EXCLUDED.seconds_trained
    RETURNING tier INTO new_tier;

    RETURN new_tier;
END;
$$;

COMMENT ON FUNCTION grant_path_insight(BIGINT, TEXT, BIGINT, BIGINT, INTEGER) IS
    'Adds insight to one Path, creating the row on first touch, and recomputes tier in the same statement.';


-- ---------------------------------------------------------------------------
-- apply_cultivation_xp
-- ---------------------------------------------------------------------------
-- Cultivation is cumulative and never spent, so a breakthrough is a side
-- effect of the total crossing a threshold rather than an action the player
-- takes. Essence and qi caps are deliberately not copied here: they are read
-- from the realm, so they widen the instant realm_id changes.

CREATE FUNCTION apply_cultivation_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_realm SMALLINT;
BEGIN
    UPDATE player_cultivation
    SET cultivation = cultivation + p_xp,
        realm_id    = realm_for_cultivation(cultivation + p_xp)
    WHERE player_id = p_player_id
    RETURNING realm_id INTO new_realm;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    RETURN new_realm;
END;
$$;

COMMENT ON FUNCTION apply_cultivation_xp(BIGINT, BIGINT) IS
    'Adds cultivation and re-derives the realm. Returns the realm after, which may be the realm before.';


-- ---------------------------------------------------------------------------
-- apply_physique_xp
-- ---------------------------------------------------------------------------
-- The body pillar's stats are recomputed from body level rather than
-- incremented, so they stay a pure function of (level, physique) and a
-- rebalance of the per-level figures reaches every existing player instead of
-- only the ones who train afterwards. Current HP rises by however much max HP
-- did, so a body breakthrough is never a stealth wound.

CREATE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
    new_level   SMALLINT;
    new_max_hp  BIGINT;
    hp_gained   BIGINT;
BEGIN
    SELECT * INTO row_before FROM player_physique WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    -- No physique yet is the common case for a new character, so the
    -- multipliers default to 1 rather than the row being required.
    SELECT hp_multiplier, defense_multiplier, strength_multiplier
    INTO mult_hp, mult_def, mult_str
    FROM physiques
    WHERE physique_id = row_before.physique_id;

    mult_hp  := COALESCE(mult_hp, 1);
    mult_def := COALESCE(mult_def, 1);
    mult_str := COALESCE(mult_str, 1);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = round(def_rate * (new_level - 1) * mult_def),
        strength    = round(str_rate * (new_level - 1) * mult_str)
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;

COMMENT ON FUNCTION apply_physique_xp(BIGINT, BIGINT) IS
    'Adds physique XP, re-derives body level, and recomputes this pillar''s stat contribution from level and physique.';


-- ---------------------------------------------------------------------------
-- resolve_training_session
-- ---------------------------------------------------------------------------
-- Turns elapsed time into progress and closes the session, all in one
-- statement from the caller's side.
--
-- Three things this shape is buying:
--
--   * The row is locked FOR UPDATE and re-checked for `resolved_at`, so two
--     `/claim`s racing cannot both pay out. The partial unique index stops a
--     second session being opened; this stops the one session paying twice.
--   * Time is capped at `ends_at`. Returning late is free but earns nothing
--     extra, and returning early pays only for what elapsed - which is what
--     makes committing to a duration a real decision.
--   * Every granted figure is written together with `resolved_at`, satisfying
--     the all-or-nothing CHECK by construction rather than by the caller
--     remembering.
--
-- Dao Marks roll once per whole elapsed hour, using random(). Unlike a battle
-- there is no rng_seed here: a training payout is a one-shot number nobody
-- replays, so it is not worth the column.

CREATE FUNCTION resolve_training_session(p_session_id BIGINT)
RETURNS TABLE (
    kind              TEXT,
    path_code         TEXT,
    hours             NUMERIC,
    xp_granted        BIGINT,
    insight_granted   BIGINT,
    dao_marks_granted INTEGER,
    realm_before      SMALLINT,
    realm_after       SMALLINT,
    level_before      SMALLINT,
    level_after       SMALLINT,
    tier_before       SMALLINT,
    tier_after        SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    s              training_sessions%ROWTYPE;
    elapsed_hours  NUMERIC;
    aptitude       NUMERIC;
    baseline       NUMERIC := game_config_value('training_aptitude_baseline');
    affinity       NUMERIC := 1;
    xp             BIGINT;
    insight        BIGINT  := 0;
    marks          INTEGER := 0;
    r_before       SMALLINT;
    r_after        SMALLINT;
    l_before       SMALLINT;
    l_after        SMALLINT;
    t_before       SMALLINT;
    t_after        SMALLINT;
BEGIN
    SELECT * INTO s FROM training_sessions
    WHERE session_id = p_session_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no training session %', p_session_id;
    END IF;
    IF s.resolved_at IS NOT NULL THEN
        RAISE EXCEPTION 'training session % is already resolved', p_session_id;
    END IF;

    elapsed_hours := GREATEST(
        0,
        EXTRACT(EPOCH FROM (LEAST(now(), s.ends_at) - s.started_at)) / 3600.0
    );

    SELECT pc.aptitude INTO aptitude
    FROM player_cultivation pc WHERE pc.player_id = s.player_id;
    aptitude := COALESCE(aptitude, baseline);

    -- The physique's affinity Path, when it matches what is being trained.
    -- This is the whole reason `affinity_bonus` exists on the physique.
    IF s.path_code IS NOT NULL THEN
        SELECT ph.affinity_bonus INTO affinity
        FROM player_physique pp
        JOIN physiques ph ON ph.physique_id = pp.physique_id
        WHERE pp.player_id = s.player_id AND ph.affinity_path = s.path_code;
        affinity := COALESCE(affinity, 1);
    END IF;

    IF s.kind = 'cultivation' THEN
        xp := round(
            elapsed_hours
            * game_config_value('cultivation_xp_per_hour')
            * (aptitude / baseline)
            * CASE WHEN s.path_code IS NULL THEN 1
                   ELSE game_config_value('path_cultivation_xp_rate') END
        );
    ELSE
        xp := round(
            elapsed_hours
            * game_config_value('physique_xp_per_hour')
            * CASE WHEN s.path_code IS NULL THEN 1
                   ELSE game_config_value('path_physique_xp_rate') END
        );
    END IF;

    IF s.path_code IS NOT NULL THEN
        insight := round(
            elapsed_hours * game_config_value('path_insight_per_hour') * affinity
        );
        SELECT count(*)::int INTO marks
        FROM generate_series(1, floor(elapsed_hours)::int)
        WHERE random() < game_config_value('dao_mark_chance_per_hour');
    END IF;

    SELECT pc.realm_id INTO r_before
    FROM player_cultivation pc WHERE pc.player_id = s.player_id;
    SELECT pp.body_level INTO l_before
    FROM player_physique pp WHERE pp.player_id = s.player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = s.player_id AND a.path_code = s.path_code;

    IF s.kind = 'cultivation' THEN
        r_after := apply_cultivation_xp(s.player_id, xp);
        l_after := l_before;
    ELSE
        l_after := apply_physique_xp(s.player_id, xp);
        r_after := r_before;
    END IF;

    IF s.path_code IS NOT NULL THEN
        t_after := grant_path_insight(
            s.player_id,
            s.path_code,
            insight,
            round(elapsed_hours * 3600)::bigint,
            marks
        );
    ELSE
        t_after := t_before;
    END IF;

    UPDATE training_sessions ts
    SET resolved_at       = now(),
        xp_granted        = xp,
        insight_granted   = insight,
        dao_marks_granted = marks,
        outcome           = jsonb_build_object(
            'hours',        round(elapsed_hours, 4),
            'aptitude',     aptitude,
            'affinity',     affinity,
            'realm_before', r_before, 'realm_after', r_after,
            'level_before', l_before, 'level_after', l_after,
            'tier_before',  t_before, 'tier_after',  t_after
        )
    WHERE ts.session_id = p_session_id;

    RETURN QUERY SELECT
        s.kind, s.path_code, round(elapsed_hours, 4),
        xp, insight, marks,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;

COMMENT ON FUNCTION resolve_training_session(BIGINT) IS
    'Pays out one training session and closes it atomically. Locks the row and refuses a second resolution.';
