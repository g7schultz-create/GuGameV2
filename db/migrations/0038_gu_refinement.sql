-- 0038_gu_refinement
--
-- Materials become Gu.
--
-- 0036 said it plainly: whole Gu off a corpse are a 2% drip, and the roster
-- document is explicit that materials drop often BECAUSE materials are what Gu
-- refinement consumes. This is that system, and it is now the main way a Gu is
-- acquired.
--
-- THREE INGREDIENTS, THREE DIFFERENT JOBS. The request names them; each is
-- given a job the other two cannot do.
--
--   base       - a GATHERING material, in bulk. What the Gu is made of. It is
--                the cost, and it is what makes a high-rank Gu expensive.
--   secondary  - a BEAST material, a fraction of the count. What the Gu
--                becomes: a Wolf Enslavement Gu wants a wolf's fang in it.
--   auxiliary  - anything, any amount, the player's choice, and not required
--                at all. This is the only ingredient with a decision in it.
--
-- 0017 wrote that gathering materials feed Gu refinement and beast materials
-- feed physique cultivation. That still holds - physique cultivation is
-- unwritten and will have the beast economy to itself in bulk. Refining takes
-- beast materials in small counts, as the thing that gives a heap of gold ore
-- a nature, and the split is enforced on the recipe rather than trusted.
--
-- COST SCALES ON TWO AXES. A rank 4 Gu costs eleven times a rank 1 by rank
-- alone, and a legendary six times a common by rarity. Both live in tables
-- keyed by rank and by rarity, so the whole economy retunes with an UPDATE
-- rather than with 35 hand-typed quantities that will drift apart.
--
-- POTENCY BUYS THE CEILING, HARMONY DECIDES HOW MUCH OF IT YOU KEEP. That is
-- the same one idea 0026 refines manuals with, and it is what makes auxiliary
-- materials a decision instead of a tax: rare materials in volume raise the
-- star ceiling, and only Paths that agree with the Gu let you reach it. Pile
-- in something the Gu's Path fights and the whole attempt can come apart.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Materials get a Path
-- ---------------------------------------------------------------------------
-- Without one there is no question to ask about an auxiliary material beyond
-- how much of it there is, and "put in more" is not a decision. With one, the
-- matchup chart the whole game already runs on answers "does this belong in
-- this Gu" for free - the same way it answers "do these pages refine" in 0026.
--
-- Nullable, because a material with no Path is a real possibility for later
-- content and it has an honest meaning: it adds bulk and no opinion.

ALTER TABLE materials ADD COLUMN path_code TEXT
    REFERENCES paths (code) ON DELETE SET NULL;

CREATE INDEX materials_path_idx ON materials (path_code);

COMMENT ON COLUMN materials.path_code IS
    'What Dao a material leans toward. Gu refinement reads it to decide whether an ingredient belongs; NULL means it has no opinion.';

UPDATE materials m SET path_code = v.path
FROM (VALUES
    -- Central Continent
    ('refinement_stone','refinement'),('wisdom_flower','wisdom'),('rule_fragment','rule'),
    ('spirit_rice','food'),('human_qi_stone','human'),('crescent_stone','light'),
    ('imperial_lotus_seed','heaven'),('purple_crystal','refinement'),('aspiring_stone','dream'),
    ('chilling_grass','ice'),('nine_palace_flowers','formation'),('jade_apicot_blossom','wood'),
    ('autumn_voice_grass','wind'),('brave_heart_fragment','strength'),('spirit_stone','qi'),
    -- Western Desert
    ('fire_stone','fire'),('desert_sand','earth'),('gold_ore','metal'),
    ('mirage_sand','illusion'),('golden_root','metal'),('gold_dust','metal'),
    ('awakening_crystal','soul'),('sand_storm_core','wind'),('oasis_water','water'),
    ('flame_sand','fire'),('metal_ore','metal'),('copper_shavings','metal'),
    ('silver_sand','metal'),('iron_filing','metal'),('fire_spirit_stone','fire'),
    -- Eastern Sea
    ('coral','water'),('deep_sea_essence','water'),('star_shell','star'),
    ('water_spirit_stone','water'),('sea_salt','water'),('tide_stone','water'),
    ('ocean_crystal','water'),('star_fragment','star'),('cloud_mist_stone','ice'),
    -- Northern Plains
    ('wind_grass','wind'),('strength_stone','strength'),('blood_flower','blood'),
    ('strength_herb','strength'),('iron_ore','metal'),('dark_iron','metal'),
    ('autumn_leaf','wood'),('storm_crystal','lightning'),('frozen_essence','ice'),
    ('grassland_herbs','wood'),('thunder_stone','lightning'),('temporal_dust','time'),
    -- Southern Border
    ('spirit_grass','qi'),('jade_leaf','wood'),('jade_bamboo','wood'),
    ('poison_herb','poison'),('mountain_rock','earth'),('earth_spirit_stone','earth'),
    ('moon_orchid','light'),('jade_shavings','earth'),('wine_grass','food'),
    ('hope_flower','dream'),('spring_water','water'),('purified_water','water'),
    ('nine_leaf_vitality_grass','wood'),('life_breath_grass','qi'),
    ('six_divine_grass','heaven'),('young_autumn_grass','wind'),
    ('water_chestnut_grass','water'),('skull_stones','bone'),('worry_stones','soul'),
    ('milk_tea_flower','food'),('earth_treasury_flower','earth'),('clear_chance_grass','luck'),
    ('steep_cliff_grass','earth'),('shame_plum','poison'),('pain_crystal','blood'),
    ('tree_bark','wood'),
    -- Beast materials
    ('lingzhi_meat','food'),('heroic_soul','soul'),('golden_crow_essence','fire'),
    ('scorpion_stinger','poison'),('centipede_venom','poison'),('poison_heart','poison'),
    ('soul_pearl','soul'),('soul_crystal','soul'),('pearl','water'),
    ('fish_scale_shard','water'),('dragon_scale','transformation'),
    ('dragon_whale_bone','bone'),('cicada_shell','transformation'),
    ('cicada_essence','transformation'),('life_essence','blood'),
    ('skull_fragment','bone'),('blood_coral','blood'),('wolf_fang','strength'),
    ('wolf_pelt','strength'),('beast_blood','blood'),('boar_tusk','strength'),
    ('black_boar_tusk','strength'),('bone_fragment','bone'),('bone_spear_tip','bone'),
    ('beast_core','qi'),('iron_bone','bone'),('snake_gall','poison'),
    ('eagle_feather','wind'),('venom_sac','poison'),('tiger_fang','strength'),
    ('tormented_soul','soul'),('footless_bird','wind')
) AS v (code, path)
WHERE m.code = v.code;


-- ---------------------------------------------------------------------------
-- spend_material
-- ---------------------------------------------------------------------------
-- The counterpart to `grant_material` from 0017. One statement, so two
-- commands racing cannot both spend the last of a stack, and a shortfall says
-- what is short rather than tripping the quantity CHECK with a constraint name.

CREATE FUNCTION spend_material(p_player_id BIGINT, p_code TEXT, p_quantity BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    remaining BIGINT;
BEGIN
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'nothing to spend' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE player_materials pm
    SET quantity = pm.quantity - p_quantity
    WHERE pm.player_id = p_player_id
      AND pm.material_code = p_code
      AND pm.quantity >= p_quantity
    RETURNING pm.quantity INTO remaining;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you need % %, and have %',
            p_quantity, material_name(p_code),
            COALESCE((SELECT held.quantity FROM player_materials held
                      WHERE held.player_id = p_player_id
                        AND held.material_code = p_code), 0)
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN remaining;
END;
$$;


-- ---------------------------------------------------------------------------
-- Professions
-- ---------------------------------------------------------------------------
-- Sparse rows rather than a table per craft, for the reason `player_cooldowns`
-- gives: a second profession should be an INSERT and not a migration that
-- copies four columns and a level formula.
--
-- `player_refinement` from 0026 is deliberately left where it is. Folding it
-- in would mean rewriting `refine()`, which works, to buy nothing today - and
-- these migrations are forward-only, so being wrong about that is permanent.
-- The profession after this one lands here instead.

CREATE TABLE professions (
    code          TEXT PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,

    -- Linear, like Refinement's. A curve can become a column later.
    exp_per_level NUMERIC(10, 2) NOT NULL CHECK (exp_per_level > 0),

    description   TEXT NOT NULL DEFAULT ''
);

INSERT INTO professions (code, name, exp_per_level, description) VALUES
    ('gu_refining', 'Gu Refiner', 150,
     'Turns regional materials into Gu. Level decides which ranks may be attempted and how many auxiliary materials fit on the bench.');

CREATE TABLE player_professions (
    player_id  BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    profession TEXT   NOT NULL REFERENCES professions (code) ON DELETE CASCADE,

    exp        BIGINT   NOT NULL DEFAULT 0 CHECK (exp >= 0),
    -- Derived from exp, stored because it is read on every attempt. Kept in
    -- step on write and never edited alone, the same discipline
    -- player_refinement.level follows.
    level      SMALLINT NOT NULL DEFAULT 1 CHECK (level >= 1),

    successes  INTEGER  NOT NULL DEFAULT 0 CHECK (successes >= 0),
    failures   INTEGER  NOT NULL DEFAULT 0 CHECK (failures >= 0),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, profession)
);

CREATE INDEX player_professions_profession_idx ON player_professions (profession);

CREATE TRIGGER player_professions_set_updated_at
    BEFORE UPDATE ON player_professions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE FUNCTION profession_level_for_exp(p_profession TEXT, p_exp BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, 1 + floor(p_exp / p.exp_per_level))::smallint
    FROM professions p WHERE p.code = p_profession;
$$;

CREATE FUNCTION profession_level(p_player_id BIGINT, p_profession TEXT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT pp.level FROM player_professions pp
         WHERE pp.player_id = p_player_id AND pp.profession = p_profession),
        1
    );
$$;

CREATE FUNCTION grant_profession_exp(
    p_player_id BIGINT, p_profession TEXT, p_exp BIGINT, p_succeeded BOOLEAN
) RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_level SMALLINT;
BEGIN
    INSERT INTO player_professions (player_id, profession, exp, level, successes, failures)
    VALUES (p_player_id, p_profession, p_exp,
            profession_level_for_exp(p_profession, p_exp),
            CASE WHEN p_succeeded THEN 1 ELSE 0 END,
            CASE WHEN p_succeeded THEN 0 ELSE 1 END)
    ON CONFLICT (player_id, profession) DO UPDATE SET
        exp       = player_professions.exp + EXCLUDED.exp,
        level     = profession_level_for_exp(p_profession,
                                             player_professions.exp + EXCLUDED.exp),
        successes = player_professions.successes + EXCLUDED.successes,
        failures  = player_professions.failures + EXCLUDED.failures
    RETURNING player_professions.level INTO new_level;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- What a Gu costs to make
-- ---------------------------------------------------------------------------
-- Two tables rather than a quantity typed onto each of the 35 recipes: rank
-- says how much of anything a Gu of that rank swallows, rarity says how much
-- harder this particular one is to come by. A recipe therefore carries only
-- WHICH materials, never HOW MANY, and the economy retunes in nine rows.

CREATE TABLE gu_refine_costs (
    rank               SMALLINT PRIMARY KEY CHECK (rank BETWEEN 1 AND 9),

    base_quantity      INTEGER  NOT NULL CHECK (base_quantity > 0),
    secondary_quantity INTEGER  NOT NULL CHECK (secondary_quantity > 0),

    required_level     SMALLINT NOT NULL DEFAULT 1 CHECK (required_level >= 1),
    exp_reward         INTEGER  NOT NULL CHECK (exp_reward > 0)
);

-- Steep on purpose: the request asks that a higher tier take far more material
-- than a lower one, and a rank 4 Gu should be a season's work rather than an
-- afternoon's. PLACEHOLDER numbers - the shape is the point, not the digits.
INSERT INTO gu_refine_costs (rank, base_quantity, secondary_quantity, required_level, exp_reward) VALUES
    (1,   8,   4,  1,   60),
    (2,  20,  10,  4,  150),
    (3,  45,  22,  9,  320),
    (4,  90,  45, 15,  600),
    (5, 160,  80, 22, 1000),
    (6, 260, 130, 30, 1600),
    (7, 400, 200, 40, 2400),
    (8, 600, 300, 52, 3400),
    (9, 900, 450, 65, 4600);

CREATE TABLE gu_refine_rarity_costs (
    rarity     TEXT PRIMARY KEY REFERENCES rarities (code) ON DELETE CASCADE,
    multiplier NUMERIC(6, 2) NOT NULL CHECK (multiplier > 0)
);

INSERT INTO gu_refine_rarity_costs (rarity, multiplier) VALUES
    ('common', 1.00), ('uncommon', 1.50), ('rare', 2.50), ('epic', 4.00),
    ('legendary', 6.00), ('mythic', 9.00), ('unique', 14.00), ('extreme', 14.00);


-- ---------------------------------------------------------------------------
-- gu_recipes
-- ---------------------------------------------------------------------------

CREATE TABLE gu_recipes (
    gu_type_id         BIGINT PRIMARY KEY
                       REFERENCES gu_types (gu_type_id) ON DELETE CASCADE,

    base_material      TEXT NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,
    secondary_material TEXT NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    CONSTRAINT gu_recipes_two_ingredients CHECK (base_material <> secondary_material)
);

CREATE INDEX gu_recipes_base_idx      ON gu_recipes (base_material);
CREATE INDEX gu_recipes_secondary_idx ON gu_recipes (secondary_material);

-- The base/secondary split is the design, so it is enforced rather than
-- trusted - exactly as 0017 enforces which economy a drop table may name.
CREATE FUNCTION check_recipe_ingredients()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.base_material) <> 'gathering' THEN
        RAISE EXCEPTION 'a recipe base is a gathering material, got %', NEW.base_material;
    END IF;
    IF (SELECT category FROM materials WHERE code = NEW.secondary_material) <> 'beast' THEN
        RAISE EXCEPTION 'a recipe secondary is a beast material, got %', NEW.secondary_material;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER gu_recipes_respect_the_split
    BEFORE INSERT OR UPDATE ON gu_recipes
    FOR EACH ROW EXECUTE FUNCTION check_recipe_ingredients();

-- Every Gu in the game is refinable. Refinement is the intended main source,
-- so a Gu with no recipe would be a Gu nobody can plan for.
INSERT INTO gu_recipes (gu_type_id, base_material, secondary_material)
SELECT t.gu_type_id, v.base, v.secondary
FROM (VALUES
    -- Central Continent
    ('bookworm',                      'wisdom_flower',       'lingzhi_meat'),
    ('moonlight_gu',                  'crescent_stone',      'pearl'),
    ('hope_gu',                       'aspiring_stone',      'heroic_soul'),
    ('rice_bag_grass_gu',             'spirit_rice',         'lingzhi_meat'),
    ('liquor_worm',                   'wine_grass',          'cicada_essence'),
    ('signal_gu',                     'human_qi_stone',      'eagle_feather'),

    -- Western Desert
    ('ghost_fire_gu',                 'awakening_crystal',   'tormented_soul'),
    ('stone_skin_gu',                 'desert_sand',         'cicada_shell'),
    ('golden_needle_gu',              'gold_dust',           'bone_spear_tip'),
    ('golden_centipede_gu',           'gold_ore',            'centipede_venom'),
    ('copper_skin_gu',                'copper_shavings',     'iron_bone'),

    -- Eastern Sea
    ('fish_scale_gu',                 'sea_salt',            'fish_scale_shard'),
    ('fish_enslavement_gu',           'tide_stone',          'fish_scale_shard'),
    ('cleansing_water_gu',            'water_spirit_stone',  'pearl'),
    ('scale_armor_gu',                'coral',               'dragon_scale'),
    ('icicle_gu',                     'cloud_mist_stone',    'bone_spear_tip'),
    ('water_spider_gu',               'ocean_crystal',       'venom_sac'),

    -- Northern Plains
    ('bear_strength_gu',              'brave_heart_fragment','beast_core'),
    ('wolf_enslavement_gu',           'grassland_herbs',     'wolf_fang'),
    ('big_strength_gu',               'strength_herb',       'boar_tusk'),
    ('bronze_skin_gu',                'dark_iron',           'iron_bone'),
    ('carapace_gu',                   'mountain_rock',       'cicada_shell'),
    ('white_boar_gu',                 'strength_stone',      'boar_tusk'),
    ('black_boar_gu',                 'strength_stone',      'black_boar_tusk'),
    ('brute_force_longhorn_beetle_gu','strength_stone',      'tiger_fang'),
    ('all_out_effort_gu',             'blood_flower',        'heroic_soul'),
    ('battle_bone_wheel',             'skull_stones',        'dragon_whale_bone'),

    -- Southern Border
    ('poison_needle_gu',              'poison_herb',         'scorpion_stinger'),
    ('grass_puppet_gu',               'jade_bamboo',         'cicada_shell'),
    ('mudskin_toad',                  'mountain_rock',       'beast_blood'),
    ('jade_skin_gu',                  'jade_leaf',           'snake_gall'),
    ('bone_bamboo_gu',                'skull_stones',        'bone_fragment'),
    ('venom_sac_gu',                  'shame_plum',          'venom_sac'),
    ('moonshadow_gu',                 'moon_orchid',         'soul_crystal'),
    ('spiral_bone_spear_gu',          'skull_stones',        'bone_spear_tip')
) AS v (gu_code, base, secondary)
JOIN gu_types t ON t.code = v.gu_code;

CREATE VIEW gu_recipe_costs AS
SELECT
    r.gu_type_id,
    t.code       AS gu_code,
    t.name       AS gu_name,
    t.emoji,
    t.rank,
    t.rarity,
    t.path_code,
    t.size,
    t.category,
    r.base_material,
    ceil(c.base_quantity * m.multiplier)::integer      AS base_quantity,
    r.secondary_material,
    ceil(c.secondary_quantity * m.multiplier)::integer AS secondary_quantity,
    c.required_level,
    c.exp_reward
FROM gu_recipes r
JOIN gu_types t               ON t.gu_type_id = r.gu_type_id
JOIN gu_refine_costs c        ON c.rank = t.rank
JOIN gu_refine_rarity_costs m ON m.rarity = t.rarity;

COMMENT ON VIEW gu_recipe_costs IS
    'A recipe with its quantities resolved. Recipes name materials; rank and rarity decide how many.';


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('gu_refine_same_path', 10,
     'Harmony an ingredient contributes when it shares the Gu''s Path. Scored here because the matchup chart has nothing to say about a Path and itself.'),
    ('gu_refine_aux_unit', 3,
     'Units of an auxiliary material that make one measure. Below one measure it still counts, in proportion.'),
    ('gu_refine_aux_measures', 3,
     'Measures beyond which more of the same auxiliary material stops helping. Variety is the only way past it.'),
    ('gu_refine_aux_base', 2,
     'Auxiliary materials a novice Gu Refiner can hold on the bench at once.'),
    ('gu_refine_aux_per_levels', 4,
     'Gu Refiner levels per additional auxiliary material.'),
    ('gu_refine_aux_max', 8,
     'Hard ceiling on auxiliary materials in one refinement.'),
    ('gu_refine_failure_threshold', 25,
     'Harmony below this and the Gu never forms.'),
    ('gu_refine_refund', 0.5,
     'Fraction of every material handed back when a refinement fails. Even a failure is not a total loss.');

CREATE FUNCTION gu_refine_aux_slots(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('gu_refine_aux_max'),
        game_config_value('gu_refine_aux_base')
        + floor(p_level / game_config_value('gu_refine_aux_per_levels'))
    )::smallint;
$$;


-- ---------------------------------------------------------------------------
-- material_affinity
-- ---------------------------------------------------------------------------
-- Whether a material belongs in a Gu of a given Path.
--
-- `pair_harmony` answers this for every pair the matchup chart or the
-- refinement overrides have an opinion about, which is most of them. The one
-- case it deliberately declines is a Path against itself: in MANUAL refinement
-- repetition is rewarded separately, by dominance. Here there is no dominance
-- to reward it with, and a Fire material in a Fire Gu is the plainest good
-- idea in the system, so it is scored here instead.

CREATE FUNCTION material_affinity(p_material TEXT, p_path TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    mine TEXT;
BEGIN
    SELECT m.path_code INTO mine FROM materials m WHERE m.code = p_material;

    IF mine IS NULL THEN
        RETURN 0;          -- bulk, and no opinion
    END IF;
    IF mine = p_path THEN
        RETURN game_config_value('gu_refine_same_path');
    END IF;
    RETURN pair_harmony(mine, p_path);
END;
$$;

COMMENT ON FUNCTION material_affinity(TEXT, TEXT) IS
    'How well a material sits in a Gu of a Path. The matchup chart answers it, except for a Path against itself, which refinement scores as agreement.';


-- ---------------------------------------------------------------------------
-- gu_refine_grades
-- ---------------------------------------------------------------------------
-- Stars need BOTH: enough material of enough quality to justify them, and
-- enough harmony to have kept it. One row per star, two thresholds, and the
-- query is a single `max(stars) WHERE both are met` - which is the lesser of
-- the two ladders without anyone having to write a LEAST.

CREATE TABLE gu_refine_grades (
    stars       SMALLINT PRIMARY KEY CHECK (stars BETWEEN 1 AND 5),
    min_potency NUMERIC(6, 2) NOT NULL CHECK (min_potency >= 0),
    min_harmony SMALLINT      NOT NULL CHECK (min_harmony >= 0)
);

INSERT INTO gu_refine_grades (stars, min_potency, min_harmony) VALUES
    (1,  0,   0),
    (2,  6,  40),
    (3, 14,  70),
    (4, 26,  95),
    (5, 42, 120);


-- ---------------------------------------------------------------------------
-- refine_gu
-- ---------------------------------------------------------------------------
-- The whole bench in one call: ingredients checked, materials spent, harmony
-- and potency scored, and either a Gu or half of everything back.
--
-- Auxiliary materials arrive as two parallel arrays rather than as rows in a
-- pending-bench table. A bench is one player choosing, with nothing at stake
-- until they press the button - unlike a trade, where the pile has to live in
-- the database because the rules there protect one player from another.
-- Ownership is still proved, at the moment the material is spent.

CREATE FUNCTION refine_gu(
    p_player_id      BIGINT,
    p_gu_type_id     BIGINT,
    p_aux_codes      TEXT[]    DEFAULT '{}',
    p_aux_quantities INTEGER[] DEFAULT '{}'
)
RETURNS TABLE (
    succeeded     BOOLEAN,
    harmony_score SMALLINT,
    potency_score NUMERIC,
    stars_made    SMALLINT,
    new_gu_id     BIGINT,
    made_name     TEXT,
    exp_gained    BIGINT,
    level_after   SMALLINT,
    spent_total   BIGINT,
    handed_back   BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    recipe   gu_recipe_costs%ROWTYPE;
    skill    SMALLINT;
    slots    SMALLINT;
    n_aux    INTEGER;
    i        INTEGER;
    a_code   TEXT;
    a_qty    INTEGER;
    measures NUMERIC;
    h        NUMERIC := 50;
    potency  NUMERIC := 0;
    spent    BIGINT  := 0;
    back     BIGINT  := 0;
    final_h  SMALLINT;
    stars    SMALLINT;
    gained   BIGINT;
    lvl      SMALLINT;
    made     BIGINT;
    pair     RECORD;
BEGIN
    -- ---- the recipe -----------------------------------------------------
    SELECT * INTO recipe FROM gu_recipe_costs c WHERE c.gu_type_id = p_gu_type_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'that Gu cannot be refined' USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'gu_refining');
    IF skill < recipe.required_level THEN
        RAISE EXCEPTION 'a % takes Gu Refiner level %, and you are level %',
            recipe.gu_name, recipe.required_level, skill
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- the auxiliaries ------------------------------------------------
    n_aux := COALESCE(array_length(p_aux_codes, 1), 0);
    IF n_aux <> COALESCE(array_length(p_aux_quantities, 1), 0) THEN
        RAISE EXCEPTION 'every auxiliary material needs a quantity'
            USING ERRCODE = 'check_violation';
    END IF;

    slots := gu_refine_aux_slots(skill);
    IF n_aux > slots THEN
        RAISE EXCEPTION 'your bench holds % auxiliary materials, not %', slots, n_aux
            USING ERRCODE = 'check_violation';
    END IF;

    IF n_aux <> (SELECT count(DISTINCT x) FROM unnest(p_aux_codes) AS x) THEN
        RAISE EXCEPTION 'name each auxiliary material once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_aux_codes && ARRAY[recipe.base_material, recipe.secondary_material] THEN
        RAISE EXCEPTION 'the base and the secondary are already in the recipe'
            USING ERRCODE = 'check_violation';
    END IF;

    CREATE TEMP TABLE _aux ON COMMIT DROP AS
    SELECT u.code, u.quantity, m.path_code,
           ra.sort_order / 10.0 AS potency_per_measure
    FROM unnest(p_aux_codes, p_aux_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    JOIN rarities ra ON ra.code = m.rarity;

    IF (SELECT count(*) FROM _aux) <> n_aux THEN
        RAISE EXCEPTION 'one of those auxiliary materials does not exist'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM _aux WHERE quantity <= 0) THEN
        RAISE EXCEPTION 'an auxiliary material with none of it in is not on the bench'
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- spend ----------------------------------------------------------
    -- A shortfall raises, which unwinds the whole call: nothing is ever half
    -- spent, so the order these come out in decides only which message the
    -- player reads first.
    PERFORM spend_material(p_player_id, recipe.base_material, recipe.base_quantity);
    PERFORM spend_material(p_player_id, recipe.secondary_material, recipe.secondary_quantity);
    spent := recipe.base_quantity + recipe.secondary_quantity;

    FOR i IN 1..n_aux LOOP
        PERFORM spend_material(p_player_id, p_aux_codes[i], p_aux_quantities[i]);
        spent := spent + p_aux_quantities[i];
    END LOOP;

    -- ---- harmony --------------------------------------------------------
    h := h + material_affinity(recipe.base_material, recipe.path_code);
    h := h + material_affinity(recipe.secondary_material, recipe.path_code);
    h := h + skill * 0.75;

    FOR a_code, a_qty, measures IN
        SELECT x.code, x.quantity,
               LEAST(game_config_value('gu_refine_aux_measures'),
                     x.quantity::numeric / game_config_value('gu_refine_aux_unit'))
        FROM _aux x
    LOOP
        h := h + material_affinity(a_code, recipe.path_code) * measures;
        potency := potency + measures
                   * (SELECT x.potency_per_measure FROM _aux x WHERE x.code = a_code);
    END LOOP;

    -- Auxiliaries argue with each other as well as with the Gu. Halved,
    -- because a bench of eight would otherwise be decided entirely by the
    -- twenty-eight pairs among them.
    FOR pair IN
        SELECT a.path_code AS pa, b.path_code AS pb
        FROM (SELECT DISTINCT path_code FROM _aux WHERE path_code IS NOT NULL) a
        JOIN (SELECT DISTINCT path_code FROM _aux WHERE path_code IS NOT NULL) b
          ON a.path_code < b.path_code
    LOOP
        h := h + pair_harmony(pair.pa, pair.pb) * 0.5;
    END LOOP;

    h := h + (random() * 8 - 4);
    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- outcome --------------------------------------------------------
    IF final_h < game_config_value('gu_refine_failure_threshold') THEN
        back := floor(recipe.base_quantity * game_config_value('gu_refine_refund'));
        IF back > 0 THEN
            PERFORM grant_material(p_player_id, recipe.base_material, back);
        END IF;

        i := floor(recipe.secondary_quantity * game_config_value('gu_refine_refund'));
        IF i > 0 THEN
            PERFORM grant_material(p_player_id, recipe.secondary_material, i);
            back := back + i;
        END IF;

        FOR a_code, a_qty IN
            SELECT x.code,
                   floor(x.quantity * game_config_value('gu_refine_refund'))::integer
            FROM _aux x
        LOOP
            IF a_qty > 0 THEN
                PERFORM grant_material(p_player_id, a_code, a_qty);
                back := back + a_qty;
            END IF;
        END LOOP;

        gained := GREATEST(10, recipe.exp_reward / 3);
        lvl := grant_profession_exp(p_player_id, 'gu_refining', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, round(potency, 2), NULL::smallint,
                            NULL::bigint, NULL::text, gained, lvl, spent, back;
        RETURN;
    END IF;

    SELECT COALESCE(max(g.stars), 1) INTO stars
    FROM gu_refine_grades g
    WHERE g.min_potency <= potency AND g.min_harmony <= final_h;

    -- Refined rather than found, so `found_in` stays NULL: nowhere is where
    -- this one came from.
    INSERT INTO player_gu (owner_id, gu_type_id, stars, harmony)
    VALUES (p_player_id, p_gu_type_id, stars, final_h)
    RETURNING gu_id INTO made;

    gained := recipe.exp_reward;
    lvl := grant_profession_exp(p_player_id, 'gu_refining', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, round(potency, 2), stars,
                        made, recipe.gu_name, gained, lvl, spent, 0::bigint;
END;
$$;

COMMENT ON FUNCTION refine_gu(BIGINT, BIGINT, TEXT[], INTEGER[]) IS
    'Materials to Gu. Rank and rarity set the cost; auxiliary potency sets the star ceiling and harmony decides how much of it survives.';
