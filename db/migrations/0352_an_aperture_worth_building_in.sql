-- 0352_an_aperture_worth_building_in
--
-- Every cultivator on this server is pinned against their aperture, wearing a
-- handful of worms out of a hoard:
--
--     clearwest      aperture 12, using 12, four Gu worn, 151 held
--     m_i_y_u_k_i.   aperture 12, using 12, seven worn, 183 held
--     pashu0         aperture 12, using 11, TWO worn, 103 held
--
-- A Gu costs its rank, so twelve buys a rank 8 and a rank 4 and nothing else.
-- There is no building to be done there - the aperture picks the build, and
-- the answer is always 'the two biggest numbers you own'. A hundred and
-- eighty-three Gu in a bag is not a collection, it is a list of things that
-- did not fit.
--
-- So the aperture becomes rank x 3, with the same +3 at a peak the old ladder
-- had. Rank 9 peak goes from twelve to thirty; a Dao Realm cultivator wears
-- five good worms instead of two.
--
-- THIS DOES NOT MAKE GU THE MULTIPLIER, and that is the point worth being
-- careful about, because more slots sounds like more power. Every effect in
-- `gu_effects` carries a cap and the big ones are already being hit -
-- attack_power caps at 2.00 and pashu0 and m_i_y_u_k_i are both sitting on
-- exactly 2.00 with a couple of worms. The extra room cannot buy more of what
-- a player already has; it can only buy them something ELSE. The aperture
-- stops choosing the build and the player starts.
--
-- NOBODY LOSES A WORM. Capacity only rises, at every rung, so no equipped set
-- anywhere becomes invalid - which matters because `enforce_gu_capacity` only
-- guards the way in, and a shrinking aperture would leave people over their
-- limit with no code anywhere to notice.
--
-- Forward-only. Do not edit once applied.


UPDATE realms
SET gu_capacity = (rank * 3 + CASE WHEN stage = 'peak' THEN 3 ELSE 0 END)::smallint;


-- ---------------------------------------------------------------------------
-- Room to build, and nobody over their limit
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad  TEXT;
    peak SMALLINT;
BEGIN
    -- Never smaller than the rung below. `breakthrough` reports the gain as a
    -- difference, and a negative one would be reported as an aperture LOST.
    SELECT string_agg(a.name, ', ') INTO bad
    FROM realms a JOIN realms b ON b.realm_id = a.realm_id - 1
    WHERE a.gu_capacity < b.gu_capacity;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'the aperture shrinks at: %', bad;
    END IF;

    -- Nobody is now over their own limit. Only a widening can guarantee this,
    -- and the trigger that enforces capacity never looks at anybody already
    -- wearing their Gu.
    SELECT string_agg(p.discord_name || ' (' || gu_used_by(p.player_id)
                      || ' of ' || gu_capacity_of(p.player_id) || ')', ', ')
    INTO bad
    FROM players p
    WHERE p.deleted_at IS NULL
      AND gu_used_by(p.player_id) > gu_capacity_of(p.player_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are over their aperture: %', bad;
    END IF;

    -- And there is room to actually build. Five rank 6 worms at the top of
    -- the mortal ladder rather than two.
    SELECT gu_capacity INTO peak FROM realms WHERE rank = 9 AND stage = 'peak';
    IF peak / 6 < 5 THEN
        RAISE EXCEPTION
            'a Dao Realm - Peak aperture of % holds only % rank 6 Gu',
            peak, peak / 6;
    END IF;

    RAISE NOTICE
        'Dao Realm - Peak now holds % (was 12): % rank 6 worms, or % rank 8',
        peak, peak / 6, peak / 8;
END;
$probe$;
