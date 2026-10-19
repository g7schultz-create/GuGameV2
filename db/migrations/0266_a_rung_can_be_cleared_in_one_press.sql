-- 0266_a_rung_can_be_cleared_in_one_press
--
-- /fuse spends one stack per press. miyuki is holding 170 stacks worth 202
-- fusions and clearwest 77 worth 78, so clearing a shelf is two hundred
-- presses of the same button on the same screen. The strictness of a fusion
-- is the interesting part; pressing it is not.
--
-- So a rung can be cleared in one press. `fuse_all` walks the qualifying
-- stacks of ONE tier and fuses each of them until that tier has nothing left
-- that qualifies - a stack of nine is three fusions, not one.
--
-- It stays on the tier it was given, deliberately. Fusing every tier in one
-- press would cascade: the tier 3 pages it just made would become tier 4, and
-- a cultivator refining a manual needs pages of a particular Path and tier.
-- Clearing a rung you asked for is a convenience; quietly eating the pages
-- above it is somebody's build.
--
-- The loop terminates on its own - every pass consumes three pages and makes
-- one, so the shelf strictly shrinks - but it carries a guard anyway, because
-- a loop that cannot run away is a loop nobody checked.
--
-- Writing the probe found a second thing. `page_fusion_shelf` counted its
-- fusions as
--
--     (count(*)::numeric / page_fusion_count)::integer
--
-- and a cast from numeric to integer ROUNDS. A stack of eight pages therefore
-- advertised three fusions where two are possible, and the screen said so to
-- the player's face. 26 stacks on this server are overstated; the shelf claims
-- 295 fusions against 269 that exist. It floors now, which is also what makes
-- the assertion below - the shelf offered N, N happened - worth asserting.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What the shelf claims it can do
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW page_fusion_shelf AS
SELECT mp.owner_id AS player_id,
       mp.tier,
       mp.path_code,
       mp.page_type,
       p.name AS path_name,
       pt.name AS type_name,
       count(*)::integer AS held,
       -- Floor, not round. Eight pages are two fusions and a spare.
       floor(count(*)::numeric
             / game_config_value('page_fusion_count'))::integer AS fusions,
       round(avg(mp.quality))::smallint AS avg_quality
FROM manual_pages mp
JOIN paths p ON p.code = mp.path_code
JOIN page_types pt ON pt.code = mp.page_type
WHERE mp.consumed_at IS NULL
  AND EXISTS (SELECT 1 FROM page_tiers t WHERE t.tier = mp.tier + 1)
GROUP BY mp.owner_id, mp.tier, mp.path_code, mp.page_type, p.name, pt.name
HAVING count(*)::numeric >= game_config_value('page_fusion_count');


DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM page_fusion_shelf s
               WHERE s.fusions <> floor(s.held / 3.0)::integer) THEN
        RAISE EXCEPTION 'the shelf still overstates what it can fuse';
    END IF;

    IF EXISTS (SELECT 1 FROM page_fusion_shelf s WHERE s.fusions < 1) THEN
        RAISE EXCEPTION 'the shelf is offering a stack it cannot fuse';
    END IF;
END;
$$;


CREATE FUNCTION fuse_all(p_player_id BIGINT, p_tier SMALLINT)
RETURNS TABLE (
    fusions      INTEGER,
    spent        INTEGER,
    made_tier    SMALLINT,
    best_quality SMALLINT,
    traits       INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    want  INTEGER := game_config_value('page_fusion_count')::integer;
    stack RECORD;
    born  RECORD;
    ids   BIGINT[];
    done  INTEGER := 0;
    best  SMALLINT := 0;
    marks INTEGER := 0;
BEGIN
    IF p_tier IS NULL THEN
        RAISE EXCEPTION 'name the tier to clear'
            USING ERRCODE = 'check_violation';
    END IF;

    LOOP
        SELECT s.tier, s.path_code, s.page_type INTO stack
        FROM page_fusion_shelf s
        WHERE s.player_id = p_player_id AND s.tier = p_tier
        ORDER BY s.avg_quality DESC, s.path_code, s.page_type
        LIMIT 1;

        EXIT WHEN NOT FOUND;

        -- The same three the single-stack button would have spent: the best
        -- of that stack, because quality is carried through a fusion.
        SELECT array_agg(t.page_id) INTO ids
        FROM (SELECT mp.page_id FROM manual_pages mp
              WHERE mp.owner_id = p_player_id AND mp.consumed_at IS NULL
                AND mp.tier = stack.tier AND mp.path_code = stack.path_code
                AND mp.page_type = stack.page_type
              ORDER BY mp.quality DESC, mp.power DESC
              LIMIT want) t;

        -- The shelf said this stack qualified; if it no longer does, the
        -- shelf and the pages disagree and looping again would spin.
        IF ids IS NULL OR array_length(ids, 1) <> want THEN
            RAISE EXCEPTION 'the shelf offered a stack that is not there';
        END IF;

        SELECT * INTO born FROM fuse_pages(p_player_id, ids);

        done := done + 1;
        best := GREATEST(best, born.quality);
        IF born.trait IS NOT NULL THEN
            marks := marks + 1;
        END IF;

        IF done > 5000 THEN
            RAISE EXCEPTION 'fusing tier % did not converge', p_tier;
        END IF;
    END LOOP;

    IF done = 0 THEN
        RAISE EXCEPTION 'nothing on tier % has % pages of one Path and one kind',
            p_tier, want
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN QUERY SELECT done, done * want, (p_tier + 1)::smallint, best, marks;
END;
$$;

COMMENT ON FUNCTION fuse_all(BIGINT, SMALLINT) IS
    'Clears one rung of the fusion shelf: every qualifying stack of that tier, fused until none of them qualifies. Stays on its own tier - the pages it makes are left alone, because they are somebody''s next manual.';


-- ---------------------------------------------------------------------------
-- One press does what the presses did
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    rung   SMALLINT;
    before INTEGER;
    after  INTEGER;
    loose  INTEGER;
    left_o INTEGER;
    got    RECORD;
BEGIN
    SELECT s.player_id, s.tier INTO who, rung
    FROM page_fusion_shelf s
    GROUP BY s.player_id, s.tier
    ORDER BY sum(s.fusions) DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no shelf to clear; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT COALESCE(sum(s.fusions), 0) INTO before
        FROM page_fusion_shelf s WHERE s.player_id = who AND s.tier = rung;

        SELECT count(*) INTO loose FROM manual_pages mp
        WHERE mp.owner_id = who AND mp.consumed_at IS NULL;

        SELECT * INTO got FROM fuse_all(who, rung);

        IF got.fusions <> before THEN
            RAISE EXCEPTION 'the shelf offered % fusions and % happened',
                before, got.fusions;
        END IF;

        -- That rung is now clear.
        SELECT COALESCE(sum(s.fusions), 0) INTO after
        FROM page_fusion_shelf s WHERE s.player_id = who AND s.tier = rung;

        IF after <> 0 THEN
            RAISE EXCEPTION 'tier % still offers % fusions', rung, after;
        END IF;

        -- Three in, one out, every time - so the shelf shrank by exactly two
        -- pages per fusion and nothing was conjured or lost.
        SELECT count(*) INTO left_o FROM manual_pages mp
        WHERE mp.owner_id = who AND mp.consumed_at IS NULL;

        IF left_o <> loose - got.fusions * 2 THEN
            RAISE EXCEPTION 'held % pages, fused % times, now hold %',
                loose, got.fusions, left_o;
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


-- ---------------------------------------------------------------------------
-- And it does not reach a rung it was not asked for
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    rung  SMALLINT;
    above INTEGER;
    now_a INTEGER;
BEGIN
    -- Somebody with pages on two rungs at once, or there is nothing to prove.
    SELECT s.player_id, min(s.tier) INTO who, rung
    FROM page_fusion_shelf s
    GROUP BY s.player_id
    HAVING count(DISTINCT s.tier) > 1
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody holds two rungs; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT count(*) INTO above FROM manual_pages mp
        WHERE mp.owner_id = who AND mp.consumed_at IS NULL AND mp.tier > rung + 1;

        PERFORM * FROM fuse_all(who, rung);

        SELECT count(*) INTO now_a FROM manual_pages mp
        WHERE mp.owner_id = who AND mp.consumed_at IS NULL AND mp.tier > rung + 1;

        IF now_a <> above THEN
            RAISE EXCEPTION
                'clearing tier % changed the pages above it: % became %',
                rung, above, now_a;
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
