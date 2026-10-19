-- 0020_metal_and_the_starter_roster
--
-- Two things that had to ship together, because the second is what makes the
-- first testable.
--
-- 1. METAL PATH GETS OFFENSIVE ROWS. Since 0002 Metal has appeared in the
--    chart only as a DEFENDER - Lightning and Refinement beat it, it resists
--    Sword - so Metal techniques were neutral into everything. It is the
--    oldest known gap in the schema, asserted by a test so it could not be
--    fixed silently or forgotten. Six rows close it.
--
--    Worth noting how the gap hid: the project's invariant query INNER JOINs
--    on attacker_path, so a Path with no attacking rows drops out of the
--    GROUP BY entirely. Metal was not passing the constraint, it was invisible
--    to it. It is inside the constraint for the first time here.
--
-- 2. THE QI CONDENSATION ROSTER. 46 rank 1 creatures across the five regions,
--    replacing the eight-species "coverage set" 0010 shipped to prove the
--    mechanics. Every one of them is rank 1: a region's danger is expressed in
--    its STATS, not in a rank, because rank gates technique use and all of
--    these are meant to be the tier a new cultivator can reach.
--
--    Stats were fitted to the survivability envelope 0015 established, then
--    checked against the real damage functions. Mean hits for a local creature
--    to kill a fresh 120 HP / 20 defense character:
--
--        central  10.4    eastern 8.3    western 7.4
--        southern 7.5     northern 5.8
--
--    which is the danger ladder the design asks for, monotonic and measured
--    rather than asserted.
--
-- OVERRIDES ARE ONLY FOR WHAT THE CHART CANNOT SAY. Where path_matchups
-- already makes Fire strong into a Wood creature, there is no row here - a
-- redundant override is noise that will disagree with the chart the first time
-- the chart is retuned. Every override below is a fact about that body:
-- a resistance to a Path it IS (reflexive chart rows are banned), an immunity
-- (the chart cannot express immunity at all), or a species quirk.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Metal, at last
-- ---------------------------------------------------------------------------
-- Three advantages and three resistances, all six chosen to keep Metal
-- distinct from Sword. Sword is the edge and the intent: it beats formation,
-- soul and transformation, and is resisted by bone, metal and strength -
-- abstractions cut, materials skid. Metal is the material and nothing else, so
-- it inverts that: it out-hardens bone, and it cannot touch soul, because an
-- ingot is only heavy.
--
-- Fire and Lightning as resistances also restore the two five-phases links the
-- chart was missing, both of which run through Metal.

INSERT INTO path_matchups (attacker_path, defender_path, interaction, flavour_text) VALUES
    ('metal', 'wood', 'advantage',
     'Timber is what you build with when you cannot afford iron.'),
    ('metal', 'bone', 'advantage',
     'Bone is the hardest thing a body can make, and it is still only the second hardest thing in the room.'),
    ('metal', 'ice', 'advantage',
     'Ice is hard the way glass is hard, which is to say not for very long.'),
    ('metal', 'fire', 'resistance',
     'Metal was made in a fire and remembers how that went.'),
    ('metal', 'lightning', 'resistance',
     'Swinging iron at a storm is how you volunteer.'),
    ('metal', 'soul', 'resistance',
     'A blade severs a spirit because a blade is an intention; an ingot is only heavy.');


-- ---------------------------------------------------------------------------
-- Beast materials the roster needs
-- ---------------------------------------------------------------------------
-- Added to the 32 from 0017. Beast materials only ever come off a creature and
-- only ever feed physique cultivation - a trigger on creature_drops enforces
-- the first half and a trigger on region_materials enforces the second.

INSERT INTO materials (code, name, category, rarity)
SELECT code, material_name(code), 'beast', rarity
FROM (VALUES
    ('crystal_carapace', 'uncommon'),   -- central
    ('tortoise_shell_plate', 'uncommon'),   -- central
    ('crab_carapace', 'common'),   -- eastern
    ('shark_tooth', 'common'),   -- eastern
    ('turtle_shell', 'uncommon'),   -- eastern
    ('desert_scale', 'common'),   -- western
    ('gilded_carapace', 'uncommon'),   -- western
    ('mirage_pelt', 'uncommon'),   -- western
    ('moth_wing_dust', 'common'),   -- southern
    ('vitality_sap', 'uncommon'),   -- southern
    ('beast_horn', 'common')   -- northern
) AS v (code, rarity);


-- ---------------------------------------------------------------------------
-- The roster
-- ---------------------------------------------------------------------------

-- Central Continent (danger 2)
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('spirit_rice_rat', 'Spirit Rice Rat', 1, 'beast',
     180, 13, 4, 21,
     'A grey rat grown fat on spirit rice stolen from the terrace paddies. It fights only when cornered, and its bite carries whatever it last ate.'),
    ('crescent_horn_deer', 'Crescent-Horn Deer', 1, 'beast',
     205, 14, 5, 24,
     'A pale doe whose single curved horn keeps holding light for hours after dusk. It runs first and gores only once the rest of the herd is behind it.'),
    ('chilling_grass_mantis', 'Chilling Grass Mantis', 1, 'beast',
     190, 15, 6, 19,
     'Waits motionless in frost-stiffened grass until something warm walks past it. The forelimbs come down cold enough that the wound is numb before it bleeds.'),
    ('purple_crystal_beetle', 'Purple Crystal Beetle', 1, 'beast',
     250, 13, 11, 8,
     'Its shell is mineral rather than chitin, grown in violet layers around a core it spends its whole life refining. Slow, near-blind, and very hard to open.'),
    ('wisdom_eyed_owl', 'Wisdom-Eyed Owl', 1, 'beast',
     195, 14, 7, 22,
     'Roosts in the eaves of abandoned academies and watches cultivators drill. It strikes at what a technique is about to become rather than where it currently is.'),
    ('jade_lotus_toad', 'Jade Lotus Toad', 1, 'beast',
     265, 13, 9, 9,
     'Sits in the lotus beds all day and swallows whatever lands near it. Its skin sweats a green sap that sheds water and discourages anything larger.'),
    ('rule_shell_tortoise', 'Rule-Shell Tortoise', 1, 'elite',
     280, 14, 12, 6,
     'The plates of its shell carry cracked lines that diviners read as law. It has never been observed moving faster than a walk, and nothing in the central plains has found a good angle on it.'),
    ('golden_crow_chick', 'Golden Crow Chick', 1, 'elite',
     245, 15, 8, 17,
     'A fledgling of the sun crows, still too young to fly properly and already too hot to pick up. It burns through its own body heat fast enough that hunting is not optional.');

-- Eastern Sea (danger 3)
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('pearl_shell_crab', 'Pearl Shell Crab', 1, 'beast',
     300, 17, 17, 9,
     'A shallows crab the size of a shield, its shell thickened in layers around grit it could not expel. It does not chase; it plants itself and waits for something to come within reach of the claw.'),
    ('coral_snake', 'Coral Snake', 1, 'beast',
     250, 19, 8, 24,
     'Banded red and white, it threads the coral shelves hunting for anything soft. Thin enough to break if you land a hit, fast enough that landing one is the problem.'),
    ('mist_jellyfish', 'Mist Jellyfish', 1, 'beast',
     245, 18, 6, 12,
     'A pale bell that drifts a foot below the surface and is easiest to find by the burns it leaves. It has no armour at all, and no organs worth rupturing either.'),
    ('star_shell_turtle', 'Star-Shell Turtle', 1, 'beast',
     360, 17, 18, 8,
     'Its shell carries a fixed pattern of pale nodes that hold their positions the way charted stars do. The slowest thing on the reef and the hardest to open.'),
    ('tidefin_fish', 'Tidefin Fish', 1, 'beast',
     240, 17, 7, 29,
     'A hand-length fish that runs the tide line in shoals and turns as one body. Individually it is barely a threat; the shoal is what bleeds you.'),
    ('deep_sea_eel', 'Deep Sea Eel', 1, 'beast',
     265, 19, 9, 26,
     'It comes up from the dark shelf at night and stuns its prey before biting it. The discharge carries through seawater, so distance is not the cover it looks like.'),
    ('scalejaw_shark', 'Scalejaw Shark', 1, 'elite',
     340, 19, 13, 22,
     'Overlapping plate scales run right up over the jaw, so a blade skates off the head and finds nothing. It hunts in a straight line and does not break off once committed.'),
    ('cicada_crab', 'Cicada Crab', 1, 'beast',
     285, 18, 15, 14,
     'It moults on a fixed count of days and buries the old shell rather than leaving it. Fishermen who know the count know exactly which week the beaches are unsafe.'),
    ('young_dragonfish', 'Young Dragonfish', 1, 'elite',
     320, 18, 16, 20,
     'A carp partway through becoming something else: the scales have already hardened and the jaw has already changed, and the rest has not caught up. It is hunted for the scales, which are worth more than the fish.');

-- Western Desert (danger 4)
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('sand_burrower', 'Sand Burrower', 1, 'beast',
     340, 19, 20, 9,
     'A flat, spade-clawed digger that spends the day under six feet of sand and surfaces when something walks overhead. It fights by dragging prey down rather than by biting, so the fight happens on its terms or not at all.'),
    ('flameback_lizard', 'Flameback Lizard', 1, 'beast',
     265, 22, 9, 24,
     'Basks on black rock until its dorsal scales glow, then spends the stored heat in a single lunge. Thin-skinned and quick; it dies fast once you are inside its range.'),
    ('golden_shell_beetle', 'Golden Shell Beetle', 1, 'elite',
     390, 18, 24, 6,
     'Its elytra are a genuine metal alloy, laid down one layer a year. It does not chase and it does not flee; it outlasts, and most attackers give up before the shell does.'),
    ('venomtail_scorpion', 'Venomtail Scorpion', 1, 'beast',
     280, 23, 14, 21,
     'Hand-sized body, forearm-length tail. The sting is not immediately fatal, which is the problem - it works slowly enough that cultivators keep fighting through it.'),
    ('desert_centipede', 'Desert Centipede', 1, 'beast',
     330, 20, 12, 28,
     'Two feet of segmented body moving faster than a man walks. It bites in a line down the limb, injecting at every segment that can reach.'),
    ('mirage_fox', 'Mirage Fox', 1, 'beast',
     260, 21, 8, 27,
     'Bends the heat-haze around itself, so the fox you swing at is standing several feet from the fox. Physically it is an ordinary fox; the entire difficulty is in the aiming.'),
    ('soul_eating_vulture', 'Soul-Eating Vulture', 1, 'beast',
     295, 22, 10, 26,
     'Circles a dying cultivator for days and starts on the soul before the body has finished. Hollow-boned and easy to put down, if you can reach something that never lands.'),
    ('ironjaw_sand_worm', 'Ironjaw Sand Worm', 1, 'elite',
     400, 23, 22, 11,
     'Blind, twenty feet long, ringed with ore-bearing teeth that grind through rock as readily as flesh. It tracks by vibration alone, so standing perfectly still is a real tactic.'),
    ('oasis_serpent', 'Oasis Serpent', 1, 'beast',
     355, 20, 16, 17,
     'Holds the only water for thirty miles and treats every arrival as a competitor for it. Drowns what it can coil around and envenoms what it cannot.');

-- Southern Border (danger 4)
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('jade_bamboo_snake', 'Jade Bamboo Snake', 1, 'beast',
     280, 21, 12, 24,
     'A green tree snake that holds itself rigid among bamboo stems until something walks past. It strikes from a standing coil and does not chase what it misses.'),
    ('mountain_boar', 'Mountain Boar', 1, 'elite',
     380, 22, 19, 16,
     'A ridge-dwelling boar with a hide packed hard by years of rubbing against rock. It charges in a straight line and turns badly.'),
    ('poison_dart_frog', 'Poison Dart Frog', 1, 'beast',
     262, 23, 9, 20,
     'Thumb-sized, brightly banded, and lethal out of all proportion to its size. It has no defence to speak of because nothing that eats one survives to try a second.'),
    ('jadeback_beetle', 'Jadeback Beetle', 1, 'beast',
     300, 18, 24, 6,
     'A knee-high beetle whose shell has taken on the green of the jade seams it burrows through. It is slow enough to walk away from and hard enough that most people do.'),
    ('spirit_grass_deer', 'Spirit Grass Deer', 1, 'beast',
     292, 18, 11, 28,
     'A small deer that grazes only on spirit grass, which shows in its meat and in how fast it leaves. Cornering one is most of the fight.'),
    ('moon_orchid_moth', 'Moon Orchid Moth', 1, 'beast',
     264, 19, 8, 27,
     'A pale moth the width of two hands that feeds on moon orchid at night. Its wing powder blurs the eye and the mind, and it comes apart the moment anything lands on it.'),
    ('vitality_grass_puppet', 'Vitality Grass Puppet', 1, 'beast',
     370, 20, 17, 7,
     'A man-shaped bundle of nine-leaf vitality grass that walks the terraces it was planted to guard. Cut it and it knits; there is nothing inside to stop.'),
    ('skullstone_lizard', 'Skullstone Lizard', 1, 'elite',
     396, 21, 22, 11,
     'A heavy lizard that nests in the skull-stone fields and wears the grave dust it sleeps in. Its plating is mineral rather than horn, and it earths what it is struck with.'),
    ('cliff_tiger_cub', 'Cliff Tiger Cub', 1, 'beast',
     285, 23, 13, 25,
     'Half-grown and already heavier-handed than it has any right to be. It has its mother''s footing on bare rock and none of her patience.'),
    ('springwater_toad', 'Springwater Toad', 1, 'beast',
     330, 19, 15, 8,
     'A squat grey toad that sits in the mouth of a mountain spring and swallows whatever the current brings. It moves twice in a fight, both times badly.');

-- Northern Plains (danger 5)
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('grassland_wolf', 'Grassland Wolf', 1, 'beast',
     340, 26, 10, 30,
     'Hunts the open steppe in pairs, one holding your eyes while the other takes the flank. It carries no armour worth the name because it does not intend to be hit.'),
    ('wild_boar', 'Wild Boar', 1, 'beast',
     430, 25, 16, 18,
     'Four hundred pounds that has settled on a direction and will not be talked out of it. The tusks ride low enough to open a leg before you have registered the charge.'),
    ('black_boar', 'Black Boar', 1, 'beast',
     450, 28, 22, 16,
     'An old boar that has outlived enough hunters to have learned from them. The hide has thickened exactly where spears kept landing.'),
    ('ironhorn_bull', 'Ironhorn Bull', 1, 'elite',
     480, 26, 30, 14,
     'Herd bull of the northern flats, its horns sheathed in a grey metal it grew rather than found. It is slow and has never needed to be otherwise.'),
    ('frost_snake', 'Frost Snake', 1, 'beast',
     330, 29, 12, 28,
     'Lies in the snow at the snow''s own temperature and commits to a single strike. The venom stiffens a limb well before it does anything fatal.'),
    ('thunderhorn_goat', 'Thunderhorn Goat', 1, 'beast',
     360, 26, 14, 26,
     'A cliff goat whose horns crackle in dry air. It butts from further away than it looks able to, because the arc leaves the horn before the horn arrives.'),
    ('bonebeak_vulture', 'Bonebeak Vulture', 1, 'beast',
     335, 25, 11, 32,
     'Follows the herds at a patient distance and is very good at judging when something has stopped being dangerous. The beak is bone the whole way through and shears rather than tears.'),
    ('storm_eagle', 'Storm Eagle', 1, 'elite',
     350, 29, 13, 31,
     'Nests in the thunderheads over the northern range and comes down inside its own weather. By the time you hear it, it has already chosen which of you it is taking.'),
    ('ironbone_bear_cub', 'Ironbone Bear Cub', 1, 'beast',
     430, 28, 24, 12,
     'Not yet grown, and already more than most hunters want. Its skeleton has begun to mineralise, so blows land on something that simply does not give.'),
    ('temporal_cicada', 'Temporal Cicada', 1, 'beast',
     420, 24, 20, 8,
     'Spent some unstated number of years underground and does not agree with you about how long this fight has been going on. It is slow, it does not dodge, and it takes an unreasonable amount of killing.');


-- ---------------------------------------------------------------------------
-- Typing
-- ---------------------------------------------------------------------------

INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path_code, v.is_primary
FROM (VALUES
    ('spirit_rice_rat', 'food', TRUE ),
    ('crescent_horn_deer', 'light', TRUE ),
    ('chilling_grass_mantis', 'ice', TRUE ),
    ('chilling_grass_mantis', 'wood', FALSE),
    ('purple_crystal_beetle', 'refinement', TRUE ),
    ('wisdom_eyed_owl', 'wisdom', TRUE ),
    ('jade_lotus_toad', 'wood', TRUE ),
    ('rule_shell_tortoise', 'rule', TRUE ),
    ('golden_crow_chick', 'fire', TRUE ),
    ('pearl_shell_crab', 'water', TRUE ),
    ('coral_snake', 'blood', TRUE ),
    ('coral_snake', 'water', FALSE),
    ('mist_jellyfish', 'water', TRUE ),
    ('star_shell_turtle', 'star', TRUE ),
    ('star_shell_turtle', 'water', FALSE),
    ('tidefin_fish', 'water', TRUE ),
    ('deep_sea_eel', 'lightning', TRUE ),
    ('deep_sea_eel', 'water', FALSE),
    ('scalejaw_shark', 'strength', TRUE ),
    ('scalejaw_shark', 'water', FALSE),
    ('cicada_crab', 'time', TRUE ),
    ('cicada_crab', 'water', FALSE),
    ('young_dragonfish', 'water', TRUE ),
    ('young_dragonfish', 'transformation', FALSE),
    ('sand_burrower', 'earth', TRUE ),
    ('flameback_lizard', 'fire', TRUE ),
    ('golden_shell_beetle', 'metal', TRUE ),
    ('venomtail_scorpion', 'poison', TRUE ),
    ('desert_centipede', 'poison', TRUE ),
    ('mirage_fox', 'illusion', TRUE ),
    ('soul_eating_vulture', 'soul', TRUE ),
    ('ironjaw_sand_worm', 'metal', TRUE ),
    ('ironjaw_sand_worm', 'earth', FALSE),
    ('oasis_serpent', 'water', TRUE ),
    ('oasis_serpent', 'poison', FALSE),
    ('jade_bamboo_snake', 'wood', TRUE ),
    ('jade_bamboo_snake', 'poison', FALSE),
    ('mountain_boar', 'strength', TRUE ),
    ('mountain_boar', 'earth', FALSE),
    ('poison_dart_frog', 'poison', TRUE ),
    ('jadeback_beetle', 'earth', TRUE ),
    ('spirit_grass_deer', 'wood', TRUE ),
    ('moon_orchid_moth', 'wood', TRUE ),
    ('vitality_grass_puppet', 'wood', TRUE ),
    ('skullstone_lizard', 'earth', TRUE ),
    ('skullstone_lizard', 'soul', FALSE),
    ('cliff_tiger_cub', 'strength', TRUE ),
    ('springwater_toad', 'water', TRUE ),
    ('grassland_wolf', 'strength', TRUE ),
    ('wild_boar', 'strength', TRUE ),
    ('black_boar', 'strength', TRUE ),
    ('ironhorn_bull', 'strength', TRUE ),
    ('ironhorn_bull', 'metal', FALSE),
    ('frost_snake', 'ice', TRUE ),
    ('frost_snake', 'poison', FALSE),
    ('thunderhorn_goat', 'lightning', TRUE ),
    ('bonebeak_vulture', 'bone', TRUE ),
    ('storm_eagle', 'wind', TRUE ),
    ('storm_eagle', 'lightning', FALSE),
    ('ironbone_bear_cub', 'strength', TRUE ),
    ('temporal_cicada', 'time', TRUE )
) AS v (species_code, path_code, is_primary)
JOIN creature_species s ON s.code = v.species_code;


-- ---------------------------------------------------------------------------
-- Per-species overrides
-- ---------------------------------------------------------------------------
-- Layer 1 of weakness resolution: facts about this body that the chart cannot
-- derive from its Path. An override completely replaces the derived value for
-- that (species, path), so these are the only place a creature can resist a
-- Path it is typed with - reflexive chart rows being banned - and the only
-- place immunity can be expressed at all.

INSERT INTO creature_path_modifiers (species_id, path_code, interaction, flavour_text)
SELECT s.species_id, v.path_code, v.interaction, v.flavour
FROM (VALUES
    ('spirit_rice_rat', 'poison', 'advantage',
     'It eats everything it finds. It has never once been able to tell what it should not have eaten.'),
    ('spirit_rice_rat', 'human', 'resistance',
     'Village children have been throwing rocks at these for nine generations. It knows what a person is about to do.'),
    ('purple_crystal_beetle', 'fire', 'advantage',
     'The lattice it spent a lifetime refining crazes and splits the instant it is heated.'),
    ('purple_crystal_beetle', 'metal', 'resistance',
     'Metal against metal, and your blade is the younger and softer of the two.'),
    ('wisdom_eyed_owl', 'wisdom', 'resistance',
     'It has already followed the deduction you are making, and it got there first.'),
    ('jade_lotus_toad', 'water', 'resistance',
     'It has lived in this pond since it hatched. You will not drown a thing in its own bed.'),
    ('rule_shell_tortoise', 'earth', 'resistance',
     'One of the lines on its shell is the rule that a mountain sits still. So it sits still.'),
    ('golden_crow_chick', 'fire', 'resistance',
     'Sun crow. Heat is what it is made of, not something that can be done to it.'),
    ('mist_jellyfish', 'strength', 'resistance',
     'Blunt force sinks into the bell and stops. There is nothing in there to break.'),
    ('star_shell_turtle', 'earth', 'advantage',
     'Earth Path finds the seams between the shell plates and prises them apart.'),
    ('deep_sea_eel', 'water', 'resistance',
     'Water is the medium it hunts in, not a weapon against it. The current parts and closes and the eel is still there.'),
    ('cicada_crab', 'wisdom', 'advantage',
     'Its moult cycle runs on a fixed count. Read the count and you know where it will be standing.'),
    ('cicada_crab', 'water', 'resistance',
     'The shell sheds a current the way it sheds an old shell.'),
    ('flameback_lizard', 'fire', 'resistance',
     'Its back plates are already carrying more heat than they can shed. Fire Path attacks bleed off them and change nothing.'),
    ('golden_shell_beetle', 'fire', 'advantage',
     'The alloy shell conducts heat straight through to the body underneath. The beetle cooks inside its own armour.'),
    ('desert_centipede', 'poison', 'resistance',
     'It carries more venom in one segment than most attacks deliver. Poison Path barely registers on it.'),
    ('mirage_fox', 'wisdom', 'advantage',
     'Wisdom Path reads the displacement for what it is and lands where the fox actually stands.'),
    ('ironjaw_sand_worm', 'fire', 'advantage',
     'Heat softens the ore in the jaw ring and the whole grinding mouth buckles - the earth in it is no protection once the metal goes.'),
    ('oasis_serpent', 'fire', 'resistance',
     'Permanently waterlogged. Fire boils off the coat of water it carries and never reaches the scales - the venom in it is beside the point.'),
    ('jade_bamboo_snake', 'poison', 'resistance',
     'Its own venom runs in its blood. Poison Path barely troubles it.'),
    ('mountain_boar', 'earth', 'resistance',
     'Stone and grit slide off a hide that has spent its life against them.'),
    ('poison_dart_frog', 'poison', 'immunity',
     'It sweats the stuff. Poison Path does nothing to it at all.'),
    ('spirit_grass_deer', 'water', 'resistance',
     'Grass that has drunk deep does not drown. Water Path washes over it.'),
    ('moon_orchid_moth', 'soul', 'resistance',
     'The powder confuses a probing spirit before it can find anything to grip.'),
    ('vitality_grass_puppet', 'water', 'resistance',
     'Water only feeds it. The wounds close as fast as they open.'),
    ('vitality_grass_puppet', 'blood', 'resistance',
     'It has no blood to boil. Blood Path finds nothing to take hold of.'),
    ('skullstone_lizard', 'lightning', 'resistance',
     'The charge runs through its stone plating and into the ground.'),
    ('cliff_tiger_cub', 'earth', 'resistance',
     'It was born on the cliff face. Shifting ground does not shift it.'),
    ('black_boar', 'strength', 'resistance',
     'The hide is a record of every man who tried hitting it harder. That is the one thing it was built against.'),
    ('ironhorn_bull', 'fire', 'advantage',
     'The horn sheath conducts beautifully. Heat it and you are cooking the skull underneath.'),
    ('frost_snake', 'ice', 'resistance',
     'You are offering cold to something that has been keeping its own since it hatched.'),
    ('thunderhorn_goat', 'wind', 'resistance',
     'It spends its life on a ledge in a gale. Wind is weather to this thing, not an attack.'),
    ('storm_eagle', 'wind', 'resistance',
     'It banks into your gust and gains height on it. You have helped.'),
    ('temporal_cicada', 'wisdom', 'advantage',
     'Count the moult lines. Its cycle is fixed, and there is a beat in it where it cannot move at all.')
) AS v (species_code, path_code, interaction, flavour)
JOIN creature_species s ON s.code = v.species_code;


-- ---------------------------------------------------------------------------
-- Drops
-- ---------------------------------------------------------------------------

INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT s.species_id, v.material, v.chance, v.lo, v.hi
FROM (VALUES
    ('spirit_rice_rat', 'beast_blood', 0.6, 1, 2),
    ('spirit_rice_rat', 'lingzhi_meat', 0.35, 1, 2),
    ('spirit_rice_rat', 'bone_fragment', 0.15, 1, 1),
    ('crescent_horn_deer', 'beast_blood', 0.65, 1, 2),
    ('crescent_horn_deer', 'lingzhi_meat', 0.3, 1, 2),
    ('crescent_horn_deer', 'bone_spear_tip', 0.2, 1, 1),
    ('chilling_grass_mantis', 'cicada_shell', 0.55, 1, 2),
    ('chilling_grass_mantis', 'bone_spear_tip', 0.22, 1, 1),
    ('chilling_grass_mantis', 'cicada_essence', 0.08, 1, 1),
    ('purple_crystal_beetle', 'crystal_carapace', 0.55, 1, 3),
    ('purple_crystal_beetle', 'cicada_shell', 0.3, 1, 2),
    ('purple_crystal_beetle', 'beast_core', 0.06, 1, 1),
    ('wisdom_eyed_owl', 'eagle_feather', 0.65, 1, 3),
    ('wisdom_eyed_owl', 'bone_fragment', 0.3, 1, 2),
    ('wisdom_eyed_owl', 'soul_pearl', 0.06, 1, 1),
    ('jade_lotus_toad', 'beast_blood', 0.6, 1, 2),
    ('jade_lotus_toad', 'lingzhi_meat', 0.35, 1, 2),
    ('jade_lotus_toad', 'venom_sac', 0.15, 1, 1),
    ('rule_shell_tortoise', 'tortoise_shell_plate', 0.5, 1, 2),
    ('rule_shell_tortoise', 'bone_fragment', 0.4, 1, 3),
    ('rule_shell_tortoise', 'beast_core', 0.08, 1, 1),
    ('golden_crow_chick', 'eagle_feather', 0.6, 1, 3),
    ('golden_crow_chick', 'beast_blood', 0.45, 1, 2),
    ('golden_crow_chick', 'golden_crow_essence', 0.1, 1, 1),
    ('pearl_shell_crab', 'crab_carapace', 0.6, 1, 2),
    ('pearl_shell_crab', 'beast_blood', 0.35, 1, 2),
    ('pearl_shell_crab', 'pearl', 0.25, 1, 1),
    ('coral_snake', 'venom_sac', 0.6, 1, 2),
    ('coral_snake', 'snake_gall', 0.4, 1, 1),
    ('coral_snake', 'blood_coral', 0.2, 1, 1),
    ('mist_jellyfish', 'venom_sac', 0.65, 1, 2),
    ('mist_jellyfish', 'beast_blood', 0.3, 1, 1),
    ('mist_jellyfish', 'life_essence', 0.05, 1, 1),
    ('star_shell_turtle', 'turtle_shell', 0.55, 1, 2),
    ('star_shell_turtle', 'bone_fragment', 0.4, 1, 2),
    ('star_shell_turtle', 'beast_core', 0.1, 1, 1),
    ('tidefin_fish', 'fish_scale_shard', 0.75, 1, 3),
    ('tidefin_fish', 'beast_blood', 0.4, 1, 2),
    ('deep_sea_eel', 'fish_scale_shard', 0.55, 1, 2),
    ('deep_sea_eel', 'beast_blood', 0.45, 1, 2),
    ('deep_sea_eel', 'beast_core', 0.12, 1, 1),
    ('scalejaw_shark', 'shark_tooth', 0.7, 1, 3),
    ('scalejaw_shark', 'fish_scale_shard', 0.5, 1, 2),
    ('scalejaw_shark', 'iron_bone', 0.1, 1, 1),
    ('cicada_crab', 'cicada_shell', 0.65, 1, 2),
    ('cicada_crab', 'crab_carapace', 0.35, 1, 2),
    ('cicada_crab', 'cicada_essence', 0.2, 1, 1),
    ('young_dragonfish', 'fish_scale_shard', 0.6, 1, 3),
    ('young_dragonfish', 'dragon_scale', 0.1, 1, 1),
    ('young_dragonfish', 'life_essence', 0.06, 1, 1),
    ('sand_burrower', 'beast_blood', 0.65, 1, 2),
    ('sand_burrower', 'bone_fragment', 0.45, 1, 2),
    ('sand_burrower', 'iron_bone', 0.07, 1, 1),
    ('flameback_lizard', 'desert_scale', 0.65, 1, 3),
    ('flameback_lizard', 'beast_blood', 0.55, 1, 2),
    ('flameback_lizard', 'golden_crow_essence', 0.05, 1, 1),
    ('golden_shell_beetle', 'gilded_carapace', 0.65, 1, 2),
    ('golden_shell_beetle', 'iron_bone', 0.25, 1, 1),
    ('golden_shell_beetle', 'beast_core', 0.1, 1, 1),
    ('venomtail_scorpion', 'scorpion_stinger', 0.75, 1, 2),
    ('venomtail_scorpion', 'venom_sac', 0.5, 1, 2),
    ('venomtail_scorpion', 'poison_heart', 0.12, 1, 1),
    ('desert_centipede', 'centipede_venom', 0.75, 1, 3),
    ('desert_centipede', 'cicada_shell', 0.4, 1, 2),
    ('desert_centipede', 'poison_heart', 0.1, 1, 1),
    ('mirage_fox', 'mirage_pelt', 0.55, 1, 2),
    ('mirage_fox', 'beast_blood', 0.5, 1, 2),
    ('mirage_fox', 'beast_core', 0.08, 1, 1),
    ('soul_eating_vulture', 'eagle_feather', 0.7, 1, 3),
    ('soul_eating_vulture', 'soul_crystal', 0.3, 1, 1),
    ('soul_eating_vulture', 'tormented_soul', 0.1, 1, 1),
    ('ironjaw_sand_worm', 'bone_spear_tip', 0.55, 1, 2),
    ('ironjaw_sand_worm', 'iron_bone', 0.35, 1, 2),
    ('ironjaw_sand_worm', 'beast_core', 0.2, 1, 1),
    ('oasis_serpent', 'desert_scale', 0.6, 1, 3),
    ('oasis_serpent', 'snake_gall', 0.55, 1, 1),
    ('oasis_serpent', 'venom_sac', 0.4, 1, 2),
    ('jade_bamboo_snake', 'venom_sac', 0.55, 1, 2),
    ('jade_bamboo_snake', 'snake_gall', 0.45, 1, 1),
    ('jade_bamboo_snake', 'beast_blood', 0.4, 1, 2),
    ('mountain_boar', 'boar_tusk', 0.7, 1, 2),
    ('mountain_boar', 'beast_blood', 0.55, 1, 3),
    ('mountain_boar', 'black_boar_tusk', 0.18, 1, 1),
    ('poison_dart_frog', 'venom_sac', 0.7, 1, 2),
    ('poison_dart_frog', 'beast_blood', 0.3, 1, 1),
    ('poison_dart_frog', 'poison_heart', 0.18, 1, 1),
    ('jadeback_beetle', 'cicada_shell', 0.65, 1, 3),
    ('jadeback_beetle', 'cicada_essence', 0.2, 1, 1),
    ('jadeback_beetle', 'iron_bone', 0.06, 1, 1),
    ('spirit_grass_deer', 'lingzhi_meat', 0.6, 1, 2),
    ('spirit_grass_deer', 'beast_blood', 0.5, 1, 2),
    ('spirit_grass_deer', 'life_essence', 0.07, 1, 1),
    ('moon_orchid_moth', 'moth_wing_dust', 0.65, 1, 3),
    ('moon_orchid_moth', 'beast_blood', 0.35, 1, 1),
    ('moon_orchid_moth', 'cicada_essence', 0.25, 1, 1),
    ('vitality_grass_puppet', 'vitality_sap', 0.65, 1, 3),
    ('vitality_grass_puppet', 'lingzhi_meat', 0.4, 1, 2),
    ('vitality_grass_puppet', 'life_essence', 0.1, 1, 1),
    ('skullstone_lizard', 'skull_fragment', 0.65, 1, 2),
    ('skullstone_lizard', 'soul_crystal', 0.28, 1, 1),
    ('skullstone_lizard', 'iron_bone', 0.1, 1, 1),
    ('cliff_tiger_cub', 'beast_blood', 0.6, 1, 2),
    ('cliff_tiger_cub', 'tiger_fang', 0.5, 1, 1),
    ('cliff_tiger_cub', 'bone_fragment', 0.35, 1, 2),
    ('springwater_toad', 'beast_blood', 0.65, 1, 2),
    ('springwater_toad', 'venom_sac', 0.22, 1, 1),
    ('springwater_toad', 'pearl', 0.08, 1, 1),
    ('grassland_wolf', 'wolf_pelt', 0.7, 1, 2),
    ('grassland_wolf', 'wolf_fang', 0.55, 1, 2),
    ('grassland_wolf', 'beast_blood', 0.4, 1, 2),
    ('wild_boar', 'boar_tusk', 0.7, 1, 2),
    ('wild_boar', 'beast_blood', 0.55, 1, 3),
    ('wild_boar', 'lingzhi_meat', 0.3, 1, 2),
    ('black_boar', 'black_boar_tusk', 0.6, 1, 2),
    ('black_boar', 'beast_blood', 0.5, 1, 3),
    ('black_boar', 'boar_tusk', 0.45, 1, 2),
    ('ironhorn_bull', 'beast_horn', 0.55, 1, 2),
    ('ironhorn_bull', 'beast_blood', 0.6, 1, 3),
    ('ironhorn_bull', 'iron_bone', 0.18, 1, 1),
    ('frost_snake', 'venom_sac', 0.6, 1, 2),
    ('frost_snake', 'snake_gall', 0.55, 1, 1),
    ('frost_snake', 'poison_heart', 0.12, 1, 1),
    ('thunderhorn_goat', 'beast_horn', 0.5, 1, 2),
    ('thunderhorn_goat', 'beast_blood', 0.5, 1, 2),
    ('thunderhorn_goat', 'beast_core', 0.08, 1, 1),
    ('bonebeak_vulture', 'bone_fragment', 0.7, 1, 3),
    ('bonebeak_vulture', 'eagle_feather', 0.4, 1, 2),
    ('bonebeak_vulture', 'skull_fragment', 0.3, 1, 2),
    ('storm_eagle', 'eagle_feather', 0.75, 1, 3),
    ('storm_eagle', 'beast_core', 0.2, 1, 1),
    ('storm_eagle', 'footless_bird', 0.05, 1, 1),
    ('ironbone_bear_cub', 'beast_blood', 0.65, 1, 3),
    ('ironbone_bear_cub', 'bone_fragment', 0.45, 1, 2),
    ('ironbone_bear_cub', 'iron_bone', 0.22, 1, 1),
    ('temporal_cicada', 'cicada_shell', 0.75, 1, 3),
    ('temporal_cicada', 'cicada_essence', 0.35, 1, 2),
    ('temporal_cicada', 'life_essence', 0.06, 1, 1)
) AS v (species_code, material, chance, lo, hi)
JOIN creature_species s ON s.code = v.species_code;


-- ---------------------------------------------------------------------------
-- Where they live
-- ---------------------------------------------------------------------------
-- The eight species from 0010 keep their placements: they are still legitimate
-- higher-rank content, and /hunt reaching a rank 5 elite in the Northern
-- Plains is the point of the Northern Plains.

INSERT INTO creature_regions (species_id, region_code, weight)
SELECT s.species_id, v.region, v.weight
FROM (VALUES
    ('spirit_rice_rat', 'central', 10),
    ('crescent_horn_deer', 'central', 10),
    ('chilling_grass_mantis', 'central', 10),
    ('purple_crystal_beetle', 'central', 10),
    ('wisdom_eyed_owl', 'central', 10),
    ('jade_lotus_toad', 'central', 10),
    ('rule_shell_tortoise', 'central', 4),
    ('golden_crow_chick', 'central', 4),
    ('pearl_shell_crab', 'eastern', 10),
    ('coral_snake', 'eastern', 10),
    ('mist_jellyfish', 'eastern', 10),
    ('star_shell_turtle', 'eastern', 10),
    ('tidefin_fish', 'eastern', 10),
    ('deep_sea_eel', 'eastern', 10),
    ('scalejaw_shark', 'eastern', 4),
    ('cicada_crab', 'eastern', 10),
    ('young_dragonfish', 'eastern', 4),
    ('sand_burrower', 'western', 10),
    ('flameback_lizard', 'western', 10),
    ('golden_shell_beetle', 'western', 4),
    ('venomtail_scorpion', 'western', 10),
    ('desert_centipede', 'western', 10),
    ('mirage_fox', 'western', 10),
    ('soul_eating_vulture', 'western', 10),
    ('ironjaw_sand_worm', 'western', 4),
    ('oasis_serpent', 'western', 10),
    ('jade_bamboo_snake', 'southern', 10),
    ('mountain_boar', 'southern', 4),
    ('poison_dart_frog', 'southern', 10),
    ('jadeback_beetle', 'southern', 10),
    ('spirit_grass_deer', 'southern', 10),
    ('moon_orchid_moth', 'southern', 10),
    ('vitality_grass_puppet', 'southern', 10),
    ('skullstone_lizard', 'southern', 4),
    ('cliff_tiger_cub', 'southern', 10),
    ('springwater_toad', 'southern', 10),
    ('grassland_wolf', 'northern', 10),
    ('wild_boar', 'northern', 10),
    ('black_boar', 'northern', 10),
    ('ironhorn_bull', 'northern', 4),
    ('frost_snake', 'northern', 10),
    ('thunderhorn_goat', 'northern', 10),
    ('bonebeak_vulture', 'northern', 10),
    ('storm_eagle', 'northern', 4),
    ('ironbone_bear_cub', 'northern', 10),
    ('temporal_cicada', 'northern', 10)
) AS v (species_code, region, weight)
JOIN creature_species s ON s.code = v.species_code;
