-- 0162_no_path_is_only_a_junior_partner
--
-- 0161 closed the reachability gap: every Path is now written on some attack
-- at rank 3 or below. Re-running the audit against the shelf rather than
-- against `technique_paths` turned up a quieter version of the same fault.
--
-- `technique_shelf` gates on a technique's DOMINANT Path - the heaviest one -
-- and three Paths never held that position anywhere a cultivator could reach:
--
--   Soul     leads only at rank 5
--   Theft    0.5 in Whisper Thief Needle, and loses the tie to Shadow
--   Illusion 0.4 in Nightjar Veil, 0.4 in Sleepwalker Step
--
-- A Path that is only ever somebody's junior partner is reachable without
-- being anything. Its attainment gates nothing, no move on the shelf is
-- measured against it, and a cultivator who has poured insight into it has
-- still never bought something that is theirs.
--
-- Stating that as the rule the roster has to satisfy - every Path leads
-- exactly one rank-1 basic attack - turned up two the audit above had not:
-- Shadow leads nothing below rank 3 and Bone leads nothing below rank 3
-- either, so both are Paths you can only start on by starting on something
-- else. Five, then, not three.
--
-- That settles rank 1 into a board worth keeping: 34 first rungs, one to a
-- Path, each priced the same and gated on nothing but the stones.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    ('soul_fray', 'Soul Fray', 1, 'attack', 127, 0.1000, 0.9500, 1,
     'Nothing is cut. A few threads at the edge are simply persuaded to let go of each other.'),

    ('light_fingered_cut', 'Light-Fingered Cut', 1, 'attack', 123, 0.0800, 1.0000, 0,
     'The wound is incidental. It is what leaves with the hand that was the point of the exercise.'),

    ('second_shadow', 'Second Shadow', 1, 'attack', 129, 0.0900, 0.9000, 0,
     'One of the two of you standing there is not standing there. Guess wrong and it costs.'),

    ('lamp_snuffed_step', 'Lamp-Snuffed Step', 1, 'attack', 133, 0.0900, 0.9000, 0,
     'The room is exactly as dark as it needs to be, and only on the side you are standing on.'),

    ('marrow_chill', 'Marrow Chill', 1, 'attack', 114, 0.0800, 1.0000, 0,
     'It starts in the bone and works outward, which is the wrong direction and does not stop.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('soul_fray',          'soul',     1.0000),
    ('light_fingered_cut', 'theft',    1.0000),
    ('second_shadow',      'illusion', 1.0000),
    ('lamp_snuffed_step',  'shadow',   1.0000),
    ('marrow_chill',       'bone',     1.0000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- The rule, stated where it can fail loudly: one first rung per Path, and no
-- Path with two of them either - a second rank-1 move on the same Path is how
-- one Path quietly becomes the obvious opening and the rest become flavour.

DO $$
DECLARE
    wrong TEXT;
    ranks TEXT;
BEGIN
    WITH lead AS (
        SELECT DISTINCT ON (t.technique_id)
               t.technique_id, tp.path_code
        FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL
          AND t.category = 'attack'
          AND t.grade = 'basic'
          AND t.rank = 1
        ORDER BY t.technique_id, tp.weight DESC, tp.path_code
    )
    SELECT string_agg(p.name || ' (' || cnt || ')', ', ' ORDER BY p.sort_order)
    INTO wrong
    FROM paths p
    CROSS JOIN LATERAL (
        SELECT count(*) AS cnt FROM lead l WHERE l.path_code = p.code
    ) c
    WHERE c.cnt <> 1;

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'these Paths do not lead exactly one rank 1 attack: %',
            wrong;
    END IF;

    -- 0161's ladder check, re-run because three new figures went onto rank 1.
    SELECT string_agg(a.rank::text, ', ') INTO ranks
    FROM (
        SELECT t.rank, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) a
    JOIN (
        SELECT t.rank, min(t.base_power) AS lo
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) b ON b.rank = a.rank + 1
    WHERE b.lo <= a.hi;

    IF ranks IS NOT NULL THEN
        RAISE EXCEPTION 'the power ladder overlaps above rank(s) %', ranks;
    END IF;
END;
$$;


-- And the shelf itself, asked of a live cultivator: 34 first rungs, every one
-- of them gated on nothing but the stones.

DO $$
DECLARE
    who    BIGINT;
    opened INTEGER;
    shut   TEXT;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 1
    ORDER BY pc.player_id
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no cultivator to probe the shelf with; tests carry it';
        RETURN;
    END IF;

    SELECT count(*), string_agg(s.name, ', ') FILTER (WHERE NOT s.tier_ok)
    INTO opened, shut
    FROM technique_shelf(who) s
    WHERE s.tech_rank = 1 AND s.category = 'attack' AND s.grade = 'basic';

    IF opened <> 34 THEN
        RAISE EXCEPTION 'the shelf shows % first rungs, not 34', opened;
    END IF;

    IF shut IS NOT NULL THEN
        RAISE EXCEPTION 'a first rung is behind an attainment gate: %', shut;
    END IF;
END;
$$;
