-- 0124_the_realms_get_their_real_names
--
-- "Rank 3 Middle" is a spreadsheet heading. The ladder a cultivator climbs in
-- this setting has names, and they carry the whole shape of the story: you
-- condense qi, you establish a foundation, you form a core, you birth a
-- nascent soul, and then you start severing pieces of yourself.
--
-- WHAT CHANGES, AND WHAT DELIBERATELY DOES NOT.
--
--   * `rank` stays 1-9. Every gate in this game - techniques, manuals, Gu,
--     creatures, the dwelling ladder - keys off rank, and none of them has to
--     learn anything today.
--   * Each rank gains a Late stage, so the ladder goes Early, Mid, Late, Peak.
--     Spirit Severing is the exception at three severings rather than four
--     stages, which is how the source material has it.
--   * 27 rungs become 35, so `realm_id` renumbers - and `realm_id` IS the
--     order here, because `realm_id + 1` is how fourteen functions ask for
--     "the next realm". The two tables that store one are remapped below.
--
-- NOBODY MOVES. A Late rung's requirement is the geometric mean of the Mid and
-- Peak either side of it - the same ~1.9x curve the ladder already runs on -
-- so every threshold that existed yesterday is unchanged and every cultivator
-- is in exactly the realm they went to sleep in, under a better name.
--
-- Forward-only. Do not edit once applied.


-- The Late rung needs a place in the vocabulary before it can be inserted.
ALTER TABLE realms DROP CONSTRAINT realms_stage_check;
ALTER TABLE realms ADD CONSTRAINT realms_stage_check
    CHECK (stage IN ('early', 'middle', 'late', 'peak'));

-- Dropped for the swap. Every id from 1 to 27 changes what rank and stage it
-- means, so for one statement two rows would claim the same pair - id 27 is
-- Rank 9 Peak on the way in and Immortal Peak on the way out. Restored below,
-- and the ladder is checked afterwards either way.
ALTER TABLE realms DROP CONSTRAINT realms_rank_stage_key;


-- The remap, written down once and used by everything below.
CREATE TEMP TABLE realm_remap (old_id SMALLINT PRIMARY KEY, new_id SMALLINT NOT NULL)
    ON COMMIT DROP;
INSERT INTO realm_remap (old_id, new_id) VALUES
    (1,1), (2,2), (3,4), (4,5), (5,6), (6,8), (7,9), (8,10), (9,12), (10,13), (11,14), (12,16), (13,17), (14,18), (15,19), (16,20), (17,21), (18,23), (19,24), (20,25), (21,27), (22,28), (23,29), (24,31), (25,32), (26,33), (27,35);


-- The ladder itself, entire, BEFORE anybody is moved onto it. The foreign key
-- on player_cultivation is not deferrable, so every destination has to exist
-- before a cultivator can be pointed at one.
INSERT INTO realms
    (realm_id, code, name, rank, stage, cultivation_required,
     qi_capacity, essence_capacity, gu_capacity)
VALUES
    (1, 'qi_condensation_early', 'Qi Condensation — Early', 1, 'early', 0, 500, 1000, 3),
    (2, 'qi_condensation_middle', 'Qi Condensation — Mid', 1, 'middle', 1000, 500, 1000, 3),
    (3, 'qi_condensation_late', 'Qi Condensation — Late', 1, 'late', 1378, 500, 1000, 3),
    (4, 'qi_condensation_peak', 'Qi Condensation — Peak', 1, 'peak', 1900, 500, 1000, 4),
    (5, 'foundation_early', 'Foundation Establishment — Early', 2, 'early', 3610, 1000, 2000, 4),
    (6, 'foundation_middle', 'Foundation Establishment — Mid', 2, 'middle', 6859, 1000, 2000, 4),
    (7, 'foundation_late', 'Foundation Establishment — Late', 2, 'late', 9454, 1000, 2000, 4),
    (8, 'foundation_peak', 'Foundation Establishment — Peak', 2, 'peak', 13032, 1000, 2000, 5),
    (9, 'core_formation_early', 'Core Formation — Early', 3, 'early', 24761, 2000, 4000, 5),
    (10, 'core_formation_middle', 'Core Formation — Mid', 3, 'middle', 47046, 2000, 4000, 5),
    (11, 'core_formation_late', 'Core Formation — Late', 3, 'late', 64848, 2000, 4000, 5),
    (12, 'core_formation_peak', 'Core Formation — Peak', 3, 'peak', 89387, 2000, 4000, 6),
    (13, 'nascent_soul_early', 'Nascent Soul — Early', 4, 'early', 169836, 4000, 8000, 6),
    (14, 'nascent_soul_middle', 'Nascent Soul — Mid', 4, 'middle', 322688, 4000, 8000, 6),
    (15, 'nascent_soul_late', 'Nascent Soul — Late', 4, 'late', 444795, 4000, 8000, 6),
    (16, 'nascent_soul_peak', 'Nascent Soul — Peak', 4, 'peak', 613107, 4000, 8000, 7),
    (17, 'spirit_severing_early', 'Spirit Severing — First Severing', 5, 'early', 1164903, 8000, 16000, 7),
    (18, 'spirit_severing_middle', 'Spirit Severing — Second Severing', 5, 'middle', 2213315, 8000, 16000, 7),
    (19, 'spirit_severing_peak', 'Spirit Severing — Third Severing', 5, 'peak', 4205298, 8000, 16000, 8),
    (20, 'dao_seeking_early', 'Dao Seeking — Early', 6, 'early', 7990067, 16000, 32000, 8),
    (21, 'dao_seeking_middle', 'Dao Seeking — Mid', 6, 'middle', 15181127, 16000, 32000, 8),
    (22, 'dao_seeking_late', 'Dao Seeking — Late', 6, 'late', 20925739, 16000, 32000, 8),
    (23, 'dao_seeking_peak', 'Dao Seeking — Peak', 6, 'peak', 28844141, 16000, 32000, 9),
    (24, 'immortal_early', 'Immortal Realm — Early', 7, 'early', 54803869, 32000, 64000, 9),
    (25, 'immortal_middle', 'Immortal Realm — Mid', 7, 'middle', 104127350, 32000, 64000, 9),
    (26, 'immortal_late', 'Immortal Realm — Late', 7, 'late', 143529647, 32000, 64000, 9),
    (27, 'immortal_peak', 'Immortal Realm — Peak', 7, 'peak', 197841966, 32000, 64000, 10),
    (28, 'ancient_early', 'Ancient Realm — Early', 8, 'early', 375899735, 64000, 128000, 10),
    (29, 'ancient_middle', 'Ancient Realm — Mid', 8, 'middle', 714209496, 64000, 128000, 10),
    (30, 'ancient_late', 'Ancient Realm — Late', 8, 'late', 984469851, 64000, 128000, 10),
    (31, 'ancient_peak', 'Ancient Realm — Peak', 8, 'peak', 1356998042, 64000, 128000, 11),
    (32, 'dao_realm_early', 'Dao Realm — Early', 9, 'early', 2578296279, 128000, 256000, 11),
    (33, 'dao_realm_middle', 'Dao Realm — Mid', 9, 'middle', 4898762931, 128000, 256000, 11),
    (34, 'dao_realm_late', 'Dao Realm — Late', 9, 'late', 6752478707, 128000, 256000, 11),
    (35, 'dao_realm_peak', 'Dao Realm — Peak', 9, 'peak', 9307649569, 128000, 256000, 12)
ON CONFLICT (realm_id) DO UPDATE SET
    code = EXCLUDED.code,
    name = EXCLUDED.name,
    rank = EXCLUDED.rank,
    stage = EXCLUDED.stage,
    cultivation_required = EXCLUDED.cultivation_required,
    qi_capacity = EXCLUDED.qi_capacity,
    essence_capacity = EXCLUDED.essence_capacity,
    gu_capacity = EXCLUDED.gu_capacity;

-- Now the two tables that store a realm follow it.
UPDATE player_cultivation pc
SET realm_id = m.new_id
FROM realm_remap m WHERE m.old_id = pc.realm_id;

UPDATE dwelling_stages ds
SET realm_required = m.new_id
FROM realm_remap m WHERE m.old_id = ds.realm_required;

ALTER TABLE realms ADD CONSTRAINT realms_rank_stage_key UNIQUE (rank, stage);


-- The ladder must climb, or `realm_id + 1` means nothing.
DO $$
DECLARE
    wrong INTEGER;
BEGIN
    SELECT count(*) INTO wrong FROM realms a
    JOIN realms b ON b.realm_id = a.realm_id + 1
    WHERE b.cultivation_required <= a.cultivation_required
       OR b.rank < a.rank;
    IF wrong > 0 THEN
        RAISE EXCEPTION 'the realm ladder does not ascend in % place(s)', wrong;
    END IF;

    IF (SELECT count(*) FROM realms) <> 35 THEN
        RAISE EXCEPTION 'expected 35 realms, found %', (SELECT count(*) FROM realms);
    END IF;
END;
$$;
