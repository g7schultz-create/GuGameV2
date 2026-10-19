-- 0455_the_leader_walks_the_party_into_a_map
--
-- A Peer Trial has been one fight against one creature. This gives it ground
-- to happen on: a grid the leader walks the party across, where what you step
-- on is what you get.
--
--     blue   open ground, costs a step and nothing else
--     jewel  a cache - it mends the party
--     fire   a lesser beast, a short fight
--     ogre   a warden, far stronger than the Trial itself, and optional
--     dragon the Trial's own creature, at the top of the map
--
-- THE WHOLE MAP IS VISIBLE. A hidden map is a dice roll wearing a decision's
-- clothes; a visible one is a route, and a route is a choice. The leader can
-- see the warden sitting between the party and two caches and decide.
--
-- AND STEPS ARE THE PRICE. The party has a fixed number of moves, far fewer
-- than it takes to sweep the grid. That is what makes a cache cost something:
-- every tile walked toward one is a tile not walked toward the dragon, and a
-- party that loots too long runs out of map and goes home with nothing. This
-- is the greed axis that was deferred, now expressed as geography rather than
-- as a prompt in the middle of a fight.
--
-- HEALTH CARRIES. One body across the whole map - what a beast takes out of
-- you is still missing when you reach the dragon. Without that the lesser
-- fights are free and the route does not matter.
--
-- IT DOES NOT RE-IMPLEMENT THE FIGHT. Every combat tile opens an ordinary
-- `trial_run` through `trial_begin`, and then the map scales the creature it
-- got and seats the party at the health it is carrying. There is one fight in
-- this game and one function that starts it; a beast is that fight at a third
-- of the size, and a warden is it at nearly double.
--
-- NO LOOT YET, as asked. A cache mends, which is worth real money in a fight
-- that already took two of three raiders down, and `trial_cache_spoils` is
-- created empty as the place the rest will land.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_map_width', 5,
     'How wide the Trial map is. Five tiles is what fits on a phone without the grid wrapping, which is what decides this rather than any design reason.'),
    ('trial_map_height', 6,
     'How deep the Trial map is. The party starts on the bottom row and the Trial''s creature waits on the top one.'),
    ('trial_map_steps', 13,
     'Moves the party gets for the whole map. Deliberately short of what it takes to visit everything: the straight run to the dragon is five, so there are eight moves of greed in a map holding four caches.'),
    ('trial_map_caches', 4,
     'Caches scattered across a Trial map.'),
    ('trial_map_beasts', 5,
     'Lesser beasts scattered across a Trial map.'),
    ('trial_map_wardens', 1,
     'Wardens on a Trial map. One, and it is never in the way - a party that wants it has to go to it.'),
    ('trial_map_beast_scale', 0.35,
     'What a lesser beast carries against the Trial''s own creature. A third: long enough to cost health, short enough that the map is not six boss fights.'),
    ('trial_map_warden_scale', 1.9,
     'What a warden carries against the Trial''s own creature. Nearly double, and optional, which is the only reason it is allowed to be this much.'),
    ('trial_map_cache_mend', 0.30,
     'The share of each raider''s own maximum that a cache restores.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- The ground
-- ---------------------------------------------------------------------------

CREATE TABLE trial_map_kinds (
    kind       TEXT PRIMARY KEY,
    emoji      TEXT NOT NULL,
    label      TEXT NOT NULL,
    scale      NUMERIC(5,2),
    blurb      TEXT NOT NULL
);

COMMENT ON TABLE trial_map_kinds IS
    'What a tile on a Trial map can be. `scale` is what that tile''s creature carries against the Trial''s own, and is null for tiles that are not a fight.';

INSERT INTO trial_map_kinds (kind, emoji, label, scale, blurb) VALUES
    ('way',    '🟦', 'open ground', NULL,
     'Nothing here. It still costs a step.'),
    ('cache',  '💠', 'a cache',     NULL,
     'Somebody left this, and did not come back for it.'),
    ('beast',  '🔥', 'a beast',     0.35,
     'Something smaller than the thing you came for, and in the way.'),
    ('warden', '👹', 'a warden',    1.90,
     'Far stronger than the Trial itself, and nobody is making you.'),
    ('gate',   '🐉', 'the Trial',   1.00,
     'What you came for.');


CREATE TABLE trial_maps (
    map_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id   BIGINT NOT NULL REFERENCES trial_parties(party_id) ON DELETE CASCADE,
    realm_rank SMALLINT NOT NULL,
    species_id BIGINT NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    width      SMALLINT NOT NULL,
    height     SMALLINT NOT NULL,
    at_x       SMALLINT NOT NULL,
    at_y       SMALLINT NOT NULL,
    steps_left SMALLINT NOT NULL,
    caches     SMALLINT NOT NULL DEFAULT 0,
    status     TEXT NOT NULL DEFAULT 'walking',
    outcome    TEXT,
    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ,
    CHECK (status IN ('walking', 'fighting', 'done')),
    CHECK (outcome IS NULL OR outcome IN ('cleared', 'wiped', 'stranded')),
    CHECK ((status = 'done') = (ended_at IS NOT NULL)),
    CHECK ((status = 'done') = (outcome IS NOT NULL)),
    CHECK (steps_left >= 0)
);

CREATE INDEX trial_maps_party_idx ON trial_maps (party_id);
CREATE INDEX trial_maps_live_idx ON trial_maps (status) WHERE status <> 'done';

COMMENT ON TABLE trial_maps IS
    'A Trial''s ground. One per party per attempt; `steps_left` is the whole budget of moves and is what makes a detour cost something.';


CREATE TABLE trial_map_tiles (
    map_id BIGINT NOT NULL REFERENCES trial_maps(map_id) ON DELETE CASCADE,
    x      SMALLINT NOT NULL,
    y      SMALLINT NOT NULL,
    kind   TEXT NOT NULL REFERENCES trial_map_kinds(kind) ON DELETE RESTRICT,
    spent  BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (map_id, x, y)
);

COMMENT ON COLUMN trial_map_tiles.spent IS
    'A tile gives what it has once. Walking back across a beaten beast is open ground and still costs a step.';


CREATE TABLE trial_map_bodies (
    map_id     BIGINT NOT NULL REFERENCES trial_maps(map_id) ON DELETE CASCADE,
    player_id  BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    max_hp     BIGINT NOT NULL,
    current_hp BIGINT NOT NULL,
    PRIMARY KEY (map_id, player_id)
);

COMMENT ON TABLE trial_map_bodies IS
    'What the party is carrying across the map. Health does not reset between tiles - that is the only thing that makes the route matter.';


-- The place loot will land. Empty on purpose: the fight underneath has to be
-- worth walking into before there is any point rewarding it.
CREATE TABLE trial_cache_spoils (
    realm_rank    SMALLINT NOT NULL,
    material_code TEXT NOT NULL REFERENCES materials(code) ON DELETE CASCADE,
    qty_low       INTEGER NOT NULL,
    qty_high      INTEGER NOT NULL,
    weight        NUMERIC(6,2) NOT NULL DEFAULT 1,
    PRIMARY KEY (realm_rank, material_code),
    CHECK (qty_low >= 1 AND qty_high >= qty_low),
    CHECK (weight > 0)
);

COMMENT ON TABLE trial_cache_spoils IS
    'What a cache can hold. Deliberately empty until the map has been walked enough to know what a cache is worth.';


ALTER TABLE trial_runs
    ADD COLUMN map_id BIGINT REFERENCES trial_maps(map_id) ON DELETE SET NULL,
    ADD COLUMN tile_kind TEXT REFERENCES trial_map_kinds(kind) ON DELETE SET NULL;

CREATE INDEX trial_runs_map_idx ON trial_runs (map_id);


-- ---------------------------------------------------------------------------
-- Laying one out
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_map_open(p_player_id bigint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party BIGINT;
    v_rank  SMALLINT;
    v_spec  BIGINT;
    v_w     SMALLINT;
    v_h     SMALLINT;
    v_map   BIGINT;
    v_sx    SMALLINT;
    r       RECORD;
BEGIN
    v_party := trial_party_of(p_player_id);
    IF v_party IS NULL THEN
        RAISE EXCEPTION 'you are not in a party' USING ERRCODE = 'check_violation';
    END IF;
    IF (SELECT p.status FROM trial_parties p WHERE p.party_id = v_party) <> 'sealed' THEN
        RAISE EXCEPTION 'the party has not set out yet'
            USING ERRCODE = 'check_violation';
    END IF;
    IF (SELECT p.leader_id FROM trial_parties p WHERE p.party_id = v_party)
       <> p_player_id THEN
        RAISE EXCEPTION 'only the one leading walks the party in'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM trial_maps m
               WHERE m.party_id = v_party AND m.status <> 'done') THEN
        RAISE EXCEPTION 'you are already in there' USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.realm_rank INTO v_rank FROM trial_parties p WHERE p.party_id = v_party;
    SELECT dg.species_id INTO v_spec FROM dungeons dg
    WHERE dg.realm_rank = v_rank LIMIT 1;
    IF v_spec IS NULL THEN
        RAISE EXCEPTION 'nothing stands at realm % to be tried against', v_rank
            USING ERRCODE = 'check_violation';
    END IF;

    v_w := GREATEST(3, game_config_value('trial_map_width')::int);
    v_h := GREATEST(3, game_config_value('trial_map_height')::int);
    v_sx := (v_w / 2)::smallint;

    INSERT INTO trial_maps
        (party_id, realm_rank, species_id, width, height, at_x, at_y, steps_left)
    VALUES (v_party, v_rank, v_spec, v_w, v_h, v_sx, (v_h - 1)::smallint,
            GREATEST(1, game_config_value('trial_map_steps')::int))
    RETURNING trial_maps.map_id INTO v_map;

    -- Open ground everywhere first, so every tile is reachable by
    -- construction and no party is ever walled away from the dragon.
    INSERT INTO trial_map_tiles (map_id, x, y, kind)
    SELECT v_map, gx::smallint, gy::smallint, 'way'
    FROM generate_series(0, v_w - 1) gx, generate_series(0, v_h - 1) gy;

    -- The dragon, on the top row, somewhere the party cannot see coming from
    -- the start column.
    UPDATE trial_map_tiles t SET kind = 'gate'
    WHERE t.map_id = v_map AND t.y = 0
      AND t.x = (SELECT gx FROM generate_series(0, v_w - 1) gx
                 ORDER BY random() LIMIT 1);

    -- Then the beasts and caches, anywhere but the gate and the tile the
    -- party is standing on.
    FOR r IN
        SELECT 'beast'::text AS kind, i FROM generate_series(1,
            GREATEST(0, game_config_value('trial_map_beasts')::int)) i
        UNION ALL
        SELECT 'cache', i FROM generate_series(1,
            GREATEST(0, game_config_value('trial_map_caches')::int)) i
        UNION ALL
        SELECT 'warden', i FROM generate_series(1,
            GREATEST(0, game_config_value('trial_map_wardens')::int)) i
    LOOP
        UPDATE trial_map_tiles t SET kind = r.kind
        WHERE (t.map_id, t.x, t.y) = (
            SELECT u.map_id, u.x, u.y FROM trial_map_tiles u
            WHERE u.map_id = v_map AND u.kind = 'way'
              AND NOT (u.x = v_sx AND u.y = v_h - 1)
              -- A warden is never on the shortest line. You go to it.
              AND (r.kind <> 'warden' OR u.x <> v_sx)
            ORDER BY random() LIMIT 1);
    END LOOP;

    -- The body the party is carrying, which from here is the only one that
    -- counts until the map lets them out.
    INSERT INTO trial_map_bodies (map_id, player_id, max_hp, current_hp)
    SELECT v_map, m.player_id,
           GREATEST(1, COALESCE(pp.max_hp, 1)),
           GREATEST(1, COALESCE(pp.current_hp, COALESCE(pp.max_hp, 1)))
    FROM trial_party_members m
    LEFT JOIN player_physique pp ON pp.player_id = m.player_id
    WHERE m.party_id = v_party;

    RETURN v_map;
END;
$fn$;

COMMENT ON FUNCTION trial_map_open(bigint) IS
    'Lays a Trial map out under a sealed party. Every tile starts walkable, so reachability is a property of the generator rather than something that has to be checked afterwards.';


CREATE OR REPLACE FUNCTION trial_map_of(p_player_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    SELECT m.map_id FROM trial_maps m
    WHERE m.party_id = trial_party_of(p_player_id) AND m.status <> 'done'
    LIMIT 1;
$fn$;


CREATE OR REPLACE FUNCTION trial_map_render(p_map_id bigint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT string_agg(row_text, chr(10) ORDER BY y)
    FROM (
        SELECT t.y,
               string_agg(
                   CASE WHEN t.x = m.at_x AND t.y = m.at_y THEN '🧍'
                        WHEN t.spent THEN '⬜'
                        ELSE k.emoji END,
                   '' ORDER BY t.x) AS row_text
        FROM trial_map_tiles t
        JOIN trial_maps m ON m.map_id = t.map_id
        JOIN trial_map_kinds k ON k.kind = t.kind
        WHERE t.map_id = p_map_id
        GROUP BY t.y, m.at_x, m.at_y
    ) rows;
$fn$;

COMMENT ON FUNCTION trial_map_render(bigint) IS
    'The map as the party sees it. Spent tiles go blank rather than disappearing, so the route already walked stays readable.';


-- ---------------------------------------------------------------------------
-- Walking it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_map_move(p_player_id bigint, p_dir text)
RETURNS TABLE(
    map_id     bigint,
    moved      boolean,
    said       text,
    kind       text,
    run_id     bigint,
    steps_left integer,
    status     text,
    outcome    text)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_map  BIGINT;
    mp     RECORD;
    v_nx   SMALLINT;
    v_ny   SMALLINT;
    v_kind TEXT;
    v_run  BIGINT;
    v_said TEXT;
    v_mend NUMERIC;
    got    RECORD;
BEGIN
    v_map := trial_map_of(p_player_id);
    IF v_map IS NULL THEN
        RAISE EXCEPTION 'you are not on a map' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO mp FROM trial_maps m WHERE m.map_id = v_map FOR UPDATE;

    IF (SELECT p.leader_id FROM trial_parties p WHERE p.party_id = mp.party_id)
       <> p_player_id THEN
        RAISE EXCEPTION 'the one leading chooses the way'
            USING ERRCODE = 'check_violation';
    END IF;
    IF mp.status = 'fighting' THEN
        RAISE EXCEPTION 'there is something in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    v_nx := mp.at_x + CASE p_dir WHEN 'left' THEN -1 WHEN 'right' THEN 1 ELSE 0 END;
    v_ny := mp.at_y + CASE p_dir WHEN 'up' THEN -1 WHEN 'down' THEN 1 ELSE 0 END;

    IF p_dir NOT IN ('up', 'down', 'left', 'right') THEN
        RAISE EXCEPTION 'there is no such way to go' USING ERRCODE = 'check_violation';
    END IF;
    IF v_nx < 0 OR v_ny < 0 OR v_nx >= mp.width OR v_ny >= mp.height THEN
        RETURN QUERY SELECT v_map, FALSE, 'The map ends there.'::text,
            NULL::text, NULL::bigint, mp.steps_left::int, mp.status, mp.outcome;
        RETURN;
    END IF;

    SELECT t.kind INTO v_kind FROM trial_map_tiles t
    WHERE t.map_id = v_map AND t.x = v_nx AND t.y = v_ny AND NOT t.spent;
    v_kind := COALESCE(v_kind, 'way');

    UPDATE trial_maps m
    SET at_x = v_nx, at_y = v_ny, steps_left = GREATEST(0, m.steps_left - 1)
    WHERE m.map_id = v_map;
    SELECT * INTO mp FROM trial_maps m WHERE m.map_id = v_map;

    IF v_kind = 'cache' THEN
        v_mend := game_config_value('trial_map_cache_mend');
        UPDATE trial_map_bodies b
        SET current_hp = LEAST(b.max_hp,
                               b.current_hp + GREATEST(1, round(b.max_hp * v_mend))::bigint)
        WHERE b.map_id = v_map;
        UPDATE trial_map_tiles t SET spent = TRUE
        WHERE t.map_id = v_map AND t.x = v_nx AND t.y = v_ny;
        UPDATE trial_maps m SET caches = m.caches + 1 WHERE m.map_id = v_map;
        v_said := 'A cache, and it is still full. The party breathes.';

    ELSIF v_kind IN ('beast', 'warden', 'gate') THEN
        -- One fight in this game, one function that starts it. The map takes
        -- the run it is given and sizes it.
        SELECT t.run_id INTO v_run
        FROM trial_begin((SELECT p.leader_id FROM trial_parties p
                          WHERE p.party_id = mp.party_id)) t;

        UPDATE trial_runs r
        SET boss_max_hp = GREATEST(1, round(r.boss_max_hp
                * (SELECT k.scale FROM trial_map_kinds k WHERE k.kind = v_kind)))::bigint,
            boss_hp = GREATEST(1, round(r.boss_hp
                * (SELECT k.scale FROM trial_map_kinds k WHERE k.kind = v_kind)))::bigint,
            map_id = v_map,
            tile_kind = v_kind
        WHERE r.run_id = v_run;

        -- And seats everybody at the body they walked in with, rather than at
        -- the full one `trial_begin` reads off the physique.
        UPDATE trial_raiders x
        SET current_hp = GREATEST(0, b.current_hp), max_hp = GREATEST(1, b.max_hp)
        FROM trial_map_bodies b
        WHERE x.run_id = v_run AND b.map_id = v_map AND b.player_id = x.player_id;

        UPDATE trial_maps m SET status = 'fighting' WHERE m.map_id = v_map;
        v_said := (SELECT k.blurb FROM trial_map_kinds k WHERE k.kind = v_kind);

    ELSE
        v_said := 'Open ground.';
    END IF;

    SELECT * INTO mp FROM trial_maps m WHERE m.map_id = v_map;

    -- Out of map. A party that spent its moves looting goes home with what it
    -- is carrying and without the Trial.
    IF mp.status = 'walking' AND mp.steps_left <= 0 THEN
        UPDATE trial_maps m
        SET status = 'done', outcome = 'stranded', ended_at = now()
        WHERE m.map_id = v_map;
        v_said := v_said || ' And that was the last of the light.';
        SELECT * INTO mp FROM trial_maps m WHERE m.map_id = v_map;
    END IF;

    RETURN QUERY SELECT v_map, TRUE, v_said, v_kind, v_run,
        mp.steps_left::int, mp.status, mp.outcome;
END;
$fn$;

COMMENT ON FUNCTION trial_map_move(bigint, text) IS
    'One step. Everything the map does happens on arrival at a tile, so there is exactly one place a tile can take effect.';


CREATE OR REPLACE FUNCTION trial_map_settle(p_map_id bigint)
RETURNS TABLE(settled boolean, status text, outcome text, said text)
LANGUAGE plpgsql
AS $fn$
DECLARE
    mp     RECORD;
    run    RECORD;
    v_said TEXT;
BEGIN
    SELECT * INTO mp FROM trial_maps m WHERE m.map_id = p_map_id FOR UPDATE;
    IF NOT FOUND OR mp.status <> 'fighting' THEN
        RETURN QUERY SELECT FALSE, COALESCE(mp.status, 'done'), mp.outcome, NULL::text;
        RETURN;
    END IF;

    SELECT * INTO run FROM trial_runs r
    WHERE r.map_id = p_map_id ORDER BY r.run_id DESC LIMIT 1;
    IF run.status <> 'done' THEN
        RETURN QUERY SELECT FALSE, mp.status, mp.outcome, NULL::text;
        RETURN;
    END IF;

    -- What the party is carrying out of that fight is what it carries on.
    UPDATE trial_map_bodies b
    SET current_hp = GREATEST(0, x.current_hp)
    FROM trial_raiders x
    WHERE b.map_id = p_map_id AND x.run_id = run.run_id AND x.player_id = b.player_id;

    IF run.outcome = 'cleared' THEN
        UPDATE trial_map_tiles t SET spent = TRUE
        WHERE t.map_id = p_map_id AND t.x = mp.at_x AND t.y = mp.at_y;

        IF run.tile_kind = 'gate' THEN
            UPDATE trial_maps m
            SET status = 'done', outcome = 'cleared', ended_at = now()
            WHERE m.map_id = p_map_id;
            v_said := 'It is down, and the Trial is yours.';
        ELSE
            UPDATE trial_maps m SET status = 'walking' WHERE m.map_id = p_map_id;
            v_said := 'The way is clear.';
        END IF;
    ELSE
        -- Wiped or outlasted both end the map. There is no second attempt at a
        -- tile that already beat you.
        UPDATE trial_maps m
        SET status = 'done', outcome = 'wiped', ended_at = now()
        WHERE m.map_id = p_map_id;
        v_said := 'The party does not walk back out.';
    END IF;

    SELECT * INTO mp FROM trial_maps m WHERE m.map_id = p_map_id;
    RETURN QUERY SELECT TRUE, mp.status, mp.outcome, v_said;
END;
$fn$;

COMMENT ON FUNCTION trial_map_settle(bigint) IS
    'Reads a finished fight back onto the map: the health the party walks away with, whether the tile is beaten, and whether the map is over.';


CREATE OR REPLACE FUNCTION trial_map_end(p_map_id bigint)
RETURNS void
LANGUAGE sql
AS $fn$
    UPDATE trial_maps m
    SET status = 'done',
        outcome = COALESCE(m.outcome, 'stranded'),
        ended_at = COALESCE(m.ended_at, now())
    WHERE m.map_id = p_map_id AND m.status <> 'done';
$fn$;


-- ---------------------------------------------------------------------------
-- A map is walkable, costly, and ends
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_map   BIGINT;
    mv      RECORD;
    st      RECORD;
    got     RECORD;
    r       RECORD;
    v_n     INTEGER := 0;
    v_gx    SMALLINT;
    v_hp0   BIGINT;
    v_hp1   BIGINT;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_lead IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
              AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;
        PERFORM trial_party_seal(v_lead);

        v_map := trial_map_open(v_lead);

        -- Every tile exists, and exactly one of them is the way out.
        IF (SELECT count(*) FROM trial_map_tiles t WHERE t.map_id = v_map)
           <> game_config_value('trial_map_width') * game_config_value('trial_map_height') THEN
            RAISE EXCEPTION 'the map has holes in it';
        END IF;
        IF (SELECT count(*) FROM trial_map_tiles t
            WHERE t.map_id = v_map AND t.kind = 'gate') <> 1 THEN
            RAISE EXCEPTION 'a map must have exactly one way out';
        END IF;
        IF (SELECT count(*) FROM trial_map_tiles t
            WHERE t.map_id = v_map AND t.kind = 'warden'
              AND t.x = (SELECT m.at_x FROM trial_maps m WHERE m.map_id = v_map)) > 0 THEN
            RAISE EXCEPTION 'a warden is standing in the only straight line';
        END IF;

        RAISE NOTICE 'the map:%', chr(10) || trial_map_render(v_map);

        -- Walking off the edge costs nothing, which is the one move that must
        -- not quietly eat a step.
        SELECT * INTO mv FROM trial_map_move(v_lead, 'down');
        IF mv.moved THEN
            RAISE EXCEPTION 'the party walked off the bottom of the map';
        END IF;
        IF mv.steps_left <> game_config_value('trial_map_steps') THEN
            RAISE EXCEPTION 'a refused move still cost a step';
        END IF;

        -- Then up the map, fighting whatever is in the way, until the gate.
        LOOP
            v_n := v_n + 1;
            EXIT WHEN v_n > 40;

            SELECT m.status INTO st FROM trial_maps m WHERE m.map_id = v_map;
            IF st.status = 'done' THEN EXIT; END IF;

            IF st.status = 'fighting' THEN
                LOOP
                    SELECT * INTO got FROM trial_resolve_round(
                        (SELECT r2.run_id FROM trial_runs r2
                         WHERE r2.map_id = v_map ORDER BY r2.run_id DESC LIMIT 1));
                    EXIT WHEN got IS NULL OR got.status = 'done';
                END LOOP;
                SELECT * INTO got FROM trial_map_settle(v_map);
                RAISE NOTICE '  the fight: % (%)', got.said, got.outcome;
                CONTINUE;
            END IF;

            -- Straight at the gate's column, then straight up it.
            SELECT t.x INTO v_gx FROM trial_map_tiles t
            WHERE t.map_id = v_map AND t.kind = 'gate';
            SELECT * INTO mv FROM trial_map_move(v_lead,
                CASE WHEN (SELECT m.at_x FROM trial_maps m WHERE m.map_id = v_map) < v_gx
                     THEN 'right'
                     WHEN (SELECT m.at_x FROM trial_maps m WHERE m.map_id = v_map) > v_gx
                     THEN 'left' ELSE 'up' END);
            RAISE NOTICE '  step on % - % (% left)', mv.kind, mv.said, mv.steps_left;
        END LOOP;

        SELECT * INTO st FROM trial_maps m WHERE m.map_id = v_map;
        RAISE NOTICE 'the map ended %, with % caches taken and % steps left',
            st.outcome, st.caches, st.steps_left;

        IF st.status <> 'done' THEN
            RAISE EXCEPTION 'the map never ended';
        END IF;

        -- The budget really is short of the whole grid. If a party can sweep
        -- every tile and still reach the gate, nothing on this map is a choice.
        IF game_config_value('trial_map_steps')
           >= game_config_value('trial_map_width') * game_config_value('trial_map_height') THEN
            RAISE EXCEPTION 'the party has steps enough to walk the entire map';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- A cache is a mend and nothing else until there is something to put in it.
    IF (SELECT count(*) FROM trial_cache_spoils) <> 0 THEN
        RAISE EXCEPTION 'something has been put in the caches already';
    END IF;
END;
$probe$;
