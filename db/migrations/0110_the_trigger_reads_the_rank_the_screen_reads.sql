-- 0110_the_trigger_reads_the_rank_the_screen_reads
--
-- 0047 left a comment above `path_still_open`:
--
--     `path_still_open` has to answer the same question the trigger does, or
--     the screen offers a button the database refuses.
--
-- 0108 moved the view onto the stored `body_rank` and left the trigger reading
-- `body_rank_for_xp(physique_xp)`, which is exactly the divergence that
-- comment was put there to prevent. The two now disagree for any cultivator
-- who has trained past a door without crossing it: the screen offers the
-- three bodies and the trigger refuses the choice.
--
-- 0047's own test caught it, which is the whole reason it exists.
--
-- WHAT THIS CHANGES FOR A PLAYER. The body path is now locked by the CROSSING
-- rather than by the training - you may still change your mind at Rank 1, and
-- Rank 1 now lasts until you spend the beast material to leave it. That is
-- the better rule anyway: a decision that locks itself while you are offline
-- is not a decision.
--
-- Forward-only. Do not edit once applied.


-- 0108 added a foreign key and no index for it. Every other FK in this schema
-- has one, and the test that says so is not decoration: `body_rank` is read
-- on every physique recompute.
CREATE INDEX player_physique_body_rank_idx ON player_physique (body_rank);


CREATE OR REPLACE FUNCTION enforce_body_path_sets() RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.body_path IS NOT DISTINCT FROM OLD.body_path THEN
        RETURN NEW;
    END IF;

    -- A choice never made is still owed, whatever rank it is owed at.
    IF OLD.body_path IS NULL THEN
        RETURN NEW;
    END IF;

    -- The rank the body has CROSSED, which is what the screen reads too.
    IF OLD.body_rank > 1 THEN
        RAISE EXCEPTION
            'your body set as % at Rank %. That is not something you take back',
            (SELECT name FROM body_paths WHERE code = OLD.body_path),
            OLD.body_rank
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_body_path_sets() IS
    'Choosing is always allowed; changing your mind is allowed only at Rank 1, which since 0108 means until you have tempered out of it. Reads the same column player_body does.';
