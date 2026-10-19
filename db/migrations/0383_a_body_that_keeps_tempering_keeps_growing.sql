-- 0383_a_body_that_keeps_tempering_keeps_growing
--
-- Five cultivators are at body rank 9, which is the top of a ladder written
-- for a nine-realm world, and four of them stopped gaining anything from
-- tempering a long time ago:
--
--     m_i_y_u_k_i.  level 589   progress 9.000
--     shinonn._.    level 322   progress 9.000
--     ._.visha._.   level 308   progress 9.000
--     clearwest     level 285   progress 9.000
--
-- Rank 9 begins at body level 211, and `body_rank_progress` gives the top rank
-- a made-up width of seventy levels before clamping at 1.0. So everything past
-- level 281 is worth nothing whatsoever - m_i_y_u_k_i has tempered three
-- hundred and eight levels past the point where it stopped counting.
--
-- TWO THINGS ARE WRONG AND THEY NEED DIFFERENT FIXES.
--
-- THE LADDER IS TOO SHORT. `body_ranks` runs to nine because the realm ladder
-- did, and 0334 added nine realms above that without the body following. Nine
-- more rungs per Path, on the curve the first nine already walk - each rung
-- about 1.4 times the last.
--
-- THE TOP RUNG IS A WALL RATHER THAN A CEILING. Extending the ladder moves the
-- wall to rank 18; it does not remove it. So the clamp becomes a soft one:
-- past the end of the last band, every DOUBLING of the excess is worth another
-- `body_overflow_weight` of a rank. At 0.5 that is the square root of the
-- excess in stat terms - a body that keeps tempering keeps growing, slowly,
-- and never again reaches a level where the next one is worth literally
-- nothing.
--
-- The soft cap is written to engage only past a band's end, and
-- `apply_physique_xp` holds levels back at `body_level_ceiling` until the rank
-- comes - so on every rung except the last it is exactly the old LEAST(1.0).
--
-- WHAT THIS DOES TO THE PEOPLE WHO EARNED IT. Their accumulated tempering
-- stops being discarded, which is the whole point, and it is a real jump:
-- m_i_y_u_k_i's 294,434 experience is rank 11 on the new ladder rather than
-- rank 9, and two ranks is four times the body. That is not a windfall - it is
-- three hundred levels of work that the ladder was throwing away being paid
-- for at the rate it was always quoted at.
--
-- Forward-only. Do not edit once applied.


-- The ladder was CHECKed to nine as well as ending there.
ALTER TABLE body_rank_requirements DROP CONSTRAINT body_rank_requirements_rank_check;
ALTER TABLE body_rank_requirements ADD CONSTRAINT body_rank_requirements_rank_check
    CHECK (rank >= 1 AND rank <= 18);


INSERT INTO body_rank_requirements (rank, xp_required) VALUES
    (10,  155000), (11,  225000), (12,  323000), (13,  460000), (14,  652000),
    (15,  921000), (16, 1297000), (17, 1824000), (18, 2562000);


INSERT INTO body_ranks (path_code, rank, name) VALUES
    ('taoist',   10, 'Primordial Dao Body'),
    ('taoist',   11, 'Heaven-Severing Form'),
    ('taoist',   12, 'Immortal Foundation Perfected'),
    ('taoist',   13, 'Chaos Origin Vessel'),
    ('taoist',   14, 'Nine Heavens Ascendant'),
    ('taoist',   15, 'Dao Sovereign Frame'),
    ('taoist',   16, 'Eternal Cycle Body'),
    ('taoist',   17, 'Venerable Dao Vessel'),
    ('taoist',   18, 'Origin of All Dao'),

    ('demonic',  10, 'Abyssal Sovereign Flesh'),
    ('demonic',  11, 'Blood Sea Incarnate'),
    ('demonic',  12, 'Demon Ancestor Frame'),
    ('demonic',  13, 'Calamity Vessel'),
    ('demonic',  14, 'Devouring Abyss Body'),
    ('demonic',  15, 'Demon Venerable Form'),
    ('demonic',  16, 'Myriad Sin Sovereign'),
    ('demonic',  17, 'Primordial Devil Vessel'),
    ('demonic',  18, 'Origin of All Demons'),

    ('buddhist', 10, 'Golden Relic Body'),
    ('buddhist', 11, 'Boundless Compassion Form'),
    ('buddhist', 12, 'Thousand-Arm Manifestation'),
    ('buddhist', 13, 'Unmoving Diamond Vessel'),
    ('buddhist', 14, 'Pure Land Incarnate'),
    ('buddhist', 15, 'Buddha Sovereign Frame'),
    ('buddhist', 16, 'Myriad Kalpa Body'),
    ('buddhist', 17, 'Venerable Buddha Vessel'),
    ('buddhist', 18, 'Origin of All Buddhas');


INSERT INTO game_config (key, value, description) VALUES
    ('body_overflow_weight', 0.5,
     'What a DOUBLING of tempering past the last body rung is worth, in rank. At 0.5 the excess pays the square root of itself in stats - a body at the top of the ladder keeps growing and never reaches a level worth nothing, without running away.');


-- ---------------------------------------------------------------------------
-- The top rung stops being a wall
-- ---------------------------------------------------------------------------
--
-- Written out rather than lifted and patched. The house rule is that a
-- function body is never retyped, and it is the right rule for a change of a
-- line or two - a lifted body cannot drift from what was there. This is not
-- that: the band calculation moves inside a subquery so the fraction can be
-- named once and read twice, and three surgical replacements against an
-- expression that is being restructured is a worse guarantee than one
-- readable definition. The old behaviour is stated exactly in the comment
-- and asserted in the probe.

-- `through` could not be built inside the same SELECT list that defines its
-- own inputs, so it is a second wrapper around the band rather than a column
-- in it. Written out because it is new code, not lifted.
CREATE OR REPLACE FUNCTION body_rank_progress(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Below the end of a band this is exactly the old LEAST(1.0):
    -- `apply_physique_xp` holds levels at `body_level_ceiling` until the rank
    -- comes, so nothing but the LAST rung can ever be past its own band.
    -- There, every doubling of the excess pays another `body_overflow_weight`
    -- of a rank - so tempering past the top of the ladder is worth less and
    -- less, and never nothing.
    SELECT (pp.body_rank - 1) + CASE
        WHEN band.through <= 1 THEN GREATEST(0.0, band.through)
        ELSE 1.0 + game_config_value('body_overflow_weight')
                   * log(2.0, band.through)
    END
    FROM player_physique pp
    JOIN LATERAL (
        SELECT (pp.body_level - edge.first_level)::numeric
               / GREATEST(1, edge.next_level - edge.first_level) AS through
        FROM (
            SELECT (1 + floor(r.xp_required
                              / game_config_value('physique_xp_per_level')))::int
                       AS first_level,
                   -- The top rung has nothing above it, so its width is the
                   -- width of the rung below - a real measure rather than the
                   -- flat seventy levels this used to invent.
                   COALESCE(
                     (1 + floor(n.xp_required
                                / game_config_value('physique_xp_per_level')))::int,
                     (1 + floor(r.xp_required
                                / game_config_value('physique_xp_per_level')))::int
                     + GREATEST(1,
                         (1 + floor(r.xp_required
                                    / game_config_value('physique_xp_per_level')))::int
                         - (1 + floor(COALESCE(b.xp_required, 0)
                                    / game_config_value('physique_xp_per_level')))::int)
                   ) AS next_level
            FROM body_rank_requirements r
            LEFT JOIN body_rank_requirements n ON n.rank = r.rank + 1
            LEFT JOIN body_rank_requirements b ON b.rank = r.rank - 1
            WHERE r.rank = pp.body_rank
        ) AS edge
    ) band ON TRUE
    WHERE pp.player_id = p_player_id;
$$;

COMMENT ON FUNCTION body_rank_progress(BIGINT) IS
    'How far up the body ladder a cultivator is, in ranks. Soft-capped at the top rung rather than clamped, so a body that keeps tempering keeps growing.';


-- Every body is rebuilt so the new ladder is in the numbers rather than
-- waiting for the next time somebody trains.
SELECT apply_physique_xp(pp.player_id, 0) FROM player_physique pp;


-- ---------------------------------------------------------------------------
-- Nobody's tempering is discarded any more
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad  TEXT;
    r    RECORD;
    n    INTEGER;
BEGIN
    -- Every rung of every Path is named, or a body ranks up into nothing.
    SELECT string_agg(t.path_code || ' ' || t.rank, ', ') INTO bad
    FROM (
        SELECT p.code AS path_code, g.rank
        FROM (SELECT DISTINCT path_code AS code FROM body_ranks) p
        CROSS JOIN generate_series(1, 18) AS g(rank)
    ) t
    WHERE NOT EXISTS (SELECT 1 FROM body_ranks br
                      WHERE br.path_code = t.path_code AND br.rank = t.rank)
       OR NOT EXISTS (SELECT 1 FROM body_rank_requirements rr
                      WHERE rr.rank = t.rank);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these body rungs have no name or no price: %', left(bad, 200);
    END IF;

    -- The ladder only ever gets dearer.
    SELECT count(*) INTO n FROM (
        SELECT xp_required, lag(xp_required) OVER (ORDER BY rank) AS below
        FROM body_rank_requirements
    ) t WHERE t.below IS NOT NULL AND t.xp_required <= t.below;
    IF n > 0 THEN
        RAISE EXCEPTION '% body rungs cost no more than the one below', n;
    END IF;

    -- THE POINT: nobody who has tempered past their rung is stuck at a flat
    -- progress any more. Before this, four cultivators read exactly 9.000.
    -- STRICTLY past, not merely at. A body sitting exactly on a band boundary
    -- reads progress 1.0 and is about to rank up - that is the ladder working,
    -- not tempering being thrown away. What must not exist is a body PAST the
    -- end of its band with rungs still above it, which is the state four
    -- cultivators were frozen in.
    SELECT string_agg(p.discord_name || ' (rank ' || pp.body_rank
                      || ', progress ' || round(body_rank_progress(pp.player_id), 2)
                      || ')', ', ')
    INTO bad
    FROM player_physique pp
    JOIN players p ON p.player_id = pp.player_id
    WHERE pp.body_rank < (SELECT max(rank) FROM body_rank_requirements)
      AND body_rank_progress(pp.player_id) > pp.body_rank::numeric;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these are past the end of a band with rungs above them: %',
            left(bad, 300);
    END IF;

    -- And the very top keeps paying: a body twice as far past the last rung
    -- must read higher than one that just reached it.
    IF game_config_value('body_overflow_weight') <= 0 THEN
        RAISE EXCEPTION 'the overflow pays nothing, so the top is still a wall';
    END IF;

    FOR r IN
        SELECT p.discord_name, pp.body_level, pp.body_rank,
               round(body_rank_progress(pp.player_id), 3) AS progress,
               round(player_power_multiple(pp.player_id)) AS climbed
        FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE pp.body_rank >= 8
        ORDER BY pp.body_level DESC
    LOOP
        RAISE NOTICE '% : level %, rank %, progress %, multiple %',
            rpad(r.discord_name, 14), r.body_level, r.body_rank,
            r.progress, r.climbed;
    END LOOP;
END;
$probe$;
