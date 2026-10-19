-- 0504_four_ceilings_between_the_game_and_rank_nineteen
--
-- Phase 5 of the Venerable spec is the Heavenly Court: "a min_rank 19 region
-- with veins, growth and creatures that carry real tables. Delve and travel
-- pick it up for free." Before any of that can be seeded, four constraints
-- say it cannot exist. Found by trying, not by reading:
--
--     regions_min_rank_check     min_rank BETWEEN 1 AND 18
--     materials_tier_check       tier BETWEEN 1 AND 12
--     ores_tier_check            tier BETWEEN 1 AND 8
--     mining_tier_cap            LEAST(8, ...)
--
-- All four were written when 18 was the top of the world, which it stops
-- being the moment the Venerable ladder opens. Each is widened by exactly
-- what the new realm needs and no further:
--
--     min_rank  -> 27    the top Venerable rung, from venerable_ranks
--     tier      -> 13    one band above the current 12, for the Court's growth
--     ore tier  -> 9     one band above the current 8, for its veins
--
-- AND THE TRAVEL GATE CANNOT SEE A VENERABLE. `begin_travel` reads a
-- cultivator's standing like this:
--
--     SELECT rr.rank FROM player_cultivation pc JOIN realms rr ...
--
-- `realms` stops at 18, so a Venerable reads 18 and a min_rank 19 region is
-- shut to the only people it is for. That is not a thing to discover later
-- with the content already seeded, so standing becomes one definition:
--
--     player_standing = GREATEST(realm rank, Venerable rank)
--
-- `venerable_ranks.rank` is already the game-wide rank - 19 to 27 - so this
-- is a GREATEST and nothing more. Every cultivator alive reads exactly what
-- they read before, because none of them is stamped; the Court opens by
-- itself the day somebody ascends, with no further migration.
--
-- NOTHING IS SEEDED HERE. This is the room the content goes in. The region,
-- its growth, its veins and its creatures are 0505, so that if the content
-- wants reworking the foundations do not move with it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The three constraints
-- ---------------------------------------------------------------------------

ALTER TABLE regions DROP CONSTRAINT regions_min_rank_check;
ALTER TABLE regions ADD CONSTRAINT regions_min_rank_check
    CHECK (min_rank >= 1 AND min_rank <= 27);

ALTER TABLE materials DROP CONSTRAINT materials_tier_check;
ALTER TABLE materials ADD CONSTRAINT materials_tier_check
    CHECK (tier IS NULL OR (tier >= 1 AND tier <= 13));

ALTER TABLE ores DROP CONSTRAINT ores_tier_check;
ALTER TABLE ores ADD CONSTRAINT ores_tier_check
    CHECK (tier >= 1 AND tier <= 9);


-- A miner can reach the new band, by the same ladder as every band before it.
--
-- Raising LEAST(8) to LEAST(9) is NOT enough on its own, which the probe
-- below caught: `mining_tier_cap` is `base_tier + ladder_steps('mining_tier',
-- level)` and the ladder has seven rungs, so 1 + 7 = 8 whatever the LEAST
-- says. The band needs an eighth rung as well. Its gaps run 4, 5, 13, 18, 22,
-- 26 from levels 4 to 92, so 122 continues the curve - and the deepest miner
-- alive is level 3,402, so it is reachable rather than decorative.
INSERT INTO profession_steps (ladder, step, level_required)
VALUES ('mining_tier', 8, 122)
ON CONFLICT DO NOTHING;

DO $patch$
DECLARE
    src TEXT;
BEGIN
    src := pg_get_functiondef('mining_tier_cap(smallint)'::regprocedure);
    IF (length(src) - length(replace(src, 'LEAST(8,', ''))) / length('LEAST(8,') <> 1 THEN
        RAISE EXCEPTION 'the mining ceiling in mining_tier_cap is not there exactly once';
    END IF;
    EXECUTE replace(src, 'LEAST(8,', 'LEAST(9,');
END;
$patch$;

-- And the delve's floor, which carried the same 8 for the same reason.
DO $patch$
DECLARE
    src TEXT;
BEGIN
    src := pg_get_functiondef('delve_tier_floor(bigint)'::regprocedure);
    IF (length(src) - length(replace(src, 'LEAST(8,', ''))) / length('LEAST(8,') <> 1 THEN
        RAISE EXCEPTION 'the delve floor ceiling is not there exactly once';
    END IF;
    EXECUTE replace(src, 'LEAST(8,', 'LEAST(9,');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- One definition of how high a cultivator stands
-- ---------------------------------------------------------------------------

CREATE FUNCTION player_standing(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- A Venerable rank IS a game-wide rank - venerable_ranks.rank runs 19 to
    -- 27 above the eighteen realms - so standing is whichever is higher. Ask
    -- this rather than joining `realms` wherever a gate needs to know how far
    -- somebody has got, or the gate stops at 18 and the realm above it is
    -- invisible.
    SELECT GREATEST(
        COALESCE(player_realm_rank(p_player_id), 1),
        COALESCE(venerable_rank_of(p_player_id), 0)
    )::SMALLINT;
$fn$;

COMMENT ON FUNCTION player_standing(BIGINT) IS
    'How far up the whole ladder a cultivator stands: their realm rank, or their Venerable rank once they hold one. The thing a rank gate should read.';


DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef(
        (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'begin_travel'));

    anchor := '            SELECT rr.rank INTO standing';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the standing read in begin_travel is not there exactly once';
    END IF;

    -- Replace the join with the one definition. The two lines that joined
    -- `realms` go with it; they are matched exactly so a reformat would be
    -- caught rather than silently half-applied.
    DECLARE
        old_block TEXT :=
            '            SELECT rr.rank INTO standing' || chr(10) ||
            '            FROM player_cultivation pc' || chr(10) ||
            '            JOIN realms rr ON rr.realm_id = pc.realm_id' || chr(10) ||
            '            WHERE pc.player_id = p_player_id;';
    BEGIN
        IF strpos(src, old_block) = 0 THEN
            RAISE EXCEPTION
                'begin_travel does not read standing the way 0016 wrote it';
        END IF;

        src := replace(src, old_block,
            '            -- One definition, so a gate above rank 18 is not' || chr(10) ||
            '            -- invisible to the only people who can pass it.' || chr(10) ||
            '            -- Was a join on `realms`, which stops at 18.' || chr(10) ||
            '            standing := player_standing(p_player_id);');
    END;

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Room for rank 19, and nobody moved
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_top  SMALLINT;
    v_bad  TEXT;
    r      RECORD;
BEGIN
    -- The room matches the ladder rather than a number I liked.
    SELECT max(rank) INTO v_top FROM venerable_ranks;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'regions_min_rank_check'
          AND pg_get_constraintdef(oid) LIKE '%' || v_top || '%'
    ) THEN
        RAISE EXCEPTION
            'the region gate does not reach the top Venerable rung (%)', v_top;
    END IF;

    -- A rank 19 region can be created at all now. Rolled back - 0505 seeds
    -- the real one.
    BEGIN
        INSERT INTO regions (code, name, danger_level, description, emoji, sort_order, min_rank)
        VALUES ('probe_court', 'Probe', 7, 'probe', '.', 99, 19);
        IF NOT EXISTS (SELECT 1 FROM regions WHERE code = 'probe_court') THEN
            RAISE EXCEPTION 'a rank 19 region did not take';
        END IF;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Both ladders widened by one band, and the readers agree with the
    -- constraints rather than being one behind them.
    IF mining_tier_cap(32767::SMALLINT) < 9 THEN
        RAISE EXCEPTION 'a miner still cannot reach the new band: %',
            mining_tier_cap(32767::SMALLINT);
    END IF;
    IF pg_get_functiondef('delve_tier_floor(bigint)'::regprocedure) LIKE '%LEAST(8,%' THEN
        RAISE EXCEPTION 'the delve floor still stops at 8';
    END IF;

    -- STANDING: every living cultivator reads exactly what they read before,
    -- because none of them is stamped. A gate that moved today would be a
    -- gate that let somebody somewhere they could not go yesterday.
    FOR r IN
        SELECT p.player_id, p.discord_name,
               COALESCE(player_realm_rank(p.player_id), 1) AS was,
               player_standing(p.player_id) AS now_at
        FROM players p WHERE p.deleted_at IS NULL
    LOOP
        IF r.now_at <> r.was THEN
            v_bad := COALESCE(v_bad, '') || r.discord_name || ' ' || r.was
                     || '->' || r.now_at || ' ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'standing moved for somebody today: %', v_bad;
    END IF;

    -- And the gate reads it.
    IF pg_get_functiondef(
        (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'begin_travel'))
       NOT LIKE '%player_standing(p_player_id)%' THEN
        RAISE EXCEPTION 'begin_travel still joins realms for standing';
    END IF;

    -- Nothing already in the tables breaks the widened constraints.
    SELECT count(*) INTO v_n FROM materials WHERE tier IS NOT NULL AND tier > 13;
    IF v_n > 0 THEN RAISE EXCEPTION '% materials are over the new tier band', v_n; END IF;

    RAISE NOTICE
        'room for min_rank up to %, material tier 13, ore tier 9; no standing moved',
        v_top;
END;
$probe$;
