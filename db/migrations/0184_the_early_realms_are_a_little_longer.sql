-- 0184_the_early_realms_are_a_little_longer
--
-- 0183 made the draw scale with rank squared, which was aimed at Spirit
-- Severing and Dao Seeking - 243 days and 1,665 - and landed on the early
-- realms too. Foundation Establishment got 4x and Core Formation 9x against
-- requirements tuned for a flat rate, so a whole realm now passes in about a
-- day:
--
--   Foundation Establishment   4 stages   1.16 days   bare
--   Core Formation             4 stages   3.50 days
--
-- Qi Condensation is left exactly alone. Rank 1 scales at 1x, so 0183 never
-- touched it, and its 0.8 days is the onboarding it was always meant to be.
--
-- Foundation Establishment doubles and Core Formation goes up by about a
-- third. Both are far below the 4x and 9x those realms gained, so every stage
-- is still reached faster than before 0183 - this narrows the change rather
-- than reversing it, which is the difference between tuning and flip-flopping.
--
--   realm 2   4 stages   1.16 -> 2.5 days   (was 4.6 before 0183)
--   realm 3   4 stages   3.50 -> 4.4 days   (was 14.0)
--
-- Nobody's cultivation moves. The targets do, so a cultivator part-way up a
-- stage is further from the top of it than they were an hour ago - and still
-- closer than they were yesterday.
--
-- Forward-only. Do not edit once applied.


-- Kept for the check below: what the ladder said before this ran.
CREATE TEMP TABLE ladder_before ON COMMIT DROP AS
SELECT realm_id, rank, cultivation_required FROM realms;


UPDATE realms SET cultivation_required = round(cultivation_required * 2.0)
WHERE rank = 2;

UPDATE realms SET cultivation_required = round(cultivation_required * 1.35)
WHERE rank = 3;


DO $$
DECLARE
    broken TEXT;
BEGIN
    -- The ladder still only goes up.
    SELECT string_agg(a.realm_id::text, ', ') INTO broken
    FROM realms a JOIN realms b ON b.realm_id = a.realm_id + 1
    WHERE b.cultivation_required <= a.cultivation_required;

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION 'the ladder stops climbing after realm(s) %', broken;
    END IF;

    -- The claim this migration makes: it narrows 0183 without undoing it.
    -- A realm may not have been raised by more than it gained in draw.
    SELECT string_agg(r.name || ' (x' || round(r.cultivation_required
                                               / b.cultivation_required, 2)
                      || ' against x' || realm_cultivation_scale(r.rank) || ')',
                      ', ' ORDER BY r.realm_id)
    INTO broken
    FROM realms r
    JOIN ladder_before b ON b.realm_id = r.realm_id
    WHERE b.cultivation_required > 0
      -- Rank 1 gained nothing from 0183 and is deliberately unmoved, so it
      -- sits exactly on this boundary. Its own rule is the one below.
      AND r.rank > 1
      AND r.cultivation_required / b.cultivation_required
          >= realm_cultivation_scale(r.rank);

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION
            'these realms are now slower than before 0183: %', broken;
    END IF;

    -- Qi Condensation untouched, because it never gained anything to narrow.
    IF EXISTS (
        SELECT 1 FROM realms r JOIN ladder_before b ON b.realm_id = r.realm_id
        WHERE r.rank = 1 AND r.cultivation_required <> b.cultivation_required
    ) THEN
        RAISE EXCEPTION 'the first realm was moved';
    END IF;

    -- And nobody was demoted: a cultivator stays in the realm they broke
    -- through into, whatever the requirement now says.
    IF EXISTS (
        SELECT 1 FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE NOT EXISTS (SELECT 1 FROM realms r2 WHERE r2.realm_id = r.realm_id)
    ) THEN
        RAISE EXCEPTION 'somebody lost the realm they were standing in';
    END IF;
END;
$$;
