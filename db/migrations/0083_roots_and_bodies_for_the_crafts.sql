-- 0083_roots_and_bodies_for_the_crafts
--
-- Eleven rolled traits for the people who make things.
--
-- Every root and body in the game so far is about cultivating, fighting or
-- surviving. Five professions have shipped since - Alchemist, Gu Refiner,
-- Blacksmith, and now Forager and Explorer - and nothing you are BORN with has
-- ever cared about any of them. A player whose whole game is the anvil rolls
-- the same table as one who has never lit a forge.
--
-- ROOTS LEARN THE VOCABULARY. `physique_effects` gave bodies a way to speak in
-- the shared `gu_effects` words back in 0053, and roots never got one - they
-- have only ever had Path packages and flat stat columns. `root_effects` is
-- the same table for the other rolled trait, and `player_stat` sums it with
-- the rest under the same ceiling.
--
-- THREE MORE WORDS, one per craft, each with exactly one consumer:
--
--   forge_power   - the base stats a forged piece comes out with. This is the
--                   Unique root's whole identity.
--   brew_potency  - what a pill pays out.
--   gu_potency    - what a bench of auxiliary materials is worth toward a Gu's
--                   star ceiling.
--
-- THE LADDER IS THE ONE BODIES ALREADY USE. `physique_power` is keyed on the
-- rarity ladder rather than on anything about physiques, so a root of a band
-- reads the same row. A rolled trait of a given rarity is worth what that
-- rarity is worth, whichever of the two pillars it landed in - and one UPDATE
-- still retunes both. The band 'unique' is added to it here, because roots
-- reach a band bodies do not.
--
-- WHAT THESE DELIBERATELY DO NOT DO. No new root carries a flat
-- `cultivation_rate_bonus`: 0011 established that no root is the one that
-- makes numbers bigger, and there is a test that says so. Each takes a single
-- Path package, below its band's ceiling, so none of them becomes the best
-- root of its rarity by accident.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The ladder reaches Unique
-- ---------------------------------------------------------------------------

INSERT INTO physique_power (tier, ranks) VALUES ('unique', 27);

COMMENT ON TABLE physique_power IS
    'What a ROLLED trait of each band is worth, in steps. Named for physiques because they asked first; roots read the same row, because a band is worth what a band is worth.';


-- ---------------------------------------------------------------------------
-- One word per craft
-- ---------------------------------------------------------------------------

INSERT INTO gu_effects (code, name, description, cap, is_live, emoji, sort_order, step) VALUES
    ('forge_power', 'Smith''s Hand',
     'Base stats on everything you forge. It is applied to the piece''s whole budget, so it reaches every stat the piece has.',
     0.6000, TRUE, '🔨', 280, 0.0120),
    ('brew_potency', 'Cauldron Sense',
     'How much a finished pill pays out, on top of what its grade and harmony already bought.',
     0.6000, TRUE, '⚗️', 290, 0.0120),
    ('gu_potency', 'Worm Sense',
     'What a bench of auxiliary materials is worth toward a Gu''s star ceiling.',
     0.6000, TRUE, '🐛', 300, 0.0120);


-- ---------------------------------------------------------------------------
-- root_effects
-- ---------------------------------------------------------------------------

CREATE TABLE root_effects (
    root_code   TEXT NOT NULL REFERENCES roots (code) ON DELETE CASCADE,
    effect_code TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE RESTRICT,

    magnitude   NUMERIC(6, 4) NOT NULL CHECK (magnitude > 0),

    PRIMARY KEY (root_code, effect_code)
);

CREATE INDEX root_effects_effect_idx ON root_effects (effect_code);

COMMENT ON TABLE root_effects IS
    'What a root is worth in the shared effect vocabulary. The other half of what 0053 gave physiques.';

-- A player has exactly one root, so there is nothing to sum - but the cap is
-- still applied, because the ceiling belongs to the effect and not to whichever
-- table happens to be granting it.
CREATE FUNCTION root_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT LEAST(e.cap, re.magnitude)
         FROM player_character pc
         JOIN root_effects re ON re.root_code = pc.root_code
         JOIN gu_effects e ON e.code = re.effect_code
         WHERE pc.player_id = p_player_id AND re.effect_code = p_effect),
        0
    );
$$;

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
    );
$$;

COMMENT ON FUNCTION player_stat(BIGINT, TEXT) IS
    'One effect, summed across Gu, worn equipment, the body and the root, capped once. The per-source functions still exist and still mean what they say.';


-- ---------------------------------------------------------------------------
-- Six roots
-- ---------------------------------------------------------------------------

INSERT INTO roots (code, name, rarity, description, special_name, special_text, sort_order) VALUES
    ('ore_reading_root', 'Ore-Reading Root', 'rare',
     'An aperture that hums at a particular pitch near worked metal, and a different one near metal worth working.',
     'Reads the Grain',
     'Knows where the metal wants to go before the hammer asks it.', 610),

    ('bitter_tongue_root', 'Bitter Tongue Root', 'rare',
     'Everything tastes of what it is. This is less pleasant than it sounds and more useful than it looks.',
     'Tastes the Dose',
     'A pill leaves this cauldron carrying more than it should.', 620),

    ('hollow_bore_root', 'Hollow Bore Root', 'epic',
     'The aperture is not solid. Something small could live in there, and something small usually does.',
     'Somewhere to Put Them',
     'Auxiliary materials sit deeper on this bench than on anybody else''s.', 630),

    ('crucible_heart_root', 'Crucible Heart Root', 'legendary',
     'Fired rather than grown. What went into this aperture did not all come out, and what stayed is doing something.',
     'Holds the Heat',
     'Metal comes out of this forge stronger, and materials that should argue do not.', 640),

    ('nine_cauldron_root', 'Nine Cauldron Root', 'mythic',
     'Nine chambers, and a cultivator who has counted them twice has counted wrong once.',
     'Nine Vessels',
     'Whatever is being brewed or bound, there is a chamber in here shaped for it.', 650),

    ('heavens_forge_root', 'Heaven''s Forge Root', 'unique',
     'The heavens make things too. This aperture is the shape of the place where they do it, at a scale a mortal can stand beside.',
     'Struck on Heaven''s Anvil',
     'Everything this cultivator forges comes off the anvil carrying more than the materials put in.', 660);

-- One Path each, and each of them under its band's ceiling: a craft root must
-- not also be the best Path package of its rarity.
INSERT INTO root_path_bonuses (root_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('ore_reading_root',    'metal',      0.1000, 0.0500),
    ('bitter_tongue_root',  'wood',       0.1000, 0.0400),
    ('hollow_bore_root',    'refinement', 0.1800, 0.0800),
    ('crucible_heart_root', 'fire',       0.2200, 0.1200),
    ('nine_cauldron_root',  'refinement', 0.3000, 0.1500),
    ('heavens_forge_root',  'metal',      0.4200, 0.2200);

INSERT INTO root_effects (root_code, effect_code, magnitude)
SELECT v.code, v.effect, round(e.step * pw.ranks * v.weight, 4)
FROM (VALUES
    ('ore_reading_root',    'forge_power',            1.00),
    ('bitter_tongue_root',  'brew_potency',           1.00),
    ('hollow_bore_root',    'gu_potency',             1.00),
    ('crucible_heart_root', 'forge_power',            0.65),
    ('crucible_heart_root', 'refine_conflict_relief', 0.35),
    ('nine_cauldron_root',  'brew_potency',           0.55),
    ('nine_cauldron_root',  'gu_potency',             0.45),
    ('heavens_forge_root',  'forge_power',            1.00)
) AS v (code, effect, weight)
JOIN roots r           ON r.code = v.code
JOIN physique_power pw ON pw.tier = r.rarity
JOIN gu_effects e      ON e.code = v.effect;


-- ---------------------------------------------------------------------------
-- Five bodies
-- ---------------------------------------------------------------------------
-- Physiques stop at Divine here. The band above is Extreme, and the Ten
-- Extreme Physiques are a named set from the setting rather than a rarity a
-- new body may simply be assigned to.

INSERT INTO physiques
    (code, name, tier, hp_multiplier, defense_multiplier, strength_multiplier,
     description, special_name, special_text)
VALUES
    ('ash_lung_body', 'Ash Lung Body', 'rare', 1.05, 1.08, 1.00,
     'Breathes forge smoke the way other bodies breathe air, and has stopped being able to tell the difference.',
     'Breathes the Forge',
     'Stands in the heat long enough to get the quench right.'),

    ('iron_palate_body', 'Iron Palate Body', 'rare', 1.08, 1.05, 1.00,
     'Has swallowed enough failed pills to have opinions about all of them.',
     'Nothing Is Poison Twice',
     'A body that has survived its own cauldron knows what the cauldron is doing.'),

    ('worm_nested_body', 'Worm-Nested Body', 'epic', 1.10, 1.06, 1.05,
     'There is more than one thing living in here and they have reached an arrangement.',
     'Room for Them',
     'Gu materials settle into this body rather than merely passing through it.'),

    ('quenched_bone_body', 'Quenched Bone Body', 'legendary', 1.17, 1.18, 1.10,
     'Bone taken to heat and then to water, on purpose, by somebody who knew what they were doing.',
     'Tempered, Not Grown',
     'A body made the way a blade is made, and it makes blades the same way.'),

    ('hundred_cauldron_body', 'Hundred Cauldron Body', 'mythic', 1.18, 1.14, 1.12,
     'A hundred brews have been through this body and every one of them left a note.',
     'The Hundredth Reading',
     'Nothing goes into a cauldron in front of this body that it has not already tasted.');

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT p.physique_id, v.effect, round(e.step * pw.ranks * v.weight, 4)
FROM (VALUES
    ('ash_lung_body',          'forge_power',            1.00),
    ('iron_palate_body',       'brew_potency',           1.00),
    ('worm_nested_body',       'gu_potency',             1.00),
    ('quenched_bone_body',     'forge_power',            0.70),
    ('quenched_bone_body',     'refine_conflict_relief', 0.30),
    ('hundred_cauldron_body',  'brew_potency',           0.70),
    ('hundred_cauldron_body',  'gu_potency',             0.30)
) AS v (code, effect, weight)
JOIN physiques p       ON p.code = v.code
JOIN physique_power pw ON pw.tier = p.tier
JOIN gu_effects e      ON e.code = v.effect;
