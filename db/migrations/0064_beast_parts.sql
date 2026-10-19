-- 0064_beast_parts
--
-- What a carcass is worth to a smith.
--
-- The design document asks that beast materials give equipment its identity,
-- and lists the vocabulary it wants: hide, scale, bone, horn, fang, shell,
-- feather, blood essence, beast core, heart. It also says, twice, to reuse the
-- monster materials that already exist rather than mint duplicates. So nothing
-- new is dropped by anything here. All forty-three beast materials in the game
-- are sorted into twelve kinds, and the kind is what a forge reads.
--
-- WHY A KIND AND NOT A COLUMN PER MATERIAL. `wolf_fang` and `tiger_fang` want
-- to mean the same thing to a forge and different things to a Gu recipe. The
-- kind is the forge's reading of the material; the Path, the rarity and the
-- code stay exactly what they were, and every existing consumer is untouched.
--
-- THE EFFECTS ARE THE SHARED ONES. 0053 settled this: `gu_effects` is the
-- whole game's effect vocabulary, not the Gu system's. A fang buying crit and
-- penetration says it in the same words a Gu does, which is what lets one
-- ceiling apply to both.
--
-- TWELVE KINDS AND NOT FIFTEEN. The document also names claws, tendons and
-- eyes. Nothing in the bestiary drops any of the three, and a kind with no
-- member is a promise in a table nobody reads - the same thing 0036 refused
-- when it flagged four effects `is_live = FALSE` rather than pretending. When
-- something with claws is added, the claw is a row.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- material_grade
-- ---------------------------------------------------------------------------
-- How much a material is worth where potency is counted, read off the rarity
-- ladder rather than hand-typed beside it. A second column holding "how good
-- is this" is a second chance to disagree with `rarity`, and 0017 already
-- refused that once for names.

CREATE FUNCTION material_grade(p_rarity TEXT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(7, GREATEST(1, ceil(r.sort_order / 10.0)))::smallint
    FROM rarities r WHERE r.code = p_rarity;
$$;

COMMENT ON FUNCTION material_grade(TEXT) IS
    'Rarity as a 1-7 potency, derived from the ladder so a new band grades itself.';


-- ---------------------------------------------------------------------------
-- part_kinds
-- ---------------------------------------------------------------------------

CREATE TABLE part_kinds (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,

    -- What it contributes to a forged item's name: 'Fang' in
    -- 'Sunsteel Fang Saber'.
    word        TEXT NOT NULL,

    emoji       TEXT NOT NULL DEFAULT '🦴',
    description TEXT NOT NULL DEFAULT '',
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO part_kinds (code, name, word, emoji, description, sort_order) VALUES
    ('fang',    'Fang',    'Fang',     '🦷', 'Where a beast puts its intent. Criticals, and the armour they go through.', 10),
    ('horn',    'Horn',    'Horn',     '🦌', 'Made for going through something. Penetration first, weight behind it.', 20),
    ('bone',    'Bone',    'Bone',     '🦴', 'The frame. Half structure, half club.', 30),
    ('scale',   'Scale',   'Scale',    '🐟', 'Overlapping plate. What a blow slides off.', 40),
    ('shell',   'Shell',   'Carapace', '🐢', 'Nothing but refusal. The heaviest defence a carcass carries.', 50),
    ('hide',    'Hide',    'Pelt',     '🧥', 'Room to take a hit and keep standing.', 60),
    ('feather', 'Feather', 'Plume',    '🪶', 'Not being where the blow lands.', 70),
    ('blood',   'Blood',   'Blood',    '🩸', 'What a beast ran on. Vitality, and taking some back.', 80),
    ('heart',   'Heart',   'Heart',    '💗', 'The engine. Endurance, and the drinking of it.', 90),
    ('core',    'Core',    'Core',     '🔶', 'A beast''s cultivation, condensed. It gives a little of everything.', 100),
    ('soul',    'Soul',    'Soul',     '👻', 'What was left when the body stopped. Understanding, and cruelty.', 110),
    ('venom',   'Venom',   'Venom',    '🧪', 'Chemistry rather than force. It gets through, and it takes.', 120);

COMMENT ON TABLE part_kinds IS
    'How a forge reads a beast material. The kind decides what an item gains; the material keeps its own Path and rarity.';


-- ---------------------------------------------------------------------------
-- part_effects
-- ---------------------------------------------------------------------------
-- What each kind buys, as shares of whatever budget the forge hands it. Shares
-- rather than magnitudes, so the tier decides how much and the kind decides
-- what - and retuning the size of an item is one number in `equipment_tiers`
-- rather than twenty-four here.

CREATE TABLE part_effects (
    part        TEXT NOT NULL REFERENCES part_kinds (code) ON DELETE CASCADE,
    effect_code TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    share       NUMERIC(4, 3) NOT NULL CHECK (share > 0 AND share <= 1),

    PRIMARY KEY (part, effect_code)
);

CREATE INDEX part_effects_effect_idx ON part_effects (effect_code);

INSERT INTO part_effects (part, effect_code, share) VALUES
    ('fang',    'crit_rate',        0.600), ('fang',    'armor_pen',        0.400),
    ('horn',    'armor_pen',        0.700), ('horn',    'attack_power',     0.300),
    ('bone',    'damage_reduction', 0.500), ('bone',    'attack_power',     0.500),
    ('scale',   'damage_reduction', 0.700), ('scale',   'max_hp',           0.300),
    ('shell',   'damage_reduction', 1.000),
    ('hide',    'max_hp',           0.600), ('hide',    'damage_reduction', 0.400),
    ('feather', 'dodge',            0.700), ('feather', 'multi_hit',        0.300),
    ('blood',   'max_hp',           0.500), ('blood',   'lifesteal',        0.500),
    ('heart',   'max_hp',           0.600), ('heart',   'lifesteal',        0.400),
    ('core',    'attack_power',     0.400), ('core',    'damage_reduction', 0.300),
    ('core',    'max_hp',           0.300),
    ('soul',    'cultivation_rate', 0.500), ('soul',    'crit_damage',      0.500),
    ('venom',   'armor_pen',        0.500), ('venom',   'lifesteal',        0.500);

COMMENT ON TABLE part_effects IS
    'What a kind of part is for, in the shared effect vocabulary, as shares of the forge''s budget.';


-- ---------------------------------------------------------------------------
-- beast_parts
-- ---------------------------------------------------------------------------

CREATE TABLE beast_parts (
    material_code TEXT PRIMARY KEY REFERENCES materials (code) ON DELETE CASCADE,
    part          TEXT NOT NULL REFERENCES part_kinds (code) ON DELETE RESTRICT
);

CREATE INDEX beast_parts_part_idx ON beast_parts (part);

COMMENT ON TABLE beast_parts IS
    'A beast material with a row here can be forged into something. The kind is the forge''s reading of it.';

-- Ore is not cut off anything. The split 0017 drew is enforced here too.
CREATE FUNCTION check_part_is_beast_material()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF (SELECT category FROM materials WHERE code = NEW.material_code) <> 'beast' THEN
        RAISE EXCEPTION 'a forging part is a beast material, and % is not', NEW.material_code;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER beast_parts_are_beast_materials
    BEFORE INSERT OR UPDATE ON beast_parts
    FOR EACH ROW EXECUTE FUNCTION check_part_is_beast_material();


-- ---------------------------------------------------------------------------
-- All forty-three of them
-- ---------------------------------------------------------------------------

INSERT INTO beast_parts (material_code, part) VALUES
    ('wolf_fang','fang'),('tiger_fang','fang'),('shark_tooth','fang'),

    ('beast_horn','horn'),('boar_tusk','horn'),('black_boar_tusk','horn'),
    ('scorpion_stinger','horn'),

    ('bone_fragment','bone'),('skull_fragment','bone'),('bone_spear_tip','bone'),
    ('iron_bone','bone'),('dragon_whale_bone','bone'),

    ('fish_scale_shard','scale'),('dragon_scale','scale'),('desert_scale','scale'),

    ('cicada_shell','shell'),('crab_carapace','shell'),('turtle_shell','shell'),
    ('crystal_carapace','shell'),('gilded_carapace','shell'),
    ('tortoise_shell_plate','shell'),

    ('wolf_pelt','hide'),('mirage_pelt','hide'),

    ('eagle_feather','feather'),('footless_bird','feather'),('moth_wing_dust','feather'),

    ('beast_blood','blood'),('blood_coral','blood'),('life_essence','blood'),
    ('vitality_sap','blood'),

    ('lingzhi_meat','heart'),('poison_heart','heart'),

    ('beast_core','core'),('pearl','core'),('cicada_essence','core'),
    ('golden_crow_essence','core'),

    ('heroic_soul','soul'),('soul_pearl','soul'),('soul_crystal','soul'),
    ('tormented_soul','soul'),

    ('centipede_venom','venom'),('venom_sac','venom'),('snake_gall','venom');
