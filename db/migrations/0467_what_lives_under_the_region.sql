-- 0467_what_lives_under_the_region
--
-- The beasts 0466 left room for. A delve tile marked with a beast puts
-- something between the cultivator and the rest of the map, and it has to be
-- killed or walked away from.
--
-- IT DRAWS FROM THE REGION. `creature_regions` already says what lives where
-- and every one of those species carries a `creature_drops` table - sixteen to
-- twenty-six of them per region, all of them with drops. So a beast under the
-- Western Desert is a Western Desert beast and pays Western Desert materials,
-- with no new bestiary and no new loot table.
--
-- IT IS SIZED BY REHEARSAL, for the reason 0454 gave: `creature_species.base_hp`
-- has not kept pace with what cultivators do, and the deepest creature in the
-- game dies to three of them in one round. So the delve runs the cultivator
-- through `player_swing` in a subtransaction it rolls back, and sets the
-- beast's body from what they actually did.
--
--     a beast       four rounds of your own damage
--     the deep one  two and a half times that
--
-- Four rather than a Trial's eight because a delve is one person and the fight
-- is a toll on the way to the stone rather than the point of the trip. The
-- deep one is the point of the trip.
--
-- AND IT HITS BACK, through `compute_creature_damage` - the same function a
-- dungeon's creature swings with. Your body is the one on your physique, so a
-- delve you walked into at half health is a delve you are fighting at half
-- health, and dying down there ends the delve with whatever you had already
-- dug out. You keep that: you dug it before you died.
--
-- THE SCOPE IS DECLARED FIRST. 0456 was the migration where a Peer Trial's
-- whole answer mechanism turned out to be writing to a `battle_effects.scope`
-- the table had never admitted, because the constraint listed five rooms and
-- nobody had added the sixth. `delve` goes on that list in this migration,
-- before anything swings, rather than in the one after the first crash.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('delve_beast_rounds', 4,
     'How many rounds of a cultivator''s own damage an ordinary delve beast carries. Four, because a beast is a toll on the way to the stone rather than the reason for the trip.'),
    ('delve_flee_actions', 2,
     'What walking away from a beast costs. More than a step, less than a fight, so fleeing is a decision and not a reflex.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- The sixth room. See 0456 for what happens when this is forgotten.
ALTER TABLE battle_effects DROP CONSTRAINT battle_effects_scope_check;

ALTER TABLE battle_effects ADD CONSTRAINT battle_effects_scope_check
    CHECK (scope IN ('battle', 'dungeon', 'boss', 'horde', 'gauntlet',
                     'trial', 'rehearsal', 'delve'));


CREATE TABLE delve_fights (
    fight_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delve_id   BIGINT NOT NULL REFERENCES delve_runs(delve_id) ON DELETE CASCADE,
    species_id BIGINT NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    tile_kind  TEXT NOT NULL REFERENCES delve_tile_kinds(kind) ON DELETE RESTRICT,
    at_x       SMALLINT NOT NULL,
    at_y       SMALLINT NOT NULL,
    hp         BIGINT NOT NULL,
    max_hp     BIGINT NOT NULL,
    round_no   INTEGER NOT NULL DEFAULT 1,
    status     TEXT NOT NULL DEFAULT 'fighting',
    outcome    TEXT,
    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ,
    CHECK (status IN ('fighting', 'done')),
    CHECK (outcome IS NULL OR outcome IN ('slain', 'fled', 'died')),
    CHECK ((status = 'done') = (ended_at IS NOT NULL)),
    CHECK ((status = 'done') = (outcome IS NOT NULL))
);

CREATE INDEX delve_fights_delve_idx ON delve_fights (delve_id);
CREATE INDEX delve_fights_species_idx ON delve_fights (species_id);
CREATE INDEX delve_fights_tile_kind_idx ON delve_fights (tile_kind);
CREATE UNIQUE INDEX delve_fights_one_live_each
    ON delve_fights (delve_id) WHERE status = 'fighting';


-- ---------------------------------------------------------------------------
-- How big the thing is
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_rehearse(p_player_id bigint, p_species_id bigint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_def  BIGINT;
    v_sum  BIGINT := 0;
    v_n    INTEGER;
    v_move BIGINT;
    v_hp   BIGINT;
    swung  RECORD;
    i      INTEGER;
BEGIN
    v_n := GREATEST(1, game_config_value('trial_rehearsal_rounds')::int);
    SELECT s.base_defense INTO v_def FROM creature_species s
    WHERE s.species_id = p_species_id;
    IF v_def IS NULL THEN
        RETURN 0;
    END IF;

    v_move := dungeon_default_move(p_player_id);
    IF v_move IS NULL THEN
        RETURN 0;
    END IF;

    SELECT GREATEST(1, COALESCE(pp.max_hp, 1)) INTO v_hp
    FROM player_physique pp WHERE pp.player_id = p_player_id;
    v_hp := COALESCE(v_hp, 1);

    BEGIN
        FOR i IN 1..v_n LOOP
            SELECT * INTO swung FROM player_swing(
                p_player_id, v_move, p_species_id,
                9223372036854775807::bigint, v_def, v_hp, v_hp,
                i, 'rehearsal', -p_player_id);
            v_sum := v_sum + GREATEST(0, swung.dealt);
        END LOOP;
        RAISE EXCEPTION 'rehearsal-done';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rehearsal-done' THEN RAISE; END IF;
    END;

    RETURN GREATEST(0, v_sum / v_n);
END;
$fn$;

COMMENT ON FUNCTION delve_rehearse(bigint, bigint) IS
    'What one cultivator really puts out in a round against this creature, found by running it and rolling it back. The solo twin of trial_rehearse, and for the same reason: crit_damage rather than any stat governs a cultivator''s output, so no fitted ratio survives contact with a second build.';


-- ---------------------------------------------------------------------------
-- Meeting it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_meet(p_delve_id bigint, p_kind text,
                                      p_x smallint, p_y smallint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    d       RECORD;
    v_spec  BIGINT;
    v_round BIGINT;
    v_pool  BIGINT;
    v_scale NUMERIC;
    v_id    BIGINT;
BEGIN
    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = p_delve_id;
    IF d IS NULL THEN
        RETURN NULL;
    END IF;

    -- What lives here, weighted the way the region weights it.
    SELECT cr.species_id INTO v_spec
    FROM creature_regions cr
    WHERE cr.region_code = d.region_code
    ORDER BY -ln(random()) / GREATEST(0.0001, cr.weight)
    LIMIT 1;
    IF v_spec IS NULL THEN
        RETURN NULL;
    END IF;

    v_scale := COALESCE((SELECT k.scale FROM delve_tile_kinds k
                         WHERE k.kind = p_kind), 1);

    v_round := delve_rehearse(d.player_id, v_spec);
    IF v_round <= 0 THEN
        -- A cultivator with nothing to throw still meets a body, sized off
        -- the species rather than off a rehearsal that cannot happen.
        SELECT GREATEST(1, s.base_hp) INTO v_round FROM creature_species s
        WHERE s.species_id = v_spec;
    END IF;

    v_pool := GREATEST(1, round(
        v_round::numeric * game_config_value('delve_beast_rounds') * v_scale
    ))::bigint;

    INSERT INTO delve_fights
        (delve_id, species_id, tile_kind, at_x, at_y, hp, max_hp)
    VALUES (p_delve_id, v_spec, p_kind, p_x, p_y, v_pool, v_pool)
    RETURNING delve_fights.fight_id INTO v_id;

    UPDATE delve_runs r SET status = 'fighting' WHERE r.delve_id = p_delve_id;

    RETURN v_id;
END;
$fn$;


CREATE OR REPLACE FUNCTION delve_strike(p_player_id bigint, p_technique_id bigint)
RETURNS TABLE(
    fight_id   bigint,
    beast_name text,
    dealt      bigint,
    taken      bigint,
    healed     bigint,
    beast_hp   bigint,
    beast_max  bigint,
    my_hp      bigint,
    my_max     bigint,
    round_no   integer,
    status     text,
    outcome    text,
    found      jsonb)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_delve BIGINT;
    f       RECORD;
    d       RECORD;
    swung   RECORD;
    hit     RECORD;
    v_move  BIGINT;
    v_hp    BIGINT;
    v_max   BIGINT;
    v_taken BIGINT := 0;
    v_found JSONB := '[]'::jsonb;
    v_out   TEXT;
    v_gu    BIGINT;
    one     RECORD;
    v_qty   BIGINT;
BEGIN
    v_delve := delve_of(p_player_id);
    IF v_delve IS NULL THEN
        RAISE EXCEPTION 'you are not down a delve' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO f FROM delve_fights x
    WHERE x.delve_id = v_delve AND x.status = 'fighting' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;

    v_move := COALESCE(p_technique_id, dungeon_default_move(p_player_id));
    IF v_move IS NULL THEN
        RAISE EXCEPTION 'you have nothing to throw' USING ERRCODE = 'check_violation';
    END IF;
    IF p_technique_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM player_techniques pt
                       WHERE pt.player_id = p_player_id
                         AND pt.technique_id = p_technique_id) THEN
        RAISE EXCEPTION 'you do not know that one' USING ERRCODE = 'check_violation';
    END IF;

    SELECT GREATEST(0, COALESCE(pp.current_hp, 0)),
           GREATEST(1, COALESCE(pp.max_hp, 1))
    INTO v_hp, v_max
    FROM player_physique pp WHERE pp.player_id = p_player_id;
    v_hp := COALESCE(v_hp, 1);
    v_max := COALESCE(v_max, 1);

    -- ---- you ------------------------------------------------------------
    SELECT * INTO swung FROM player_swing(
        p_player_id, v_move, f.species_id, f.hp,
        (SELECT s.base_defense FROM creature_species s
         WHERE s.species_id = f.species_id)::bigint,
        v_hp, v_max, f.round_no, 'delve', v_delve);

    UPDATE delve_fights x SET hp = GREATEST(0, x.hp - GREATEST(0, swung.dealt))
    WHERE x.fight_id = f.fight_id;

    IF swung.healed > 0 THEN
        v_hp := LEAST(v_max, v_hp + swung.healed);
    END IF;

    SELECT * INTO f FROM delve_fights x WHERE x.fight_id = f.fight_id;

    -- ---- and it ---------------------------------------------------------
    IF f.hp > 0 THEN
        SELECT * INTO hit FROM compute_creature_damage(
            f.species_id, p_player_id, 1.0,
            (SELECT GREATEST(0, COALESCE(pp.defense, 0)) FROM player_physique pp
             WHERE pp.player_id = p_player_id)::bigint);
        v_taken := GREATEST(0, COALESCE(hit.final_damage, 0));
        v_hp := GREATEST(0, v_hp - v_taken);
    END IF;

    UPDATE player_physique pp SET current_hp = v_hp
    WHERE pp.player_id = p_player_id;

    -- ---- how it stands --------------------------------------------------
    IF f.hp <= 0 THEN
        v_out := 'slain';

        -- What it was carrying, from its own table.
        FOR one IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity,
                   m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = f.species_id
        LOOP
            CONTINUE WHEN random() >= one.chance;
            v_qty := one.min_quantity
                     + floor(random() * (one.max_quantity - one.min_quantity + 1));
            PERFORM grant_material(p_player_id, one.material_code, v_qty);
            v_found := v_found || jsonb_build_object(
                'what', one.name, 'how_many', v_qty);
        END LOOP;

        -- And the thing from the deep keeps something alive.
        IF f.tile_kind = 'deep' THEN
            v_gu := roll_gu_drop(p_player_id, d.region_code,
                                 player_realm_rank(p_player_id));
            IF v_gu IS NOT NULL AND v_gu > 0 THEN
                v_found := v_found || jsonb_build_object('what', 'a living Gu',
                                                         'how_many', 1);
            END IF;
        END IF;

        UPDATE delve_fights x
        SET status = 'done', outcome = 'slain', ended_at = now()
        WHERE x.fight_id = f.fight_id;
        UPDATE delve_tiles t SET spent = TRUE
        WHERE t.delve_id = v_delve AND t.x = f.at_x AND t.y = f.at_y;
        UPDATE delve_runs r SET status = 'walking' WHERE r.delve_id = v_delve;
        PERFORM effect_clear('delve', v_delve);

    ELSIF v_hp <= 0 THEN
        v_out := 'died';
        UPDATE delve_fights x
        SET status = 'done', outcome = 'died', ended_at = now()
        WHERE x.fight_id = f.fight_id;
        PERFORM delve_end(v_delve, 'died');
        PERFORM effect_clear('delve', v_delve);

    ELSE
        UPDATE delve_fights x SET round_no = x.round_no + 1
        WHERE x.fight_id = f.fight_id;
        PERFORM effect_tick('delve', v_delve);
    END IF;

    SELECT * INTO f FROM delve_fights x WHERE x.fight_id = f.fight_id;
    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;

    RETURN QUERY SELECT f.fight_id,
        (SELECT s.name FROM creature_species s WHERE s.species_id = f.species_id),
        GREATEST(0, swung.dealt), v_taken, swung.healed,
        f.hp, f.max_hp, v_hp, v_max, f.round_no,
        d.status, COALESCE(f.outcome, v_out), v_found;
END;
$fn$;

COMMENT ON FUNCTION delve_strike(bigint, bigint) IS
    'One round against whatever is in the way. Your body is the one on your physique, so a delve walked into at half health is fought at half health.';


CREATE OR REPLACE FUNCTION delve_flee(p_player_id bigint)
RETURNS TABLE(fled boolean, actions_left integer, status text, outcome text)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_delve BIGINT;
    f       RECORD;
    d       RECORD;
BEGIN
    v_delve := delve_of(p_player_id);
    IF v_delve IS NULL THEN
        RAISE EXCEPTION 'you are not down a delve' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO f FROM delve_fights x
    WHERE x.delve_id = v_delve AND x.status = 'fighting' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing to walk away from'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE delve_fights x
    SET status = 'done', outcome = 'fled', ended_at = now()
    WHERE x.fight_id = f.fight_id;

    -- The tile is NOT spent: it is still there, and so is the beast if you
    -- come back this way. What fleeing costs is the strength to do it.
    UPDATE delve_runs r
    SET status = 'walking',
        actions_left = GREATEST(0, r.actions_left
                                   - game_config_value('delve_flee_actions')::int)
    WHERE r.delve_id = v_delve;

    PERFORM effect_clear('delve', v_delve);

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;
    IF d.actions_left <= 0 AND d.status = 'walking' THEN
        PERFORM delve_end(v_delve, 'spent');
        SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;
    END IF;

    RETURN QUERY SELECT TRUE, d.actions_left::int, d.status, d.outcome;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- A beast tile actually puts something in the way
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_step' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_step is missing';
    END IF;

    anchor := concat(
'    ELSIF v_kind IN (''beast'', ''deep'') THEN', chr(10),
'        -- The fight is 0467. Until then the ground simply notes it.', chr(10),
'        v_said := (SELECT k.blurb FROM delve_tile_kinds k WHERE k.kind = v_kind);');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_step no longer notes its beasts where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    ELSIF v_kind IN (''beast'', ''deep'') THEN', chr(10),
'        PERFORM delve_meet(v_id, v_kind, v_nx, v_ny);', chr(10),
'        v_said := (SELECT k.blurb FROM delve_tile_kinds k WHERE k.kind = v_kind);'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- It is sized against you, it hits back, and it pays its own table
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p     BIGINT;
    v_id    BIGINT;
    v_spec  BIGINT;
    v_fight BIGINT;
    v_round BIGINT;
    v_hp0   BIGINT;
    v_mat0  BIGINT;
    v_mat1  BIGINT;
    r       RECORD;
    n       INTEGER := 0;
    at      RECORD;
BEGIN
    -- The room is admitted before anything tries to stand in it.
    BEGIN
        INSERT INTO battle_effects
            (scope, scope_id, player_id, effect_code, magnitude, turns_left)
        VALUES ('delve', -1, (SELECT min(player_id) FROM players),
                'regen', 0.1, 1);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN check_violation THEN
            RAISE EXCEPTION 'battle_effects still refuses a delve';
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);

        -- Put a beast where they are about to step.
        SELECT r2.at_x, r2.at_y INTO at FROM delve_runs r2 WHERE r2.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'beast', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;

        PERFORM delve_step(v_p, 'up');

        SELECT * INTO r FROM delve_fights x
        WHERE x.delve_id = v_id AND x.status = 'fighting';
        IF NOT FOUND THEN
            RAISE EXCEPTION 'stepping onto a beast put nothing in the way';
        END IF;
        v_fight := r.fight_id;
        v_spec := r.species_id;

        -- It is sized against what this cultivator does, not off the species.
        v_round := delve_rehearse(v_p, v_spec);
        IF v_round > 0 AND r.max_hp < v_round * 2 THEN
            RAISE EXCEPTION
                'the beast carries % against a cultivator who deals % a round',
                r.max_hp, v_round;
        END IF;

        SELECT pp.current_hp INTO v_hp0 FROM player_physique pp
        WHERE pp.player_id = v_p;
        SELECT COALESCE(sum(pm.quantity), 0) INTO v_mat0
        FROM player_materials pm WHERE pm.player_id = v_p;

        -- Fight it down.
        LOOP
            n := n + 1;
            EXIT WHEN n > 40;
            SELECT * INTO r FROM delve_strike(v_p, NULL);
            EXIT WHEN r.status = 'done' OR r.outcome IN ('slain', 'died');
        END LOOP;

        RAISE NOTICE 'the beast went down in % rounds; it was carrying %',
            n, COALESCE(jsonb_array_length(r.found), 0);

        IF r.outcome = 'slain' THEN
            SELECT COALESCE(sum(pm.quantity), 0) INTO v_mat1
            FROM player_materials pm WHERE pm.player_id = v_p;
            IF v_mat1 < v_mat0 THEN
                RAISE EXCEPTION 'killing it cost materials';
            END IF;

            -- The tile is finished and the delve carries on.
            IF NOT (SELECT t.spent FROM delve_tiles t
                    WHERE t.delve_id = v_id AND t.x = at.at_x
                      AND t.y = at.at_y - 1) THEN
                RAISE EXCEPTION 'the beast is dead and the tile is not spent';
            END IF;
            IF (SELECT r2.status FROM delve_runs r2 WHERE r2.delve_id = v_id)
               <> 'walking' THEN
                RAISE EXCEPTION 'the delve did not resume after the kill';
            END IF;
        END IF;

        -- Nothing leaked out of the room.
        IF EXISTS (SELECT 1 FROM battle_effects b
                   WHERE b.scope = 'delve' AND b.scope_id = v_id) THEN
            RAISE EXCEPTION 'the fight left its effects behind';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Walking away costs more than a step and leaves the beast standing.
    IF game_config_value('delve_flee_actions') < 2 THEN
        RAISE EXCEPTION 'fleeing is a reflex rather than a decision';
    END IF;
END;
$probe$;
