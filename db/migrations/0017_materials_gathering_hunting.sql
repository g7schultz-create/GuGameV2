-- 0017_materials_gathering_hunting
--
-- Two material economies, an inventory to hold them, and the two ways to fill
-- it: gathering what grows in a region, and killing what lives there.
--
-- THE SPLIT. Materials divide into two disjoint sets that feed different
-- systems and are acquired differently:
--
--   'gathering' - herbs, ores, stones, waters. Found in a region, taken with
--                 /gather (and later from caches guarded by beasts). These are
--                 what Gu refinement will consume.
--   'beast'     - fangs, pelts, blood, bone, scale, venom, soul. Dropped by
--                 creatures on a kill. These are what physique cultivation
--                 will consume.
--
-- One `materials` table with a category rather than two tables, because an
-- inventory row, a stack size and a display name are identical for both and a
-- second table would double every one of those. Where they differ is where
-- they come from, and that is expressed by which side table references them:
-- `region_materials` for gathering, `creature_drops` for beast.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- materials
-- ---------------------------------------------------------------------------

CREATE TABLE materials (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,

    category    TEXT NOT NULL CHECK (category IN ('gathering', 'beast')),

    -- Bands the roll, and drives the display colour. Same ladder roots and
    -- physiques use, so "rare" means one thing across the whole game.
    rarity      TEXT NOT NULL DEFAULT 'common'
                REFERENCES rarities (code) ON DELETE RESTRICT,

    description TEXT NOT NULL DEFAULT ''
);

CREATE INDEX materials_category_idx ON materials (category, rarity);
CREATE INDEX materials_rarity_idx ON materials (rarity);

COMMENT ON TABLE materials IS
    'Two disjoint economies in one table: gathering materials feed Gu refinement, beast materials feed physique cultivation.';

-- Names are derived from the code rather than typed twice: every code in this
-- content set is already the display name in snake_case, and a hand-typed
-- second copy is a hand-typed second chance to disagree.
CREATE FUNCTION material_name(p_code TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
    SELECT initcap(replace(p_code, '_', ' '));
$$;


-- ---------------------------------------------------------------------------
-- Gathering materials, by region
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity)
SELECT code, material_name(code), 'gathering', rarity
FROM (VALUES
    -- Central Continent
    ('refinement_stone','uncommon'),('wisdom_flower','uncommon'),('rule_fragment','rare'),
    ('spirit_rice','common'),('human_qi_stone','uncommon'),('crescent_stone','uncommon'),
    ('imperial_lotus_seed','rare'),('purple_crystal','uncommon'),('aspiring_stone','common'),
    ('chilling_grass','common'),('nine_palace_flowers','rare'),('jade_apicot_blossom','uncommon'),
    ('autumn_voice_grass','common'),('brave_heart_fragment','uncommon'),('spirit_stone','common'),
    -- Western Desert
    ('fire_stone','common'),('desert_sand','common'),('gold_ore','uncommon'),
    ('mirage_sand','uncommon'),('golden_root','rare'),('gold_dust','common'),
    ('awakening_crystal','rare'),('sand_storm_core','rare'),('oasis_water','uncommon'),
    ('flame_sand','common'),('metal_ore','common'),('copper_shavings','common'),
    ('silver_sand','uncommon'),('iron_filing','common'),('fire_spirit_stone','uncommon'),
    -- Eastern Sea
    ('coral','common'),('deep_sea_essence','rare'),('star_shell','rare'),
    ('water_spirit_stone','uncommon'),('sea_salt','common'),('tide_stone','common'),
    ('ocean_crystal','uncommon'),('star_fragment','rare'),('cloud_mist_stone','uncommon'),
    -- Northern Plains
    ('wind_grass','common'),('strength_stone','uncommon'),('blood_flower','rare'),
    ('strength_herb','common'),('iron_ore','common'),('dark_iron','uncommon'),
    ('autumn_leaf','common'),('storm_crystal','rare'),('frozen_essence','uncommon'),
    ('grassland_herbs','common'),('thunder_stone','uncommon'),('temporal_dust','rare'),
    -- Southern Border
    ('spirit_grass','common'),('jade_leaf','common'),('jade_bamboo','common'),
    ('poison_herb','common'),('mountain_rock','common'),('earth_spirit_stone','uncommon'),
    ('moon_orchid','rare'),('jade_shavings','common'),('wine_grass','common'),
    ('hope_flower','rare'),('spring_water','common'),('purified_water','uncommon'),
    ('nine_leaf_vitality_grass','rare'),('life_breath_grass','uncommon'),
    ('six_divine_grass','rare'),('young_autumn_grass','common'),
    ('water_chestnut_grass','common'),('skull_stones','uncommon'),('worry_stones','common'),
    ('milk_tea_flower','common'),('earth_treasury_flower','rare'),('clear_chance_grass','uncommon'),
    ('steep_cliff_grass','common'),('shame_plum','uncommon'),('pain_crystal','rare'),
    ('tree_bark','common')
) AS v (code, rarity);


-- ---------------------------------------------------------------------------
-- Beast materials
-- ---------------------------------------------------------------------------
-- Everything anatomical: what you cut off a thing rather than pick up.

INSERT INTO materials (code, name, category, rarity)
SELECT code, material_name(code), 'beast', rarity
FROM (VALUES
    ('lingzhi_meat','common'),('heroic_soul','rare'),('golden_crow_essence','rare'),
    ('scorpion_stinger','common'),('centipede_venom','common'),('poison_heart','uncommon'),
    ('soul_pearl','rare'),('soul_crystal','uncommon'),
    ('pearl','uncommon'),('fish_scale_shard','common'),('dragon_scale','rare'),
    ('dragon_whale_bone','rare'),('cicada_shell','common'),('cicada_essence','uncommon'),
    ('life_essence','rare'),('skull_fragment','common'),('blood_coral','uncommon'),
    ('wolf_fang','common'),('wolf_pelt','common'),('beast_blood','common'),
    ('boar_tusk','common'),('black_boar_tusk','uncommon'),('bone_fragment','common'),
    ('bone_spear_tip','uncommon'),('beast_core','rare'),('iron_bone','rare'),
    ('snake_gall','uncommon'),('eagle_feather','common'),
    ('venom_sac','common'),('tiger_fang','uncommon'),('tormented_soul','rare'),
    ('footless_bird','rare')
) AS v (code, rarity);


-- ---------------------------------------------------------------------------
-- region_materials
-- ---------------------------------------------------------------------------
-- What can be gathered where, and how often it comes up. Weight is relative
-- within a region, so a region's table needs no normalising when a material is
-- added to it.
--
-- Beast materials are deliberately absent: they come off creatures, and a
-- region that hands out fangs for foraging makes hunting pointless.

CREATE TABLE region_materials (
    region_code   TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,
    material_code TEXT NOT NULL REFERENCES materials (code) ON DELETE CASCADE,

    weight        NUMERIC(8, 4) NOT NULL DEFAULT 1 CHECK (weight > 0),

    PRIMARY KEY (region_code, material_code)
);

CREATE INDEX region_materials_material_idx ON region_materials (material_code);

-- Weight falls with rarity, so a common herb turns up far more than a rare one
-- without either needing a hand-set number.
INSERT INTO region_materials (region_code, material_code, weight)
SELECT v.region, m.code,
       CASE m.rarity WHEN 'common' THEN 10 WHEN 'uncommon' THEN 4 ELSE 1 END
FROM (VALUES
    ('central','refinement_stone'),('central','wisdom_flower'),('central','rule_fragment'),
    ('central','spirit_rice'),('central','human_qi_stone'),('central','crescent_stone'),
    ('central','imperial_lotus_seed'),('central','purple_crystal'),('central','aspiring_stone'),
    ('central','chilling_grass'),('central','nine_palace_flowers'),('central','jade_apicot_blossom'),
    ('central','autumn_voice_grass'),('central','brave_heart_fragment'),('central','spirit_stone'),

    ('western','fire_stone'),('western','desert_sand'),('western','gold_ore'),
    ('western','mirage_sand'),('western','golden_root'),('western','gold_dust'),
    ('western','awakening_crystal'),('western','sand_storm_core'),('western','oasis_water'),
    ('western','flame_sand'),('western','metal_ore'),('western','copper_shavings'),
    ('western','silver_sand'),('western','iron_filing'),('western','fire_spirit_stone'),

    ('eastern','coral'),('eastern','deep_sea_essence'),('eastern','star_shell'),
    ('eastern','water_spirit_stone'),('eastern','sea_salt'),('eastern','tide_stone'),
    ('eastern','ocean_crystal'),('eastern','star_fragment'),('eastern','cloud_mist_stone'),

    ('northern','wind_grass'),('northern','strength_stone'),('northern','blood_flower'),
    ('northern','strength_herb'),('northern','iron_ore'),('northern','dark_iron'),
    ('northern','autumn_leaf'),('northern','storm_crystal'),('northern','frozen_essence'),
    ('northern','grassland_herbs'),('northern','thunder_stone'),('northern','temporal_dust'),

    ('southern','spirit_grass'),('southern','jade_leaf'),('southern','jade_bamboo'),
    ('southern','poison_herb'),('southern','mountain_rock'),('southern','earth_spirit_stone'),
    ('southern','moon_orchid'),('southern','jade_shavings'),('southern','wine_grass'),
    ('southern','hope_flower'),('southern','spring_water'),('southern','purified_water'),
    ('southern','nine_leaf_vitality_grass'),('southern','life_breath_grass'),
    ('southern','six_divine_grass'),('southern','young_autumn_grass'),
    ('southern','water_chestnut_grass'),('southern','skull_stones'),('southern','worry_stones'),
    ('southern','milk_tea_flower'),('southern','earth_treasury_flower'),
    ('southern','clear_chance_grass'),('southern','steep_cliff_grass'),('southern','shame_plum'),
    ('southern','pain_crystal'),('southern','tree_bark')
) AS v (region, material)
JOIN materials m ON m.code = v.material;


-- ---------------------------------------------------------------------------
-- creature_regions
-- ---------------------------------------------------------------------------
-- Where each species is found. Many-to-many because a beast is not obliged to
-- respect a border.

CREATE TABLE creature_regions (
    species_id  BIGINT NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,
    region_code TEXT   NOT NULL REFERENCES regions (code) ON DELETE CASCADE,

    -- Relative frequency of running into it here.
    weight      NUMERIC(8, 4) NOT NULL DEFAULT 1 CHECK (weight > 0),

    PRIMARY KEY (species_id, region_code)
);

CREATE INDEX creature_regions_region_idx ON creature_regions (region_code);

-- The eight species from 0010 are a mechanics coverage set rather than a
-- regional roster, so this places them plausibly to make hunting work now.
-- The real 46-strong starter roster replaces this placement when it lands.
INSERT INTO creature_regions (species_id, region_code, weight)
SELECT s.species_id, v.region, v.weight
FROM (VALUES
    ('ash_moth','western',10),('ash_moth','central',6),
    ('mire_toad','southern',10),('mire_toad','eastern',6),
    ('stone_hide_boar','northern',6),('stone_hide_boar','southern',4),
    ('hollow_reed_serpent','southern',6),('hollow_reed_serpent','eastern',3),
    ('frost_maned_ape','northern',2),
    ('nine_distortion_wolf','northern',1),
    ('void_ash_revenant','western',1),
    ('heaven_scourge_leviathan','eastern',1)
) AS v (code, region, weight)
JOIN creature_species s ON s.code = v.code;


-- ---------------------------------------------------------------------------
-- creature_drops
-- ---------------------------------------------------------------------------

CREATE TABLE creature_drops (
    species_id    BIGINT NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,
    material_code TEXT   NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    -- Probability per kill, 0-1.
    chance        NUMERIC(6, 4) NOT NULL CHECK (chance > 0 AND chance <= 1),

    min_quantity  SMALLINT NOT NULL DEFAULT 1 CHECK (min_quantity >= 1),
    max_quantity  SMALLINT NOT NULL DEFAULT 1,

    PRIMARY KEY (species_id, material_code),

    CONSTRAINT creature_drops_quantity_range CHECK (max_quantity >= min_quantity)
);

CREATE INDEX creature_drops_material_idx ON creature_drops (material_code);

-- A beast material must not be gatherable and vice versa. The split is the
-- whole design, so it is enforced rather than trusted.
CREATE FUNCTION check_drop_is_beast_material()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.material_code) <> 'beast' THEN
        RAISE EXCEPTION 'creature_drops takes beast materials only, got %', NEW.material_code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER creature_drops_beast_only
    BEFORE INSERT OR UPDATE ON creature_drops
    FOR EACH ROW EXECUTE FUNCTION check_drop_is_beast_material();

CREATE FUNCTION check_gathered_is_gathering_material()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.material_code) <> 'gathering' THEN
        RAISE EXCEPTION 'region_materials takes gathering materials only, got %', NEW.material_code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER region_materials_gathering_only
    BEFORE INSERT OR UPDATE ON region_materials
    FOR EACH ROW EXECUTE FUNCTION check_gathered_is_gathering_material();

INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT s.species_id, v.material, v.chance, v.lo, v.hi
FROM (VALUES
    ('ash_moth','beast_blood',0.70,1,2),
    ('ash_moth','golden_crow_essence',0.05,1,1),

    ('mire_toad','beast_blood',0.70,1,2),
    ('mire_toad','venom_sac',0.30,1,1),

    ('stone_hide_boar','boar_tusk',0.75,1,2),
    ('stone_hide_boar','beast_blood',0.60,1,3),
    ('stone_hide_boar','iron_bone',0.08,1,1),

    ('hollow_reed_serpent','snake_gall',0.45,1,1),
    ('hollow_reed_serpent','venom_sac',0.60,1,2),
    ('hollow_reed_serpent','beast_blood',0.50,1,2),

    ('frost_maned_ape','wolf_pelt',0.60,1,2),
    ('frost_maned_ape','beast_core',0.25,1,1),
    ('frost_maned_ape','iron_bone',0.15,1,1),

    ('nine_distortion_wolf','wolf_fang',0.80,1,3),
    ('nine_distortion_wolf','wolf_pelt',0.70,1,2),
    ('nine_distortion_wolf','beast_core',0.40,1,1),

    ('void_ash_revenant','tormented_soul',0.60,1,2),
    ('void_ash_revenant','soul_crystal',0.45,1,2),
    ('void_ash_revenant','heroic_soul',0.15,1,1),

    ('heaven_scourge_leviathan','dragon_whale_bone',1.00,2,5),
    ('heaven_scourge_leviathan','dragon_scale',1.00,1,3),
    ('heaven_scourge_leviathan','life_essence',0.50,1,2)
) AS v (code, material, chance, lo, hi)
JOIN creature_species s ON s.code = v.code;


-- ---------------------------------------------------------------------------
-- player_materials
-- ---------------------------------------------------------------------------

CREATE TABLE player_materials (
    player_id     BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    material_code TEXT   NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    quantity      BIGINT NOT NULL DEFAULT 0 CHECK (quantity >= 0),

    first_got_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, material_code)
);

CREATE TRIGGER player_materials_set_updated_at
    BEFORE UPDATE ON player_materials
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX player_materials_material_idx ON player_materials (material_code);

CREATE FUNCTION grant_material(p_player_id BIGINT, p_code TEXT, p_quantity BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    total BIGINT;
BEGIN
    INSERT INTO player_materials (player_id, material_code, quantity)
    VALUES (p_player_id, p_code, p_quantity)
    ON CONFLICT (player_id, material_code) DO UPDATE
        SET quantity = player_materials.quantity + EXCLUDED.quantity
    RETURNING quantity INTO total;
    RETURN total;
END;
$$;


-- ---------------------------------------------------------------------------
-- player_cooldowns
-- ---------------------------------------------------------------------------
-- One row per player per action, rather than a column per action on some
-- player table. A new timed action is then an INSERT, not a migration that
-- widens a table - the same reason attainment is sparse rows and not 28
-- columns.

CREATE TABLE player_cooldowns (
    player_id    BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    action       TEXT   NOT NULL,
    available_at TIMESTAMPTZ NOT NULL,

    PRIMARY KEY (player_id, action)
);

CREATE INDEX player_cooldowns_ready_idx ON player_cooldowns (available_at);

-- Claims the cooldown and reports whether it was free to take. One statement,
-- so two commands racing cannot both pass the check.
CREATE FUNCTION claim_cooldown(p_player_id BIGINT, p_action TEXT, p_minutes NUMERIC)
RETURNS TABLE (claimed BOOLEAN, ready_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    existing TIMESTAMPTZ;
BEGIN
    SELECT c.available_at INTO existing
    FROM player_cooldowns c
    WHERE c.player_id = p_player_id AND c.action = p_action
    FOR UPDATE;

    IF existing IS NOT NULL AND existing > now() THEN
        RETURN QUERY SELECT FALSE, existing;
        RETURN;
    END IF;

    INSERT INTO player_cooldowns (player_id, action, available_at)
    VALUES (p_player_id, p_action, now() + make_interval(secs => p_minutes * 60))
    ON CONFLICT (player_id, action) DO UPDATE
        SET available_at = EXCLUDED.available_at;

    RETURN QUERY SELECT TRUE, now() + make_interval(secs => p_minutes * 60);
END;
$$;


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('gather_cooldown_minutes', 20,
     'PLACEHOLDER - wait between gathers.'),
    ('gather_yield_min', 1,
     'PLACEHOLDER - fewest units a gather returns.'),
    ('gather_yield_max', 3,
     'PLACEHOLDER - most units a gather returns.'),
    ('hunt_cooldown_minutes', 5,
     'PLACEHOLDER - wait between hunts.'),
    ('hunt_turn_cap', 50,
     'Turns after which a hunt is called a draw. A stalemate has to end somewhere.');


-- ---------------------------------------------------------------------------
-- gather
-- ---------------------------------------------------------------------------
-- Weighted draw from what grows here, using the same -ln(random())/weight
-- sampling as roll_root().

CREATE FUNCTION gather(p_player_id BIGINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, rarity TEXT, quantity BIGINT, held BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    picked  TEXT;
    lo      NUMERIC := game_config_value('gather_yield_min');
    hi      NUMERIC := game_config_value('gather_yield_max');
    amount  BIGINT;
    total   BIGINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    SELECT rm.material_code INTO picked
    FROM region_materials rm
    WHERE rm.region_code = here
    ORDER BY -ln(random()) / rm.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'nothing grows in %', here USING ERRCODE = 'check_violation';
    END IF;

    amount := lo + floor(random() * (hi - lo + 1));
    total  := grant_material(p_player_id, picked, amount);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, amount, total
    FROM materials m WHERE m.code = picked;
END;
$$;


-- ---------------------------------------------------------------------------
-- hunt
-- ---------------------------------------------------------------------------
-- One encounter, resolved to the end.
--
-- Both sides use the functions that already exist - compute_technique_damage
-- from 0008 and compute_creature_damage from 0015 - so /damage's preview and
-- what actually happens cannot disagree. Every swing is written to
-- battle_actions with its resolved numbers, so "why did that hit for 91?" is
-- answered by reading the row rather than re-deriving it.
--
-- The player swings first: they chose to start this. A speed system would
-- change that, and creature_species.base_speed is already sitting there
-- waiting for it.
--
-- Losing costs the HP and nothing else. There is no death state - HP is
-- recoverable through regeneration since 0015, and a permanent loss on a
-- forward-only schema is not a thing to add casually.

CREATE FUNCTION hunt(p_player_id BIGINT, p_species_id BIGINT, p_technique_id BIGINT)
RETURNS TABLE (
    battle_id         BIGINT,
    won               BOOLEAN,
    turns             INTEGER,
    damage_dealt      BIGINT,
    damage_taken      BIGINT,
    player_hp_after   BIGINT,
    creature_hp_after BIGINT,
    drops             JSONB,
    discovered        TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    species     creature_species%ROWTYPE;
    tech        techniques%ROWTYPE;
    body        player_physique%ROWTYPE;
    cap         INTEGER := game_config_value('hunt_turn_cap');
    seed        BIGINT;
    b_id        BIGINT;
    turn        INTEGER := 1;
    c_hp        BIGINT;
    p_hp        BIGINT;
    dealt       BIGINT := 0;
    taken       BIGINT := 0;
    hit         RECORD;
    external    NUMERIC;
    victory     BOOLEAN := FALSE;
    drop_list   JSONB := '[]'::jsonb;
    found_path  TEXT;
    d           RECORD;
    qty         BIGINT;
BEGIN
    SELECT * INTO STRICT species FROM creature_species WHERE species_id = p_species_id;
    SELECT * INTO STRICT tech FROM techniques WHERE technique_id = p_technique_id;
    SELECT * INTO STRICT body FROM player_physique WHERE player_id = p_player_id;

    IF body.current_hp <= 0 THEN
        RAISE EXCEPTION 'no strength left to fight' USING ERRCODE = 'check_violation';
    END IF;

    c_hp := species.base_hp;
    p_hp := body.current_hp;
    seed := floor(random() * 9223372036854775806)::bigint;

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('pve', 'active', seed)
    RETURNING battles.battle_id INTO b_id;

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'technique', tech.code),
            body.max_hp, p_hp);

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, c_hp);

    external := player_external_multiplier(p_player_id, p_technique_id);

    WHILE turn <= cap AND c_hp > 0 AND p_hp > 0 LOOP
        -- The player swings.
        SELECT * INTO hit FROM compute_technique_damage(
            p_player_id, p_technique_id, p_species_id, external, species.base_defense);

        c_hp  := GREATEST(0, c_hp - hit.final_damage);
        dealt := dealt + hit.final_damage;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage, detail)
        VALUES (b_id, 0, turn, 'technique', p_technique_id, tech.name, 1,
                hit.base_power, hit.attainment_bonus, hit.matchup_modifier,
                hit.final_damage,
                jsonb_build_object('external', external, 'target_hp_after', c_hp));

        EXIT WHEN c_hp <= 0;

        -- The creature swings back.
        SELECT * INTO hit FROM compute_creature_damage(p_species_id, p_player_id, 1, body.defense);

        p_hp  := GREATEST(0, p_hp - hit.final_damage);
        taken := taken + hit.final_damage;

        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_name, target_no,
             base_power, attainment_bonus, matchup_modifier, damage, detail)
        VALUES (b_id, 1, turn, 'technique', species.name, 0,
                hit.base_power, hit.attainment_bonus, hit.matchup_modifier,
                hit.final_damage,
                jsonb_build_object('target_hp_after', p_hp));

        turn := turn + 1;
    END LOOP;

    victory := c_hp <= 0;

    UPDATE battles
    SET status      = 'complete',
        winner_side = CASE WHEN victory THEN 0 ELSE 1 END,
        turn_number = GREATEST(turn, 1),
        ended_at    = now()
    WHERE battles.battle_id = b_id;

    -- Aliased because this function's RETURNS TABLE declares an OUT parameter
    -- called battle_id, which otherwise shadows the column.
    UPDATE battle_combatants bc SET current_hp = p_hp
    WHERE bc.battle_id = b_id AND bc.combatant_no = 0;
    UPDATE battle_combatants bc SET current_hp = c_hp
    WHERE bc.battle_id = b_id AND bc.combatant_no = 1;

    UPDATE player_physique SET current_hp = p_hp WHERE player_id = p_player_id;

    -- Meeting a thing is what puts it in your bestiary; killing it is what
    -- teaches you how it takes a hit.
    INSERT INTO player_bestiary (player_id, species_id, times_encountered, times_defeated)
    VALUES (p_player_id, p_species_id, 1, CASE WHEN victory THEN 1 ELSE 0 END)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            times_defeated    = player_bestiary.times_defeated
                                + CASE WHEN victory THEN 1 ELSE 0 END,
            last_seen_at      = now();

    -- Swinging a Path at something teaches you what that Path does to it -
    -- 'combat' rather than 'insight', which is what /study records.
    -- A dual-Path technique can reveal two things at once, so the insert's
    -- RETURNING is aggregated in a CTE. `RETURNING ... INTO` would raise on
    -- the second row.
    WITH revealed AS (
        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT p_player_id, p_species_id, cip.path_code, 'combat'
        FROM creature_incoming_paths cip
        JOIN technique_paths tp ON tp.path_code = cip.path_code
        WHERE cip.species_id = p_species_id
          AND tp.technique_id = p_technique_id
        ON CONFLICT (player_id, species_id, path_code) DO NOTHING
        RETURNING path_code
    )
    SELECT string_agg(path_code, ', ') INTO found_path FROM revealed;

    IF victory THEN
        FOR d IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity, m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = p_species_id
        LOOP
            IF random() < d.chance THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(p_player_id, d.material_code, qty);
                drop_list := drop_list || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty);
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY SELECT b_id, victory, GREATEST(turn, 1), dealt, taken, p_hp, c_hp,
                        drop_list, found_path;
END;
$$;

COMMENT ON FUNCTION hunt(BIGINT, BIGINT, BIGINT) IS
    'Resolves one PvE encounter end to end using the two damage functions, logs every swing, applies HP, drops and discovery.';
