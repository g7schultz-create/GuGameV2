-- 0471_a_beast_that_tells_you_what_it_is_about_to_do
--
-- A delve fight is currently one button pressed until somebody falls over.
-- You deal what your build deals, it takes a flat share of you, and nothing
-- either of you does changes anything. Eleven rounds of that is not a fight,
-- it is a progress bar with a cooldown.
--
-- THE TRIAL ALREADY SOLVED THIS and the solution is not party-shaped. A Peer
-- Trial telegraphs what is coming and asks the party to cover it; what makes
-- that work is the TELEGRAPH, not the party. One cultivator can read a beast
-- just as well as three can.
--
-- SO IT TELLS YOU WHAT IT IS ABOUT TO DO.
--
--     It gathers itself      guard     a heavy blow, 20 per cent of you
--     It comes in low        press     14, and it is wide open while it does
--     Something is building  strike    5, and it grows if you let it
--     It circles you         -          2, and it is thinking
--
-- AND YOU CHOOSE HOW TO MEET IT. Four stances, which are the same four at
-- every realm:
--
--     Strike   your blow, as now
--     Guard    two-fifths of your damage, and you are braced
--     Press    half again your damage, and nearly double what it costs you
--     Search   nothing dealt, the blow lands in full, and you go through
--              the lair while it is on top of you
--
-- Meeting a move with its answer costs you a QUARTER of what it would. Meeting
-- a lunge with a press costs you nearly double. That spread is the content:
-- reading it right is worth eight times reading it wrong, and the telegraph is
-- always honest.
--
-- SEARCH IS THE LOOT OPTION, and this is where it belongs rather than on the
-- map. On the map every action already loots - stepping on a seam works it.
-- In a fight there was nothing to trade, so there was no choice to make. Now
-- there is: you take the blow in full and come up with what the thing was
-- sitting on.
--
-- AND LETTING IT BUILD HAS A PRICE. `Something is building` adds a stack if
-- you do not take a real bite out of it that round, and every stack makes
-- everything afterwards a quarter worse. A beast you let coil three times is
-- a different beast.
--
-- `delve_strike` IS KEPT, delegating to the new verb with the `strike` stance,
-- so nothing that calls it has to move at once.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('delve_answered_share', 0.25,
     'What a beast''s move still costs when it is met with its answer. A quarter: reading it right has to be worth something large or the telegraph is decoration, and it must not be free or the fight stops being a fight.'),
    ('delve_rage_step', 0.25,
     'How much worse everything gets for each time you let the thing finish building. A quarter, compounding, so three stacks is roughly double.'),
    ('delve_press_share', 0.10,
     'The share of a beast''s whole body you must take off in one round for that round to count as a real blow - which is what answers `Something is building`.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What it can do, and what meets it
-- ---------------------------------------------------------------------------

CREATE TABLE delve_beast_moves (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    telegraph   TEXT NOT NULL,
    answered_by TEXT NOT NULL,
    share       NUMERIC(5,3) NOT NULL,
    builds      BOOLEAN NOT NULL DEFAULT FALSE,
    weight      NUMERIC(5,2) NOT NULL,
    missed_line TEXT NOT NULL,
    CHECK (share >= 0 AND share <= 1),
    CHECK (weight > 0)
);

COMMENT ON TABLE delve_beast_moves IS
    'What a delve beast announces and what meets it. `share` is of the cultivator''s OWN maximum, so one number works at every realm - the same device the Peer Trial''s threats use.';

INSERT INTO delve_beast_moves
    (code, name, telegraph, answered_by, share, builds, weight, missed_line) VALUES
    ('lunge', 'It gathers itself',
     'It drops its weight back onto its haunches. Whatever is coming is coming all at once.',
     'guard', 0.200, FALSE, 1.00,
     'It arrives before you are set, and all of it lands.'),
    ('maul', 'It comes in low',
     'Jaw open, head down. For a moment it has stopped caring what you do about it.',
     'press', 0.140, FALSE, 1.00,
     'You give ground, and it takes the ground you gave.'),
    ('coil', 'Something is building',
     'The air around it thickens, and it has stopped breathing.',
     'strike', 0.050, TRUE, 0.80,
     'Whatever it was gathering, it finishes gathering.'),
    ('circle', 'It circles you',
     'It has not decided about you yet. For one breath it is not going to do anything at all.',
     'none', 0.020, FALSE, 0.60,
     'It watches, and does very little.');


CREATE TABLE delve_stances (
    code       TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    deal_mult  NUMERIC(5,2) NOT NULL,
    taken_mult NUMERIC(5,2) NOT NULL,
    blurb      TEXT NOT NULL,
    CHECK (deal_mult >= 0),
    CHECK (taken_mult >= 0)
);

COMMENT ON TABLE delve_stances IS
    'How a cultivator meets what is coming. A stance whose code matches a move''s `answered_by` is the answer to it, which is how the two tables stay one rule rather than two.';

INSERT INTO delve_stances (code, name, deal_mult, taken_mult, blurb) VALUES
    ('strike', 'Strike', 1.00, 1.00,
     'Your blow, and nothing clever.'),
    ('guard',  'Guard',  0.40, 1.00,
     'Two-fifths of your damage, and you are set for whatever arrives.'),
    ('press',  'Press',  1.60, 1.75,
     'Half again your damage. If you have read it wrong it costs you nearly double.'),
    ('search', 'Search the lair', 0.00, 1.00,
     'You deal nothing and the blow lands in full, and you come up with whatever it was sitting on.');


ALTER TABLE delve_fights
    ADD COLUMN coming TEXT REFERENCES delve_beast_moves(code) ON DELETE RESTRICT,
    ADD COLUMN rage SMALLINT NOT NULL DEFAULT 0;

CREATE INDEX delve_fights_coming_idx ON delve_fights (coming);


CREATE OR REPLACE FUNCTION delve_draw_move()
RETURNS TEXT
LANGUAGE sql
VOLATILE
AS $fn$
    SELECT m.code FROM delve_beast_moves m
    ORDER BY -ln(random()) / m.weight LIMIT 1;
$fn$;


-- Everything that is already in the ground gets a first telegraph, so a fight
-- opened before this migration does not sit there with nothing coming.
UPDATE delve_fights SET coming = delve_draw_move()
WHERE status = 'fighting' AND coming IS NULL;


-- ---------------------------------------------------------------------------
-- The round
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION delve_act(p_player_id bigint, p_stance text,
                                     p_technique_id bigint)
RETURNS TABLE(
    fight_id   bigint,
    beast_name text,
    stance     text,
    answered   boolean,
    was        text,
    was_name   text,
    said       text,
    dealt      bigint,
    taken      bigint,
    healed     bigint,
    beast_hp   bigint,
    beast_max  bigint,
    my_hp      bigint,
    my_max     bigint,
    rage       integer,
    round_no   integer,
    coming     text,
    telegraph  text,
    status     text,
    outcome    text,
    found      jsonb)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_delve BIGINT;
    f       RECORD;
    d       RECORD;
    st      RECORD;
    mv      RECORD;
    swung   RECORD;
    hit     RECORD;
    v_move  BIGINT;
    v_hp    BIGINT;
    v_max   BIGINT;
    v_dealt BIGINT := 0;
    v_taken BIGINT := 0;
    v_found JSONB := '[]'::jsonb;
    v_ok    BOOLEAN;
    v_said  TEXT;
    v_out   TEXT;
    v_next  TEXT;
    v_gu    BIGINT;
    one     RECORD;
    v_qty   BIGINT;
    got     RECORD;
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

    SELECT * INTO st FROM delve_stances s WHERE s.code = p_stance;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such way to meet it'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;
    SELECT * INTO mv FROM delve_beast_moves m WHERE m.code = f.coming;

    v_move := COALESCE(p_technique_id, dungeon_default_move(p_player_id));
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

    -- ---- what you do -----------------------------------------------------
    IF st.deal_mult > 0 AND v_move IS NOT NULL THEN
        SELECT * INTO swung FROM player_swing(
            p_player_id, v_move, f.species_id, f.hp,
            (SELECT s.base_defense FROM creature_species s
             WHERE s.species_id = f.species_id)::bigint,
            v_hp, v_max, f.round_no, 'delve', v_delve);

        v_dealt := GREATEST(0, round(swung.dealt * st.deal_mult))::bigint;
        IF swung.healed > 0 THEN
            v_hp := LEAST(v_max, v_hp + swung.healed);
        END IF;
    END IF;

    -- Searching the lair while it is standing over you.
    IF p_stance = 'search' THEN
        BEGIN
            SELECT * INTO got FROM gather(p_player_id);
            v_found := v_found || jsonb_build_object(
                'what', got.material_name, 'how_many', got.quantity);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
        FOR one IN
            SELECT cd.material_code, cd.chance, cd.min_quantity,
                   cd.max_quantity, m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = f.species_id
        LOOP
            CONTINUE WHEN random() >= one.chance / 2;
            v_qty := one.min_quantity
                     + floor(random() * (one.max_quantity - one.min_quantity + 1));
            PERFORM grant_material(p_player_id, one.material_code, v_qty);
            v_found := v_found || jsonb_build_object(
                'what', one.name, 'how_many', v_qty);
        END LOOP;
    END IF;

    UPDATE delve_fights x SET hp = GREATEST(0, x.hp - v_dealt)
    WHERE x.fight_id = f.fight_id;
    SELECT * INTO f FROM delve_fights x WHERE x.fight_id = f.fight_id;

    -- ---- was it met ------------------------------------------------------
    v_ok := CASE
        WHEN mv.answered_by = 'none' THEN TRUE
        WHEN mv.answered_by = 'strike' THEN
            v_dealt >= f.max_hp * game_config_value('delve_press_share')
        ELSE p_stance = mv.answered_by
    END;

    -- ---- and what it costs -----------------------------------------------
    IF f.hp > 0 THEN
        SELECT * INTO hit FROM compute_creature_damage(
            f.species_id, p_player_id, 1.0,
            (SELECT GREATEST(0, COALESCE(pp.defense, 0)) FROM player_physique pp
             WHERE pp.player_id = p_player_id)::bigint);

        v_taken := GREATEST(
            GREATEST(0, COALESCE(hit.final_damage, 0)),
            GREATEST(1, round(
                v_max * mv.share
                * (1 + f.rage * game_config_value('delve_rage_step'))
                * st.taken_mult
                * CASE WHEN v_ok THEN game_config_value('delve_answered_share')
                       ELSE 1 END
            ))::bigint);

        v_hp := GREATEST(0, v_hp - v_taken);
    END IF;

    IF mv.builds AND NOT v_ok THEN
        UPDATE delve_fights x SET rage = x.rage + 1 WHERE x.fight_id = f.fight_id;
    END IF;

    UPDATE player_physique pp SET current_hp = v_hp
    WHERE pp.player_id = p_player_id;

    v_said := CASE WHEN v_ok AND mv.answered_by <> 'none'
                   THEN 'You read it, and it costs you a fraction of what it meant to.'
                   ELSE mv.missed_line END;

    SELECT * INTO f FROM delve_fights x WHERE x.fight_id = f.fight_id;

    -- ---- how it stands ---------------------------------------------------
    IF f.hp <= 0 THEN
        v_out := 'slain';
        FOR one IN
            SELECT cd.material_code, cd.chance, cd.min_quantity,
                   cd.max_quantity, m.name
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

        IF f.tile_kind = 'deep' THEN
            v_gu := roll_gu_drop(p_player_id, d.region_code,
                                 player_realm_rank(p_player_id));
            IF v_gu IS NOT NULL AND v_gu > 0 THEN
                v_found := v_found || jsonb_build_object(
                    'what', 'a living Gu', 'how_many', 1);
            END IF;
        END IF;

        UPDATE delve_fights x
        SET status = 'done', outcome = 'slain', ended_at = now(), coming = NULL
        WHERE x.fight_id = f.fight_id;
        UPDATE delve_tiles t SET spent = TRUE
        WHERE t.delve_id = v_delve AND t.x = f.at_x AND t.y = f.at_y;
        UPDATE delve_runs r SET status = 'walking' WHERE r.delve_id = v_delve;
        PERFORM effect_clear('delve', v_delve);

    ELSIF v_hp <= 0 THEN
        v_out := 'died';
        UPDATE delve_fights x
        SET status = 'done', outcome = 'died', ended_at = now(), coming = NULL
        WHERE x.fight_id = f.fight_id;
        PERFORM delve_end(v_delve, 'died');
        PERFORM effect_clear('delve', v_delve);

    ELSE
        v_next := delve_draw_move();
        UPDATE delve_fights x
        SET round_no = x.round_no + 1, coming = v_next
        WHERE x.fight_id = f.fight_id;
        PERFORM effect_tick('delve', v_delve);
    END IF;

    PERFORM delve_record(v_delve, v_found);

    SELECT * INTO f FROM delve_fights x WHERE x.fight_id = f.fight_id;
    SELECT * INTO d FROM delve_runs r WHERE r.delve_id = v_delve;

    RETURN QUERY SELECT f.fight_id,
        (SELECT s.name FROM creature_species s WHERE s.species_id = f.species_id),
        p_stance, v_ok, mv.code, mv.name, v_said,
        v_dealt, v_taken, COALESCE(swung.healed, 0),
        f.hp, f.max_hp, v_hp, v_max, f.rage::int, f.round_no,
        f.coming,
        (SELECT m2.telegraph FROM delve_beast_moves m2 WHERE m2.code = f.coming),
        d.status, COALESCE(f.outcome, v_out), v_found;
END;
$fn$;

COMMENT ON FUNCTION delve_act(bigint, text, bigint) IS
    'One round against a beast that has told you what it means to do. Meeting a move with its answer costs a quarter; meeting it with a press costs nearly double. The telegraph is always honest, so the whole of the fight is whether you read it.';


-- The old verb still works, and is simply the `strike` stance.
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
LANGUAGE sql
AS $fn$
    SELECT a.fight_id, a.beast_name, a.dealt, a.taken, a.healed,
           a.beast_hp, a.beast_max, a.my_hp, a.my_max, a.round_no,
           a.status, a.outcome, a.found
    FROM delve_act(p_player_id, 'strike', p_technique_id) a;
$fn$;


-- And meeting something draws its first move.
DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_meet' AND pronamespace = 'public'::regnamespace;

    anchor := concat(
'    INSERT INTO delve_fights', chr(10),
'        (delve_id, species_id, tile_kind, at_x, at_y, hp, max_hp)', chr(10),
'    VALUES (p_delve_id, v_spec, p_kind, p_x, p_y, v_pool, v_pool)');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_meet no longer opens a fight where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    INSERT INTO delve_fights', chr(10),
'        (delve_id, species_id, tile_kind, at_x, at_y, hp, max_hp, coming)', chr(10),
'    VALUES (p_delve_id, v_spec, p_kind, p_x, p_y, v_pool, v_pool,', chr(10),
'            delve_draw_move())'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Reading it is worth something, and reading it wrong costs
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p    BIGINT;
    v_id   BIGINT;
    at     RECORD;
    f      RECORD;
    r      RECORD;
    v_right BIGINT;
    v_wrong BIGINT;
    v_max  BIGINT;
BEGIN
    -- Every move has a stance that answers it, or a telegraph is a lie.
    IF EXISTS (SELECT 1 FROM delve_beast_moves m
               WHERE m.answered_by NOT IN ('none', 'strike')
                 AND NOT EXISTS (SELECT 1 FROM delve_stances s
                                 WHERE s.code = m.answered_by)) THEN
        RAISE EXCEPTION 'a move names an answer nobody can give';
    END IF;

    -- And pressing a blow you have not read really is worse than taking it.
    IF (SELECT taken_mult FROM delve_stances WHERE code = 'press') <= 1 THEN
        RAISE EXCEPTION 'pressing costs nothing, so it is never wrong';
    END IF;
    IF (SELECT deal_mult FROM delve_stances WHERE code = 'press')
       <= (SELECT deal_mult FROM delve_stances WHERE code = 'strike') THEN
        RAISE EXCEPTION 'pressing is strictly worse than striking';
    END IF;
    IF (SELECT deal_mult FROM delve_stances WHERE code = 'search') <> 0 THEN
        RAISE EXCEPTION 'searching the lair also hits it, which is free value';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT pp.max_hp INTO v_max FROM player_physique pp
        WHERE pp.player_id = v_p;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);
        SELECT r2.at_x, r2.at_y INTO at FROM delve_runs r2 WHERE r2.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'beast', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;
        PERFORM delve_step(v_p, 'up');

        SELECT * INTO f FROM delve_fights x
        WHERE x.delve_id = v_id AND x.status = 'fighting';
        IF f.coming IS NULL THEN
            RAISE EXCEPTION 'the beast is not telling anybody what it will do';
        END IF;

        -- Force a lunge and meet it correctly, then force one and press it.
        UPDATE delve_fights x SET coming = 'lunge' WHERE x.fight_id = f.fight_id;
        UPDATE player_physique pp SET current_hp = pp.max_hp WHERE pp.player_id = v_p;
        SELECT * INTO r FROM delve_act(v_p, 'guard', NULL);
        v_right := r.taken;
        IF NOT r.answered THEN
            RAISE EXCEPTION 'guarding a lunge did not answer it';
        END IF;

        UPDATE delve_fights x SET coming = 'lunge', rage = 0
        WHERE x.fight_id = f.fight_id;
        UPDATE player_physique pp SET current_hp = pp.max_hp WHERE pp.player_id = v_p;
        SELECT * INTO r FROM delve_act(v_p, 'press', NULL);
        v_wrong := r.taken;
        IF r.answered THEN
            RAISE EXCEPTION 'pressing a lunge somehow answered it';
        END IF;

        RAISE NOTICE
            'a lunge guarded takes %, the same lunge pressed takes % - % times',
            v_right, v_wrong,
            round(v_wrong::numeric / GREATEST(1, v_right), 1);

        IF v_wrong <= v_right THEN
            RAISE EXCEPTION
                'reading it wrong (%) costs no more than reading it right (%)',
                v_wrong, v_right;
        END IF;

        -- Letting it build really builds.
        UPDATE delve_fights x SET coming = 'coil', rage = 0
        WHERE x.fight_id = f.fight_id;
        PERFORM delve_act(v_p, 'guard', NULL);
        IF (SELECT x.rage FROM delve_fights x WHERE x.fight_id = f.fight_id) < 1 THEN
            RAISE EXCEPTION 'letting it finish gathering cost nothing';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
