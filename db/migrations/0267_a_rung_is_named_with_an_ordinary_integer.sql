-- 0267_a_rung_is_named_with_an_ordinary_integer
--
-- 0266 declared `fuse_all(BIGINT, SMALLINT)`. Postgres will not implicitly
-- narrow an integer to a smallint when it resolves a function, and psycopg
-- sends a Python int as `integer` - so every call from the bot would have come
-- back as
--
--     function fuse_all(integer, integer) does not exist
--
-- which is to say the button could not have worked once. The tests caught it
-- before the button shipped; the migration's own probes did not, because
-- plpgsql was resolving a smallint literal against a smallint parameter.
--
-- The tier is an ordinary integer now, the way `horde_gauntlet_worth(INTEGER)`
-- and every other small-number parameter in this schema already is. A
-- parameter type cannot be changed in place, so this drops and recreates; the
-- body is 0266's, unchanged.
--
-- Forward-only. Do not edit once applied.


DROP FUNCTION fuse_all(BIGINT, SMALLINT);

CREATE FUNCTION fuse_all(p_player_id BIGINT, p_tier INTEGER)
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

COMMENT ON FUNCTION fuse_all(BIGINT, INTEGER) IS
    'Clears one rung of the fusion shelf: every qualifying stack of that tier, fused until none of them qualifies. Stays on its own tier - the pages it makes are left alone, because they are somebody''s next manual.';


-- ---------------------------------------------------------------------------
-- Callable the way the bot actually calls it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who  BIGINT;
    rung INTEGER;
BEGIN
    SELECT s.player_id, s.tier INTO who, rung
    FROM page_fusion_shelf s ORDER BY s.tier LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no shelf to clear; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- An integer, not a smallint literal. This is the resolution that
        -- failed, and asserting it in plpgsql only works with an INTEGER
        -- variable rather than an inline constant.
        PERFORM * FROM fuse_all(who, rung);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM = 'probe-ok' THEN
                NULL;
            ELSIF SQLERRM LIKE '%does not exist%' THEN
                RAISE EXCEPTION 'fuse_all still cannot be called with an integer';
            ELSE
                RAISE;
            END IF;
    END;
END;
$$;
