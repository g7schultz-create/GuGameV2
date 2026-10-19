-- 0375_a_revelation_is_allowed_its_third_path
--
-- 0373 let a Dao Revelation stand on three Paths. 0360 wrote the table it has
-- to fit in, and that table says two:
--
--     CHECK (array_length(paths, 1) >= 1 AND array_length(paths, 1) <= 2)
--     CHECK (dual = (array_length(paths, 1) = 2))
--
-- So a Dao Revelation drawing its third Path fails BOTH of them and the whole
-- command dies with a constraint violation. It is one forge in a hundred, on
-- the single best outcome the feature has - the rarest good thing in the
-- system was the one guaranteed to crash.
--
-- Nothing caught it until a three thousand forge sweep, and that is the point
-- worth keeping: 0373's probe forged ONCE, and 0374's forced each tier onto an
-- already-open forge with an UPDATE, which skips `forge_begin` and therefore
-- skips the INSERT that was failing. Both probes were reasonable and neither
-- could have seen this. Only opening thousands of real forges did.
--
-- `dual` becomes what it always meant - more than one Path - rather than
-- exactly two, and the ceiling goes to three. The column keeps its name: it is
-- read by the technique's own description and by 0370's destiny gifts, and
-- renaming it to buy a more accurate word is not worth the blast radius.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE technique_forges DROP CONSTRAINT technique_forges_paths_check;
ALTER TABLE technique_forges ADD CONSTRAINT technique_forges_paths_check
    CHECK (array_length(paths, 1) >= 1 AND array_length(paths, 1) <= 3);

ALTER TABLE technique_forges DROP CONSTRAINT technique_forges_check;
ALTER TABLE technique_forges ADD CONSTRAINT technique_forges_check
    CHECK (dual = (array_length(paths, 1) > 1));

COMMENT ON COLUMN technique_forges.dual IS
    'Whether the technique stands on more than one Path. Named `dual` from 0360 when two was the most it could be; a Dao Revelation reaches three.';


-- The description still announced 'two Paths' for anything that was not one.
DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        || CASE WHEN f.dual', chr(10),
'                THEN ''It stands on two Paths at once.''', chr(10),
'                ELSE ''It stands on one Path, and stands well.'' END)');

    swap := concat(
'        || CASE WHEN array_length(f.paths, 1) > 2', chr(10),
'                THEN ''It stands on three Paths at once, which should not be ''', chr(10),
'                     || ''possible.''', chr(10),
'                WHEN f.dual', chr(10),
'                THEN ''It stands on two Paths at once.''', chr(10),
'                ELSE ''It stands on one Path, and stands well.'' END)');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'forge_take';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer describes its Paths where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every tier can actually be opened, thousands of times
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    fid    BIGINT;
    tries  INTEGER := 4000;
    tally  TEXT;
    worst  TEXT;
    seen   INTEGER;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= game_config_value('technique_forge_min_rank')
    ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to forge with';
        RETURN;
    END IF;

    BEGIN
        CREATE TEMP TABLE probe_forges (quality TEXT, paths INTEGER) ON COMMIT DROP;

        -- Opened for real, through `forge_begin`, thousands of times. This is
        -- the only thing that would have caught the constraint, so it is the
        -- thing the probe does.
        FOR i IN 1..tries LOOP
            DELETE FROM technique_forges
            WHERE player_id = who AND finished_at IS NULL;
            DELETE FROM player_cooldowns
            WHERE player_id = who AND action = 'forge_technique';

            fid := forge_begin(who, NULL);
            INSERT INTO probe_forges
            SELECT quality, array_length(paths, 1)
            FROM technique_forges WHERE forge_id = fid;
        END LOOP;

        -- Every tier must have been reachable, or one of them is unreachable
        -- fiction.
        SELECT string_agg(e.code, ', ') INTO worst
        FROM enlighten_qualities e
        WHERE e.weight > 0
          AND NOT EXISTS (SELECT 1 FROM probe_forges pf WHERE pf.quality = e.code);
        IF worst IS NOT NULL THEN
            RAISE EXCEPTION
                'these tiers never came up in % forges: %', tries, worst;
        END IF;

        -- And no tier produced a path count outside what it promises.
        SELECT string_agg(pf.quality || ' gave ' || pf.paths, ', ') INTO worst
        FROM (SELECT DISTINCT quality, paths FROM probe_forges) pf
        JOIN enlighten_qualities e ON e.code = pf.quality
        WHERE pf.paths < e.min_paths OR pf.paths > e.max_paths;
        IF worst IS NOT NULL THEN
            RAISE EXCEPTION 'these broke their own Path range: %', worst;
        END IF;

        SELECT count(*) INTO seen FROM probe_forges WHERE paths = 3;
        SELECT string_agg(e.name || ' ' || t.c || ' (' ||
                          round(100.0 * t.c / tries, 2) || ' percent)',
                          ', ' ORDER BY e.sort_order)
        INTO tally
        FROM (SELECT quality, count(*) c FROM probe_forges GROUP BY quality) t
        JOIN enlighten_qualities e ON e.code = t.quality;

        RAISE NOTICE 'over % forges: %', tries, tally;
        RAISE NOTICE '% of them stood on three Paths', seen;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'four thousand forges opened and rolled back';
END;
$probe$;
