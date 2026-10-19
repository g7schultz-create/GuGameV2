-- 0163_insight_goes_where_you_point_it
--
-- A brew's lead herb Path decides the pill's kind through `path_pill_kinds`,
-- and `take_pill` then granted insight into that same Path. Both halves are
-- reasonable and together they lock 27 of the 34 Paths out of pills entirely.
--
-- `path_pill_kinds` maps seven Paths to 'insight' - Refinement, Formation,
-- Enslavement, Theft, Human, Painting, Illusion - and Theft and Painting have
-- no herbs at all, so they can never lead a brew. Wisdom and Dream map to
-- 'attainment_rate', whose `min_tier` is 5 and whose fallback is 'insight',
-- so below tier 5 they come out as insight pills too. Five Paths in practice,
-- seven once anybody brews at tier 5, and Human and Wisdom are the two a
-- player actually notices.
--
-- Which means a Space cultivator could not buy, brew, trade or find anything
-- that raised Space insight. Focus was the only channel, and pills - the one
-- accelerant in the game - served a fifth of the Paths.
--
-- So the pill stops deciding. It is brewed on a Path, named for that Path and
-- still reads as that Path's work, but insight is a thing you understand
-- rather than a thing that has a destination written on it: you say where it
-- goes as you swallow it, at full strength, into any of the 34.
--
-- Only 'insight' takes a target. 'attainment_rate' is a boost on the whole
-- cultivator rather than on a Path, and pointing a healing pill at a Path is
-- a caller with a bug, so it is refused rather than quietly ignored.
--
-- Forward-only. Do not edit once applied.


-- A third argument with a default would be an overload, and `take_pill(a, b)`
-- would then be ambiguous rather than defaulting. The old one goes first.
DROP FUNCTION take_pill(BIGINT, BIGINT);

CREATE FUNCTION take_pill(
    p_player_id BIGINT,
    p_pill_id   BIGINT,
    p_path_code TEXT DEFAULT NULL
)
RETURNS TABLE (
    pill_name TEXT,
    kind      TEXT,
    granted   BIGINT,
    detail    TEXT,
    remaining SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     player_pills%ROWTYPE;
    before BIGINT;
    after  BIGINT;
    bonus  NUMERIC;
    banked NUMERIC;
    said   TEXT;
    left_n SMALLINT;
    target TEXT;
    aimed  TEXT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    -- Where the insight is being pointed, settled before anything is spent.
    -- A pill named for one Path taken into another is the ordinary case now,
    -- so the only thing worth refusing is a Path that does not exist and a
    -- target on a pill that has nowhere to put one.
    target := it.path_code;

    IF p_path_code IS NOT NULL THEN
        IF it.kind <> 'insight' THEN
            RAISE EXCEPTION
                'a % pill does not go into a Path', it.kind
                USING ERRCODE = 'check_violation';
        END IF;

        SELECT pa.code INTO target FROM paths pa WHERE pa.code = p_path_code;
        IF target IS NULL THEN
            RAISE EXCEPTION 'there is no % Path', p_path_code
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- What this body gets out of the pill, which is not always what is in it.
    -- Scaled once on the local copy of the row, so all five branches below pay
    -- the adjusted dose without any of them having to remember to - and every
    -- one of them still measures what it actually banked, as 0058 insisted.
    it.magnitude := GREATEST(1, round(
        it.magnitude * (1 + player_stat(p_player_id, 'pill_potency'))));

    IF it.kind IN ('cultivation_rate', 'attainment_rate') THEN
        SELECT pt.rate_bonus INTO bonus FROM pill_tiers pt WHERE pt.tier = it.tier;
        banked := grant_boost(p_player_id, it.kind, bonus, it.magnitude);
        after  := it.magnitude;
        said   := percent_text(bonus) || ' for ' || round(it.magnitude)
                  || ' hours of cultivation, ' || round(banked) || ' banked in total.';

    ELSIF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The bottleneck refused the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        SELECT pp.physique_xp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        SELECT pp.physique_xp INTO after FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        after := after - before;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        SELECT COALESCE(a.insight, 0) INTO before
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = target;
        PERFORM grant_path_insight(p_player_id, target, it.magnitude, 0, 0);
        SELECT COALESCE(a.insight, 0) INTO after
        FROM (SELECT 1) _ LEFT JOIN player_path_attainment a
          ON a.player_id = p_player_id AND a.path_code = target;
        after := after - before;

        -- The Path's name rather than its code, which is what the old line
        -- read back and what nobody would have chosen to write.
        SELECT pa.name INTO aimed FROM paths pa WHERE pa.code = target;
        said := 'Insight into the ' || aimed || '.'
                || CASE WHEN target <> it.path_code
                        THEN ' Brewed elsewhere; understanding does not mind.'
                        ELSE '' END;

    ELSIF it.kind = 'healing' THEN
        SELECT pp.current_hp INTO before FROM player_physique pp
        WHERE pp.player_id = p_player_id;
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The body could not hold all of it.'
                     ELSE 'Health, at once.' END;

    ELSE
        SELECT pc.qi INTO before FROM player_cultivation pc
        WHERE pc.player_id = p_player_id;
        UPDATE player_cultivation pc
        SET qi = LEAST(
                player_max_qi(p_player_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id
        RETURNING pc.qi INTO after;
        after := after - before;
        said := CASE WHEN after < it.magnitude
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

    RETURN QUERY SELECT it.name, it.kind, GREATEST(0, COALESCE(after, 0)), said, left_n;
END;
$$;


-- A function that parses is not a function that works, and this one is only
-- worth anything if the insight lands somewhere it could not have landed
-- before. Probed on a live cultivator inside a subtransaction that is thrown
-- away afterwards, so the pill, the insight and the reading all vanish again.

DO $$
DECLARE
    who    BIGINT;
    made   BIGINT;
    got    BIGINT;
    space  BIGINT;
    human  BIGINT;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc ORDER BY pc.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no cultivator to probe with; tests carry it';
        RETURN;
    END IF;

    BEGIN
        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
        VALUES (who, 'Probe Clarity Pill', 1, 'insight', 'human', 100, 1, 100)
        RETURNING pill_id INTO made;

        SELECT t.granted INTO got FROM take_pill(who, made, 'space') t;

        SELECT COALESCE(a.insight, 0) INTO space FROM player_path_attainment a
        WHERE a.player_id = who AND a.path_code = 'space';
        SELECT COALESCE(a.insight, 0) INTO human FROM player_path_attainment a
        WHERE a.player_id = who AND a.path_code = 'human';

        IF got <= 0 THEN
            RAISE EXCEPTION 'a redirected pill granted nothing';
        END IF;
        IF space < got THEN
            RAISE EXCEPTION 'the insight did not land on the Path it was aimed at';
        END IF;

        -- Space is a Path with no herbs mapped to insight, so before this
        -- migration there was no pill in the game that could have moved it.
        IF EXISTS (SELECT 1 FROM path_pill_kinds WHERE path_code = 'space'
                                                   AND kind = 'insight') THEN
            RAISE EXCEPTION 'the probe picked a Path that was already served';
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
