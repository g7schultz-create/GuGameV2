-- 0466_the_deep_places_and_what_they_keep
--
-- A delve. One cultivator, a dark map under the region they are standing in,
-- and a fixed number of actions to spend on it. What you step on is what you
-- get: a seam to break, a grove to pick over, a trace to follow, a hoard
-- somebody left, or something that lives down there.
--
-- WHY IT EXISTS: ORE. Twenty-one of the thirty-four cultivators in this game
-- are held to tier 1 stone and will be until their mining comes up, because
-- `mine` caps every strike at `mining_tier_cap(skill)`. Every region has veins
-- down to tier 8 and almost nobody can touch them.
--
-- SO DEPTH LIFTS THE CAP. The further up the map you push, the deeper the
-- stone you can work:
--
--     the entrance    tier 1        halfway     tier 4
--     the far wall    tier 6
--
-- and a cultivator whose own mining already reaches further keeps that - the
-- lift is a floor, not a ceiling, so nobody is made worse at their own trade
-- by going underground.
--
-- IT DOES NOT RE-IMPLEMENT MINING. A seam calls `mine`, a grove calls
-- `gather`, a trace calls `explore` - the same three verbs the surface uses,
-- so a Gu that finds more in a forage finds more down here, professions still
-- earn, fortune still leans the draw, and there is one definition of what a
-- seam gives rather than two. What a delve adds is the cap and the number of
-- pulls, which is what "at better rates" means when you say it precisely.
--
-- ACTIONS, NOT TIME. Sixteen of them against a map of thirty tiles, so a delve
-- is a route and not a sweep. Running out is not a failure - you climb out with
-- what you are carrying - which is what makes the choice between one more seam
-- and the hoard two tiles over an actual choice.
--
-- DARK, like a Trial map and for the same reason, except that here it is also
-- simply true: you cannot see through rock.
--
-- THE BEASTS ARE THE NEXT MIGRATION. This one lays the ground, the actions and
-- the three working tiles. `delve_tile_kinds` carries the beasts already so
-- the map generates around them rather than being rebuilt to admit them.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('delve_width', 5,
     'How wide a delve is. Five, because that is what fits on a phone without the grid wrapping.'),
    ('delve_height', 6,
     'How deep a delve goes. The cultivator enters on the bottom row and the richest stone is against the far wall.'),
    ('delve_actions', 16,
     'Actions in one delve, against a map of thirty tiles. Deliberately short of a sweep: a delve is a route.'),
    ('delve_cooldown_minutes', 1320,
     'How long before a cultivator may go down again. The same day-and-a-bit as sitting at the forge.'),
    ('delve_tier_per_depth', 1,
     'How many tiers of stone each row deeper opens. One: the entrance works tier 1 and the far wall works tier 6, which is five rows of climbing for five tiers.'),
    ('delve_seam_pulls', 2,
     'How many strikes one seam is worth. The rate half of "at better rates" - the other half is the tier.'),
    ('delve_grove_pulls', 2,
     'How many armfuls one grove is worth.'),
    ('delve_seams', 5, 'Seams scattered through a delve.'),
    ('delve_groves', 4, 'Groves scattered through a delve.'),
    ('delve_traces', 3, 'Traces scattered through a delve.'),
    ('delve_hoards', 2, 'Hoards scattered through a delve.'),
    ('delve_beasts', 3, 'Beasts scattered through a delve.'),
    ('delve_deeps', 1, 'How many of the things that live at the bottom. One, and it is never on the way in.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What is down there
-- ---------------------------------------------------------------------------

CREATE TABLE delve_tile_kinds (
    kind    TEXT PRIMARY KEY,
    emoji   TEXT NOT NULL,
    label   TEXT NOT NULL,
    is_work BOOLEAN NOT NULL DEFAULT FALSE,
    is_beast BOOLEAN NOT NULL DEFAULT FALSE,
    scale   NUMERIC(5,2),
    blurb   TEXT NOT NULL
);

COMMENT ON TABLE delve_tile_kinds IS
    'What a tile in a delve can be. `scale` is what that tile''s creature carries and is null for anything that is not a fight.';

INSERT INTO delve_tile_kinds (kind, emoji, label, is_work, is_beast, scale, blurb) VALUES
    ('way',   '🟦', 'bare rock',  FALSE, FALSE, NULL,
     'Nothing in it. It still costs you an action.'),
    ('seam',  '⛏',  'a seam',     TRUE,  FALSE, NULL,
     'Ore, and the deeper you have come the better it is.'),
    ('grove', '🌿', 'a growth',   TRUE,  FALSE, NULL,
     'Something is growing down here that should not be.'),
    ('trace', '🔍', 'a trace',    TRUE,  FALSE, NULL,
     'Signs that somebody came this way before you.'),
    ('hoard', '💰', 'a hoard',    TRUE,  FALSE, NULL,
     'Whoever put this here did not come back for it.'),
    ('beast', '🐗', 'a beast',    FALSE, TRUE,  1.00,
     'Something that lives here, and has noticed you.'),
    ('deep',  '👹', 'the deep thing', FALSE, TRUE, 2.50,
     'It was here before the stone was. Nobody is making you.');


CREATE TABLE delve_runs (
    delve_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id    BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    region_code  TEXT NOT NULL REFERENCES regions(code) ON DELETE RESTRICT,
    width        SMALLINT NOT NULL,
    height       SMALLINT NOT NULL,
    at_x         SMALLINT NOT NULL,
    at_y         SMALLINT NOT NULL,
    actions_left SMALLINT NOT NULL,
    deepest      SMALLINT NOT NULL DEFAULT 0,
    status       TEXT NOT NULL DEFAULT 'walking',
    outcome      TEXT,
    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at     TIMESTAMPTZ,
    CHECK (status IN ('walking', 'fighting', 'done')),
    CHECK (outcome IS NULL OR outcome IN ('climbed_out', 'spent', 'died')),
    CHECK ((status = 'done') = (ended_at IS NOT NULL)),
    CHECK ((status = 'done') = (outcome IS NOT NULL)),
    CHECK (actions_left >= 0)
);

CREATE INDEX delve_runs_player_idx ON delve_runs (player_id);
CREATE INDEX delve_runs_region_idx ON delve_runs (region_code);
CREATE UNIQUE INDEX delve_runs_one_open_each
    ON delve_runs (player_id) WHERE status <> 'done';

COMMENT ON TABLE delve_runs IS
    'One cultivator underneath one region. `deepest` is the furthest row reached and is what the stone is worked against, so climbing back down does not take your depth away.';


CREATE TABLE delve_tiles (
    delve_id BIGINT NOT NULL REFERENCES delve_runs(delve_id) ON DELETE CASCADE,
    x        SMALLINT NOT NULL,
    y        SMALLINT NOT NULL,
    kind     TEXT NOT NULL REFERENCES delve_tile_kinds(kind) ON DELETE RESTRICT,
    spent    BOOLEAN NOT NULL DEFAULT FALSE,
    seen     BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (delve_id, x, y)
);

CREATE INDEX delve_tiles_kind_idx ON delve_tiles (kind);


-- ---------------------------------------------------------------------------
-- How deep a cultivator is standing, and what that lets them work
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_of(p_player_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    SELECT d.delve_id FROM delve_runs d
    WHERE d.player_id = p_player_id AND d.status <> 'done'
    LIMIT 1;
$fn$;


CREATE OR REPLACE FUNCTION delve_tier_floor(p_player_id bigint)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- A floor, never a ceiling. Somebody whose own mining already reaches
    -- deeper keeps it: going underground must not make a cultivator worse at
    -- their own trade.
    SELECT COALESCE((
        SELECT LEAST(8, 1 + d.deepest
                         * game_config_value('delve_tier_per_depth'))::smallint
        FROM delve_runs d
        WHERE d.player_id = p_player_id AND d.status <> 'done'
    ), 0)::smallint;
$fn$;

COMMENT ON FUNCTION delve_tier_floor(bigint) IS
    'The tier of stone a cultivator may work because of how far into a delve they have pushed, regardless of their mining. Zero when they are not down one at all, which is what keeps `mine` behaving exactly as it did on the surface.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'mine' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'mine is missing';
    END IF;

    anchor := concat(
'    skill := profession_level(p_player_id, ''mining'');', chr(10),
'    cap   := mining_tier_cap(skill);');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'mine no longer caps its strike where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    skill := profession_level(p_player_id, ''mining'');', chr(10),
'    -- 0466: and whatever a delve has opened under them, which is a floor', chr(10),
'    -- rather than a ceiling - a better miner keeps being a better miner.', chr(10),
'    cap   := GREATEST(mining_tier_cap(skill),', chr(10),
'                      delve_tier_floor(p_player_id));'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Going down
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_open(p_player_id bigint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    here  TEXT;
    v_w   SMALLINT;
    v_h   SMALLINT;
    v_sx  SMALLINT;
    v_id  BIGINT;
    ready RECORD;
    r     RECORD;
BEGIN
    IF delve_of(p_player_id) IS NOT NULL THEN
        RAISE EXCEPTION 'you are already down there'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT region_code INTO here FROM player_location
    WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'you are nowhere in particular'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO ready FROM claim_cooldown(
        p_player_id, 'delve',
        game_config_value('delve_cooldown_minutes'));
    IF NOT ready.claimed THEN
        RAISE EXCEPTION 'the ground has not settled since you were last down'
            USING ERRCODE = 'check_violation';
    END IF;

    v_w := GREATEST(3, game_config_value('delve_width')::int);
    v_h := GREATEST(3, game_config_value('delve_height')::int);
    v_sx := (v_w / 2)::smallint;

    INSERT INTO delve_runs
        (player_id, region_code, width, height, at_x, at_y, actions_left)
    VALUES (p_player_id, here, v_w, v_h, v_sx, (v_h - 1)::smallint,
            GREATEST(1, game_config_value('delve_actions')::int))
    RETURNING delve_runs.delve_id INTO v_id;

    INSERT INTO delve_tiles (delve_id, x, y, kind)
    SELECT v_id, gx::smallint, gy::smallint, 'way'
    FROM generate_series(0, v_w - 1) gx, generate_series(0, v_h - 1) gy;

    FOR r IN
        SELECT k.kind, g.i
        FROM delve_tile_kinds k
        CROSS JOIN LATERAL generate_series(1, GREATEST(0,
            game_config_value('delve_' ||
                CASE k.kind WHEN 'deep' THEN 'deeps' ELSE k.kind || 's' END
            )::int)) g (i)
        WHERE k.kind <> 'way'
    LOOP
        UPDATE delve_tiles t SET kind = r.kind
        WHERE (t.delve_id, t.x, t.y) = (
            SELECT u.delve_id, u.x, u.y FROM delve_tiles u
            WHERE u.delve_id = v_id AND u.kind = 'way'
              AND NOT (u.x = v_sx AND u.y = v_h - 1)
              -- The deep thing is never on the way in. You go to it.
              AND (r.kind <> 'deep' OR u.y <= 1)
            ORDER BY random() LIMIT 1);
    END LOOP;

    UPDATE delve_tiles t SET seen = TRUE
    WHERE t.delve_id = v_id AND t.x = v_sx AND t.y = v_h - 1;

    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION delve_open(bigint) IS
    'Opens a delve under wherever the cultivator is standing. The region decides the veins and the growth, so where you went in is what you are digging through.';


CREATE OR REPLACE FUNCTION delve_render(p_delve_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT string_agg(row_text, chr(10) ORDER BY y)
    FROM (
        SELECT t.y,
               string_agg(
                   CASE WHEN t.x = d.at_x AND t.y = d.at_y THEN '🧍'
                        WHEN NOT t.seen THEN '⬛'
                        WHEN t.spent THEN '⬜'
                        ELSE k.emoji END,
                   '' ORDER BY t.x) AS row_text
        FROM delve_tiles t
        JOIN delve_runs d ON d.delve_id = t.delve_id
        JOIN delve_tile_kinds k ON k.kind = t.kind
        WHERE t.delve_id = p_delve_id
        GROUP BY t.y, d.at_x, d.at_y
    ) rows;
$fn$;


CREATE OR REPLACE FUNCTION delve_end(p_delve_id bigint, p_outcome text)
RETURNS void
LANGUAGE sql
AS $fn$
    UPDATE delve_runs d
    SET status = 'done',
        outcome = COALESCE(d.outcome, p_outcome),
        ended_at = COALESCE(d.ended_at, now())
    WHERE d.delve_id = p_delve_id AND d.status <> 'done';
$fn$;


-- ---------------------------------------------------------------------------
-- A step, and what the ground gives for it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_step(p_player_id bigint, p_dir text)
RETURNS TABLE(
    delve_id     bigint,
    moved        boolean,
    kind         text,
    said         text,
    found        jsonb,
    actions_left integer,
    deepest      integer,
    status       text,
    outcome      text)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_id    BIGINT;
    d       RECORD;
    v_nx    SMALLINT;
    v_ny    SMALLINT;
    v_kind  TEXT;
    v_said  TEXT;
    v_found JSONB := '[]'::jsonb;
    v_depth SMALLINT;
    i       INTEGER;
    got     RECORD;
    v_gu    BIGINT;
BEGIN
    v_id := delve_of(p_player_id);
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'you are not down a delve' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id FOR UPDATE;

    IF d.status = 'fighting' THEN
        RAISE EXCEPTION 'there is something in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_dir NOT IN ('up', 'down', 'left', 'right') THEN
        RAISE EXCEPTION 'there is no such way to go' USING ERRCODE = 'check_violation';
    END IF;

    v_nx := d.at_x + CASE p_dir WHEN 'left' THEN -1 WHEN 'right' THEN 1 ELSE 0 END;
    v_ny := d.at_y + CASE p_dir WHEN 'up' THEN -1 WHEN 'down' THEN 1 ELSE 0 END;

    IF v_nx < 0 OR v_ny < 0 OR v_nx >= d.width OR v_ny >= d.height THEN
        RETURN QUERY SELECT v_id, FALSE, NULL::text, 'Solid rock.'::text,
            v_found, d.actions_left::int, d.deepest::int, d.status, d.outcome;
        RETURN;
    END IF;

    SELECT t.kind INTO v_kind FROM delve_tiles t
    WHERE t.delve_id = v_id AND t.x = v_nx AND t.y = v_ny AND NOT t.spent;
    v_kind := COALESCE(v_kind, 'way');

    -- Depth is the furthest row reached and it is kept. Climbing back toward
    -- the entrance must not take the stone away from you.
    v_depth := GREATEST(d.deepest, (d.height - 1 - v_ny))::smallint;

    UPDATE delve_runs r
    SET at_x = v_nx, at_y = v_ny,
        actions_left = GREATEST(0, r.actions_left - 1),
        deepest = v_depth
    WHERE r.delve_id = v_id;

    UPDATE delve_tiles t SET seen = TRUE
    WHERE t.delve_id = v_id AND t.x = v_nx AND t.y = v_ny;

    -- ---- what is here ----------------------------------------------------
    IF v_kind = 'seam' THEN
        FOR i IN 1..GREATEST(1, game_config_value('delve_seam_pulls')::int) LOOP
            BEGIN
                SELECT * INTO got FROM mine(p_player_id);
                v_found := v_found || jsonb_build_object(
                    'what', got.material_name, 'how_many', got.quantity,
                    'tier', got.ore_tier, 'rich', got.rich);
            EXCEPTION WHEN OTHERS THEN
                EXIT;
            END;
        END LOOP;
        v_said := 'You set to the stone.';

    ELSIF v_kind = 'grove' THEN
        FOR i IN 1..GREATEST(1, game_config_value('delve_grove_pulls')::int) LOOP
            BEGIN
                SELECT * INTO got FROM gather(p_player_id);
                v_found := v_found || jsonb_build_object(
                    'what', got.material_name, 'how_many', got.quantity);
            EXCEPTION WHEN OTHERS THEN
                EXIT;
            END;
        END LOOP;
        v_said := 'Something is growing down here that should not be.';

    ELSIF v_kind = 'trace' THEN
        BEGIN
            SELECT * INTO got FROM explore(p_player_id);
            v_said := COALESCE(got.outcome_name, 'You follow it a while.');
            IF got.material_name IS NOT NULL THEN
                v_found := v_found || jsonb_build_object(
                    'what', got.material_name, 'how_many', got.quantity);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_said := 'The trail goes cold.';
        END;

    ELSIF v_kind = 'hoard' THEN
        -- Somebody's cache: a Gu they were keeping, and the stone around it.
        v_gu := roll_gu_drop(p_player_id, d.region_code,
                             player_realm_rank(p_player_id));
        FOR i IN 1..GREATEST(1, game_config_value('delve_seam_pulls')::int) LOOP
            BEGIN
                SELECT * INTO got FROM mine(p_player_id);
                v_found := v_found || jsonb_build_object(
                    'what', got.material_name, 'how_many', got.quantity,
                    'tier', got.ore_tier, 'rich', got.rich);
            EXCEPTION WHEN OTHERS THEN
                EXIT;
            END;
        END LOOP;
        v_said := CASE WHEN v_gu IS NOT NULL AND v_gu > 0
                       THEN 'A hoard, and something alive still in it.'
                       ELSE 'A hoard, long since picked over.' END;

    ELSIF v_kind IN ('beast', 'deep') THEN
        -- The fight is 0467. Until then the ground simply notes it.
        v_said := (SELECT k.blurb FROM delve_tile_kinds k WHERE k.kind = v_kind);

    ELSE
        v_said := 'Bare rock.';
    END IF;

    IF v_kind <> 'way' AND v_kind NOT IN ('beast', 'deep') THEN
        UPDATE delve_tiles t SET spent = TRUE
        WHERE t.delve_id = v_id AND t.x = v_nx AND t.y = v_ny;
    END IF;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id;

    IF d.status = 'walking' AND d.actions_left <= 0 THEN
        PERFORM delve_end(v_id, 'spent');
        v_said := v_said || ' And that is the last of your strength.';
        SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_id;
    END IF;

    RETURN QUERY SELECT v_id, TRUE, v_kind, v_said, v_found,
        d.actions_left::int, d.deepest::int, d.status, d.outcome;
END;
$fn$;

COMMENT ON FUNCTION delve_step(bigint, text) IS
    'One action. A working tile calls the same `mine`, `gather` or `explore` the surface uses, so a delve is better rates and deeper stone rather than a second economy.';


-- ---------------------------------------------------------------------------
-- A delve is a route, the stone gets deeper, and the surface is untouched
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p     BIGINT;
    v_id    BIGINT;
    v_cap0  SMALLINT;
    v_floor SMALLINT;
    st      RECORD;
    mv      RECORD;
    n       INTEGER := 0;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        WHERE p.deleted_at IS NULL
        ORDER BY p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- On the surface, nothing has changed about mining.
        IF delve_tier_floor(v_p) <> 0 THEN
            RAISE EXCEPTION
                'a cultivator standing in the sun has a delve floor of %',
                delve_tier_floor(v_p);
        END IF;
        v_cap0 := mining_tier_cap(profession_level(v_p, 'mining'));

        DELETE FROM player_cooldowns
        WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);

        IF (SELECT count(*) FROM delve_tiles t WHERE t.delve_id = v_id)
           <> game_config_value('delve_width') * game_config_value('delve_height') THEN
            RAISE EXCEPTION 'the delve has holes in it';
        END IF;

        -- The deep thing is never on the way in.
        IF EXISTS (SELECT 1 FROM delve_tiles t JOIN delve_runs d
                       ON d.delve_id = t.delve_id
                   WHERE t.delve_id = v_id AND t.kind = 'deep'
                     AND t.y > 1) THEN
            RAISE EXCEPTION 'the deep thing is sitting in the entrance';
        END IF;

        -- Only the ground underfoot is lit.
        IF (SELECT count(*) FROM delve_tiles t
            WHERE t.delve_id = v_id AND t.seen) <> 1 THEN
            RAISE EXCEPTION 'the delve is not dark';
        END IF;

        RAISE NOTICE 'opened:%', chr(10) || delve_render(v_id);

        -- Solid rock costs nothing.
        SELECT * INTO mv FROM delve_step(v_p, 'down');
        IF mv.moved THEN
            RAISE EXCEPTION 'the cultivator walked out through the floor';
        END IF;
        IF mv.actions_left <> game_config_value('delve_actions') THEN
            RAISE EXCEPTION 'a refused step still cost an action';
        END IF;

        -- Then straight up, which is straight down, and the stone deepens.
        LOOP
            n := n + 1;
            EXIT WHEN n > 20;
            SELECT * INTO st FROM delve_runs r WHERE r.delve_id = v_id;
            EXIT WHEN st.status = 'done' OR st.at_y = 0;
            SELECT * INTO mv FROM delve_step(v_p, 'up');
            RAISE NOTICE '  % - % (% left, depth %)',
                mv.kind, mv.said, mv.actions_left, mv.deepest;
        END LOOP;

        v_floor := delve_tier_floor(v_p);
        RAISE NOTICE 'at the far wall the stone reaches tier % (mining alone gives %)',
            v_floor, v_cap0;

        IF v_floor <= 1 THEN
            RAISE EXCEPTION
                'pushing to the far wall opened nothing deeper than tier %',
                v_floor;
        END IF;

        -- And it is a floor. A better miner is never made worse.
        IF v_floor < v_cap0 AND GREATEST(v_floor, v_cap0) <> v_cap0 THEN
            RAISE EXCEPTION 'the delve took a miner''s own reach away';
        END IF;

        PERFORM delve_end(v_id, 'climbed_out');
        IF delve_tier_floor(v_p) <> 0 THEN
            RAISE EXCEPTION 'the lift outlasted the delve';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- The budget really is short of the whole map.
    IF game_config_value('delve_actions')
       >= game_config_value('delve_width') * game_config_value('delve_height') THEN
        RAISE EXCEPTION 'a delve can be swept rather than routed';
    END IF;

    -- `mine` still reads its own cap, and now the delve floor beside it.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'mine'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%delve_tier_floor%' THEN
        RAISE EXCEPTION 'mine never learned about the delve';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'mine'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%mining_tier_cap%' THEN
        RAISE EXCEPTION 'mine forgot the miner';
    END IF;
END;
$probe$;
