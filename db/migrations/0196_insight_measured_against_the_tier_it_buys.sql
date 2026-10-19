-- 0196_insight_measured_against_the_tier_it_buys
--
-- 0195's problem again, in the other ladder. A grade 7 `insight` pill grants
-- 2,704 insight. The attainment ladder it is climbing:
--
--     Ordinary    -> Expert                   1,000     270% of the tier
--     Master      -> Quasi-Grandmaster       12,000      23%
--     Grandmaster -> Quasi-Great GM          70,000       3.9%
--     Great GM    -> Quasi-Supreme GM       450,000       0.6%
--     Quasi-Supreme -> Supreme Grandmaster 1,250,000      0.2%
--
-- Same cause, same fix: a constant measured against a ladder that trebles.
-- An insight pill is now worth a share of the ATTAINMENT TIER the drinker is
-- standing in, for the Path the insight is being pointed at - and never less
-- than the flat number, so the early tiers are untouched.
--
-- The Path matters because 0163 made insight pills go where you point them:
-- `target` is settled before any branch runs, so a Poison pill taken into
-- Heaven is measured against the drinker's HEAVEN tier, which is the tier it
-- is actually going to move.
--
-- Tiers 0 and 1 both require 0 insight, so "the next tier" is found by the
-- next REQUIREMENT that is larger rather than by tier + 1. Reading tier + 1
-- from Uninitiated gives a gap of zero and a pill worth nothing.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pill_insight_share', 0.05,
     'Share of the gap to the next attainment tier that a TOP GRADE insight '
     'pill grants in the Path it is pointed at. Lower grades give their '
     'proportion by pill_tiers.base_magnitude. Twenty grade 7 pills is one '
     'tier, at Expert or at Supreme Grandmaster alike.');


-- The attainment tier the cultivator is standing in, for one Path, measured
-- floor to floor. The top tier borrows the last step, as `cultivation_stage_gap`
-- does at the top of the realm ladder.
CREATE FUNCTION attainment_stage_gap(p_player_id BIGINT, p_path TEXT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    WITH here AS (
        SELECT COALESCE((SELECT at.insight_required
                         FROM player_path_attainment a
                         JOIN attainment_tiers at ON at.tier = a.tier
                         WHERE a.player_id = p_player_id
                           AND a.path_code = p_path), 0) AS floor_at
    )
    SELECT GREATEST(1, COALESCE(
        -- The next requirement that is actually larger. Tiers 0 and 1 share a
        -- requirement of 0, so tier + 1 is not the same question.
        (SELECT min(at.insight_required) - here.floor_at
         FROM attainment_tiers at, here
         WHERE at.insight_required > here.floor_at
         GROUP BY here.floor_at),
        -- Nothing above: borrow the ladder's own last step.
        (SELECT max(at.insight_required)
                - (SELECT max(a2.insight_required) FROM attainment_tiers a2
                   WHERE a2.insight_required < (SELECT max(insight_required)
                                                FROM attainment_tiers))
         FROM attainment_tiers at),
        1
    ))::bigint;
$$;


CREATE FUNCTION pill_insight_value(
    p_player_id BIGINT, p_path TEXT, p_tier SMALLINT, p_magnitude BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        GREATEST(1, p_magnitude),
        round(
            attainment_stage_gap(p_player_id, p_path)
            * game_config_value('pill_insight_share')
            * (SELECT pt.base_magnitude FROM pill_tiers pt
               WHERE pt.tier = p_tier)
            / (SELECT max(pt.base_magnitude) FROM pill_tiers pt)
        )
    )::bigint;
$$;

COMMENT ON FUNCTION pill_insight_value(BIGINT, TEXT, SMALLINT, BIGINT) IS
    'An insight pill measured against the attainment tier it is trying to '
    'buy, in the Path it is pointed at, never below its flat number.';


DO $$
DECLARE
    src TEXT;
    old TEXT := '    ELSIF it.kind = ''insight'' THEN
        SELECT COALESCE(a.insight, 0) INTO before';
    new TEXT := '    ELSIF it.kind = ''insight'' THEN
        -- Measured against the tier it is buying, in the Path it was pointed
        -- at - `target` is settled above, so a pill taken into another Path
        -- is weighed against THAT Path''s tier.
        it.magnitude := pill_insight_value(p_player_id, target, it.tier,
                                           it.magnitude);
        SELECT COALESCE(a.insight, 0) INTO before';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'take_pill';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'take_pill no longer grants insight the old way';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


DO $$
DECLARE
    got  RECORD;
    who  BIGINT;
    pill BIGINT;
    was  BIGINT;
    share NUMERIC := game_config_value('pill_insight_share');
BEGIN
    -- Every tier of the ladder is worth a real share to a top grade pill.
    FOR got IN
        SELECT at.tier, at.name,
               COALESCE(
                   LEAD(at.insight_required) OVER (ORDER BY at.insight_required)
                   - at.insight_required, 0) AS gap
        FROM attainment_tiers at
    LOOP
        CONTINUE WHEN got.gap <= 0;
        IF round(got.gap * share) * 1.0 / got.gap < share - 0.001 THEN
            RAISE EXCEPTION 'a top grade pill is noise at %', got.name;
        END IF;
    END LOOP;

    -- The zero-requirement pair is the trap. Somebody who has never touched a
    -- Path must still get a usable gap out of it.
    SELECT p.player_id INTO who FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no live cultivator; tests carry it';
        RETURN;
    END IF;

    IF attainment_stage_gap(who, 'painting') <= 1 THEN
        RAISE EXCEPTION 'an untouched Path has no tier to measure against';
    END IF;

    BEGIN
        -- Pointed at the Path this cultivator is furthest along, which is
        -- where the flat number is worst.
        SELECT a.path_code, a.insight INTO got
        FROM player_path_attainment a
        WHERE a.player_id = who ORDER BY a.insight DESC LIMIT 1;

        IF got.path_code IS NULL THEN
            RAISE NOTICE 'nobody has attainment yet; tests carry it';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        was := got.insight;

        INSERT INTO player_pills (owner_id, name, tier, kind, path_code,
                                  magnitude, quantity, harmony)
        VALUES (who, 'Probe Insight', 7, 'insight', got.path_code, 2704, 1, 150)
        RETURNING pill_id INTO pill;

        PERFORM take_pill(who, pill, got.path_code);

        IF (SELECT a.insight FROM player_path_attainment a
            WHERE a.player_id = who AND a.path_code = got.path_code) <= was THEN
            RAISE EXCEPTION 'the insight pill granted nothing';
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
