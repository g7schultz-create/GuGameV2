-- 0112_what_stands_inside_it
--
-- The dwelling is the container. This is what goes in it, and the decision.
--
-- A ladder of ten stages that only ever grants "more of everything" would be
-- a number going up. What makes it a system is that a Cave Abode holds THREE
-- facilities and there are ten worth building - so a cultivator has to decide
-- what their home is FOR. The alchemist's abode and the smith's abode are
-- different places, and neither is wrong.
--
-- EVERY FACILITY GRANTS A NORMAL EFFECT. `dwelling_stat` joins the same
-- `gu_effects` vocabulary as Gu, gear, physiques and roots, so a Meditation
-- Chamber's cultivation speed adds to a manual's exactly the way two Gu add
-- to each other - additively, under the same cap, with no new arithmetic
-- anywhere. A facility is not a special case; it is a fifth grantor.
--
-- PHYSIQUE RATE IS A NEW WORD, AND IT FIXES AN OLD ASYMMETRY.
-- `settle_passive_cultivation` has always read `player_stat('cultivation_rate')`
-- and had no equivalent line for the body, so gear and Gu that claim to
-- strengthen a cultivator did nothing for the pillar named after it. The
-- Training Yard needs that word to exist, and wiring it fixes the gap for
-- everything else at the same time.
--
-- SLOTS ARE CHECKED WHERE THEY CANNOT BE BYPASSED. A trigger, not the command
-- that happens to be writing - the same call 0046 made about the body path.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The word the body was missing
-- ---------------------------------------------------------------------------

INSERT INTO gu_effects (code, name, emoji, cap, is_live, sort_order, description)
VALUES ('physique_rate', 'Body Tempering Speed', '💪', 1.0000, TRUE, 115,
        'How much faster the body tempers while you are away. The physique''s answer to Cultivation Speed.');


-- ---------------------------------------------------------------------------
-- The catalogue
-- ---------------------------------------------------------------------------

CREATE TABLE dwelling_facilities (
    code         TEXT PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,
    emoji        TEXT NOT NULL DEFAULT '🧱',

    effect_code  TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    -- What one level is worth. Levels are linear; the stages are where the
    -- curve lives.
    per_level    NUMERIC(6, 4) NOT NULL CHECK (per_level > 0),
    max_level    SMALLINT NOT NULL CHECK (max_level BETWEEN 1 AND 20),

    -- Which dwelling it first becomes possible to build. A Spirit Spring
    -- needs a manor to sit in.
    min_stage    SMALLINT NOT NULL REFERENCES dwelling_stages (stage) ON DELETE RESTRICT,

    -- Cost of the FIRST level; each level after multiplies by the growth.
    stone_cost   BIGINT NOT NULL CHECK (stone_cost >= 0),
    ore_weight   BIGINT NOT NULL CHECK (ore_weight >= 0),
    beast_weight BIGINT NOT NULL CHECK (beast_weight >= 0),

    description  TEXT NOT NULL,
    sort_order   SMALLINT NOT NULL DEFAULT 0
);

COMMENT ON TABLE dwelling_facilities IS
    'What may be built inside a dwelling. Each grants an ordinary effect, so nothing downstream needs to know these exist.';

INSERT INTO game_config (key, value, description) VALUES
    ('facility_level_growth', 1.85,
     'What each level of a facility multiplies the previous level''s cost by.');

INSERT INTO dwelling_facilities
    (code, name, emoji, effect_code, per_level, max_level, min_stage,
     stone_cost, ore_weight, beast_weight, description, sort_order) VALUES

    ('meditation_chamber', 'Meditation Chamber', '🧘', 'cultivation_rate',
     0.0200, 10, 1, 40, 30, 0,
     'A room with nothing in it. The whole point is that there is nothing in it.', 10),

    ('training_yard', 'Training Yard', '💪', 'physique_rate',
     0.0200, 10, 1, 40, 35, 5,
     'Packed earth, a stone to lift, and a post to hit until the hitting means something.', 20),

    ('spirit_field', 'Spirit Field', '🌿', 'gathering_yield',
     0.0250, 8, 2, 90, 60, 0,
     'Worked ground that gives back more than was put in, which is the whole trick of it.', 30),

    ('medicine_garden', 'Medicine Garden', '⚗️', 'brew_potency',
     0.0200, 6, 3, 200, 150, 30,
     'Herbs grown where you can watch them, picked at the hour they are worth picking.', 40),

    ('forge_shed', 'Forge Shed', '🔨', 'forge_power',
     0.0200, 6, 3, 200, 220, 30,
     'A hearth that stays hot and a floor that has stopped catching fire.', 50),

    ('worm_room', 'Worm Room', '🐛', 'gu_potency',
     0.0200, 6, 4, 400, 300, 90,
     'Dark, damp and quiet, kept at the temperature the things inside prefer.', 60),

    ('spirit_spring', 'Spirit Spring', '💧', 'max_qi',
     0.0300, 6, 5, 900, 700, 150,
     'Water that comes up warm out of the rock and does not run out.', 70),

    ('beast_pen', 'Beast Pen', '🐗', 'beast_damage',
     0.0200, 6, 5, 900, 800, 300,
     'Live specimens, studied at leisure rather than at the moment they are trying to kill you.', 80),

    ('scripture_loft', 'Scripture Loft', '📖', 'resource_find',
     0.0200, 6, 6, 1800, 1400, 350,
     'Everything anybody wrote down about where things are found, and the quiet to read it in.', 90),

    ('ward_array', 'Ward Array', '🛡️', 'damage_reduction',
     0.0150, 5, 7, 4000, 3600, 1200,
     'A formation cut into the threshold. It does not stop a blow; it disagrees with it.', 100);


-- ---------------------------------------------------------------------------
-- What is actually built
-- ---------------------------------------------------------------------------

CREATE TABLE player_facilities (
    player_id BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    facility  TEXT   NOT NULL REFERENCES dwelling_facilities (code) ON DELETE RESTRICT,
    level     SMALLINT NOT NULL DEFAULT 1 CHECK (level >= 1),
    built_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_id, facility)
);

CREATE INDEX player_facilities_facility_idx ON player_facilities (facility);

COMMENT ON TABLE player_facilities IS
    'One row per thing standing in a dwelling. The count is capped by the dwelling''s slots, by trigger.';


-- A slot count enforced by whichever command happens to be writing is not
-- enforced. This is the same call 0046 made about the body path.
CREATE FUNCTION enforce_facility_slots() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    slots SMALLINT;
    built INTEGER;
BEGIN
    SELECT s.facility_slots INTO slots
    FROM player_dwelling pd
    JOIN dwelling_stages s ON s.stage = pd.stage
    WHERE pd.player_id = NEW.player_id;

    IF slots IS NULL THEN
        RAISE EXCEPTION 'you have nowhere to build it'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO built
    FROM player_facilities pf WHERE pf.player_id = NEW.player_id;

    IF built > slots THEN
        RAISE EXCEPTION
            'your dwelling has room for % and you have built %',
            slots, built
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER player_facilities_fit_the_dwelling
    AFTER INSERT ON player_facilities
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_facility_slots();


-- ---------------------------------------------------------------------------
-- The fifth grantor
-- ---------------------------------------------------------------------------

CREATE FUNCTION dwelling_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(f.per_level * pf.level), 0)
    FROM player_facilities pf
    JOIN dwelling_facilities f ON f.code = pf.facility
    WHERE pf.player_id = p_player_id AND f.effect_code = p_effect;
$$;

COMMENT ON FUNCTION dwelling_stat(BIGINT, TEXT) IS
    'What a cultivator''s home is worth in one effect. The fifth grantor beside Gu, gear, physique and root.';


CREATE OR REPLACE FUNCTION player_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        (SELECT ef.cap FROM gu_effects ef WHERE ef.code = p_effect),
        gu_stat(p_player_id, p_effect)
        + equipment_stat(p_player_id, p_effect)
        + physique_stat(p_player_id, p_effect)
        + root_stat(p_player_id, p_effect)
        + dwelling_stat(p_player_id, p_effect)
    );
$$;


-- ---------------------------------------------------------------------------
-- Building and improving
-- ---------------------------------------------------------------------------

CREATE FUNCTION facility_cost(p_facility TEXT, p_level SMALLINT)
RETURNS TABLE (stone_cost BIGINT, ore_weight BIGINT, beast_weight BIGINT)
LANGUAGE sql STABLE
AS $$
    -- Level 1 is the listed price; every level after multiplies.
    SELECT round(f.stone_cost * power(game_config_value('facility_level_growth'),
                                      p_level - 1))::bigint,
           round(f.ore_weight * power(game_config_value('facility_level_growth'),
                                      p_level - 1))::bigint,
           round(f.beast_weight * power(game_config_value('facility_level_growth'),
                                        p_level - 1))::bigint
    FROM dwelling_facilities f WHERE f.code = p_facility;
$$;

COMMENT ON FUNCTION facility_cost(TEXT, SMALLINT) IS
    'What raising a facility TO this level costs. Level 1 is the price of building it at all.';


CREATE FUNCTION build_facility(p_player_id BIGINT, p_facility TEXT)
RETURNS TABLE (
    facility     TEXT,
    name         TEXT,
    emoji        TEXT,
    level_before SMALLINT,
    level_after  SMALLINT,
    effect_name  TEXT,
    effect_now   NUMERIC,
    stones_spent BIGINT,
    ore_spent    JSONB,
    beast_spent  JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    spec  dwelling_facilities%ROWTYPE;
    stage SMALLINT;
    slots SMALLINT;
    built INTEGER;
    was   SMALLINT := 0;
    want  SMALLINT;
    price RECORD;
    ores  JSONB;
    parts JSONB;
BEGIN
    SELECT * INTO spec FROM dwelling_facilities WHERE code = p_facility;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is no such thing as a %', p_facility
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pd.stage, s.facility_slots INTO stage, slots
    FROM player_dwelling pd
    JOIN dwelling_stages s ON s.stage = pd.stage
    WHERE pd.player_id = p_player_id;

    IF stage IS NULL THEN
        RAISE EXCEPTION 'you have nowhere to build it. **/dwelling** raises a first roof'
            USING ERRCODE = 'check_violation';
    END IF;

    IF stage < spec.min_stage THEN
        RAISE EXCEPTION 'a % wants at least a %',
            spec.name, (SELECT s.name FROM dwelling_stages s WHERE s.stage = spec.min_stage)
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pf.level INTO was FROM player_facilities pf
    WHERE pf.player_id = p_player_id AND pf.facility = p_facility;
    was := COALESCE(was, 0);

    IF was >= spec.max_level THEN
        RAISE EXCEPTION 'your % is as good as one gets', spec.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- A new facility needs a free slot; improving one already standing does
    -- not, which is what makes a full dwelling a decision rather than a wall.
    IF was = 0 THEN
        SELECT count(*) INTO built FROM player_facilities pf
        WHERE pf.player_id = p_player_id;
        IF built >= slots THEN
            RAISE EXCEPTION
                'your dwelling holds % and all of them are taken. Raise it, or improve what stands',
                slots
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    want := was + 1;
    SELECT * INTO price FROM facility_cost(p_facility, want);

    IF price.stone_cost > 0 THEN
        PERFORM spend_material(p_player_id, 'spirit_stone', price.stone_cost);
    END IF;
    ores  := spend_material_weight(p_player_id, 'ore', price.ore_weight);
    parts := spend_material_weight(p_player_id, 'beast', price.beast_weight);

    INSERT INTO player_facilities (player_id, facility, level)
    VALUES (p_player_id, p_facility, want)
    ON CONFLICT (player_id, facility) DO UPDATE SET level = EXCLUDED.level;

    RETURN QUERY
    SELECT spec.code, spec.name, spec.emoji, was, want,
           (SELECT e.name FROM gu_effects e WHERE e.code = spec.effect_code),
           spec.per_level * want,
           price.stone_cost, ores, parts;
END;
$$;

COMMENT ON FUNCTION build_facility(BIGINT, TEXT) IS
    'Builds a facility, or raises one already standing by a level. The only thing that writes player_facilities.';
