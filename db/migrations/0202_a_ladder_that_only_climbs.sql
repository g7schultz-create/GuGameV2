-- 0202_a_ladder_that_only_climbs
--
-- Nascent Soul - Mid asked for more than Nascent Soul - Late:
--
--     Early -> Mid    152,852
--     Mid   -> Late   122,107      <- easier than the stage before it
--     Late  -> Peak   168,312
--
-- It is not one realm. EVERY rank does it, in all nine, and Qi Condensation
-- does it twice. The Mid step was inflated and the Late step paid for it, so a
-- cultivator who ground through Mid was rewarded with a stage that took less
-- work than the one they had just finished - which reads as the game being
-- broken, and is.
--
-- The floors are recomputed so every step is strictly larger than the one
-- before it, across the whole ladder from Qi Condensation to Dao Realm.
--
-- THE RANK BOUNDARIES DO NOT MOVE. Realm 1, 5, 9, 13, 17, 20, 24, 28 and 32
-- are exactly where they were - those are the realm thresholds every other
-- system is balanced against (`realm_cultivation_scale`, technique ranks,
-- manual required_rank), and moving them would move people between realms for
-- reasons that have nothing to do with this. Only the stages INSIDE a rank are
-- redistributed, as a geometric climb between the rank's own floor and the
-- next rank's.
--
-- The ratio is 1.55 where it can be, and lower where a block's first step
-- would otherwise land under the boundary step that ran into it - a rank
-- boundary that dips is the same fault as a stage that dips, so it is checked
-- the same way.
--
-- ONE CULTIVATOR IS LIFTED. Qi Condensation - Peak rises from 1,900 to 4,121,
-- and chickenshavelegs is sitting on 2,280 - inside the old Peak and under the
-- new one. They are moved up to the new floor rather than demoted a stage for
-- a change they had no part in. That is 1,841 cultivation, and it is the same
-- thing 0186 did when 0184 left five people under their own floor.
--
-- Nobody else moves. Two go UP a stage because a floor came down under them
-- (grafv into Core Formation - Mid, luckymate0_0 into Foundation Establishment
-- - Late), which is a gift and not a problem.
--
-- Forward-only. Do not edit once applied.


UPDATE realms r SET cultivation_required = v.floor
FROM (VALUES
    (1, 0), (2, 832), (3, 2122), (4, 4121),
    (5, 7220), (6, 10321), (7, 15064), (8, 22322),
    (9, 33427), (10, 49149), (11, 73518), (12, 111290),
    (13, 169836), (14, 284523), (15, 462288), (16, 737823),
    (17, 1164903), (18, 2543028), (19, 4679122),
    (20, 7990067), (21, 13385615), (22, 21748716), (23, 34711521),
    (24, 54803869), (25, 91811936), (26, 149174439), (27, 238086320),
    (28, 375899735), (29, 629738065), (30, 1023187478), (31, 1633034066),
    (32, 2578296279), (33, 4426649175), (34, 7291596164), (35, 11732263997)
) AS v(realm_id, floor)
WHERE r.realm_id = v.realm_id;


-- Anybody now standing under their own realm's floor is lifted to it. Written
-- as a rule rather than as one name, so it catches whoever it catches.
UPDATE player_cultivation pc
SET cultivation = r.cultivation_required
FROM realms r
WHERE r.realm_id = pc.realm_id
  AND pc.cultivation < r.cultivation_required;


DO $$
DECLARE
    thin TEXT;
    got  RECORD;
BEGIN
    -- 1. The rule this migration exists for.
    SELECT string_agg(name || ' (' || step || ' after ' || before || ')', ', ')
    INTO thin
    FROM (
        SELECT r.name, r.cultivation_required
               - LAG(r.cultivation_required) OVER (ORDER BY r.realm_id) AS step,
               LAG(r.cultivation_required) OVER (ORDER BY r.realm_id)
               - LAG(r.cultivation_required, 2) OVER (ORDER BY r.realm_id) AS before
        FROM realms r
    ) s
    WHERE step IS NOT NULL AND before IS NOT NULL AND step <= before;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these stages are easier than the one before: %', thin;
    END IF;

    -- 2. The rank boundaries are where they were. Named by value rather than
    --    by realm_id so a renumbering cannot quietly satisfy this.
    SELECT string_agg(r.name || ' = ' || r.cultivation_required, ', ') INTO thin
    FROM realms r
    JOIN (VALUES (1, 0), (5, 7220), (9, 33427), (13, 169836), (17, 1164903),
                 (20, 7990067), (24, 54803869), (28, 375899735), (32, 2578296279))
         AS v(realm_id, floor) ON v.realm_id = r.realm_id
    WHERE r.cultivation_required <> v.floor;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'a rank boundary moved: %', thin;
    END IF;

    -- 3. Floors still climb at all, which the UPDATE above could have broken
    --    by transposing two values.
    IF EXISTS (
        SELECT 1 FROM realms a JOIN realms b ON b.realm_id = a.realm_id + 1
        WHERE b.cultivation_required <= a.cultivation_required
    ) THEN
        RAISE EXCEPTION 'the floors are not in order';
    END IF;

    -- 4. Nobody was demoted, and nobody is left under their own floor.
    FOR got IN
        SELECT p.discord_name, pc.cultivation, pc.realm_id,
               r.cultivation_required AS floor_at
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    LOOP
        IF got.cultivation < got.floor_at THEN
            RAISE EXCEPTION '% holds % and their realm floor is %',
                got.discord_name, got.cultivation, got.floor_at;
        END IF;
    END LOOP;
END;
$$;
