-- 0500_the_king_cap_traded_one_fault_for_a_worse_one
--
-- 0499 did two things. The `ceiling` fix to the body floor was right and
-- stays. The change to `horde_king_line_reach` was wrong and is reverted
-- here.
--
-- It capped the King's sea term by the PRESENT roster when no line gathered,
-- so that a King could never be unreachable. It worked, and then:
--
--     the King carries 36,383 against an elite spawn's 40,346,529
--
-- The King came out a thousand times smaller than the ordinary beasts of its
-- own tide. I traded "a finale nobody can finish" for "a finale weaker than
-- the things it comes in behind", which is worse - the first is a wall, the
-- second is nonsense.
--
-- AND THE TWO STANDING TESTS BRACKET IT, which is how I know this is not
-- mine to settle:
--
--     test_the_king_is_bigger_than_the_beasts_it_comes_after
--         King >= 2x an elite spawn
--     test_the_king_can_still_be_felled_in_the_time_it_stands
--         King <= what the room can land in the time it stands
--
-- In a quiet region there is NO value satisfying both, because the thing in
-- the middle is not the King at all. An elite spawn is
-- `GREATEST(region floor, what the room can be asked for)`, and on a quiet
-- server the region floor wins and sits ABOVE what the room can land. The
-- minions are already out of reach, so a King that is twice a minion is
-- further out of reach, and a King the room can fell is below its own
-- minions. The contradiction is in the beast floor, not in the King.
--
-- That floor is deliberate. 0240 built region-counted bodies, 0291 sized them
-- to the room, and the floor was kept on purpose so "a quiet server never
-- gets a softer tide than the one it had before". Removing it is a real
-- design decision with a real cost, and it is the user's:
--
--     EITHER the region floor is capped by what the room can land, which
--     makes tides genuinely easier on a quiet server - the thing the floor
--     exists to prevent
--
--     OR the "fellable" guarantee holds only when a line gathers, and a tide
--     in an empty region is allowed to be out of reach until people turn up
--     - which is arguably what a tide IS
--
-- I am not picking one by stealth inside a migration about rounding. The
-- NULL fallback goes back, which restores exactly the behaviour 0377 shipped,
-- and the question goes to the user.
--
-- What this leaves: `test_the_king_can_still_be_felled_in_the_time_it_stands`
-- fails in some regions, as it did before 0499 and for the same pre-existing
-- reason. It is a real finding and it is now written down in two places
-- rather than being quietly made green.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION horde_king_line_reach(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- What the line that gathered could put into it, times the reach. NULL
    -- when nobody gathered: LEAST ignores NULLs, so the floor stands alone
    -- rather than being clamped to zero.
    --
    -- 0499 tried replacing that NULL with the present roster's reach, to stop
    -- a King in a quiet region being unreachable. It made the King smaller
    -- than the beasts of its own tide, because an elite spawn carries a
    -- region floor that a quiet room cannot match either. The fault is the
    -- beast floor and the fix is a design decision - see 0500.
    SELECT CASE WHEN COALESCE(sum(horde_walker_burst(c.player_id, p_species_id)), 0) > 0
                THEN sum(horde_walker_burst(c.player_id, p_species_id))
                     * game_config_value('horde_king_burst')
                     * game_config_value('horde_king_bursts_expected')
                     * game_config_value('horde_king_effort')
                     * game_config_value('horde_king_reach')
                ELSE NULL END
    FROM horde_contributions c WHERE c.horde_id = p_horde_id;
$fn$;


DO $probe$
DECLARE
    v_sp   BIGINT;
    v_bad  TEXT;
    v_n    INTEGER;
    r      RECORD;
BEGIN
    -- Back to 0377's behaviour exactly.
    IF horde_king_line_reach(-1::BIGINT,
                             (SELECT species_id FROM creature_species LIMIT 1)) IS NOT NULL THEN
        RAISE EXCEPTION 'the cap still answers when no line gathered';
    END IF;

    -- 0499's other half is untouched: the body floor is still a ceiling.
    IF pg_get_functiondef('horde_body_pool(bigint,bigint,boolean)'::regprocedure)
       NOT LIKE '%ceiling(cs.base_hp%' THEN
        RAISE EXCEPTION 'the body floor fix was lost';
    END IF;

    -- And the King is bigger than its own minions again, which is the
    -- invariant 0499 broke. Checked across live hordes rather than asserted.
    FOR r IN
        SELECT h.horde_id, cs.species_id
        FROM beast_hordes h
        JOIN creature_regions cr ON cr.region_code = h.region_code
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cs.kind = 'beast'
        LIMIT 60
    LOOP
        IF horde_king_pool(r.horde_id, r.species_id)
           < horde_body_pool(r.horde_id, r.species_id, TRUE) THEN
            v_bad := 'horde ' || r.horde_id || ' species ' || r.species_id;
            EXIT;
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a King is still smaller than an elite of its own tide: %', v_bad;
    END IF;

    RAISE NOTICE
        'king cap reverted to 0377; the beast floor question is open for the user';
END;
$probe$;
