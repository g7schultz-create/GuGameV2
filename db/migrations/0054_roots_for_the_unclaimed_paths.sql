-- 0054_roots_for_the_unclaimed_paths
--
-- Fourteen Paths that no root was born for.
--
-- The root roster grew top-down - the interesting bands got written first -
-- and left half the Path list with nothing pointing at it. A cultivator could
-- roll thirty-one different roots and not one of them would ever have an
-- opinion about Bone, Poison, Shadow, Light, Star, Wind, Lightning, Soul, Qi,
-- Human, Food, Enslavement, Illusion or Painting.
--
-- That is worse than a gap in a rarity band, which at least fails loudly by
-- awarding nothing. This failed quietly: those Paths were fully playable, had
-- techniques and creatures and Gu, and simply could not be a talent.
--
-- LOW BANDS ON PURPOSE. Two Common, two Uncommon, two Rare, two Epic. These
-- are missing coverage, not new top-end content - a Path nobody is born for
-- needs an ordinary root far more than it needs a legendary one, and the
-- Common band is where the roll actually lands 45% of the time.
--
-- Band weight is split among members rather than added to, so eight more roots
-- change no band's odds. They change what those odds pay out.
--
-- PAIRED, BECAUSE A PAIR SAYS SOMETHING A SINGLE PATH CANNOT. Poison with Bone
-- is rot and what rot leaves; Wind with Lightning is one storm seen twice.
-- Every pairing here is new to the roster, which the neighbour rule requires.
--
-- Forward-only. Do not edit once applied.

INSERT INTO roots (code, name, rarity, description, special_name, special_text, unmodelled, sort_order) VALUES
    -- Common. The two most ordinary things a body does.
    ('spirit_breath_root', 'Spirit Breath Root', 'common',
     'The first thing anyone cultivates is breathing, and most people stop there.',
     NULL, NULL,
     '{"Battle Qi recovered out of combat": "+5%"}'::jsonb,
     301),

    ('ripe_field_root', 'Ripe Field Root', 'common',
     'A farmer''s root. It has never been fashionable and it has never gone hungry.',
     NULL, NULL,
     '{"Food-Path consumables": "keep longer"}'::jsonb,
     302),

    -- Uncommon.
    ('dawnlight_root', 'Dawnlight Root', 'uncommon',
     'Attuned to the hour when the stars are still out and the light has already started.',
     'First Light',
     'Sees a little further into a dark place than the dark place expects.',
     '{"Exploration in unlit regions": "a better find"}'::jsonb,
     303),

    ('storm_herald_root', 'Storm Herald Root', 'uncommon',
     'Wind arrives first. Everything else in a storm is commentary.',
     'Ahead of the Thunder',
     'Knows what is coming a moment before it comes, which is occasionally enough.',
     '{"The first round of an ambush": "acted in, not reacted to"}'::jsonb,
     304),

    -- Rare.
    ('grave_lily_root', 'Grave Lily Root', 'rare',
     'It grows where something is buried, and it grows better the more there is.',
     'What Rot Leaves',
     'Bone and venom are the same study taken to two different conclusions.',
     '{"Beast materials from a poisoned kill": "more of them"}'::jsonb,
     305),

    ('soul_leash_root', 'Soul Leash Root', 'rare',
     'Binding is not commanding. The distinction matters to exactly one of the two parties.',
     'Held by the Name',
     'What it binds stays bound a little past the point where it should have slipped.',
     '{"Enslaved creatures": "held for longer"}'::jsonb,
     306),

    -- Epic.
    ('false_face_root', 'False Face Root', 'epic',
     'A root for people who would rather not be looked at directly.',
     'Nobody in Particular',
     'The description they give afterwards is always of somebody else.',
     '{"Rogue cultivators": "less likely to pick you out of a region"}'::jsonb,
     307),

    ('ink_wandering_root', 'Ink Wandering Root', 'epic',
     'What is painted well enough is somewhere, and somewhere can be walked into.',
     'Into the Painting',
     'The line between what was drawn and where you are standing is thinner than it is for other people.',
     '{"A painted or dreamed place": "may be entered"}'::jsonb,
     308);

INSERT INTO root_path_bonuses (root_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('spirit_breath_root', 'qi',          0.0500, 0.0300),
    ('spirit_breath_root', 'human',       0.0200, 0.0100),

    ('ripe_field_root',    'food',        0.0500, 0.0300),
    ('ripe_field_root',    'wood',        0.0200, 0.0100),

    ('dawnlight_root',     'light',       0.0800, 0.0500),
    ('dawnlight_root',     'star',        0.0400, 0.0200),

    ('storm_herald_root',  'wind',        0.0800, 0.0500),
    ('storm_herald_root',  'lightning',   0.0400, 0.0200),

    ('grave_lily_root',    'poison',      0.1500, 0.0800),
    ('grave_lily_root',    'bone',        0.0700, 0.0400),

    ('soul_leash_root',    'enslavement', 0.1500, 0.0800),
    ('soul_leash_root',    'soul',        0.0700, 0.0400),

    ('false_face_root',    'illusion',    0.2500, 0.1500),
    ('false_face_root',    'shadow',      0.1200, 0.0700),

    ('ink_wandering_root', 'painting',    0.2500, 0.1500),
    ('ink_wandering_root', 'dream',       0.1200, 0.0700);
