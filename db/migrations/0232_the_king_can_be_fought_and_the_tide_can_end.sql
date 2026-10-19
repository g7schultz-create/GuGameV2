-- 0232_the_king_can_be_fought_and_the_tide_can_end
--
-- Tide 235 emptied its sea, raised its King, and then stopped being a game.
--
-- THE KING COULD NOT BE STRUCK. `horde_king_rise` sets the tide to 'king' the
-- moment the finale appears, and `horde_strike` refuses any swing unless the
-- tide is 'fighting'. So the one encounter that only exists while the status is
-- 'king' is the one encounter nothing can hit. It went up at 09:27, stood at
-- 54,000 of 54,000 health while people clicked at it, and walked off the field
-- untouched. That has been true since 0221 wrote both halves in the same
-- migration, and no test caught it because the tests raise the King and then
-- assert about the verdict rather than trying to fight the thing.
--
-- THEN THE TIDE COULD NOT END. `horde_verdict` answered 'king' for as long as
-- a King existed and had not been slain - and an escaped King is never slain.
-- So the verdict was 'king' forever, `horde_settle` refuses to close anything
-- that is not 'won' or 'lost', and `horde_king_rise` will not raise a second
-- one. Permanently stuck: chests never unlock, the region is never scored, and
-- `horde_open` refuses every future tide because one is still running. Two
-- players sat on three earned chests each that nothing could open.
--
-- The rule 0221 actually meant is still the rule: THE LINE IS THE ONLY
-- FAILURE. So a King that gets past is a tide that was held - they cleared the
-- sea and the line never broke, which was the job. Killing it stays the best
-- ending; missing it is not a punishment, it is the end of the event.
--
-- AND THE SEA COULD BE OVERDRAWN. 659 of 638 beasts slain, because the
-- gauntlet checks what is left when it ROLLS a wave and not when it credits
-- one - a wave worth five rolled against a sea with one in it. That is the
-- board reporting more beasts than the tide ever had, and it is what pushed
-- this tide into its finale early, which killed every gauntlet in flight with
-- 'the tide has broken off'. Both counters are clamped now, and a run in
-- progress lives through the King phase and ends when its wave does.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The King is a beast, and beasts can be hit
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := '    IF met.tide_status <> ''fighting'' THEN
        RAISE EXCEPTION ''the tide has broken off'' USING ERRCODE = ''check_violation'';
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer gates on the tide the old way';
    END IF;

    EXECUTE replace(src, old,
        '    -- ''king'' as well as ''fighting''. The King only ever exists while the
    -- tide says ''king'', so gating on ''fighting'' alone made the finale the
    -- one thing in this event that could not be fought.
    IF met.tide_status NOT IN (''fighting'', ''king'') THEN
        RAISE EXCEPTION ''the tide has broken off'' USING ERRCODE = ''check_violation'';
    END IF;');
END;
$$;


-- ---------------------------------------------------------------------------
-- A King that gets past ends the tide instead of freezing it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_verdict(p_horde_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        WHEN h.status IN ('won', 'lost') THEN h.status

        -- The only failure: enough of them got past.
        WHEN h.beasts_lost >= h.line_holds THEN 'lost'

        -- The King came out and went down. That is the best ending there is.
        WHEN EXISTS (SELECT 1 FROM horde_encounters e
                     WHERE e.horde_id = h.horde_id
                       AND e.kind = 'king' AND e.status = 'slain')
            THEN 'won'

        -- The King came out and got past. The sea was still emptied and the
        -- line still held, which was the job - missing the finale is the end
        -- of the event, not a loss. Without this the answer stayed 'king'
        -- forever, because an escaped King is never a slain one.
        WHEN EXISTS (SELECT 1 FROM horde_encounters e
                     WHERE e.horde_id = h.horde_id
                       AND e.kind = 'king' AND e.status = 'escaped')
            THEN 'won'

        -- Cleared the sea, so the thing behind it is out or is coming.
        WHEN h.beasts_slain >= h.beasts_total THEN 'king'

        -- Time up with the line unbroken. You held; that was the job.
        WHEN h.ends_at <= now() THEN 'won'

        ELSE 'fighting'
    END
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_verdict(BIGINT) IS
    'Where the tide stands, computed rather than stored. Holding the line to the end is a win, only beasts getting past is a loss, and the King is a finale rather than a gate - one that walks off ends the event instead of stalling it.';


-- ---------------------------------------------------------------------------
-- Neither lane can draw more beasts than the tide has
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_gauntlet_swing';

    old := '        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + horde_gauntlet_worth(was_wave)
        WHERE h.horde_id = run.horde_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_swing no longer charges the sea the old way';
    END IF;

    EXECUTE replace(src, old,
        '        -- Clamped. The sea is checked when a wave is ROLLED, and a wave
        -- worth five can be rolled against a sea holding one - which is how a
        -- tide came to report 659 of 638 slain.
        UPDATE beast_hordes h
        SET beasts_slain = LEAST(h.beasts_total,
                                 h.beasts_slain + horde_gauntlet_worth(was_wave))
        WHERE h.horde_id = run.horde_id;');
END;
$$;


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := '        UPDATE beast_hordes h
        SET beasts_slain = h.beasts_slain + met.worth
        WHERE h.horde_id = met.horde_id;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer counts a pack the old way';
    END IF;

    EXECUTE replace(src, old,
        '        UPDATE beast_hordes h
        SET beasts_slain = LEAST(h.beasts_total, h.beasts_slain + met.worth)
        WHERE h.horde_id = met.horde_id;');
END;
$$;


-- ---------------------------------------------------------------------------
-- A run in progress lives through the finale
-- ---------------------------------------------------------------------------
-- Somebody mid-wave when the sea empties was having their run ended under them
-- with 'the tide has broken off'. Let the wave finish: `horde_gauntlet_next`
-- already refuses to roll another once the sea is empty, so the run closes as
-- 'cleared' at the natural place.

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_gauntlet_swing';

    old := '    IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = run.horde_id)
       <> ''fighting'' THEN';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_swing no longer gates on the tide the old way';
    END IF;

    EXECUTE replace(src, old,
        '    IF (SELECT h.status FROM beast_hordes h WHERE h.horde_id = run.horde_id)
       NOT IN (''fighting'', ''king'') THEN');
END;
$$;


-- And opening one during the finale says the true reason it is refused.
CREATE OR REPLACE FUNCTION horde_gauntlet_open(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    tide RECORD;
    body BIGINT;
    pool BIGINT;
    made BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes
    WHERE status IN ('fighting', 'king') ORDER BY horde_id DESC LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no tide to walk into'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM horde_gauntlets g
               WHERE g.player_id = p_player_id AND g.status = 'fighting') THEN
        RAISE EXCEPTION 'you are already on the line'
            USING ERRCODE = 'check_violation';
    END IF;

    IF dungeon_default_move(p_player_id) IS NULL THEN
        RAISE EXCEPTION 'you have nothing to swing - learn a technique with /learn first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- During the finale this is the honest refusal: there is a tide, it just
    -- has nothing left to send you.
    IF horde_sea_left(tide.horde_id) <= 0 THEN
        RAISE EXCEPTION 'the sea is empty - what is left of it is in the channel'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.max_hp INTO body FROM player_physique pp
    WHERE pp.player_id = p_player_id;

    IF body IS NULL THEN
        RAISE EXCEPTION 'you have no body to walk it with'
            USING ERRCODE = 'check_violation';
    END IF;

    pool := GREATEST(1, player_max_qi(p_player_id));

    INSERT INTO horde_gauntlets (horde_id, player_id, hp, max_hp, qi, max_qi)
    VALUES (tide.horde_id, p_player_id,
            GREATEST(1, body), GREATEST(1, body), pool, pool)
    RETURNING gauntlet_id INTO made;

    IF NOT horde_gauntlet_next(made) THEN
        UPDATE horde_gauntlets SET status = 'cleared', ended_at = now()
        WHERE gauntlet_id = made;
    END IF;

    RETURN made;
END;
$$;


DO $$
DECLARE
    tide  BIGINT;
    who   BIGINT;
    king  BIGINT;
    hit   RECORD;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 2::smallint, NULL);

        -- Empty the sea and raise the finale.
        UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = tide;
        IF horde_verdict(tide) <> 'king' THEN
            RAISE EXCEPTION 'an empty sea did not bring the King out';
        END IF;

        king := horde_king_rise(tide);
        IF king IS NULL THEN
            RAISE EXCEPTION 'the King did not rise';
        END IF;

        -- The whole of this migration: it can be hit.
        SELECT * INTO hit FROM horde_strike(king, who);
        IF hit.dealt <= 0 THEN
            RAISE EXCEPTION 'the King took no damage from a swing at it';
        END IF;

        -- And one that walks off ends the tide rather than freezing it.
        UPDATE horde_encounters SET status = 'escaped', settled_at = now()
        WHERE encounter_id = king;

        IF horde_verdict(tide) <> 'won' THEN
            RAISE EXCEPTION 'an escaped King left the tide at %',
                horde_verdict(tide);
        END IF;
        IF horde_settle(tide) <> 'won' THEN
            RAISE EXCEPTION 'the tide would not close';
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
