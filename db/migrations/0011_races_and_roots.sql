-- 0011_races_and_roots
--
-- The first two of the three character-creation traits. Physiques already
-- exist (0006); this adds the Race a character is born as and the Root they
-- are born with, per the Races/Roots/Physiques design.
--
-- The three are deliberately independent: Race is what you are, Root is your
-- affinity with the Dao, Physique is the body itself. Rolling them separately
-- is what produces build diversity from three small tables instead of one
-- enormous list of pre-baked characters.
--
-- Shape notes:
--
--   * Bonuses that apply to *everything* are columns on the race/root
--     (cultivation rate, all-Path attainment). Bonuses that apply to one Path
--     are rows in a side table, because "how much does this character gain in
--     Fire" is summed on every accrual and has to be joinable.
--
--   * `race_path_bonuses` and `root_path_bonuses` are two tables rather than
--     one polymorphic table with a `source_kind` column. A polymorphic parent
--     cannot have a real foreign key, and every FK in this schema is declared.
--
--   * Effects the game has no system for yet (evasion, crit, Gu refinement,
--     drop rates, cooldowns) go in `unmodelled` as JSONB and are displayed as
--     text. They are recorded rather than dropped so the design survives in
--     one place, and they are honestly marked rather than silently doing
--     nothing.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- rarities
-- ---------------------------------------------------------------------------
-- Shared by roots and physiques. `roll_weight` is the design's percentage, and
-- it is a weight rather than a probability on purpose: a band with no members
-- yet simply never comes up and the rest renormalise, instead of the roll
-- failing or silently returning nothing.

CREATE TABLE rarities (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,

    roll_weight NUMERIC(8, 4) NOT NULL CHECK (roll_weight >= 0),

    -- Embed colour, so a Unique root does not have to be recognised by name.
    colour      INTEGER NOT NULL DEFAULT 5987746,

    sort_order  SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO rarities (code, name, roll_weight, colour, sort_order) VALUES
    ('common',    'Common',    45.0000,  9807270, 10),
    ('uncommon',  'Uncommon',  28.0000,  3901635, 20),
    ('rare',      'Rare',      15.0000,  3447003, 30),
    ('epic',      'Epic',       7.0000, 10181046, 40),
    ('legendary', 'Legendary',  3.5000, 15844367, 50),
    ('mythic',    'Mythic',     1.4000, 15277667, 60),
    ('unique',    'Unique',     0.1000, 16766720, 70),
    -- The Ten Extreme sit outside the normal ladder by design. No root is
    -- extreme; the band exists for physiques only.
    ('extreme',   'Extreme',    0.1000, 16711680, 80);

COMMENT ON TABLE rarities IS
    'Roll bands shared by roots and physiques. roll_weight is a weight, not a probability: empty bands renormalise away.';


-- ---------------------------------------------------------------------------
-- races
-- ---------------------------------------------------------------------------
-- Humans and the variant-human races. A race is chosen, not rolled - it is the
-- one trait the player states about their character rather than receives.

CREATE TABLE races (
    code                   TEXT PRIMARY KEY,
    name                   TEXT NOT NULL UNIQUE,

    -- One word for what this race is for, shown beside the name.
    specialty              TEXT NOT NULL DEFAULT '',
    description            TEXT NOT NULL DEFAULT '',

    -- Fractions, not multipliers: 0.05 means +5%. Stored this way so several
    -- sources can be summed before being applied once, rather than multiplying
    -- and quietly compounding.
    cultivation_rate_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    physique_rate_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,

    -- Attainment gain in *every* Path. This is the human advantage, and the
    -- reason the generalist is not simply worse than every specialist.
    attainment_rate_bonus  NUMERIC(6, 4) NOT NULL DEFAULT 0,

    hp_bonus               NUMERIC(6, 4) NOT NULL DEFAULT 0,
    defense_bonus          NUMERIC(6, 4) NOT NULL DEFAULT 0,
    strength_bonus         NUMERIC(6, 4) NOT NULL DEFAULT 0,

    -- Designed effects with no system behind them yet. Keys are display text.
    unmodelled             JSONB NOT NULL DEFAULT '{}'::jsonb,

    playable               BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order             SMALLINT NOT NULL DEFAULT 0
);

COMMENT ON COLUMN races.unmodelled IS
    'Designed effects with no system yet (evasion, yields, refinement). Displayed as text and marked inactive, never silently applied.';

INSERT INTO races
    (code, name, specialty, description,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     hp_bonus, defense_bonus, strength_bonus, unmodelled, sort_order)
VALUES
    ('human', 'Human', 'Adaptability',
     'Spirit of All Living Beings. No specialty, and no weakness either - the only race that gains in every Path at once.',
     0.0500, 0, 0.0500, 0, 0, 0, '{}'::jsonb, 10),

    ('hairy_man', 'Hairy Man', 'Refinement',
     'Broad-backed and patient. The refiners other races come to when a Gu matters.',
     0, 0, 0, 0, 0, 0,
     '{"Gu refinement success": "+10%"}'::jsonb, 20),

    ('rockman', 'Rockman', 'Earth',
     'Slow, immovable, and still standing when the fight is over.',
     0, 0, 0, 0, 0.1000, 0, '{}'::jsonb, 30),

    ('featherman', 'Featherman', 'Flight',
     'Hollow-boned and quick. Distance is a suggestion.',
     0, 0, 0, 0, 0, 0,
     '{"Speed / evasion": "+10%"}'::jsonb, 40),

    ('inkman', 'Inkman', 'Information',
     'Remembers everything it has read, which is most things.',
     0, 0, 0, 0, 0, 0,
     '{"Technique comprehension": "+10%"}'::jsonb, 50),

    ('snowman', 'Snowman', 'Ice',
     'Born in eternal frost, calm and enduring.',
     0, 0, 0, 0, 0, 0, '{}'::jsonb, 60),

    ('miniman', 'Miniman', 'Wood',
     'Small enough to live among the roots, and to know what grows there.',
     0, 0, 0, 0, 0, 0,
     '{"Herb and material yield": "+10%"}'::jsonb, 70),

    ('merman', 'Merman', 'Water',
     'At home in deep water, where sound carries further than sight.',
     0, 0, 0, 0, 0, 0, '{}'::jsonb, 80),

    ('beastman', 'Beastman', 'Transformation',
     'Wears a shape rather than being one.',
     0, 0.1000, 0, 0, 0, 0, '{}'::jsonb, 90),

    ('mushroomman', 'Mushroomman', 'Poison',
     'What kills it is usually what it eats.',
     0, 0, 0, 0, 0, 0,
     '{"Poison resistance": "+15%"}'::jsonb, 100),

    ('dragonman', 'Dragonman', 'Enslavement',
     'Made rather than born. It has never entirely forgiven that.',
     0, 0, 0, 0, 0, 0,
     '{"Servant and pet power": "+10%"}'::jsonb, 110);


-- ---------------------------------------------------------------------------
-- race_path_bonuses
-- ---------------------------------------------------------------------------
-- The per-Path half of a race's advantage.
--
-- MAPPING NOTE. The design names four Paths this game does not have: Cloud,
-- Information, Sound and Snow. Rather than invent four Paths that would sit
-- outside the matchup chart the way Metal currently does, each is mapped to
-- its nearest existing Path and recorded here:
--
--     Cloud / Flying -> space        (displacement and position)
--     Information    -> wisdom       (deduction and stratagem)
--     Sound          -> soul         (the closest non-physical Path; a stretch)
--     Snow           -> ice          (the same thing under another name)
--
-- The Sound mapping is the weak one. If a Sound Path is ever added, this table
-- is where Merman moves - one row, not a schema change.

CREATE TABLE race_path_bonuses (
    race_code        TEXT NOT NULL REFERENCES races (code) ON DELETE CASCADE,
    path_code        TEXT NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    attainment_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    damage_bonus     NUMERIC(6, 4) NOT NULL DEFAULT 0,

    PRIMARY KEY (race_code, path_code)
);

CREATE INDEX race_path_bonuses_path_idx ON race_path_bonuses (path_code);

INSERT INTO race_path_bonuses (race_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('hairy_man',   'refinement',     0.1500, 0),
    ('rockman',     'earth',          0.1500, 0),
    ('featherman',  'space',          0.1500, 0),
    ('inkman',      'wisdom',         0.1500, 0),
    ('snowman',     'ice',            0.1500, 0.1500),
    ('miniman',     'wood',           0.1500, 0),
    ('merman',      'water',          0.1000, 0.1000),
    ('merman',      'soul',           0.1000, 0),
    ('beastman',    'transformation', 0.1500, 0),
    ('mushroomman', 'poison',         0.1500, 0),
    ('dragonman',   'enslavement',    0.1500, 0);


-- ---------------------------------------------------------------------------
-- roots
-- ---------------------------------------------------------------------------
-- Affinity with the Dao. Rolled, not chosen - which is what makes a reroll
-- worth spending and a Unique worth remembering.

CREATE TABLE roots (
    code                   TEXT PRIMARY KEY,
    name                   TEXT NOT NULL UNIQUE,

    rarity                 TEXT NOT NULL REFERENCES rarities (code) ON DELETE RESTRICT,

    description            TEXT NOT NULL DEFAULT '',

    cultivation_rate_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    physique_rate_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,
    attainment_rate_bonus  NUMERIC(6, 4) NOT NULL DEFAULT 0,

    hp_bonus               NUMERIC(6, 4) NOT NULL DEFAULT 0,
    defense_bonus          NUMERIC(6, 4) NOT NULL DEFAULT 0,
    strength_bonus         NUMERIC(6, 4) NOT NULL DEFAULT 0,

    -- The named once-per-day powers of the inheritor roots, and everything
    -- else with no system yet.
    special_name           TEXT,
    special_text           TEXT,
    unmodelled             JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- Roots evolve through inheritances and rare opportunities (design §7).
    -- NULL means this is where the line ends for now.
    evolves_into           TEXT REFERENCES roots (code) ON DELETE SET NULL,

    sort_order             SMALLINT NOT NULL DEFAULT 0
);

CREATE INDEX roots_rarity_idx ON roots (rarity);
CREATE INDEX roots_evolves_into_idx ON roots (evolves_into);

COMMENT ON COLUMN roots.evolves_into IS
    'Design section 7: a weak starting roll is not a permanent ceiling. Self-referencing, so an evolution line is data rather than code.';

INSERT INTO roots
    (code, name, rarity, description,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     hp_bonus, defense_bonus, strength_bonus,
     special_name, special_text, unmodelled, sort_order)
VALUES
    -- Common
    ('earthen_root', 'Earthen Root', 'common',
     'Steady, unhurried, and harder to move each year.',
     0, 0.0300, 0, 0, 0, 0, NULL, NULL, '{}'::jsonb, 10),

    ('flowing_water_root', 'Flowing Water Root', 'common',
     'Takes the shape of whatever holds it, and wears that away.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Essence recovery": "+3%"}'::jsonb, 20),

    ('green_wood_root', 'Green Wood Root', 'common',
     'Grows toward whatever light there is.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Gathering yield": "+3%"}'::jsonb, 30),

    ('ember_root', 'Ember Root', 'common',
     'Never quite goes out.',
     0, 0, 0, 0, 0, 0, NULL, NULL, '{}'::jsonb, 40),

    ('iron_root', 'Iron Root', 'common',
     'Plain, heavy, and unwilling to bend.',
     0, 0, 0, 0, 0.0300, 0, NULL, NULL, '{}'::jsonb, 50),

    -- Uncommon
    ('frozen_river_root', 'Frozen River Root', 'uncommon',
     'Water that stopped moving without ever stopping.',
     0, 0, 0, 0, 0, 0, NULL, NULL, '{}'::jsonb, 60),

    ('blood_vine_root', 'Blood Vine Root', 'uncommon',
     'It grows, and what it grows on gets less.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Blood-technique lifesteal": "+3%"}'::jsonb, 70),

    ('mountain_heart_root', 'Mountain Heart Root', 'uncommon',
     'The patience of something that expects to outlast the range it sits in.',
     0, 0.0500, 0, 0.0500, 0, 0, NULL, NULL, '{}'::jsonb, 80),

    -- Rare
    ('heavenly_sword_root', 'Heavenly Sword Root', 'rare',
     'Born already knowing which way an edge wants to go.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Sword technique comprehension": "+10%"}'::jsonb, 90),

    ('ancient_beast_root', 'Ancient Beast Root', 'rare',
     'Something older than your bloodline is awake in it.',
     0, 0.1000, 0, 0, 0, 0, NULL, NULL, '{}'::jsonb, 100),

    ('thousand_thought_root', 'Thousand Thought Root', 'rare',
     'Considers every branch at once, and is tired accordingly.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Technique comprehension": "+15%", "Attainment breakthrough chance": "+5%"}'::jsonb, 110),

    -- Epic
    ('void_spirit_root', 'Void Spirit Root', 'epic',
     'Occupies rather less space than it appears to.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Evasion": "+8%"}'::jsonb, 120),

    ('primordial_blood_root', 'Primordial Blood Root', 'epic',
     'The blood is older than the body carrying it.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Lifesteal": "+5%"}'::jsonb, 130),

    ('heavenly_refinement_root', 'Heavenly Refinement Root', 'epic',
     'Sees what a material was meant to become.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Gu refinement success": "+10%", "Refinement material consumption": "-5%"}'::jsonb, 140),

    -- Legendary
    ('primordial_sword_heart', 'Primordial Sword Heart', 'legendary',
     'Not a talent for the sword. A sword, wearing a person.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Sword techniques ignore defense": "5%", "Sword breakthrough chance": "+10%"}'::jsonb, 150),

    ('ancient_time_root', 'Ancient Time Root', 'legendary',
     'Arrives slightly before it is due.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Cooldown reduction": "+5%"}'::jsonb, 160),

    ('heavenly_wisdom_root', 'Heavenly Wisdom Root', 'legendary',
     'Reaches the end of the reasoning before the question finishes.',
     0, 0, 0, 0, 0, 0,
     'Insight of Heaven',
     'A chance to reveal a creature''s weakness without paying for it in blood.',
     '{"Wisdom technique effectiveness": "+20%"}'::jsonb, 170),

    -- Unique - the inheritors
    ('giant_suns_inheritor', 'Giant Sun''s Inheritor', 'unique',
     'The Giant Sun Immortal Venerable''s fortune, carried by someone who has not earned it yet.',
     0, 0, 0, 0, 0, 0,
     'Fortune Favors the Chosen',
     'Once per day, reroll one failed refinement, breakthrough or rare drop.',
     '{"Rare drop chance": "+10%", "Critical chance": "+5%", "Luck": "+50"}'::jsonb, 180),

    ('red_lotus_inheritor', 'Red Lotus'' Inheritor', 'unique',
     'Red Lotus Demon Venerable''s line. Time is a room you can walk back into.',
     0, 0, 0, 0, 0, 0,
     'River of Time',
     'Once per day, reset the cooldown of one technique.',
     '{"Cooldown reduction": "+10%"}'::jsonb, 190),

    ('reckless_savages_inheritor', 'Reckless Savage''s Inheritor', 'unique',
     'Reckless Savage Demon Venerable''s line. Refinement was never the point.',
     0, 0.2500, 0, 0, 0, 0, NULL, NULL, '{}'::jsonb, 200),

    ('thieving_heavens_inheritor', 'Thieving Heaven''s Inheritor', 'unique',
     'Thieving Heaven Demon Venerable''s line. What is yours is a temporary arrangement.',
     0, 0, 0, 0, 0, 0, NULL, NULL,
     '{"Rare loot chance": "+10%", "Evasion": "+10%"}'::jsonb, 210);


-- The one evolution line the design gives as an example. Its two upper stages
-- are not rollable - `roll_weight` never sees them because the roll only draws
-- from bands, and these carry the same band as their source; instead they are
-- reached by evolving. Marked by having something evolve *into* them.
INSERT INTO roots (code, name, rarity, description, sort_order) VALUES
    ('blazing_yang_root', 'Blazing Yang Root', 'rare',
     'An Ember Root that caught properly.', 41),
    ('heavenly_flame_root', 'Heavenly Flame Root', 'epic',
     'Fire that no longer needs anything to burn.', 42);

UPDATE roots SET evolves_into = 'blazing_yang_root'   WHERE code = 'ember_root';
UPDATE roots SET evolves_into = 'heavenly_flame_root' WHERE code = 'blazing_yang_root';


-- ---------------------------------------------------------------------------
-- root_path_bonuses
-- ---------------------------------------------------------------------------

CREATE TABLE root_path_bonuses (
    root_code        TEXT NOT NULL REFERENCES roots (code) ON DELETE CASCADE,
    path_code        TEXT NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    attainment_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    damage_bonus     NUMERIC(6, 4) NOT NULL DEFAULT 0,

    PRIMARY KEY (root_code, path_code)
);

CREATE INDEX root_path_bonuses_path_idx ON root_path_bonuses (path_code);

INSERT INTO root_path_bonuses (root_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('earthen_root',              'earth',          0.0500, 0),
    ('flowing_water_root',        'water',          0.0500, 0),
    ('green_wood_root',           'wood',           0.0500, 0),
    ('ember_root',                'fire',           0.0500, 0.0300),
    ('iron_root',                 'metal',          0.0500, 0),

    ('frozen_river_root',         'ice',            0.0800, 0.0500),
    ('frozen_river_root',         'water',          0.0500, 0),
    ('blood_vine_root',           'blood',          0.0800, 0),
    ('blood_vine_root',           'wood',           0.0500, 0),
    ('mountain_heart_root',       'earth',          0.0800, 0),

    ('heavenly_sword_root',       'sword',          0.1500, 0.0800),
    ('ancient_beast_root',        'transformation', 0.1500, 0),
    ('ancient_beast_root',        'strength',       0.0800, 0),
    ('thousand_thought_root',     'wisdom',         0.1500, 0),

    ('void_spirit_root',          'space',          0.2000, 0.1200),
    ('primordial_blood_root',     'blood',          0.2000, 0.1200),
    ('heavenly_refinement_root',  'refinement',     0.2000, 0),

    ('primordial_sword_heart',    'sword',          0.3000, 0.1500),
    ('ancient_time_root',         'time',           0.3000, 0.1500),
    ('heavenly_wisdom_root',      'wisdom',         0.3000, 0.2000),

    ('giant_suns_inheritor',      'luck',           0.5000, 0.2500),
    ('red_lotus_inheritor',       'time',           0.5000, 0.2500),
    ('reckless_savages_inheritor','strength',       0.3500, 0.1500),
    ('reckless_savages_inheritor','transformation', 0.3500, 0),
    ('thieving_heavens_inheritor','theft',          0.5000, 0),
    ('thieving_heavens_inheritor','space',          0.2000, 0),

    ('blazing_yang_root',         'fire',           0.1500, 0.0800),
    ('heavenly_flame_root',       'fire',           0.2500, 0.1500);
