-- 0065_blacksmithing
--
-- Ore and carcass become equipment.
--
-- NO RECIPE LIST, for the third time. 0026 refined manuals from pages, 0057
-- brewed pills from herbs, and both refused a cookbook for the same reason the
-- design document gives here: "do not hardcode every possible equipment
-- combination." What goes in decides what comes out. An ore, one to four beast
-- parts, the Paths they carry and the smith's own steadiness are the whole
-- input, and two smiths with the same materials do not get the same sword.
--
-- ORE IS THE FOUNDATION, PARTS ARE THE IDENTITY. The document's closing
-- summary is the design: mining answers what raw foundation, hunting answers
-- what supernatural properties, smithing answers how well they were combined.
-- So the ore decides the CEILING - an item can never out-tier the metal it is
-- made of, however much of it goes in - and the parts decide WHICH effects
-- appear at all.
--
-- GEAR IS A PERCENTAGE. Every stat an item carries is a fraction in the shared
-- `gu_effects` vocabulary, capped by that effect's own ceiling, added to the
-- same stack a Gu and a manual and a race feed. +8% attack from a saber and
-- +5% from a Gu is +13%, never a product of the two. That is the whole game's
-- arithmetic and equipment does not get an exception.
--
-- QUALITY IS THE RARITY LADDER. The document proposes Crude - Common - Fine -
-- Superior - Masterwork - Perfect, and asks in the same breath whether an
-- existing rarity system already serves. It does: `rarities` has banded roots,
-- physiques, materials and Gu since 0011, the colours and marks are already
-- rendered, and a second six-word ladder meaning the same thing would be two
-- vocabularies for one idea. A Legendary saber is legendary in the sense the
-- rest of the game already uses.
--
-- WHAT IS NOT MODELLED, said plainly rather than half-built: durability and
-- weight (nothing decays or encumbers), and proc traits like Burning (there is
-- no status system to burn with). The document's derived reactions ARE built,
-- because they can be - a reaction is a name and an effect, and both exist.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- equipment_slots
-- ---------------------------------------------------------------------------
-- Four, and every one of them has live effects to hand out. A fifth slot whose
-- stats nothing reads would be the thing 0036 refused to ship.

CREATE TABLE equipment_slots (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    emoji       TEXT NOT NULL DEFAULT '⚔️',
    description TEXT NOT NULL DEFAULT '',
    sort_order  SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO equipment_slots (code, name, emoji, description, sort_order) VALUES
    ('weapon', 'Weapon', '⚔️', 'What you hit with. Damage, and the chance it lands badly for them.', 10),
    ('armour', 'Armour', '🛡️', 'What is between you and it. Turns blows aside and gives you more to spend.', 20),
    ('helm',   'Helm',   '⛑️', 'Worn for the head rather than the body. Clarity, and what a critical is worth.', 30),
    ('boots',  'Boots',  '👢', 'Not being there. Evasion, and the second strike.', 40);

CREATE TABLE slot_effects (
    slot        TEXT NOT NULL REFERENCES equipment_slots (code) ON DELETE CASCADE,
    effect_code TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,
    share       NUMERIC(4, 3) NOT NULL CHECK (share > 0 AND share <= 1),
    PRIMARY KEY (slot, effect_code)
);

CREATE INDEX slot_effects_effect_idx ON slot_effects (effect_code);

INSERT INTO slot_effects (slot, effect_code, share) VALUES
    ('weapon', 'attack_power',     0.700), ('weapon', 'crit_rate',        0.300),
    ('armour', 'damage_reduction', 0.600), ('armour', 'max_hp',           0.400),
    ('helm',   'cultivation_rate', 0.550), ('helm',   'crit_damage',      0.450),
    ('boots',  'dodge',            0.650), ('boots',  'multi_hit',        0.350);

COMMENT ON TABLE slot_effects IS
    'What a slot is for, before anything is put into it. The ore''s share of the budget is spent here and on its signature.';

-- The nouns a name can end in. Rows, like pill endings, so a new slot brings
-- its own vocabulary instead of needing the generator edited.
CREATE TABLE slot_nouns (
    slot TEXT NOT NULL REFERENCES equipment_slots (code) ON DELETE CASCADE,
    noun TEXT NOT NULL,
    PRIMARY KEY (slot, noun)
);

INSERT INTO slot_nouns (slot, noun) VALUES
    ('weapon','Saber'),('weapon','Blade'),('weapon','Spear'),('weapon','Halberd'),
    ('armour','Mail'),('armour','Cuirass'),('armour','Robe'),('armour','Plate'),
    ('helm','Crown'),('helm','Helm'),('helm','Circlet'),('helm','Mask'),
    ('boots','Boots'),('boots','Greaves'),('boots','Treads'),('boots','Striders');


-- ---------------------------------------------------------------------------
-- equipment_tiers
-- ---------------------------------------------------------------------------
-- Potency counts an ore's tier and a part's grade SQUARED, which is what makes
-- deep material irreplaceable rather than merely efficient: a hundred units of
-- Tier 1 iron is a hundred potency and still cannot leave Tier 1, because the
-- ore caps the item. Nine units of Tier 7 adamant is four hundred and forty.
--
-- `base_magnitude` is the whole fraction budget an item of that tier hands
-- out, split across its effects. A Tier 1 piece is worth six points of
-- percentage in total; a Tier 7 is worth eighty.

CREATE TABLE equipment_tiers (
    tier             SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 7),
    potency_required NUMERIC(8, 2) NOT NULL CHECK (potency_required >= 0),
    base_magnitude   NUMERIC(6, 4) NOT NULL CHECK (base_magnitude > 0)
);

INSERT INTO equipment_tiers (tier, potency_required, base_magnitude) VALUES
    (1,   4, 0.0600),
    (2,  12, 0.1000),
    (3,  28, 0.1600),
    (4,  60, 0.2500),
    (5, 120, 0.3800),
    (6, 230, 0.5500),
    (7, 400, 0.8000);


-- ---------------------------------------------------------------------------
-- equipment_qualities
-- ---------------------------------------------------------------------------
-- How much of the tier's budget survives the forging, banded onto the ladder
-- the whole game already reads. Two smiths at Tier 4 are three times apart
-- from end to end, which is the document's "identical ingredients should not
-- always produce identical results" expressed as a number.

CREATE TABLE equipment_qualities (
    rarity      TEXT PRIMARY KEY REFERENCES rarities (code) ON DELETE RESTRICT,
    min_harmony SMALLINT NOT NULL UNIQUE CHECK (min_harmony >= 0),
    keep        NUMERIC(4, 2) NOT NULL CHECK (keep > 0)
);

INSERT INTO equipment_qualities (rarity, min_harmony, keep) VALUES
    ('common',      0, 0.55),
    ('uncommon',   40, 0.75),
    ('rare',       60, 0.92),
    ('epic',       78, 1.08),
    ('legendary',  92, 1.22),
    ('divine',    108, 1.40),
    ('mythic',    125, 1.60);


-- ---------------------------------------------------------------------------
-- forge_reactions
-- ---------------------------------------------------------------------------
-- The document's best idea, and the only one of its list that this engine can
-- actually pay: a smith good enough turns a conflict into a property. Below
-- the level, Fire and Ice in one crucible is just a harmony penalty. At it,
-- the penalty stands AND the item comes out Frostfire.
--
-- Paths are stored in the order the chart compares them, so a lookup is one
-- indexed probe rather than two.

CREATE TABLE forge_reactions (
    path_a      TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,
    path_b      TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,

    word        TEXT NOT NULL,
    effect_code TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,
    min_level   SMALLINT NOT NULL DEFAULT 10 CHECK (min_level >= 1),
    description TEXT NOT NULL DEFAULT '',

    PRIMARY KEY (path_a, path_b),
    CONSTRAINT forge_reactions_ordered CHECK (path_a < path_b)
);

CREATE INDEX forge_reactions_effect_idx ON forge_reactions (effect_code);

INSERT INTO forge_reactions (path_a, path_b, word, effect_code, min_level, description) VALUES
    ('fire','water','Steamveil','dodge', 8,
     'The quench never finishes. What comes off it is still coming off it.'),
    ('fire','ice','Frostfire','crit_damage', 10,
     'Neither one wins, and the edge is where they are still arguing.'),
    ('earth','fire','Magmaforged','attack_power', 8,
     'Poured rather than beaten, and it remembers being poured.'),
    ('metal','poison','Venomsteel','armor_pen', 12,
     'The venom did not sit on the metal. It went in.'),
    ('lightning','water','Stormbound','multi_hit', 10,
     'Struck once and it answers three times.'),
    ('metal','shadow','Darksteel','damage_reduction', 12,
     'Takes no light and gives nothing back, which turns out to include blows.'),
    ('light','shadow','Duskbound','crit_rate', 15,
     'The seam between them is thinner than either, and that is the part that cuts.'),
    ('blood','soul','Soulbleed','lifesteal', 15,
     'It takes something that is not blood, and it is not fussy about whose.');

COMMENT ON TABLE forge_reactions IS
    'Conflicts a skilled enough smith can turn into a property. Below min_level the conflict is only a conflict.';


-- ---------------------------------------------------------------------------
-- What a player has forged
-- ---------------------------------------------------------------------------

CREATE TABLE player_equipment (
    equipment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    owner_id  BIGINT   NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    name      TEXT     NOT NULL,
    slot      TEXT     NOT NULL REFERENCES equipment_slots (code) ON DELETE RESTRICT,
    tier      SMALLINT NOT NULL REFERENCES equipment_tiers (tier) ON DELETE RESTRICT,
    quality   TEXT     NOT NULL REFERENCES rarities (code) ON DELETE RESTRICT,
    harmony   SMALLINT NOT NULL CHECK (harmony BETWEEN 0 AND 150),

    -- What Dao the piece leans toward: the ore's, which is the foundation's.
    path_code TEXT     REFERENCES paths (code) ON DELETE SET NULL,
    ore_code  TEXT     NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    -- The word a derived reaction gave it, if one happened.
    reaction  TEXT,

    forged_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_equipment_owner_idx   ON player_equipment (owner_id);
CREATE INDEX player_equipment_slot_idx    ON player_equipment (slot);
CREATE INDEX player_equipment_quality_idx ON player_equipment (quality);
CREATE INDEX player_equipment_ore_idx     ON player_equipment (ore_code);

CREATE TABLE equipment_effects (
    equipment_id BIGINT NOT NULL REFERENCES player_equipment (equipment_id) ON DELETE CASCADE,
    effect_code  TEXT   NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    magnitude    NUMERIC(6, 4) NOT NULL CHECK (magnitude > 0),

    PRIMARY KEY (equipment_id, effect_code)
);

CREATE INDEX equipment_effects_effect_idx ON equipment_effects (effect_code);

COMMENT ON TABLE equipment_effects IS
    'What a forged piece is worth, in the same fractions and the same vocabulary a Gu speaks.';


-- ---------------------------------------------------------------------------
-- player_equipped
-- ---------------------------------------------------------------------------
-- One piece per slot, by primary key rather than by a count the caller has to
-- remember to run.

CREATE TABLE player_equipped (
    player_id    BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    slot         TEXT   NOT NULL REFERENCES equipment_slots (code) ON DELETE RESTRICT,
    equipment_id BIGINT NOT NULL UNIQUE
                 REFERENCES player_equipment (equipment_id) ON DELETE CASCADE,

    equipped_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, slot)
);

CREATE INDEX player_equipped_player_idx ON player_equipped (player_id);

-- Wearing somebody else's boots, or wearing a helm on your feet. Neither is
-- reachable through the commands, which is exactly why it is enforced here
-- instead of there.
CREATE FUNCTION check_equipped_piece()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    it player_equipment%ROWTYPE;
BEGIN
    SELECT * INTO it FROM player_equipment WHERE equipment_id = NEW.equipment_id;

    IF it.owner_id <> NEW.player_id THEN
        RAISE EXCEPTION 'that piece is not yours to wear';
    END IF;
    IF it.slot <> NEW.slot THEN
        RAISE EXCEPTION '% goes in the % slot, not the %', it.name, it.slot, NEW.slot;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER player_equipped_is_yours_and_fits
    BEFORE INSERT OR UPDATE ON player_equipped
    FOR EACH ROW EXECUTE FUNCTION check_equipped_piece();


-- ---------------------------------------------------------------------------
-- What the gear is worth
-- ---------------------------------------------------------------------------

CREATE VIEW player_equipment_stats AS
SELECT
    e.player_id,
    ee.effect_code,
    LEAST(ef.cap, sum(ee.magnitude)) AS total,
    sum(ee.magnitude) > ef.cap       AS capped
FROM player_equipped e
JOIN equipment_effects ee ON ee.equipment_id = e.equipment_id
JOIN gu_effects ef        ON ef.code = ee.effect_code
GROUP BY e.player_id, ee.effect_code, ef.cap;

COMMENT ON VIEW player_equipment_stats IS
    'Summed magnitudes across worn pieces, already capped, exactly as player_gu_stats does for Gu.';

CREATE FUNCTION equipment_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT s.total FROM player_equipment_stats s
         WHERE s.player_id = p_player_id AND s.effect_code = p_effect),
        0
    );
$$;


-- ---------------------------------------------------------------------------
-- The profession, and its dials
-- ---------------------------------------------------------------------------

INSERT INTO professions (code, name, exp_per_level, description) VALUES
    ('blacksmithing', 'Blacksmith', 220,
     'Forges ore and beast materials into equipment. Level decides how deep a piece can be, how many parts fit on the anvil, and how steady the crucible is.');

INSERT INTO game_config (key, value, description) VALUES
    ('forge_base_parts', 1,
     'Beast materials a novice smith can hold on the anvil.'),
    ('forge_parts_per_levels', 4,
     'Blacksmith levels per additional part.'),
    ('forge_max_parts', 4,
     'Hard ceiling on parts in one forging.'),
    ('forge_base_tier', 2,
     'Deepest piece a Blacksmith at level 1 can attempt.'),
    ('forge_tier_per_levels', 4,
     'Blacksmith levels per additional tier of depth.'),
    ('forge_failure_threshold', 25,
     'Harmony below this and the forging comes apart.'),
    ('forge_refund', 0.5,
     'Fraction of every material raked back out of a ruined forging.'),
    ('forge_exp_per_tier', 60,
     'PLACEHOLDER - Blacksmith EXP per tier of the piece forged.'),
    ('forge_ore_share', 0.55,
     'Fraction of a piece''s budget the ore decides. The rest belongs to the beast materials.'),
    ('forge_signature_share', 0.35,
     'Fraction of the ore''s share that goes to the ore''s signature rather than the slot''s own stats.'),
    ('forge_reaction_share', 0.25,
     'What a derived reaction adds, as a fraction of the piece''s budget.');

CREATE FUNCTION smith_part_slots(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('forge_max_parts'),
        game_config_value('forge_base_parts')
        + floor(p_level / game_config_value('forge_parts_per_levels'))
    )::smallint;
$$;

CREATE FUNCTION smith_tier_cap(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(7,
        game_config_value('forge_base_tier')
        + floor(p_level / game_config_value('forge_tier_per_levels'))
    )::smallint;
$$;


-- ---------------------------------------------------------------------------
-- forged_name
-- ---------------------------------------------------------------------------
-- The same machinery manuals and pills are named by: a title off the harmony
-- ladder, a word from what it is made of, and an ending from what it is. A
-- reaction replaces the ore's word, because 'Frostfire Crowblade' is the
-- document's own example and 'Froststeel Frostfire Crowblade' is not a name.

CREATE FUNCTION forged_name(
    p_ore_word  TEXT,
    p_part_word TEXT,
    p_slot      TEXT,
    p_harmony   SMALLINT,
    p_reaction  TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    title TEXT;
    noun  TEXT;
BEGIN
    SELECT ht.word INTO title
    FROM harmony_titles ht WHERE ht.min_harmony <= p_harmony
    ORDER BY ht.min_harmony DESC LIMIT 1;

    SELECT sn.noun INTO noun
    FROM slot_nouns sn WHERE sn.slot = p_slot ORDER BY random() LIMIT 1;

    RETURN trim(both ' ' FROM
        COALESCE(title || ' ', '')
        || COALESCE(p_reaction, p_ore_word) || ' '
        || p_part_word || ' '
        || COALESCE(noun, 'Piece'));
END;
$$;


-- ---------------------------------------------------------------------------
-- forge
-- ---------------------------------------------------------------------------
-- One ore in bulk, one to four beast parts, and a slot to make it for.
--
-- Harmony is scored the way a refinement and a brew are, because a crucible
-- holding Fire and Water is the same problem in a third vessel: agreement
-- between the Paths present, a reward for parts that echo the ore, a penalty
-- per extra Path and per mismatched grade, the smith's steadiness, and a roll.
-- A body that softens Path conflict softens it here too.

CREATE FUNCTION forge(
    p_player_id  BIGINT,
    p_slot       TEXT,
    p_ore_code   TEXT,
    p_ore_qty    INTEGER,
    p_parts      TEXT[],
    p_part_qtys  INTEGER[]
)
RETURNS TABLE (
    succeeded    BOOLEAN,
    harmony      SMALLINT,
    potency      NUMERIC,
    equipment_id BIGINT,
    item_name    TEXT,
    item_tier    SMALLINT,
    quality      TEXT,
    slot         TEXT,
    path_code    TEXT,
    reaction     TEXT,
    exp_gained   BIGINT,
    level_after  SMALLINT,
    spent_total  BIGINT,
    handed_back  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill       SMALLINT;
    slots       SMALLINT;
    n_parts     INTEGER;
    known       INTEGER;
    ore         ores%ROWTYPE;
    ore_path    TEXT;
    refund      NUMERIC;
    relief      NUMERIC;
    total       NUMERIC := 0;
    ore_pot     NUMERIC := 0;
    part_pot    NUMERIC := 0;
    h           NUMERIC := 50;
    pair_sum    NUMERIC := 0;
    echoes      INTEGER := 0;
    distinct_n  INTEGER := 1;
    spread      INTEGER := 0;
    final_h     SMALLINT;
    grade       SMALLINT;
    tier_by_pot SMALLINT;
    base_mag    NUMERIC;
    keep_frac   NUMERIC;
    band        TEXT;
    budget      NUMERIC;
    ore_side    NUMERIC;
    sig_side    NUMERIC;
    base_side   NUMERIC;
    part_side   NUMERIC;
    react       forge_reactions%ROWTYPE;
    react_word  TEXT;
    react_eff   TEXT;
    react_mag   NUMERIC := 0;
    lead_word   TEXT;
    made_name   TEXT;
    made_id     BIGINT;
    gained      BIGINT;
    lvl         SMALLINT;
    spent       BIGINT := 0;
    back        BIGINT := 0;
BEGIN
    -- ---- the anvil ------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM equipment_slots WHERE code = p_slot) THEN
        RAISE EXCEPTION 'there is nothing worn as a %', p_slot
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO ore FROM ores WHERE material_code = p_ore_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'a forging starts with ore, and % is not ore', p_ore_code
            USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_ore_qty, 0) < 1 THEN
        RAISE EXCEPTION 'a forging needs ore in it' USING ERRCODE = 'check_violation';
    END IF;

    n_parts := COALESCE(array_length(p_parts, 1), 0);
    IF n_parts <> COALESCE(array_length(p_part_qtys, 1), 0) THEN
        RAISE EXCEPTION 'every part needs a quantity' USING ERRCODE = 'check_violation';
    END IF;
    IF n_parts < 1 THEN
        RAISE EXCEPTION 'ore alone is an ingot. A piece needs something off a beast in it'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n_parts <> (SELECT count(DISTINCT x) FROM unnest(p_parts) AS x) THEN
        RAISE EXCEPTION 'name each part once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_part_qtys) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'a part with none of it in is not on the anvil'
            USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'blacksmithing');
    slots := smith_part_slots(skill);
    IF n_parts > slots THEN
        RAISE EXCEPTION 'your anvil holds % beast materials, not %', slots, n_parts
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_parts) AS u (code)
    JOIN beast_parts bp ON bp.material_code = u.code;

    IF known <> n_parts THEN
        RAISE EXCEPTION 'only beast materials go on the anvil, and one of those is not'
            USING ERRCODE = 'check_violation';
    END IF;

    IF ore.tier > smith_tier_cap(skill) THEN
        RAISE EXCEPTION 'you cannot work tier % metal yet - your anvil reaches tier %',
            ore.tier, smith_tier_cap(skill) USING ERRCODE = 'check_violation';
    END IF;

    SELECT m.path_code INTO ore_path FROM materials m WHERE m.code = p_ore_code;

    -- ---- what is on the anvil -------------------------------------------
    -- Squared, so depth cannot be bought with volume. The ore caps the tier
    -- besides, but the curve is what makes a Tier 6 ingot feel like one.
    ore_pot := ore.tier::numeric ^ 2 * p_ore_qty;

    SELECT COALESCE(sum(material_grade(m.rarity)::numeric ^ 2 * u.quantity), 0)
    INTO part_pot
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
    JOIN materials m ON m.code = u.code;

    total := ore_pot + part_pot;

    SELECT max(et.tier) INTO tier_by_pot
    FROM equipment_tiers et WHERE et.potency_required <= total;

    IF tier_by_pot IS NULL THEN
        RAISE EXCEPTION 'there is not enough on the anvil to make anything - tier 1 wants % potency',
            (SELECT potency_required FROM equipment_tiers WHERE tier = 1)
            USING ERRCODE = 'check_violation';
    END IF;

    -- Ore is the foundation, so it is also the ceiling.
    grade := LEAST(tier_by_pot, ore.tier, smith_tier_cap(skill));

    -- ---- spend ----------------------------------------------------------
    PERFORM spend_material(p_player_id, p_ore_code, p_ore_qty::bigint);
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity);

    spent := p_ore_qty + COALESCE((SELECT sum(q) FROM unnest(p_part_qtys) AS q), 0);

    -- ---- harmony --------------------------------------------------------
    relief := LEAST(1, physique_stat(p_player_id, 'refine_conflict_relief'));

    SELECT COALESCE(sum(
        CASE WHEN pair_harmony(a.p, b.p) < 0
             THEN pair_harmony(a.p, b.p) * (1 - relief)
             ELSE pair_harmony(a.p, b.p) END
    ), 0)
    INTO pair_sum
    FROM (SELECT DISTINCT p FROM (
              SELECT ore_path AS p
              UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                       JOIN materials m ON m.code = u.code) x) a
    JOIN (SELECT DISTINCT p FROM (
              SELECT ore_path AS p
              UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                       JOIN materials m ON m.code = u.code) y) b
      ON a.p < b.p;

    SELECT count(*) INTO echoes
    FROM unnest(p_parts) AS u (code)
    JOIN materials m ON m.code = u.code
    WHERE m.path_code = ore_path;

    SELECT count(DISTINCT p) INTO distinct_n
    FROM (SELECT ore_path AS p
          UNION SELECT m.path_code FROM unnest(p_parts) AS u (code)
                                   JOIN materials m ON m.code = u.code) z;

    SELECT max(g) - min(g) INTO spread
    FROM (SELECT ore.tier AS g
          UNION ALL SELECT material_grade(m.rarity)
                    FROM unnest(p_parts) AS u (code)
                    JOIN materials m ON m.code = u.code) w;

    h := h
       + pair_sum
       + 9 * echoes                -- a part that echoes the metal settles it
       - 4 * (distinct_n - 1)      -- every extra Path is another seam
       - 2 * spread                -- grades that do not match sit badly
       + skill * 0.9
       + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- ruined ---------------------------------------------------------
    IF final_h < game_config_value('forge_failure_threshold') THEN
        refund := game_config_value('forge_refund');

        PERFORM grant_material(p_player_id, p_ore_code, floor(p_ore_qty * refund)::bigint)
        WHERE floor(p_ore_qty * refund) > 0;

        PERFORM grant_material(p_player_id, u.code, floor(u.quantity * refund)::bigint)
        FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
        WHERE floor(u.quantity * refund) > 0;

        back := floor(p_ore_qty * refund)
              + COALESCE((SELECT sum(floor(q * refund)) FROM unnest(p_part_qtys) AS q), 0);

        gained := GREATEST(10, round(grade * game_config_value('forge_exp_per_tier') / 2));
        lvl := grant_profession_exp(p_player_id, 'blacksmithing', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, total, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, p_slot, ore_path, NULL::text,
                            gained, lvl, spent, back;
        RETURN;
    END IF;

    -- ---- the piece ------------------------------------------------------
    SELECT eq.rarity, eq.keep INTO band, keep_frac
    FROM equipment_qualities eq WHERE eq.min_harmony <= final_h
    ORDER BY eq.min_harmony DESC LIMIT 1;

    SELECT et.base_magnitude INTO base_mag
    FROM equipment_tiers et WHERE et.tier = grade;

    budget    := base_mag * keep_frac;
    ore_side  := budget * game_config_value('forge_ore_share');
    sig_side  := ore_side * game_config_value('forge_signature_share');
    base_side := ore_side - sig_side;
    part_side := budget - ore_side;

    -- A conflict a smith is good enough to use.
    SELECT r.* INTO react
    FROM forge_reactions r
    JOIN unnest(p_parts) AS u (code) ON TRUE
    JOIN materials m ON m.code = u.code
    WHERE ((r.path_a = ore_path AND r.path_b = m.path_code)
        OR (r.path_b = ore_path AND r.path_a = m.path_code))
      AND r.min_level <= skill
    ORDER BY r.min_level DESC
    LIMIT 1;

    IF FOUND THEN
        react_word := react.word;
        react_eff  := react.effect_code;
        react_mag  := budget * game_config_value('forge_reaction_share');
    END IF;

    -- The part carrying the most weight is the one the name remembers.
    SELECT pk.word INTO lead_word
    FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    JOIN beast_parts bp ON bp.material_code = u.code
    JOIN part_kinds pk ON pk.code = bp.part
    GROUP BY pk.word
    ORDER BY sum(material_grade(m.rarity)::numeric ^ 2 * u.quantity) DESC
    LIMIT 1;

    made_name := forged_name(ore.word, COALESCE(lead_word, 'Beast'), p_slot,
                             final_h, react_word);

    INSERT INTO player_equipment
        (owner_id, name, slot, tier, quality, harmony, path_code, ore_code, reaction)
    VALUES (p_player_id, made_name, p_slot, grade, band, final_h,
            ore_path, p_ore_code, react_word)
    RETURNING player_equipment.equipment_id INTO made_id;

    -- ---- what it is worth -----------------------------------------------
    -- Three sources and a reaction, summed per effect and capped once. The cap
    -- belongs to the effect, not to whichever table granted it.
    INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
    SELECT made_id, c.effect_code,
           LEAST(ef.cap, round(sum(c.magnitude), 4))
    FROM (
        -- what the metal is known for
        SELECT ore.signature AS effect_code, sig_side AS magnitude
        UNION ALL
        -- what the slot is for
        SELECT se.effect_code, base_side * se.share
        FROM slot_effects se WHERE se.slot = p_slot
        UNION ALL
        -- what came off the beasts, each part paid its share of the weight
        SELECT pe.effect_code,
               part_side * (pp.pot / GREATEST(part_pot, 1)) * pe.share
        FROM (SELECT bp.part,
                     material_grade(m.rarity)::numeric ^ 2 * u.quantity AS pot
              FROM unnest(p_parts, p_part_qtys) AS u (code, quantity)
              JOIN materials m ON m.code = u.code
              JOIN beast_parts bp ON bp.material_code = u.code) pp
        JOIN part_effects pe ON pe.part = pp.part
        UNION ALL
        -- and the reaction, if the smith could hold it
        SELECT react_eff, react_mag WHERE react_eff IS NOT NULL
    ) c
    JOIN gu_effects ef ON ef.code = c.effect_code
    GROUP BY c.effect_code, ef.cap
    HAVING round(sum(c.magnitude), 4) > 0;

    gained := GREATEST(10, grade * game_config_value('forge_exp_per_tier'));
    lvl := grant_profession_exp(p_player_id, 'blacksmithing', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, total, made_id, made_name, grade, band,
                        p_slot, ore_path, react_word, gained, lvl, spent, 0::bigint;
END;
$$;

COMMENT ON FUNCTION forge(BIGINT, TEXT, TEXT, INTEGER, TEXT[], INTEGER[]) IS
    'Ore and beast materials to equipment. The ore decides the ceiling, the parts decide what it does, harmony decides how much of it survives.';


-- ---------------------------------------------------------------------------
-- equip / unequip
-- ---------------------------------------------------------------------------
-- `apply_physique_xp(player, 0)` is not a flourish. Max HP and defence are
-- STORED on `player_physique` and a battle snapshots them at the door, so a
-- vest granting +10% max HP does nothing at all until something recomputes the
-- body. Zero XP is the recompute, and it is the only line in this file that
-- has to be here rather than anywhere else.

CREATE FUNCTION equip(p_player_id BIGINT, p_equipment_id BIGINT)
RETURNS TABLE (slot TEXT, item_name TEXT, replaced TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    it       player_equipment%ROWTYPE;
    was      TEXT;
BEGIN
    SELECT * INTO it FROM player_equipment
    WHERE equipment_id = p_equipment_id AND owner_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to wear' USING ERRCODE = 'check_violation';
    END IF;

    SELECT pe.name INTO was
    FROM player_equipped q JOIN player_equipment pe ON pe.equipment_id = q.equipment_id
    WHERE q.player_id = p_player_id AND q.slot = it.slot;

    DELETE FROM player_equipped q
    WHERE q.player_id = p_player_id AND q.slot = it.slot;

    INSERT INTO player_equipped (player_id, slot, equipment_id)
    VALUES (p_player_id, it.slot, p_equipment_id);

    PERFORM apply_physique_xp(p_player_id, 0);

    RETURN QUERY SELECT it.slot, it.name, was;
END;
$$;

CREATE FUNCTION unequip(p_player_id BIGINT, p_slot TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    was TEXT;
BEGIN
    SELECT pe.name INTO was
    FROM player_equipped q JOIN player_equipment pe ON pe.equipment_id = q.equipment_id
    WHERE q.player_id = p_player_id AND q.slot = p_slot;

    IF was IS NULL THEN
        RAISE EXCEPTION 'you are wearing nothing there' USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM player_equipped q
    WHERE q.player_id = p_player_id AND q.slot = p_slot;

    PERFORM apply_physique_xp(p_player_id, 0);

    RETURN was;
END;
$$;
