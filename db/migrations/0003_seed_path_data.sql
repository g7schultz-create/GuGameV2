-- 0003_seed_path_data
--
-- Reference data for the Path system: the Paths themselves, the matchup
-- chart from design spec section 4, attainment tiers from section 1, and the
-- global tunables sections 5/10/11 call out.
--
-- GENERATED - see scratchpad/gen_seed.py. Values marked PLACEHOLDER are not
-- specified by the design doc and exist to be tuned.
--
-- Forward-only. Rebalancing later means a new migration with UPDATEs, not an
-- edit to this file (the runner checksums applied files and will refuse).


-- ---------------------------------------------------------------------------
-- Matchup interaction magnitudes (spec section 3)
-- ---------------------------------------------------------------------------
-- Deliberately NOT Pokemon's 2x: with attainment, Dao Marks, equipment, Gu,
-- physiques and crits all stacking, doubling would dominate every other system.

INSERT INTO matchup_interactions (code, name, damage_modifier, sort_order) VALUES
    ('major_advantage', 'Major Advantage', 0.5000, 1),
    ('advantage', 'Advantage', 0.2500, 2),
    ('neutral', 'Neutral', 0.0000, 3),
    ('resistance', 'Resistance', -0.2000, 4);


-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

INSERT INTO paths (code, name, category, uses_matchups, description, sort_order) VALUES
    ('fire', 'Fire Path', 'combat', TRUE , 'Burning, consuming force.', 10),
    ('water', 'Water Path', 'combat', TRUE , 'Flowing, adaptive force.', 20),
    ('ice', 'Ice Path', 'combat', TRUE , 'Freezing stillness.', 30),
    ('wood', 'Wood Path', 'combat', TRUE , 'Growth, vitality and life.', 40),
    ('lightning', 'Lightning Path', 'combat', TRUE , 'Sudden, piercing speed.', 50),
    ('earth', 'Earth Path', 'combat', TRUE , 'Weight, stability and mass.', 60),
    ('metal', 'Metal Path', 'combat', TRUE , 'Hardness, edge and sharpness.', 70),
    ('sword', 'Sword Path', 'combat', TRUE , 'The edge that severs all things.', 80),
    ('strength', 'Strength Path', 'combat', TRUE , 'Raw physical might.', 90),
    ('blood', 'Blood Path', 'combat', TRUE , 'Vitality drawn from blood and flesh.', 100),
    ('soul', 'Soul Path', 'combat', TRUE , 'Attacks upon the spirit itself.', 110),
    ('wisdom', 'Wisdom Path', 'combat', TRUE , 'Insight, deduction and stratagem.', 120),
    ('space', 'Space Path', 'combat', TRUE , 'Distance, position and displacement.', 130),
    ('time', 'Time Path', 'combat', TRUE , 'Acceleration, delay and sequence.', 140),
    ('luck', 'Luck Path', 'combat', TRUE , 'Fortune bent toward the wielder.', 150),
    ('refinement', 'Refinement Path', 'combat', TRUE , 'Purification and reforging.', 160),
    ('formation', 'Formation Path', 'combat', TRUE , 'Arrays, wards and battlefield structure.', 170),
    ('enslavement', 'Enslavement Path', 'combat', TRUE , 'Domination and control of others.', 180),
    ('transformation', 'Transformation Path', 'combat', TRUE , 'Change of shape and nature.', 190),
    ('theft', 'Theft Path', 'combat', TRUE , 'Taking what belongs to another.', 200),
    ('poison', 'Poison Path', 'combat', TRUE , 'Corruption that spreads and lingers.', 210),
    ('human', 'Human Path', 'special', TRUE , 'The strength and cunning of humankind.', 220),
    ('heaven', 'Heaven Path', 'special', TRUE , 'The will of heaven and fate itself.', 230),
    ('qi', 'Qi Path', 'exotic', FALSE, 'Manipulation of raw qi.', 240),
    ('dream', 'Dream Path', 'exotic', FALSE, 'Intrusion into sleep and illusion.', 250),
    ('painting', 'Painting Path', 'exotic', FALSE, 'Reality rendered and rewritten.', 260),
    ('food', 'Food Path', 'exotic', FALSE, 'Sustenance, flavour and nourishment.', 270),
    ('rule', 'Rule Path', 'exotic', FALSE, 'Law imposed upon reality.', 280);


-- ---------------------------------------------------------------------------
-- Path matchup chart (spec section 4)
-- ---------------------------------------------------------------------------
-- Directed attacker -> defender. Neutral pairings are absent rows, not stored
-- zeroes. Every Path gets ~3 advantages and ~2 resistances so no single type is
-- strictly best, which is what makes covering several Paths worth the effort.
--
-- NOTE: Metal appears only as a DEFENDER in the design chart (Lightning and
-- Refinement beat it; it resists Sword). It has no attacking row of its own, so
-- Metal techniques are currently neutral into everything. Add its offensive
-- matchups in a later migration once decided.

INSERT INTO path_matchups (attacker_path, defender_path, interaction) VALUES
    -- fire
    ('fire', 'wood', 'advantage'),
    ('fire', 'ice', 'advantage'),
    ('fire', 'poison', 'advantage'),
    ('fire', 'water', 'resistance'),
    ('fire', 'earth', 'resistance'),
    -- water
    ('water', 'fire', 'advantage'),
    ('water', 'lightning', 'advantage'),
    ('water', 'blood', 'advantage'),
    ('water', 'ice', 'resistance'),
    ('water', 'earth', 'resistance'),
    -- ice
    ('ice', 'water', 'advantage'),
    ('ice', 'wood', 'advantage'),
    ('ice', 'transformation', 'advantage'),
    ('ice', 'fire', 'resistance'),
    ('ice', 'strength', 'resistance'),
    -- wood
    ('wood', 'earth', 'advantage'),
    ('wood', 'soul', 'advantage'),
    ('wood', 'water', 'advantage'),
    ('wood', 'fire', 'resistance'),
    ('wood', 'poison', 'resistance'),
    -- lightning
    ('lightning', 'metal', 'advantage'),
    ('lightning', 'transformation', 'advantage'),
    ('lightning', 'soul', 'advantage'),
    ('lightning', 'earth', 'resistance'),
    ('lightning', 'time', 'resistance'),
    -- earth
    ('earth', 'lightning', 'advantage'),
    ('earth', 'fire', 'advantage'),
    ('earth', 'strength', 'advantage'),
    ('earth', 'wood', 'resistance'),
    ('earth', 'space', 'resistance'),
    -- sword
    ('sword', 'soul', 'advantage'),
    ('sword', 'transformation', 'advantage'),
    ('sword', 'formation', 'advantage'),
    ('sword', 'metal', 'resistance'),
    ('sword', 'strength', 'resistance'),
    -- strength
    ('strength', 'sword', 'advantage'),
    ('strength', 'ice', 'advantage'),
    ('strength', 'transformation', 'advantage'),
    ('strength', 'wisdom', 'resistance'),
    ('strength', 'soul', 'resistance'),
    -- blood
    ('blood', 'strength', 'advantage'),
    ('blood', 'human', 'advantage'),
    ('blood', 'wood', 'advantage'),
    ('blood', 'fire', 'resistance'),
    ('blood', 'soul', 'resistance'),
    -- soul
    ('soul', 'blood', 'advantage'),
    ('soul', 'strength', 'advantage'),
    ('soul', 'wisdom', 'advantage'),
    ('soul', 'sword', 'resistance'),
    ('soul', 'lightning', 'resistance'),
    -- wisdom
    ('wisdom', 'strength', 'advantage'),
    ('wisdom', 'formation', 'advantage'),
    ('wisdom', 'enslavement', 'advantage'),
    ('wisdom', 'soul', 'resistance'),
    ('wisdom', 'luck', 'resistance'),
    -- space
    ('space', 'earth', 'advantage'),
    ('space', 'formation', 'advantage'),
    ('space', 'sword', 'advantage'),
    ('space', 'time', 'resistance'),
    ('space', 'wisdom', 'resistance'),
    -- time
    ('time', 'space', 'advantage'),
    ('time', 'lightning', 'advantage'),
    ('time', 'transformation', 'advantage'),
    ('time', 'wisdom', 'resistance'),
    ('time', 'luck', 'resistance'),
    -- luck
    ('luck', 'wisdom', 'advantage'),
    ('luck', 'time', 'advantage'),
    ('luck', 'theft', 'advantage'),
    ('luck', 'human', 'resistance'),
    ('luck', 'formation', 'resistance'),
    -- refinement
    ('refinement', 'metal', 'advantage'),
    ('refinement', 'poison', 'advantage'),
    ('refinement', 'formation', 'advantage'),
    ('refinement', 'theft', 'resistance'),
    ('refinement', 'fire', 'resistance'),
    -- formation
    ('formation', 'luck', 'advantage'),
    ('formation', 'refinement', 'advantage'),
    ('formation', 'enslavement', 'advantage'),
    ('formation', 'wisdom', 'resistance'),
    ('formation', 'space', 'resistance'),
    -- enslavement
    ('enslavement', 'strength', 'advantage'),
    ('enslavement', 'soul', 'advantage'),
    ('enslavement', 'human', 'advantage'),
    ('enslavement', 'wisdom', 'resistance'),
    ('enslavement', 'formation', 'resistance'),
    -- transformation
    ('transformation', 'wood', 'advantage'),
    ('transformation', 'enslavement', 'advantage'),
    ('transformation', 'poison', 'advantage'),
    ('transformation', 'sword', 'resistance'),
    ('transformation', 'ice', 'resistance'),
    -- theft
    ('theft', 'refinement', 'advantage'),
    ('theft', 'formation', 'advantage'),
    ('theft', 'human', 'advantage'),
    ('theft', 'luck', 'resistance'),
    ('theft', 'wisdom', 'resistance'),
    -- poison
    ('poison', 'wood', 'advantage'),
    ('poison', 'blood', 'advantage'),
    ('poison', 'enslavement', 'advantage'),
    ('poison', 'fire', 'resistance'),
    ('poison', 'refinement', 'resistance'),
    -- human
    ('human', 'luck', 'advantage'),
    ('human', 'enslavement', 'advantage'),
    ('human', 'theft', 'advantage'),
    ('human', 'blood', 'resistance'),
    ('human', 'heaven', 'resistance'),
    -- heaven
    ('heaven', 'human', 'advantage'),
    ('heaven', 'luck', 'advantage'),
    ('heaven', 'transformation', 'advantage');


-- ---------------------------------------------------------------------------
-- Attainment tiers (spec section 1)
-- ---------------------------------------------------------------------------
-- damage_bonus is taken verbatim from the design doc's scaling table.
--
-- resistance_bonus: only the Grandmaster value (+10%) is specified, by the
-- section 8 example. Higher tiers are PLACEHOLDER.
--
-- insight_required: entirely PLACEHOLDER - the doc gives no curve. Roughly
-- 2.5x per tier so each rank costs meaningfully more than the last. Expect to
-- retune once there are real numbers for insight per hour of cultivation.

INSERT INTO attainment_tiers (tier, code, name, damage_bonus, resistance_bonus, insight_required) VALUES
    ( 0, 'uninitiated',                'Uninitiated',                  0.0000, 0.0000,         0),
    ( 1, 'ordinary',                   'Ordinary',                     0.0000, 0.0000,         0),
    ( 2, 'expert',                     'Expert',                       0.0300, 0.0000,      1000),
    ( 3, 'quasi_master',               'Quasi-Master',                 0.0600, 0.0000,      3000),
    ( 4, 'master',                     'Master',                       0.1000, 0.0000,      8000),
    ( 5, 'quasi_grandmaster',          'Quasi-Grandmaster',            0.1500, 0.0000,     20000),
    ( 6, 'grandmaster',                'Grandmaster',                  0.2000, 0.1000,     50000),
    ( 7, 'quasi_great_grandmaster',    'Quasi-Great Grandmaster',      0.2700, 0.1000,    120000),
    ( 8, 'great_grandmaster',          'Great Grandmaster',            0.3500, 0.1500,    300000),
    ( 9, 'quasi_supreme_grandmaster',  'Quasi-Supreme Grandmaster',    0.4500, 0.1500,    750000),
    (10, 'supreme_grandmaster',        'Supreme Grandmaster',          0.6000, 0.2500,   2000000);


-- ---------------------------------------------------------------------------
-- Global tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('matchup_bonus_cap', 0.50, 'Maximum total matchup bonus a single technique can receive (spec 5).'),
    ('matchup_penalty_floor', -0.50, 'PLACEHOLDER - floor on total matchup penalty. Not specified; mirrors the cap.'),
    ('path_cultivation_xp_rate', 0.85, 'Cultivation XP multiplier when cultivating toward a specific Path (spec 10).'),
    ('path_physique_xp_rate', 0.80, 'Physique XP multiplier when training toward a specific Path (spec 11).'),
    ('dual_path_primary_weight', 0.50, 'Default weight of a dual-Path technique''s primary Path. 0.50 = simple average (spec 5).');
