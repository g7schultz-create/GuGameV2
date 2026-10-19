-- 0582_a_farm_for_the_eggs
--
-- There are 1405 unhatched eggs in the live world and nothing to do with all
-- but a handful of them. `hatch_egg` turns one into a pet, only one pet may
-- walk at your heel, and the other 1404 sit on the shelf forever:
--
--     pashu0 288    clearwest 245    sylvrime 214    m_i_y_u_k_i. 201
--
-- A pen is the second thing an egg can be for. Put it in the ground, pay
-- immortal essence, wait, and then choose: butcher it for beast materials, or
-- take the grown thing as a beast.
--
-- NOTHING TICKS, as nowhere else in this game. A pen is ready when its hour has
-- passed and `farm_butcher`/`farm_hatch` are what notice - the same shape the
-- garden uses, for the same reason.
--
-- THE EGG LEAVES THE SHELF. `farm_place` DELETES the `player_beast_eggs` row
-- and keeps species, tier, rarity and where it was found on the pen, exactly as
-- `garden_plant` takes the herb out of the satchel. The alternative - leaving
-- the row and marking it - would mean teaching every reader of the shelf a new
-- rule, and this game's recurring bug is a guard that moved while a reader did
-- not. `farm_hatch` writes the egg row back and calls `hatch_egg`, so hatching
-- still has exactly ONE definition and the beast's `egg_id` still points at the
-- egg it came out of.
--
-- WHAT IT COSTS, measured rather than guessed. Essence is the gate and time is
-- the bill:
--
--     a tier 9 egg   81 * 50 = 4050 essence value, and 27 hours
--     a tier 1 egg         50 essence value, and 3 hours
--
-- Worth saying plainly: for an essence-rich cultivator that gate is not a gate.
-- clearwest holds 52 billion in essence value, so 4050 is a rounding error and
-- the real limit is pens times hours. grafv, on 58 eggs and ZERO essence,
-- cannot use the farm at all. Both of those follow from "immortal essence is
-- needed" being the spec; `farm_essence_per_tier` is the dial if the first
-- should bite harder.
--
-- PENS come off the dwelling stage, the same ladder the garden's plots climb -
-- nine at an Immortal Cave, none without a dwelling.


INSERT INTO game_config (key, value, description) VALUES
    ('farm_hours_per_tier', 3,
     'Hours per tier of egg that a pen needs before the thing in it is grown. A tier 9 egg takes 27.'),
    ('farm_essence_per_tier', 50,
     'Immortal essence VALUE needed per tier squared to pen an egg. Paid with any immortal essence at its own unit_value, so a tier 9 egg wants 4050 - which is a gate for a mortal and a rounding error for a hoarder.'),
    ('farm_butcher_per_tier', 2,
     'Multiplies every beast material a butchered pen yields, by the egg''s tier. Every drop on the species table lands, because the thing was raised deliberately rather than met in a field.');


-- ---------------------------------------------------------------------------
-- The pens
-- ---------------------------------------------------------------------------

CREATE TABLE player_farm (
    player_id    BIGINT      NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    pen_no       SMALLINT    NOT NULL CHECK (pen_no >= 1),
    species_id   BIGINT      NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    tier         SMALLINT    NOT NULL CHECK (tier >= 1 AND tier <= 10),
    rarity       TEXT        NOT NULL REFERENCES rarities(code) ON DELETE RESTRICT,
    -- Kept so `farm_hatch` can write the egg row back as it was.
    found_in     TEXT        REFERENCES regions(code) ON DELETE SET NULL,
    essence_code TEXT        NOT NULL REFERENCES materials(code) ON DELETE RESTRICT,
    essence_paid BIGINT      NOT NULL CHECK (essence_paid > 0),
    penned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    ready_at     TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (player_id, pen_no)
);

-- The composite key leads on player_id, so a read of one farm is covered. The
-- rest are the halves of a foreign key nobody thinks about until a species or a
-- region is touched and Postgres scans the lot.
CREATE INDEX player_farm_ready_idx   ON player_farm (player_id, ready_at);
CREATE INDEX player_farm_species_idx ON player_farm (species_id);
CREATE INDEX player_farm_rarity_idx  ON player_farm (rarity);
CREATE INDEX player_farm_region_idx  ON player_farm (found_in);
CREATE INDEX player_farm_essence_idx ON player_farm (essence_code);


-- ---------------------------------------------------------------------------
-- What a pen costs and how long it takes
-- ---------------------------------------------------------------------------

CREATE FUNCTION farm_pens(p_player_id BIGINT) RETURNS SMALLINT
LANGUAGE sql STABLE AS $$
    -- One pen a stage, the same ladder `garden_plots` climbs. A dwelling comes
    -- first; a cultivator sleeping under a tree has nowhere to put a beast.
    SELECT COALESCE((SELECT d.stage FROM player_dwelling d
                     WHERE d.player_id = p_player_id), 0)::smallint;
$$;

CREATE FUNCTION farm_ready_in(p_tier SMALLINT) RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT make_interval(hours => GREATEST(1, p_tier)
                                  * game_config_value('farm_hours_per_tier')::int);
$$;

CREATE FUNCTION farm_essence_needed(p_tier SMALLINT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    -- Squared, the way this game prices everything that scales with a tier.
    SELECT GREATEST(1, p_tier)::numeric ^ 2
           * game_config_value('farm_essence_per_tier');
$$;


-- ---------------------------------------------------------------------------
-- Putting one in
-- ---------------------------------------------------------------------------

CREATE FUNCTION farm_place(p_player_id BIGINT, p_egg_id BIGINT, p_essence_code TEXT)
RETURNS TABLE (pen_no SMALLINT, beast_name TEXT, tier SMALLINT, rarity TEXT,
               essence_name TEXT, essence_spent BIGINT, ready_at TIMESTAMPTZ,
               pens_free INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    egg     RECORD;
    v_pens  SMALLINT;
    v_pen   SMALLINT;
    v_unit  BIGINT;
    v_need  NUMERIC;
    v_qty   BIGINT;
    v_ready TIMESTAMPTZ;
BEGIN
    SELECT e.*, cs.name AS species_name
    INTO egg
    FROM player_beast_eggs e
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE e.egg_id = p_egg_id AND e.owner_id = p_player_id
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that egg is not yours' USING ERRCODE = 'check_violation';
    END IF;
    IF egg.hatched_at IS NOT NULL THEN
        RAISE EXCEPTION 'that one has already hatched'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM trade_offer_eggs oe
               JOIN trades tr ON tr.trade_id = oe.trade_id
               WHERE oe.egg_id = p_egg_id
                 AND tr.status NOT IN ('complete', 'cancelled')) THEN
        RAISE EXCEPTION 'that egg is on the table in a trade'
            USING ERRCODE = 'check_violation';
    END IF;

    v_pens := farm_pens(p_player_id);
    IF v_pens <= 0 THEN
        RAISE EXCEPTION
            'you have nowhere to keep a beast - a dwelling comes first'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The lowest empty pen, so the numbers a cultivator reads stay stable.
    SELECT n INTO v_pen
    FROM generate_series(1, v_pens) AS n
    WHERE NOT EXISTS (SELECT 1 FROM player_farm f
                      WHERE f.player_id = p_player_id AND f.pen_no = n)
    ORDER BY n LIMIT 1;

    IF v_pen IS NULL THEN
        RAISE EXCEPTION 'all % of your pens are full', v_pens
            USING ERRCODE = 'check_violation';
    END IF;

    -- IMMORTAL ESSENCE ONLY, and `beast_food_is_essence` is the one place that
    -- knows what counts as some - the same answer `feed_beast` gets.
    IF NOT beast_food_is_essence(p_essence_code) THEN
        RAISE EXCEPTION '% is not immortal essence',
            COALESCE(material_name(p_essence_code), p_essence_code)
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT ie.unit_value INTO v_unit FROM immortal_essences ie
    WHERE ie.material_code = p_essence_code;

    v_need := farm_essence_needed(egg.tier);
    -- Paid in whatever essence is handed over, at what that essence is worth.
    -- A deeper essence therefore goes further, which is what being deeper means.
    v_qty  := GREATEST(1, ceil(v_need / v_unit))::bigint;

    PERFORM spend_material(p_player_id, p_essence_code, v_qty);

    v_ready := now() + farm_ready_in(egg.tier);

    INSERT INTO player_farm
        (player_id, pen_no, species_id, tier, rarity, found_in,
         essence_code, essence_paid, ready_at)
    VALUES (p_player_id, v_pen, egg.species_id, egg.tier, egg.rarity,
            egg.found_in, p_essence_code, v_qty, v_ready);

    -- OFF THE SHELF, like a herb out of the satchel. `farm_hatch` writes it
    -- back if the thing is taken rather than butchered.
    DELETE FROM player_beast_eggs WHERE egg_id = p_egg_id;

    RETURN QUERY
    SELECT v_pen, egg.species_name, egg.tier, egg.rarity,
           material_name(p_essence_code), v_qty, v_ready,
           (v_pens - (SELECT count(*) FROM player_farm f
                      WHERE f.player_id = p_player_id))::integer;
END;
$$;


-- ---------------------------------------------------------------------------
-- Butchering one
-- ---------------------------------------------------------------------------

CREATE FUNCTION farm_butcher(p_player_id BIGINT, p_pen_no SMALLINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, emoji TEXT, quantity BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    pen  RECORD;
    one  RECORD;
    v_mul NUMERIC;
    v_qty BIGINT;
BEGIN
    SELECT f.*, cs.name AS species_name
    INTO pen
    FROM player_farm f
    JOIN creature_species cs ON cs.species_id = f.species_id
    WHERE f.player_id = p_player_id AND f.pen_no = p_pen_no
    FOR UPDATE OF f;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing in pen %', p_pen_no
            USING ERRCODE = 'check_violation';
    END IF;
    IF pen.ready_at > now() THEN
        RAISE EXCEPTION '% is not grown yet', pen.species_name
            USING ERRCODE = 'check_violation';
    END IF;

    v_mul := pen.tier * game_config_value('farm_butcher_per_tier');

    -- EVERY DROP ON THE TABLE LANDS, once. No chance gate, because this one was
    -- raised on purpose rather than met in a field - and ONE roll each, not the
    -- whole table several times over, which is the shape that made a single
    -- delve corpse worth four sets of notes before 0578 capped it.
    FOR one IN
        SELECT cd.material_code AS code, cd.min_quantity, cd.max_quantity,
               m.name, m.emoji
        FROM creature_drops cd
        JOIN materials m ON m.code = cd.material_code
        WHERE cd.species_id = pen.species_id
        ORDER BY cd.material_code
    LOOP
        v_qty := GREATEST(1, round(
            (one.min_quantity
             + floor(random() * (one.max_quantity - one.min_quantity + 1)))
            * v_mul))::bigint;

        PERFORM grant_material(p_player_id, one.code, v_qty);

        RETURN QUERY SELECT one.code, one.name, one.emoji, v_qty;
    END LOOP;

    DELETE FROM player_farm
    WHERE player_id = p_player_id AND pen_no = p_pen_no;
END;
$$;


-- ---------------------------------------------------------------------------
-- Or taking it as a beast
-- ---------------------------------------------------------------------------

CREATE FUNCTION farm_hatch(p_player_id BIGINT, p_pen_no SMALLINT)
RETURNS TABLE (beast_id BIGINT, beast_name TEXT, stage TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    pen    RECORD;
    v_egg  BIGINT;
    v_made BIGINT;
BEGIN
    SELECT f.*, cs.name AS species_name
    INTO pen
    FROM player_farm f
    JOIN creature_species cs ON cs.species_id = f.species_id
    WHERE f.player_id = p_player_id AND f.pen_no = p_pen_no
    FOR UPDATE OF f;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing in pen %', p_pen_no
            USING ERRCODE = 'check_violation';
    END IF;
    IF pen.ready_at > now() THEN
        RAISE EXCEPTION '% is not grown yet', pen.species_name
            USING ERRCODE = 'check_violation';
    END IF;

    -- THE EGG ROW GOES BACK so `hatch_egg` can do the hatching. One definition
    -- of what hatching is, rather than a second copy here that drifts.
    INSERT INTO player_beast_eggs (owner_id, species_id, tier, rarity, found_in)
    VALUES (p_player_id, pen.species_id, pen.tier, pen.rarity, pen.found_in)
    RETURNING egg_id INTO v_egg;

    v_made := hatch_egg(p_player_id, v_egg);

    -- RAISED, NOT CRACKED. It spent its hours in the pen and ate essence, so it
    -- comes out a rung above the thing that walks out of an egg on the shelf.
    -- Juvenile and no further: `feed_beast` is still the whole rest of the
    -- ladder, and the pen is not a way around it.
    UPDATE player_beasts SET stage = 'juvenile' WHERE player_beasts.beast_id = v_made;

    DELETE FROM player_farm
    WHERE player_id = p_player_id AND pen_no = p_pen_no;

    RETURN QUERY
    SELECT b.beast_id, b.name, s.name
    FROM player_beasts b
    JOIN beast_stages s ON s.code = b.stage
    WHERE b.beast_id = v_made;
END;
$$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_sp    BIGINT;
    v_egg   BIGINT;
    v_put   RECORD;
    v_cut   RECORD;
    v_rows  INTEGER;
    v_bad   TEXT;
    v_beast RECORD;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1104, 'farm-probe') RETURNING player_id INTO v_who;

        -- A species that actually drops something, or the butcher probe proves
        -- nothing. This is the mistake 0554's first probe made.
        SELECT cd.species_id INTO v_sp
        FROM creature_drops cd GROUP BY cd.species_id
        HAVING count(*) >= 2 LIMIT 1;

        -- 0. NO DWELLING, NO PEN.
        PERFORM grant_beast_egg(v_who, v_sp, 3::smallint, 'rare', NULL);
        SELECT e.egg_id INTO v_egg FROM player_beast_eggs e
        WHERE e.owner_id = v_who LIMIT 1;
        PERFORM grant_material(v_who, 'dewberry_essence', 100000);

        BEGIN
            PERFORM farm_place(v_who, v_egg, 'dewberry_essence');
            RAISE EXCEPTION 'an egg was penned by somebody with no dwelling';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        INSERT INTO player_dwelling (player_id, stage) VALUES (v_who, 2)
        ON CONFLICT (player_id) DO UPDATE SET stage = 2;

        -- 1. PENNING TAKES THE EGG OFF THE SHELF AND CHARGES ESSENCE.
        SELECT * INTO v_put FROM farm_place(v_who, v_egg, 'dewberry_essence');
        IF EXISTS (SELECT 1 FROM player_beast_eggs WHERE egg_id = v_egg) THEN
            RAISE EXCEPTION 'the penned egg is still on the shelf';
        END IF;
        IF v_put.essence_spent <> farm_essence_needed(3::smallint) THEN
            RAISE EXCEPTION
                'a tier 3 egg cost % dewberry essence against a need of %',
                v_put.essence_spent, farm_essence_needed(3::smallint);
        END IF;
        IF (SELECT quantity FROM player_materials
            WHERE player_id = v_who AND material_code = 'dewberry_essence')
           <> 100000 - v_put.essence_spent THEN
            RAISE EXCEPTION 'the essence was reported spent but not taken';
        END IF;
        RAISE NOTICE
            'pen % holds a tier 3 % for % essence, grown %',
            v_put.pen_no, v_put.beast_name, v_put.essence_spent, v_put.ready_at;

        -- 2. AND IT IS NOT READY YET. A pen that could be cut open at once
        --    would make the whole clock decorative.
        BEGIN
            PERFORM farm_butcher(v_who, v_put.pen_no);
            RAISE EXCEPTION 'a pen was butchered before its hours had passed';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- 3. ONCE GROWN, BUTCHERING PAYS BEAST MATERIALS - every drop on the
        --    species table, and nothing that is not a beast material.
        UPDATE player_farm SET ready_at = now() - interval '1 minute'
        WHERE player_id = v_who AND pen_no = v_put.pen_no;

        SELECT count(*) INTO v_rows FROM farm_butcher(v_who, v_put.pen_no);
        IF v_rows = 0 THEN
            RAISE EXCEPTION 'butchering a grown pen yielded nothing at all';
        END IF;

        SELECT string_agg(m.code, ', ') INTO v_bad
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = v_who AND pm.quantity > 0
          AND m.category <> 'beast' AND m.code <> 'dewberry_essence';
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'butchering also handed over: %', v_bad;
        END IF;

        IF EXISTS (SELECT 1 FROM player_farm
                   WHERE player_id = v_who AND pen_no = v_put.pen_no) THEN
            RAISE EXCEPTION 'the butchered pen is still occupied';
        END IF;
        RAISE NOTICE 'butchering a tier 3 pen paid % kinds of beast material', v_rows;

        -- 4. OR IT CAN BE TAKEN AS A BEAST, a rung above a cracked egg, and the
        --    beast still points at an egg row.
        PERFORM grant_beast_egg(v_who, v_sp, 2::smallint, 'rare', NULL);
        SELECT e.egg_id INTO v_egg FROM player_beast_eggs e
        WHERE e.owner_id = v_who AND e.hatched_at IS NULL LIMIT 1;
        SELECT * INTO v_put FROM farm_place(v_who, v_egg, 'dewberry_essence');
        UPDATE player_farm SET ready_at = now() - interval '1 minute'
        WHERE player_id = v_who AND pen_no = v_put.pen_no;

        SELECT * INTO v_beast FROM farm_hatch(v_who, v_put.pen_no);
        IF v_beast.stage <> 'Juvenile' THEN
            RAISE EXCEPTION 'a raised beast came out at the % stage', v_beast.stage;
        END IF;
        IF (SELECT b.egg_id FROM player_beasts b
            WHERE b.beast_id = v_beast.beast_id) IS NULL THEN
            RAISE EXCEPTION 'the raised beast points at no egg';
        END IF;
        RAISE NOTICE 'taking one out of the pen gave % at %',
            v_beast.beast_name, v_beast.stage;

        -- 5. PENS ARE BOUNDED BY THE DWELLING. Stage 2 is two pens, and a third
        --    egg has nowhere to go.
        FOR v_rows IN 1..3 LOOP
            PERFORM grant_beast_egg(v_who, v_sp, 1::smallint, 'common', NULL);
        END LOOP;

        BEGIN
            FOR v_egg IN
                SELECT e.egg_id FROM player_beast_eggs e
                WHERE e.owner_id = v_who AND e.hatched_at IS NULL
            LOOP
                PERFORM farm_place(v_who, v_egg, 'dewberry_essence');
            END LOOP;
            RAISE EXCEPTION
                'a stage 2 dwelling took more than its % pens',
                farm_pens(v_who);
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        IF (SELECT count(*) FROM player_farm WHERE player_id = v_who)
           > farm_pens(v_who) THEN
            RAISE EXCEPTION 'the farm holds more pens than the dwelling allows';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
