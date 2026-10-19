-- 0520_a_venerable_keeps_growing
--
-- A Venerable would be frozen at a Yellow Apricot Immortal's body. The three
-- capacity readers all join `realms` by `player_cultivation.realm_id`:
--
--     gu_capacity_of      SELECT r.gu_capacity FROM player_cultivation pc
--                         JOIN realms r ON r.realm_id = pc.realm_id
--     player_max_qi       the same, for qi_capacity
--     player_qi_aperture  the same again
--
-- and a Venerable never leaves realm_id 71, because the Venerable ladder is
-- `venerable_ranks` rather than a continuation of `realms` - deliberately, so
-- `breakthrough` cannot walk into it and start demanding `cultivation_required`
-- from people whose meter is understanding.
--
-- So the capacities would stop dead: 57 aperture for ever, at the exact moment
-- apex worms start costing 9 points each. A Venerable Rank 9 cultivator would
-- have the same aperture as the rank 18 they were yesterday.
--
-- THE CURVES ARE CONTINUED RATHER THAN CHOSEN. Measured off the top of the
-- realm ladder, where they are perfectly regular:
--
--     rank 15  48 aperture   8,192,000 qi    16,384,000 essence
--     rank 16  51            16,384,000      32,768,000
--     rank 17  54            32,768,000      65,536,000
--     rank 18  57            65,536,000      131,072,000
--
--     aperture +3 a rank, qi x2 a rank, essence x2 a rank
--
-- V1 is 60 aperture and V9 is 84, with qi and essence doubling each rung as
-- they have since rank 1. Nothing is invented; the ladder simply continues.
--
-- GREATEST, NOT REPLACE. Each reader takes whichever of the two ladders gives
-- more, so a cultivator who has not ascended reads exactly what they read
-- before and nothing can ever go down. A Venerable reads their rung.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE venerable_ranks
    ADD COLUMN gu_capacity      SMALLINT,
    ADD COLUMN qi_capacity      BIGINT,
    ADD COLUMN essence_capacity BIGINT;

-- Continued off rank 18's 57 / 65,536,000 / 131,072,000.
UPDATE venerable_ranks SET
    gu_capacity      = 57 + 3 * venerable_tier,
    qi_capacity      = 65536000::BIGINT  * power(2, venerable_tier)::BIGINT,
    essence_capacity = 131072000::BIGINT * power(2, venerable_tier)::BIGINT;

ALTER TABLE venerable_ranks
    ALTER COLUMN gu_capacity      SET NOT NULL,
    ALTER COLUMN qi_capacity      SET NOT NULL,
    ALTER COLUMN essence_capacity SET NOT NULL,
    ADD CONSTRAINT venerable_ranks_capacities_climb
        CHECK (gu_capacity > 57 AND qi_capacity > 65536000
               AND essence_capacity > 131072000);

COMMENT ON COLUMN venerable_ranks.gu_capacity IS
    'The aperture a Venerable of this rung carries. Continues the realm ladder''s +3 a rank off rank 18''s 57 - a Venerable frozen at 57 while apex worms cost 9 points each would be a realm that takes something away.';


-- ---------------------------------------------------------------------------
-- One definition of what a cultivator's standing allows
-- ---------------------------------------------------------------------------

CREATE FUNCTION standing_capacity(p_player_id BIGINT, p_what TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE AS $fn$
    -- Whichever ladder gives more. A cultivator who has not ascended holds no
    -- `player_dao` row, so the Venerable side is NULL and GREATEST ignores it
    -- - they read their realm exactly as before. Guarded by the same EXISTS
    -- 0519 put on `player_standing`, because this is read per fight too.
    SELECT GREATEST(
        (SELECT CASE p_what
                    WHEN 'gu'      THEN r.gu_capacity::BIGINT
                    WHEN 'qi'      THEN r.qi_capacity
                    WHEN 'essence' THEN r.essence_capacity
                END
         FROM player_cultivation pc
         JOIN realms r ON r.realm_id = pc.realm_id
         WHERE pc.player_id = p_player_id),
        (SELECT CASE p_what
                    WHEN 'gu'      THEN v.gu_capacity::BIGINT
                    WHEN 'qi'      THEN v.qi_capacity
                    WHEN 'essence' THEN v.essence_capacity
                END
         FROM venerable_ranks v
         WHERE EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id)
           AND v.rank = venerable_rank_of(p_player_id))
    );
$fn$;

COMMENT ON FUNCTION standing_capacity(BIGINT, TEXT) IS
    'What a cultivator''s standing allows them to hold, taking the higher of the realm ladder and the Venerable ladder. The one place the two ladders meet.';


-- ---------------------------------------------------------------------------
-- The three readers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION gu_capacity_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- Was a bare join on `realms`, which stops at 57 and would have left a
    -- Venerable with a Yellow Apricot's aperture.
    SELECT standing_capacity(p_player_id, 'gu')::SMALLINT;
$fn$;


DO $patch$
DECLARE
    one TEXT;
    src TEXT;
BEGIN
    FOREACH one IN ARRAY ARRAY['player_max_qi', 'player_qi_aperture']::TEXT[] LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one));

        IF strpos(src, 'r.qi_capacity') = 0 THEN
            RAISE EXCEPTION '% does not read qi_capacity off realms', one;
        END IF;

        -- Matched as a PATTERN rather than as literal text: the two functions
        -- indent the same subquery differently, and an exact-text match
        -- silently did nothing to the second one. The subquery holds no
        -- parentheses of its own, so [^)]* reaches exactly its closing one.
        src := regexp_replace(
            src,
            '\(SELECT r\.qi_capacity[^)]*\)',
            'standing_capacity(p_player_id, ''qi'')',
            'g');

        IF strpos(src, 'r.qi_capacity') > 0 THEN
            RAISE EXCEPTION
                '% still reads qi_capacity off realms after the patch', one;
        END IF;
        IF strpos(src, 'standing_capacity') = 0 THEN
            RAISE EXCEPTION '% lost the read entirely', one;
        END IF;

        EXECUTE src;
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The ladder continues, and nobody alive moves
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
    one   RECORD;
BEGIN
    -- The Venerable ladder continues the realm one on all three, and climbs.
    IF (SELECT min(gu_capacity) FROM venerable_ranks) <> 60
       OR (SELECT max(gu_capacity) FROM venerable_ranks) <> 84 THEN
        RAISE EXCEPTION
            'the aperture ladder does not run 60 to 84: % to %',
            (SELECT min(gu_capacity) FROM venerable_ranks),
            (SELECT max(gu_capacity) FROM venerable_ranks);
    END IF;

    SELECT string_agg('V' || a.venerable_tier, ', ') INTO v_bad
    FROM venerable_ranks a JOIN venerable_ranks b ON b.rank = a.rank + 1
    WHERE b.gu_capacity <= a.gu_capacity
       OR b.qi_capacity <= a.qi_capacity
       OR b.essence_capacity <= a.essence_capacity;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a capacity stopped climbing at: %', v_bad;
    END IF;

    -- And V1 is strictly above rank 18 on all three, or ascending would cost
    -- something.
    IF (SELECT gu_capacity FROM venerable_ranks WHERE venerable_tier = 1)
       <= (SELECT gu_capacity FROM realms WHERE rank = 18 AND stage = 'peak') THEN
        RAISE EXCEPTION 'V1 does not carry more aperture than rank 18';
    END IF;

    -- NOBODY ALIVE MOVES. Nobody is stamped, so every reader must return
    -- exactly the realm value it returned before.
    FOR one IN
        SELECT p.player_id, p.discord_name,
               gu_capacity_of(p.player_id) AS now_gu,
               (SELECT r.gu_capacity FROM player_cultivation pc
                JOIN realms r ON r.realm_id = pc.realm_id
                WHERE pc.player_id = p.player_id) AS realm_gu,
               player_max_qi(p.player_id) AS now_qi
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        WHERE p.deleted_at IS NULL
    LOOP
        IF one.now_gu IS DISTINCT FROM one.realm_gu THEN
            v_bad := COALESCE(v_bad, '') || one.discord_name || ' aperture '
                     || one.realm_gu || '->' || one.now_gu || ' ';
        END IF;
        IF one.now_qi IS NULL OR one.now_qi < 1 THEN
            v_bad := COALESCE(v_bad, '') || one.discord_name || ' lost their qi ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a capacity moved for somebody who has not ascended: %', v_bad;
    END IF;

    -- And nobody is suddenly over their aperture, which would unequip worms.
    SELECT count(*) INTO v_n
    FROM players p WHERE p.deleted_at IS NULL
      AND gu_used_by(p.player_id) > gu_capacity_of(p.player_id);
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators are now over their own aperture', v_n;
    END IF;

    RAISE NOTICE
        'the Venerable ladder carries % to % aperture; nobody alive moved',
        (SELECT min(gu_capacity) FROM venerable_ranks),
        (SELECT max(gu_capacity) FROM venerable_ranks);
END;
$probe$;
