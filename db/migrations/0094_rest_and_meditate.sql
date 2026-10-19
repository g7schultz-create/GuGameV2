-- 0094_rest_and_meditate
--
-- Two things to do with a quiet hour.
--
-- WHAT THE PERCENTAGES ARE OF, because "plus five percent" is not a quantity
-- until something says five percent of what:
--
--   rest      - of MAXIMUM health. A percentage of what is missing would pay
--               least exactly when a player most needs it, and a flat number
--               would stop mattering the moment a body grows.
--
--   meditate  - of the REALM's requirement, or of the next attainment tier's.
--               Not of what the player already holds: a percentage of a total
--               pays the rich and starves the poor, and cultivation totals in
--               this game span several orders of magnitude. A percentage of
--               the distance being travelled is worth the same at every realm,
--               which is what makes one number balanceable for all of them.
--
-- MEDITATION IS A CHOICE, NOT A COIN FLIP. Cultivation and Path insight are
-- the two axes a cultivator spends time on, and `/focus` already makes a
-- player state which Path they are aiming at. Rolling for them would take that
-- decision back; the screen offers both and the player picks.
--
-- BOTH REPORT WHAT THEY BANKED. Cultivation stops at the realm's door and
-- health stops at the body's cap, so what is offered and what is deposited are
-- routinely different numbers. 0045 and 0058 were both this bug, and both are
-- avoided the same way: measure before, measure after, report the difference.
--
-- THE COOLDOWNS ARE THE BALANCE DIAL, and they are placeholders like every
-- other one. Seven percent of a realm is a large step: at the half-minute this
-- schema is currently testing with it crosses a realm in under twenty minutes,
-- and at half an hour it takes a couple of days. The magnitude is what the
-- design asked for; the wait is what makes it mean something.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('rest_cooldown_minutes', 0.5,
     'PLACEHOLDER - wait between rests. Held at the testing value the other world actions use.'),
    ('rest_heal_min_pct', 0.15,
     'Least of maximum health a rest returns.'),
    ('rest_heal_max_pct', 0.55,
     'Most of maximum health a rest returns.'),
    ('meditate_cooldown_minutes', 0.5,
     'PLACEHOLDER - wait between meditations. This is the dial that decides what a meditation is worth, not the percentage.'),
    ('meditate_min_pct', 0.01,
     'Least of a realm - or of the next attainment tier - one meditation is worth.'),
    ('meditate_max_pct', 0.07,
     'Most of a realm - or of the next attainment tier - one meditation is worth.');


-- ---------------------------------------------------------------------------
-- rest
-- ---------------------------------------------------------------------------

CREATE FUNCTION rest(p_player_id BIGINT)
RETURNS TABLE (
    healed     BIGINT,
    offered    BIGINT,
    current_hp BIGINT,
    max_hp     BIGINT,
    full_up    BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    body   player_physique%ROWTYPE;
    lo     NUMERIC := game_config_value('rest_heal_min_pct');
    hi     NUMERIC := game_config_value('rest_heal_max_pct');
    gift   BIGINT;
    before BIGINT;
    after  BIGINT;
BEGIN
    SELECT * INTO body FROM player_physique
    WHERE player_id = p_player_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no body to rest', p_player_id;
    END IF;

    IF body.current_hp >= body.max_hp THEN
        RETURN QUERY SELECT 0::bigint, 0::bigint, body.current_hp, body.max_hp, TRUE;
        RETURN;
    END IF;

    before := body.current_hp;
    gift   := GREATEST(1, round(body.max_hp * (lo + random() * (hi - lo))));

    UPDATE player_physique pp
    SET current_hp = LEAST(pp.max_hp, pp.current_hp + gift)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO after;

    -- What it BANKED, not what it offered: the body's cap is why those differ.
    RETURN QUERY SELECT after - before, gift, after, body.max_hp,
                        after >= body.max_hp;
END;
$$;

COMMENT ON FUNCTION rest(BIGINT) IS
    'An hour off its feet. Reports the health it actually restored rather than the health it rolled.';


-- ---------------------------------------------------------------------------
-- meditate
-- ---------------------------------------------------------------------------
-- One function, two axes, because the wait is shared and a second cooldown
-- would let a player take both every time and never choose at all.

CREATE FUNCTION meditate(p_player_id BIGINT, p_on TEXT)
RETURNS TABLE (
    gained      BIGINT,
    offered     BIGINT,
    axis        TEXT,
    path_code   TEXT,
    tier_before SMALLINT,
    tier_after  SMALLINT,
    at_the_door BOOLEAN
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult    player_cultivation%ROWTYPE;
    lo      NUMERIC := game_config_value('meditate_min_pct');
    hi      NUMERIC := game_config_value('meditate_max_pct');
    share   NUMERIC;
    span    BIGINT;
    gift    BIGINT;
    before  BIGINT;
    after   BIGINT;
    t_was   SMALLINT;
    t_now   SMALLINT;
BEGIN
    IF p_on NOT IN ('cultivation', 'path') THEN
        RAISE EXCEPTION 'you can sit on your cultivation or on a Path, not on %', p_on
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    share := lo + random() * (hi - lo);

    IF p_on = 'cultivation' THEN
        -- A share of the realm being crossed, so one number is worth the same
        -- at the bottom of the ladder and the top of it.
        SELECT r.cultivation_required INTO span
        FROM realms r WHERE r.realm_id = cult.realm_id + 1;

        IF span IS NULL THEN
            RAISE EXCEPTION 'there is nothing above this realm to sit toward'
                USING ERRCODE = 'check_violation';
        END IF;

        gift   := GREATEST(1, round(span * share));
        before := cult.cultivation;
        PERFORM apply_cultivation_xp(p_player_id, gift);

        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;

        RETURN QUERY SELECT after - before, gift, 'cultivation'::text,
                            cult.focus_path, NULL::smallint, NULL::smallint,
                            after >= cultivation_ceiling(p_player_id);
        RETURN;
    END IF;

    IF cult.focus_path IS NULL THEN
        RAISE EXCEPTION 'you are aimed at no Path. **/focus** first'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(a.tier, 0), COALESCE(a.insight, 0) INTO t_was, before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
           ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    -- The next tier's requirement, or the last one's if the ladder is done -
    -- a Path at the top still rewards sitting with it.
    SELECT COALESCE(
        (SELECT t.insight_required FROM attainment_tiers t
         WHERE t.insight_required > before ORDER BY t.insight_required LIMIT 1),
        (SELECT max(t.insight_required) FROM attainment_tiers t)
    ) INTO span;

    gift  := GREATEST(1, round(GREATEST(span, 1) * share));
    t_now := grant_path_insight(p_player_id, cult.focus_path, gift, 0, 0);

    SELECT a.insight INTO after FROM player_path_attainment a
    WHERE a.player_id = p_player_id AND a.path_code = cult.focus_path;

    RETURN QUERY SELECT after - before, gift, 'path'::text, cult.focus_path,
                        t_was, t_now, FALSE;
END;
$$;

COMMENT ON FUNCTION meditate(BIGINT, TEXT) IS
    'A share of the realm being crossed, or of the next attainment tier. Reports what it banked - cultivation stops at the realm''s door.';
