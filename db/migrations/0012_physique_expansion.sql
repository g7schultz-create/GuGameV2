-- 0012_physique_expansion
--
-- 0006 built `physiques` with three rows, enough to prove the shape. This
-- fills it out to the design's list and brings it into line with the two
-- traits added in 0011, so all three of Race, Root and Physique carry the
-- same kinds of bonus and the bot can read them the same way.
--
-- Three changes to the existing table:
--
--   1. `tier` becomes a real foreign key into `rarities` instead of a CHECK
--      list. The CHECK had five values and the design needs eight; more to the
--      point, roll weights now live in one place for both roots and physiques
--      rather than being a constant somewhere in the roller.
--
--   2. Rate and unmodelled columns are added to match `races` and `roots`.
--
--   3. The two extreme physiques seeded in 0006 are corrected to the design's
--      numbers and moved out of `legendary`, where they never belonged - the
--      Ten Extreme sit outside the normal ladder.
--
-- Note the two conventions living side by side here, deliberately:
-- `hp_multiplier` and friends are multipliers (1.25), because 0008's pipeline
-- already multiplies by them; every bonus added since is an additive fraction
-- (0.25), because several sources are summed before being applied once.
-- `player_trait_bonuses` in 0013 is where the two meet.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Bring the table into line
-- ---------------------------------------------------------------------------

ALTER TABLE physiques DROP CONSTRAINT physiques_tier_check;

ALTER TABLE physiques
    ADD CONSTRAINT physiques_tier_fkey
    FOREIGN KEY (tier) REFERENCES rarities (code) ON DELETE RESTRICT;

CREATE INDEX physiques_tier_idx ON physiques (tier);

ALTER TABLE physiques
    ADD COLUMN cultivation_rate_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN physique_rate_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN attainment_rate_bonus  NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN special_name           TEXT,
    ADD COLUMN special_text           TEXT,
    ADD COLUMN unmodelled             JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- The Ten Extreme carry Aperture Instability. There is no instability
    -- system yet, so this is the flag that will drive it and, until then, the
    -- warning line in the embed.
    ADD COLUMN aperture_instability   BOOLEAN NOT NULL DEFAULT FALSE,
    -- Not everything in this table should be reachable by a first roll.
    ADD COLUMN rollable               BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN physiques.unmodelled IS
    'Designed effects with no system yet. Displayed as text and marked inactive - distinct from `traits`, which holds live mechanical payloads.';
COMMENT ON COLUMN physiques.aperture_instability IS
    'The Ten Extreme drawback. No system behind it yet; carried so the risk half of the risk/reward is not quietly lost.';


-- ---------------------------------------------------------------------------
-- physique_path_bonuses
-- ---------------------------------------------------------------------------
-- The third of the three per-Path bonus tables, matching the two in 0011.

CREATE TABLE physique_path_bonuses (
    physique_id      SMALLINT NOT NULL REFERENCES physiques (physique_id) ON DELETE CASCADE,
    path_code        TEXT     NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    attainment_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    damage_bonus     NUMERIC(6, 4) NOT NULL DEFAULT 0,

    PRIMARY KEY (physique_id, path_code)
);

CREATE INDEX physique_path_bonuses_path_idx ON physique_path_bonuses (path_code);


-- ---------------------------------------------------------------------------
-- Correct the two extreme physiques from 0006
-- ---------------------------------------------------------------------------

UPDATE physiques SET
    tier                 = 'extreme',
    hp_multiplier        = 1.2500,
    defense_multiplier   = 1.1500,
    strength_multiplier  = 1.3000,
    physique_rate_bonus  = 0.5000,
    aperture_instability = TRUE,
    special_name         = 'True Martial',
    special_text         = 'Every physique breakthrough permanently increases physical damage.',
    description          = 'A body forged for raw power. There is no technique in it, and none is needed.'
WHERE code = 'great_strength_true_martial';

UPDATE physiques SET
    tier                   = 'extreme',
    hp_multiplier          = 1.2000,
    defense_multiplier     = 1.4000,
    cultivation_rate_bonus = 0.2500,
    physique_rate_bonus    = 0.2000,
    aperture_instability   = TRUE,
    special_name           = 'Northern Dark Ice',
    special_text           = 'Ice techniques have a chance to freeze what they touch.',
    unmodelled             = '{"Ice resistance": "+50%"}'::jsonb,
    description            = 'A frozen soul-body. The cold is not something it endures; it is what it is made of.'
WHERE code = 'northern_dark_ice_soul';


-- ---------------------------------------------------------------------------
-- The rest of the list
-- ---------------------------------------------------------------------------

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, aperture_instability, description)
VALUES
    -- Common
    ('strong_boned_body', 'Strong-Boned Body', 'common', NULL, 1,
     1.0500, 1.0000, 1.0000, 0, 0.0500, 0,
     NULL, NULL, '{}'::jsonb, FALSE,
     'Nothing remarkable, except that it keeps not breaking.'),

    ('flexible_meridian_body', 'Flexible Meridian Body', 'common', NULL, 1,
     1.0000, 1.0000, 1.0000, 0, 0, 0,
     NULL, NULL, '{"Essence regeneration": "+5%", "Evasion": "+3%"}'::jsonb, FALSE,
     'Qi moves through it the way water moves downhill.'),

    ('thick_skinned_body', 'Thick-Skinned Body', 'common', NULL, 1,
     1.0000, 1.0700, 1.0000, 0, 0, 0,
     NULL, NULL, '{}'::jsonb, FALSE,
     'Takes a hit the way a wall takes a thrown stone.'),

    ('lightfoot_body', 'Lightfoot Body', 'common', NULL, 1,
     1.0000, 1.0000, 1.0000, 0, 0, 0,
     NULL, NULL, '{"Speed": "+5%", "Evasion": "+3%"}'::jsonb, FALSE,
     'Leaves less of a print than it should.'),

    -- Uncommon
    ('iron_bone_physique', 'Iron Bone Physique', 'uncommon', NULL, 1,
     1.0000, 1.1000, 1.0000, 0, 0.0800, 0,
     NULL, NULL, '{"Strength resistance": "+5%"}'::jsonb, FALSE,
     'The bones ring when struck. They do not give.'),

    ('jade_skin_physique', 'Jade Skin Physique', 'uncommon', NULL, 1,
     1.0500, 1.0800, 1.0000, 0, 0, 0,
     NULL, NULL, '{"Poison resistance": "+10%"}'::jsonb, FALSE,
     'Cool and faintly translucent. Very little gets through it.'),

    ('flameblood_physique', 'Flameblood Physique', 'uncommon', 'fire', 1.2000,
     1.0000, 1.0000, 1.0000, 0, 0.0800, 0,
     NULL, NULL, '{"Fire resistance": "+10%"}'::jsonb, FALSE,
     'Runs hot enough that winter is an inconvenience rather than a season.'),

    ('frostblood_physique', 'Frostblood Physique', 'uncommon', 'ice', 1.2000,
     1.0000, 1.0000, 1.0000, 0, 0.0800, 0,
     NULL, NULL, '{"Ice resistance": "+10%"}'::jsonb, FALSE,
     'Cold to the touch, and unbothered by being so.'),

    -- Rare
    ('blood_tyrant_body', 'Blood Tyrant Body', 'rare', 'blood', 1.3000,
     1.1500, 1.0000, 1.0000, 0, 0.1500, 0,
     NULL, NULL, '{"Lifesteal": "+5%"}'::jsonb, FALSE,
     'It heals from what it takes, which is a habit that gets worse.'),

    ('thunderbone_physique', 'Thunderbone Physique', 'rare', 'lightning', 1.3000,
     1.0000, 1.0000, 1.0000, 0, 0, 0,
     NULL, NULL, '{"Speed": "+10%", "Lightning resistance": "+15%"}'::jsonb, FALSE,
     'The marrow carries a charge it never fully discharges.'),

    ('ancient_beast_body', 'Ancient Beast Body', 'rare', 'transformation', 1.3000,
     1.1000, 1.0000, 1.1500, 0, 0.2000, 0,
     NULL, NULL, '{}'::jsonb, FALSE,
     'Something in the lineage was not a person, and has not forgotten.'),

    ('sword_bone_physique', 'Sword Bone Physique', 'rare', 'sword', 1.3000,
     1.0000, 1.1000, 1.0000, 0, 0, 0,
     NULL, NULL, '{"Sword resistance": "+10%"}'::jsonb, FALSE,
     'The skeleton is an edge that happens to be inside someone.'),

    -- Extreme: the two the design specifies beyond the pair already seeded.
    ('carefree_wisdom_heart', 'Carefree Wisdom Heart Physique', 'extreme', 'wisdom', 1.5000,
     1.0000, 1.0000, 1.0000, 0, 0, 0.1000,
     'Carefree Heart',
     'Can occasionally comprehend a technique simply by watching it used.',
     '{"Technique comprehension": "+30%", "Attainment breakthrough chance": "+15%"}'::jsonb, TRUE,
     'A mind entirely unbothered by what it is looking at, which turns out to be the trick.'),

    ('blazing_glory_lightning_brilliance', 'Blazing Glory Lightning Brilliance Physique', 'extreme', 'fire', 1.5000,
     1.0000, 1.0000, 1.0000, 0, 0, 0,
     'Blazing Lightning',
     'Techniques typed both Fire and Lightning strike for a quarter again as much.',
     '{"Speed": "+15%", "Fire + Lightning dual-Path damage": "+25%"}'::jsonb, TRUE,
     'Two Paths that should tear a body apart, running in the same channels without complaint.');


-- ---------------------------------------------------------------------------
-- Per-Path bonuses for everything above
-- ---------------------------------------------------------------------------

INSERT INTO physique_path_bonuses (physique_id, path_code, attainment_bonus, damage_bonus)
SELECT p.physique_id, v.path_code, v.attainment_bonus, v.damage_bonus
FROM (VALUES
    ('flameblood_physique',                'fire',      0.0000, 0.0800),
    ('frostblood_physique',                'ice',       0.0000, 0.0800),

    ('blood_tyrant_body',                  'blood',     0.0000, 0.1200),
    ('thunderbone_physique',               'lightning', 0.0000, 0.1500),
    ('ancient_beast_body',                 'strength',  0.0000, 0.1500),
    ('ancient_beast_body',                 'transformation', 0.0000, 0.1000),
    ('sword_bone_physique',                'sword',     0.0000, 0.1500),

    ('northern_dark_ice_soul',             'ice',       0.5000, 0.3000),
    ('northern_dark_ice_soul',             'soul',      0.2500, 0.0000),
    ('great_strength_true_martial',        'strength',  0.5000, 0.3000),
    ('carefree_wisdom_heart',              'wisdom',    0.5000, 0.0000),
    ('blazing_glory_lightning_brilliance', 'fire',      0.3500, 0.2000),
    ('blazing_glory_lightning_brilliance', 'lightning', 0.3500, 0.2000)
) AS v (physique_code, path_code, attainment_bonus, damage_bonus)
JOIN physiques p ON p.code = v.physique_code;


-- Mortal Body is what you have before anything else is revealed. It stays
-- rollable - most characters get it, and that is the point of the extremes
-- being extreme.
COMMENT ON TABLE physiques IS
    'Innate bodies, rolled at character creation. `tier` bands them for rolling; the Ten Extreme sit in their own band outside the normal ladder.';
