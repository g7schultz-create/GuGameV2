-- 0574_a_garden_in_the_dwelling
--
-- A dwelling has ten facilities and every one of them is a passive fraction -
-- a Medicine Garden raises `brew_potency`, a Spirit Field raises
-- `gathering_yield`. Nothing in a dwelling is a thing you DO. You raise it and
-- then it sits there being worth a percentage.
--
-- So: ground you plant in. Put a herb in, wait, take back more than you put.
--
-- HOW MANY PLOTS: the dwelling's own stage, one plot a stage. A Thatched Hut
-- has one square of dirt and an Immortal Cave has eight, which needs no new
-- column and means the garden grows for the same reason everything else in a
-- dwelling does.
--
-- HOW LONG: `garden_hours_per_tier` x the herb's tier. A tier 1 weed is up in
-- two hours and a tier 13 bloom takes twenty-six, so the shallow end is an
-- afternoon and the deep end is a day you plan around.
--
-- WHAT COMES BACK: `garden_yield` of them, raised by the cultivator's own
-- `gathering_yield` - which is the stat the Spirit Field facility has always
-- granted and never had anything to point at but the ground outside. A
-- dwelling that improves its own garden is the shape this should have had from
-- the start.
--
-- NOTHING TICKS, as nowhere else in this game does. A plot is ready when its
-- `ready_at` has passed, and `garden_harvest` is what notices - the same rule
-- the passive cultivation settle, the world boss spawn and the dungeon round
-- all already follow.


CREATE TABLE player_garden (
    player_id     BIGINT      NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    plot_no       SMALLINT    NOT NULL CHECK (plot_no >= 1),
    material_code TEXT        NOT NULL REFERENCES materials(code),
    planted       BIGINT      NOT NULL CHECK (planted > 0),
    planted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ready_at      TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (player_id, plot_no),
    CHECK (ready_at > planted_at)
);

COMMENT ON TABLE player_garden IS
    'What is in the ground at a cultivator''s dwelling. One row per occupied plot; an empty plot is the absence of a row rather than a row saying nothing, so the table is as long as the garden is full.';

CREATE INDEX player_garden_ready_idx ON player_garden (player_id, ready_at);


INSERT INTO game_config (key, value, description) VALUES
    ('garden_hours_per_tier', 2,
     'Hours a planted herb takes per tier of its own depth. A tier 1 weed is an afternoon; a tier 13 bloom is a day you plan around.'),
    ('garden_yield', 4,
     'How many come back for each one planted, before the cultivator''s own `gathering_yield` is added. Four is the number that makes a plot worth the wait without making gathering pointless.');


-- ---------------------------------------------------------------------------
-- How much ground there is
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION garden_plots(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- One plot a stage. A Thatched Hut has a square of dirt by the door and an
    -- Immortal Cave has eight, which is the same ladder every other thing in a
    -- dwelling climbs - and needs no column of its own to say so.
    SELECT COALESCE((SELECT d.stage FROM player_dwelling d
                     WHERE d.player_id = p_player_id), 0)::smallint;
$fn$;


CREATE OR REPLACE FUNCTION garden_ready_at(p_material_code TEXT)
RETURNS INTERVAL
LANGUAGE sql
STABLE
AS $fn$
    SELECT make_interval(hours =>
        GREATEST(1, COALESCE(m.tier, 1))
        * game_config_value('garden_hours_per_tier')::int)
    FROM materials m WHERE m.code = p_material_code;
$fn$;


-- ---------------------------------------------------------------------------
-- Putting it in
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION garden_plant(
    p_player_id BIGINT, p_material_code TEXT, p_quantity BIGINT DEFAULT 1
)
RETURNS TABLE (plot_no SMALLINT, material_name TEXT, planted BIGINT,
               ready_at TIMESTAMPTZ, plots_free SMALLINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_plots SMALLINT;
    v_used  SMALLINT;
    v_slot  SMALLINT;
    v_tier  SMALLINT;
BEGIN
    v_plots := garden_plots(p_player_id);
    IF v_plots <= 0 THEN
        RAISE EXCEPTION
            'you have no ground to plant in - a dwelling comes first'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*)::smallint INTO v_used FROM player_garden g
    WHERE g.player_id = p_player_id;
    IF v_used >= v_plots THEN
        RAISE EXCEPTION
            'every plot is already planted - % of %', v_used, v_plots
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.tier INTO v_tier FROM materials m WHERE m.code = p_material_code;
    IF v_tier IS NULL THEN
        RAISE EXCEPTION
            'that is not something that grows'
            USING ERRCODE = 'check_violation';
    END IF;
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'plant how many?' USING ERRCODE = 'check_violation';
    END IF;

    -- The lowest free plot, so a garden fills from the near end rather than
    -- scattering across the ground.
    SELECT COALESCE(min(s.n), 1)::smallint INTO v_slot
    FROM generate_series(1, v_plots) s(n)
    WHERE NOT EXISTS (SELECT 1 FROM player_garden g
                      WHERE g.player_id = p_player_id AND g.plot_no = s.n);

    -- Refuses rather than going negative, so a short bag costs nothing.
    PERFORM spend_material(p_player_id, p_material_code, p_quantity);

    INSERT INTO player_garden
        (player_id, plot_no, material_code, planted, ready_at)
    VALUES (p_player_id, v_slot, p_material_code, p_quantity,
            now() + garden_ready_at(p_material_code));

    RETURN QUERY
    SELECT v_slot, material_name(p_material_code), p_quantity,
           now() + garden_ready_at(p_material_code),
           (v_plots - v_used - 1)::smallint;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- Taking it out
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION garden_harvest(p_player_id BIGINT)
RETURNS TABLE (plot_no SMALLINT, material_code TEXT, material_name TEXT,
               planted BIGINT, picked BIGINT)
LANGUAGE plpgsql
AS $fn$
DECLARE
    r     RECORD;
    v_out BIGINT;
    v_mul NUMERIC;
BEGIN
    -- The cultivator's own hand with growing things, which until now the
    -- Spirit Field raised and had nothing to raise it ON.
    v_mul := game_config_value('garden_yield')
             * (1 + COALESCE(player_stat(p_player_id, 'gathering_yield'), 0));

    FOR r IN
        SELECT g.plot_no, g.material_code, g.planted
        FROM player_garden g
        WHERE g.player_id = p_player_id AND g.ready_at <= now()
        ORDER BY g.plot_no
    LOOP
        v_out := GREATEST(1, round(r.planted * v_mul))::bigint;
        PERFORM grant_material(p_player_id, r.material_code, v_out);

        DELETE FROM player_garden g
        WHERE g.player_id = p_player_id AND g.plot_no = r.plot_no;

        RETURN QUERY SELECT r.plot_no, r.material_code,
                            material_name(r.material_code), r.planted, v_out;
    END LOOP;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_mat  TEXT;
    v_got  RECORD;
    v_n    INTEGER;
    v_had  BIGINT;
    v_now  BIGINT;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1201, 'garden-probe') RETURNING player_id INTO v_who;

        -- 1. NO DWELLING, NO GROUND.
        BEGIN
            PERFORM garden_plant(v_who, 'spirit_dew_grass', 1);
            RAISE EXCEPTION 'somebody with no dwelling planted a garden';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        INSERT INTO player_dwelling (player_id, stage) VALUES (v_who, 3);

        IF garden_plots(v_who) <> 3 THEN
            RAISE EXCEPTION 'a stage 3 dwelling has % plots', garden_plots(v_who);
        END IF;

        -- 2. PLANTING TAKES THE SEED AND FILLS THE NEAREST PLOT.
        SELECT code INTO v_mat FROM materials WHERE tier = 1 LIMIT 1;
        PERFORM grant_material(v_who, v_mat, 10);

        SELECT * INTO v_got FROM garden_plant(v_who, v_mat, 4);
        IF v_got.plot_no <> 1 THEN
            RAISE EXCEPTION 'the first planting went into plot %', v_got.plot_no;
        END IF;

        SELECT quantity INTO v_had FROM player_materials
        WHERE player_id = v_who AND material_code = v_mat;
        IF v_had <> 6 THEN
            RAISE EXCEPTION 'planting four of ten left % in the bag', v_had;
        END IF;

        -- 3. AND IT IS NOT READY YET. A garden that pays at once is a button,
        --    not a garden.
        SELECT count(*) INTO v_n FROM garden_harvest(v_who);
        IF v_n > 0 THEN
            RAISE EXCEPTION 'a plot was harvestable the moment it was planted';
        END IF;

        -- 4. ONCE THE TIME HAS PASSED, IT PAYS MORE THAN WENT IN.
        -- The WHOLE planting is moved back, not just the ripening:
        -- `ready_at > planted_at` is a real invariant and the probe tripped
        -- over it by ageing one end only. A plot cannot come up before it went
        -- in, and the constraint should go on saying so.
        UPDATE player_garden
        SET planted_at = now() - interval '2 hours',
            ready_at   = now() - interval '1 minute'
        WHERE player_id = v_who;

        SELECT * INTO v_got FROM garden_harvest(v_who);
        IF v_got.picked <= v_got.planted THEN
            RAISE EXCEPTION
                'four planted came back as % - a garden that loses you seed is '
                'a worse shelf than a bag', v_got.picked;
        END IF;
        RAISE NOTICE
            'four planted came back as % after the wait', v_got.picked;

        -- 5. AND THE PLOT IS FREE AGAIN.
        IF EXISTS (SELECT 1 FROM player_garden WHERE player_id = v_who) THEN
            RAISE EXCEPTION 'the plot is still occupied after harvest';
        END IF;

        -- 6. THE GROUND RUNS OUT. Three plots is three.
        PERFORM grant_material(v_who, v_mat, 10);
        PERFORM garden_plant(v_who, v_mat, 1);
        PERFORM garden_plant(v_who, v_mat, 1);
        PERFORM garden_plant(v_who, v_mat, 1);
        BEGIN
            PERFORM garden_plant(v_who, v_mat, 1);
            RAISE EXCEPTION 'a stage 3 dwelling planted a fourth plot';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 7. AND NOBODY'S GARDEN EXISTS YET, so no live dwelling changed.
    IF EXISTS (SELECT 1 FROM player_garden) THEN
        RAISE EXCEPTION 'somebody already has something in the ground';
    END IF;
END
$probe$;
