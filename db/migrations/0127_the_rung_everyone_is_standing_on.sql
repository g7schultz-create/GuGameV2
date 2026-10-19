-- 0127_the_rung_everyone_is_standing_on
--
-- 0125 filled ranks 4 through 9 and left ranks 2 and 3 with two techniques
-- each, which is where every cultivator in this game actually is. The two at
-- rank 2 are Ice and Poison; a cultivator who crossed into Foundation
-- Establishment on the Sword Path arrived to find nothing addressed to them.
--
-- Eight more, four to a rank, so that the first realm anybody crosses opens a
-- shelf rather than a pair. Same 2.5x-a-rank curve, same rule as 0125: every
-- one is 'attack', because combat still reads neither `category` nor
-- `effects` and a technique that does nothing is worse than no technique.
--
-- Forward-only. Do not edit once applied.


INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    -- ---- rank 2, around 300 --------------------------------------------
    ('split_bamboo_stroke', 'Split Bamboo Stroke', 2, 'attack', 300, 0.1000, 0.9500, 1,
     'Bamboo splits along its whole length from one tap at the top. So does most of what walks.'),

    ('cinder_moth_swarm', 'Cinder Moth Swarm', 2, 'attack', 290, 0.1100, 0.9000, 1,
     'Each moth carries one ember and one drop of something worse. Individually they are a nuisance.'),

    ('stone_lung_press', 'Stone Lung Press', 2, 'attack', 330, 0.1300, 0.9000, 2,
     'The air in the ribs is replaced, slowly and from below, with grit.'),

    ('whisper_thief_needle', 'Whisper Thief Needle', 2, 'attack', 270, 0.0900, 1.0000, 1,
     'It takes something small on the way through. The wound is the receipt.'),

    -- ---- rank 3, around 670 --------------------------------------------
    ('hollow_fang_draught', 'Hollow Fang Draught', 3, 'attack', 660, 0.1600, 0.9500, 2,
     'Not a bite. A drawing-off, through a channel opened somewhere the opponent was not watching.'),

    ('mirror_lake_severance', 'Mirror Lake Severance', 3, 'attack', 690, 0.1700, 0.9500, 2,
     'The lake is perfectly still, and the cut is already in the reflection before it is anywhere else.'),

    ('bonefield_reckoning', 'Bonefield Reckoning', 3, 'attack', 600, 0.1500, 1.0000, 1,
     'Every battlefield is a field of bones eventually. This one is simply asked to be one early.'),

    ('nightjar_veil', 'Nightjar Veil', 3, 'attack', 620, 0.1600, 0.9000, 2,
     'A bird nobody sees and everybody hears, and by the time the sound arrives it is behind you.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('split_bamboo_stroke',   'sword',    0.7000),
    ('split_bamboo_stroke',   'wood',     0.3000),
    ('cinder_moth_swarm',     'fire',     0.6000),
    ('cinder_moth_swarm',     'poison',   0.4000),
    ('stone_lung_press',      'earth',    0.7000),
    ('stone_lung_press',      'strength', 0.3000),
    ('whisper_thief_needle',  'theft',    0.5000),
    ('whisper_thief_needle',  'shadow',   0.5000),

    ('hollow_fang_draught',   'blood',    0.6000),
    ('hollow_fang_draught',   'poison',   0.4000),
    ('mirror_lake_severance', 'water',    0.6000),
    ('mirror_lake_severance', 'sword',    0.4000),
    ('bonefield_reckoning',   'bone',     0.7000),
    ('bonefield_reckoning',   'earth',    0.3000),
    ('nightjar_veil',         'shadow',   0.6000),
    ('nightjar_veil',         'illusion', 0.4000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- The same two checks 0125 ran, because they are the ones that catch a typo
-- in a power figure - and a rank with four techniques nobody can tell apart
-- from a rank with four techniques in the wrong order.

DO $$
DECLARE
    thin  SMALLINT;
    wrong INTEGER;
BEGIN
    SELECT r.rank INTO thin
    FROM generate_series(1, 9) AS r (rank)
    WHERE (SELECT count(*) FROM techniques t
           WHERE t.created_by IS NULL AND t.rank = r.rank) < 4
    ORDER BY r.rank
    LIMIT 1;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'rank % has fewer than four techniques on it', thin;
    END IF;

    SELECT count(*) INTO wrong
    FROM (
        SELECT t.rank, min(t.base_power) AS lo, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) a
    JOIN (
        SELECT t.rank, min(t.base_power) AS lo, max(t.base_power) AS hi
        FROM techniques t
        WHERE t.created_by IS NULL AND t.category = 'attack'
        GROUP BY t.rank
    ) b ON b.rank = a.rank + 1
    WHERE b.lo <= a.hi;

    IF wrong > 0 THEN
        RAISE EXCEPTION 'the power ladder overlaps at % rank boundary(s)', wrong;
    END IF;
END;
$$;
