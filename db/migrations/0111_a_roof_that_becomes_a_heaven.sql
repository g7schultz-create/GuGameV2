-- 0111_a_roof_that_becomes_a_heaven
--
-- Somewhere to put a lifetime of surplus.
--
-- This game generates far more than it consumes. The busiest cultivator on
-- the shelf carries 1,203 spirit stones, 4,498 weight of ore and 375 of beast
-- material, and there is nothing in the world that wants any of it: gear is
-- forged once and worn forever, pills are drunk in an afternoon, and the
-- auction house has never carried a single listing because nobody has a
-- reason to want money. A game with faucets and no sinks is a game whose
-- middle is a slow drift.
--
-- A dwelling is the sink. It is bought once and kept forever, it grows for as
-- long as the character does, and everything it grants is passive - which is
-- the only reward shape that suits a game whose whole thesis is that nothing
-- ticks and it is worked out when you look.
--
-- TEN STAGES, MORTAL TO IMMORTAL. It begins as a thatched hut a Rank 1
-- cultivator throws up out of reeds, and it ends as a Grotto-Heaven: a
-- pocket of the world folded in on itself, which in this setting is what a
-- Rank 8 immortal builds when they want somewhere to be. In between, the
-- ladder passes through the courtyard, the mountain retreat, the cave abode
-- and the Blessed Land - the same progression the source material runs, and
-- Rank 6 is where it stops being architecture and starts being geography,
-- because Rank 6 is where a Gu Master becomes a Gu Immortal.
--
-- IT IS DELIBERATELY EXPENSIVE. The last stage wants three hundred thousand
-- spirit stones and six hundred Spirit Jade. That is not a number anybody
-- reaches this year, and it is not meant to be: the point of a sink is that
-- it is still there when everything else has been finished. The first two
-- stages, by contrast, are within reach of a character's first afternoon,
-- because a ladder nobody can get onto is not a ladder.
--
-- WHAT IT COSTS IS WEIGHT, NOT NAMES. A stage wants so much ore and so much
-- beast material, measured in grade the way `temper_body` measures it, and
-- takes the commonest first. Naming specific materials would have made the
-- whole ladder a scavenger hunt and pinned it to today's material list.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The ladder
-- ---------------------------------------------------------------------------

CREATE TABLE dwelling_stages (
    stage           SMALLINT PRIMARY KEY CHECK (stage BETWEEN 1 AND 20),
    name            TEXT NOT NULL UNIQUE,
    emoji           TEXT NOT NULL DEFAULT '🏠',

    -- The realm you must have reached to build it. A hut needs nothing; a
    -- Grotto-Heaven needs an immortal to fold the space.
    realm_required  SMALLINT NOT NULL REFERENCES realms (realm_id) ON DELETE RESTRICT,

    -- How many facilities may stand in it at once. This is the decision the
    -- whole system exists to pose: a Cave Abode holds three, and there are
    -- ten things worth building.
    facility_slots  SMALLINT NOT NULL CHECK (facility_slots >= 0),

    stone_cost      BIGINT NOT NULL CHECK (stone_cost >= 0),
    ore_weight      BIGINT NOT NULL CHECK (ore_weight >= 0),
    beast_weight    BIGINT NOT NULL CHECK (beast_weight >= 0),
    jade_cost       BIGINT NOT NULL DEFAULT 0 CHECK (jade_cost >= 0),

    description     TEXT NOT NULL,
    flavour         TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE dwelling_stages IS
    'What a cultivator lives in, from a mortal''s roof to a folded pocket of the world. One row per rung; the costs are the sink this game did not have.';

INSERT INTO dwelling_stages
    (stage, name, emoji, realm_required, facility_slots,
     stone_cost, ore_weight, beast_weight, jade_cost, description, flavour) VALUES

    (1, 'Thatched Hut', '🛖', 1, 1,
     0, 0, 0, 0,
     'Reeds, mud and a door that does not shut. It keeps the rain off, which is more than the road does.',
     'Every immortal in the histories began somewhere they would not admit to later.'),

    (2, 'Tiled House', '🏠', 3, 1,
     60, 40, 0, 0,
     'A floor that is not earth and a roof that does not leak. Room enough to sit still in.',
     'The first thing a cultivator buys is quiet.'),

    (3, 'Walled Courtyard', '🏡', 4, 2,
     260, 200, 25, 0,
     'A wall, a gate, and a square of open ground. What happens inside is nobody else''s business.',
     'A wall is not for keeping people out. It is for marking where your attention ends.'),

    (4, 'Mountain Retreat', '🏔️', 6, 2,
     800, 700, 110, 0,
     'Far enough up that nobody climbs it by accident. The air is thinner and the qi is not.',
     'Height is the cheapest solitude there is.'),

    (5, 'Spirit Spring Manor', '⛲', 7, 3,
     2400, 2000, 340, 5,
     'Built over a vein of living water. The spring does not freeze, and neither do you.',
     'The first dwelling that gives something back instead of only keeping things out.'),

    (6, 'Cave Abode', '🕳️', 9, 3,
     6500, 5200, 950, 15,
     'A worked cavern with a sealed mouth. Stone holds qi the way a jar holds water.',
     'Cultivators have always ended up underground. The mountain is patient and does not gossip.'),

    (7, 'Sealed Cavern Mansion', '🏛️', 11, 4,
     18000, 14000, 2600, 40,
     'Halls cut back into the rock and a formation across the entrance. Nothing leaks out and nothing wanders in.',
     'By now the dwelling is worth more than everything you own that can be carried.'),

    (8, 'Immortal Cave', '🌌', 13, 4,
     52000, 40000, 7200, 110,
     'The qi inside has stopped behaving like weather and started behaving like a room.',
     'The last address a mortal can hold. Everything above this needs you to have stopped being one.'),

    (9, 'Blessed Land', '🏞️', 16, 5,
     140000, 110000, 19000, 260,
     'Not a building. A stretch of the world that has agreed with you, where the seasons come when called.',
     'A Gu Immortal does not live in a house. They live in a place that has taken their side.'),

    (10, 'Grotto-Heaven', '🌠', 22, 6,
     380000, 300000, 52000, 640,
     'A pocket of the world folded closed and kept. Inside it, time and qi answer to the owner and to nobody above them.',
     'The oldest ambition in the histories: not to be sheltered by the world, but to carry a piece of it that is yours.');


-- ---------------------------------------------------------------------------
-- Whose it is
-- ---------------------------------------------------------------------------

CREATE TABLE player_dwelling (
    player_id  BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,
    stage      SMALLINT NOT NULL DEFAULT 1
               REFERENCES dwelling_stages (stage) ON DELETE RESTRICT,
    name       TEXT,
    founded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    raised_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_dwelling_stage_idx ON player_dwelling (stage);

COMMENT ON TABLE player_dwelling IS
    'One dwelling per cultivator, kept for life. The absence of a row means they are still on the road.';

COMMENT ON COLUMN player_dwelling.name IS
    'What its owner calls it. NULL means it goes by its stage name, which is what most of them do.';


-- ---------------------------------------------------------------------------
-- Spending weight
-- ---------------------------------------------------------------------------
-- `temper_body` in 0108 already spends beast material commonest-first. The
-- dwelling wants the same thing for ore, so the loop becomes a function
-- rather than a second copy of itself.

CREATE FUNCTION material_weight_held(p_player_id BIGINT, p_kind TEXT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(pm.quantity * material_grade(m.rarity)), 0)::bigint
    FROM player_materials pm
    JOIN materials m ON m.code = pm.material_code
    WHERE pm.player_id = p_player_id
      AND pm.quantity > 0
      AND (
        (p_kind = 'ore'   AND EXISTS (SELECT 1 FROM ores o
                                      WHERE o.material_code = pm.material_code))
     OR (p_kind = 'beast' AND EXISTS (SELECT 1 FROM beast_parts bp
                                      WHERE bp.material_code = pm.material_code))
      );
$$;

COMMENT ON FUNCTION material_weight_held(BIGINT, TEXT) IS
    'Ore or beast material a cultivator holds, measured in grade. The currency every large cost in this game is quoted in.';


CREATE FUNCTION spend_material_weight(
    p_player_id BIGINT, p_kind TEXT, p_weight BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    remaining BIGINT := p_weight;
    take      BIGINT;
    part      RECORD;
    taken     JSONB := '[]'::jsonb;
BEGIN
    IF p_weight <= 0 THEN
        RETURN taken;
    END IF;

    IF material_weight_held(p_player_id, p_kind) < p_weight THEN
        RAISE EXCEPTION 'you carry % of the % weight of % this wants',
            material_weight_held(p_player_id, p_kind), p_weight, p_kind
            USING ERRCODE = 'check_violation';
    END IF;

    -- Commonest first. The rare stone is what the forge wants, and a cost
    -- that ate it while the iron sat in the bag would be a trap.
    FOR part IN
        SELECT pm.material_code, pm.quantity, material_grade(m.rarity) AS grade,
               material_name(pm.material_code) AS name
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = p_player_id AND pm.quantity > 0
          AND (
            (p_kind = 'ore'   AND EXISTS (SELECT 1 FROM ores o
                                          WHERE o.material_code = pm.material_code))
         OR (p_kind = 'beast' AND EXISTS (SELECT 1 FROM beast_parts bp
                                          WHERE bp.material_code = pm.material_code))
          )
        ORDER BY material_grade(m.rarity), pm.material_code
    LOOP
        EXIT WHEN remaining <= 0;
        take := LEAST(part.quantity, ceil(remaining::numeric / part.grade)::bigint);
        PERFORM spend_material(p_player_id, part.material_code, take);
        remaining := remaining - take * part.grade;
        taken := taken || jsonb_build_object(
            'code', part.material_code, 'name', part.name, 'quantity', take);
    END LOOP;

    RETURN taken;
END;
$$;

COMMENT ON FUNCTION spend_material_weight(BIGINT, TEXT, BIGINT) IS
    'Takes weight out of a cultivator''s stores, commonest first, and says what it took.';


-- ---------------------------------------------------------------------------
-- What is next, and whether it is within reach
-- ---------------------------------------------------------------------------

CREATE FUNCTION dwelling_next(p_player_id BIGINT)
RETURNS TABLE (
    stage          SMALLINT,
    name           TEXT,
    emoji          TEXT,
    realm_required SMALLINT,
    realm_name     TEXT,
    facility_slots SMALLINT,
    stone_cost     BIGINT,
    ore_weight     BIGINT,
    beast_weight   BIGINT,
    jade_cost      BIGINT,
    description    TEXT,
    flavour        TEXT,
    realm_ok       BOOLEAN,
    stones_ok      BOOLEAN,
    ore_ok         BOOLEAN,
    beast_ok       BOOLEAN,
    jade_ok        BOOLEAN,
    ready          BOOLEAN
)
LANGUAGE sql STABLE
AS $$
    WITH here AS (
        SELECT COALESCE((SELECT pd.stage FROM player_dwelling pd
                         WHERE pd.player_id = p_player_id), 0) AS stage
    ),
    want AS (
        SELECT s.* FROM dwelling_stages s, here WHERE s.stage = here.stage + 1
    ),
    have AS (
        SELECT
            (SELECT pc.realm_id FROM player_cultivation pc
             WHERE pc.player_id = p_player_id) AS realm,
            COALESCE((SELECT pm.quantity FROM player_materials pm
                      WHERE pm.player_id = p_player_id
                        AND pm.material_code = 'spirit_stone'), 0) AS stones,
            material_weight_held(p_player_id, 'ore') AS ore,
            material_weight_held(p_player_id, 'beast') AS beast,
            jade_held(p_player_id) AS jade
    )
    SELECT w.stage, w.name, w.emoji, w.realm_required, r.name,
           w.facility_slots, w.stone_cost, w.ore_weight, w.beast_weight,
           w.jade_cost, w.description, w.flavour,
           h.realm >= w.realm_required,
           h.stones >= w.stone_cost,
           h.ore    >= w.ore_weight,
           h.beast  >= w.beast_weight,
           h.jade   >= w.jade_cost,
           h.realm >= w.realm_required AND h.stones >= w.stone_cost
           AND h.ore >= w.ore_weight AND h.beast >= w.beast_weight
           AND h.jade >= w.jade_cost
    FROM want w JOIN realms r ON r.realm_id = w.realm_required, have h;
$$;

COMMENT ON FUNCTION dwelling_next(BIGINT) IS
    'The next rung and every gate on it, each answered separately - so a screen can say which one is in the way rather than only that something is.';


-- ---------------------------------------------------------------------------
-- Raising it
-- ---------------------------------------------------------------------------

CREATE FUNCTION raise_dwelling(p_player_id BIGINT)
RETURNS TABLE (
    stage_before SMALLINT,
    stage_after  SMALLINT,
    name_before  TEXT,
    name_after   TEXT,
    slots_after  SMALLINT,
    flavour      TEXT,
    stones_spent BIGINT,
    jade_spent   BIGINT,
    ore_spent    JSONB,
    beast_spent  JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    want  RECORD;
    was   SMALLINT;
    ores  JSONB;
    parts JSONB;
BEGIN
    SELECT * INTO want FROM dwelling_next(p_player_id);

    IF want.stage IS NULL THEN
        RAISE EXCEPTION 'a Grotto-Heaven is the last of them. There is nothing above it'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT want.realm_ok THEN
        RAISE EXCEPTION 'a % is built by a cultivator of %, and you are not one yet',
            want.name, want.realm_name
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT want.stones_ok THEN
        RAISE EXCEPTION 'a % wants % spirit stones', want.name, want.stone_cost
            USING ERRCODE = 'check_violation';
    END IF;
    IF NOT want.jade_ok THEN
        RAISE EXCEPTION 'a % wants % Spirit Jade', want.name, want.jade_cost
            USING ERRCODE = 'check_violation';
    END IF;

    -- The weight checks live inside spend_material_weight, which refuses
    -- before it takes anything - so a half-paid dwelling is not a state that
    -- can exist.
    SELECT COALESCE((SELECT pd.stage FROM player_dwelling pd
                     WHERE pd.player_id = p_player_id), 0) INTO was;

    IF want.stone_cost > 0 THEN
        PERFORM spend_material(p_player_id, 'spirit_stone', want.stone_cost);
    END IF;
    IF want.jade_cost > 0 THEN
        PERFORM spend_jade(p_player_id, want.jade_cost, 'dwelling');
    END IF;
    ores  := spend_material_weight(p_player_id, 'ore', want.ore_weight);
    parts := spend_material_weight(p_player_id, 'beast', want.beast_weight);

    INSERT INTO player_dwelling (player_id, stage)
    VALUES (p_player_id, want.stage)
    ON CONFLICT (player_id) DO UPDATE
        SET stage = EXCLUDED.stage, raised_at = now();

    RETURN QUERY
    SELECT was, want.stage,
           (SELECT s.name FROM dwelling_stages s WHERE s.stage = was),
           want.name, want.facility_slots, want.flavour,
           want.stone_cost, want.jade_cost, ores, parts;
END;
$$;

COMMENT ON FUNCTION raise_dwelling(BIGINT) IS
    'One rung up the ladder, paid in full or not at all. The only thing that moves player_dwelling.stage.';
