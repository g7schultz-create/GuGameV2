-- 0010_starter_content
--
-- The first canonical content: techniques a player can actually learn and
-- creatures they can actually be measured against. Up to now every technique
-- and species in this database was built ad hoc by a test, which is fine for
-- proving the schema and useless for playing.
--
-- Deliberately small and spread wide rather than deep. The point of this set
-- is coverage of the *mechanics* - a single-Path move and a dual-Path one, a
-- rank the starting realm can use and ranks it cannot, a species that resists
-- by species override and one that is outright immune, a world boss - so that
-- every branch the damage pipeline and the bestiary view can take has content
-- behind it. Balance figures are placeholder; the shapes are not.
--
-- `created_by` is NULL throughout: this is canonical content, shared by
-- everyone, as opposed to a player's own killer move.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Techniques
-- ---------------------------------------------------------------------------
-- `rank` gates use behind the cultivation realm, so the first four are
-- reachable from the starting realm and the rest are targets. Blood Blade is
-- carried at the spec's own numbers (section 3: 10,000 base at rank 6) so the
-- worked example can be reproduced against live data, not only in the tests.

INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    ('crimson_palm', 'Crimson Palm', 1, 'attack', 120, 0.0500, 1.0000, 0,
     'A palm strike that draws on the striker''s own blood. The first thing most Blood cultivators learn, and the last thing many of them regret.'),

    ('ember_lash', 'Ember Lash', 1, 'attack', 130, 0.0600, 0.9500, 0,
     'A whip of live coals. Quick, cheap, and prone to setting the surroundings alight.'),

    ('rooted_stance', 'Rooted Stance', 1, 'defense', 0, 0.0400, 1.0000, 2,
     'Settle your weight into the earth. Nothing moves you until you choose to move.'),

    ('minds_eye', 'Mind''s Eye', 1, 'utility', 0, 0.0800, 1.0000, 3,
     'Read the shape of an opponent rather than strike it. Wisdom Path''s answer to a creature whose weaknesses you have not yet paid for in blood.'),

    ('venom_thorn_net', 'Venom Thorn Net', 2, 'attack', 280, 0.1000, 0.9000, 1,
     'A cast net of barbs, each one wet. The wound is the delivery, not the point.'),

    ('frost_lotus_seal', 'Frost Lotus Seal', 2, 'attack', 320, 0.1200, 1.0000, 1,
     'A lotus of black ice blooms where the seal lands, and goes on blooming inward.'),

    ('thunder_step', 'Thunder Step', 3, 'attack', 640, 0.1500, 0.9500, 2,
     'Cross the distance as the sound does. The strike arrives before the step is seen.'),

    ('mountain_breaker_fist', 'Mountain Breaker Fist', 3, 'attack', 700, 0.1800, 0.9000, 2,
     'No technique to speak of. A body cultivated until technique stopped being necessary.'),

    ('blazing_heaven_sword', 'Blazing Heaven Sword', 4, 'attack', 1600, 0.2200, 0.9500, 3,
     'The sword-intent and the fire are not layered - they are the same edge, which is why it is counted as both.'),

    ('blood_blade', 'Blood Blade', 6, 'attack', 10000, 0.3000, 0.9500, 4,
     'The spec''s worked example made real: a rank 6 killing move that costs the wielder as much as it costs anyone else.');


-- ---------------------------------------------------------------------------
-- Technique typing
-- ---------------------------------------------------------------------------
-- One row per Path. Weights must total exactly 1 per technique, checked at
-- COMMIT by the deferred constraint trigger from 0004 - which is precisely why
-- the 0.50/0.50 pair below can be inserted one row at a time.

INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('crimson_palm',          'blood',     1.0000),
    ('ember_lash',            'fire',      1.0000),
    ('rooted_stance',         'earth',     1.0000),
    ('minds_eye',             'wisdom',    1.0000),
    ('venom_thorn_net',       'poison',    1.0000),
    ('frost_lotus_seal',      'ice',       1.0000),
    ('thunder_step',          'lightning', 1.0000),
    ('mountain_breaker_fist', 'strength',  1.0000),
    ('blazing_heaven_sword',  'sword',     0.5000),
    ('blazing_heaven_sword',  'fire',      0.5000),
    ('blood_blade',           'blood',     1.0000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- ---------------------------------------------------------------------------
-- Creature species
-- ---------------------------------------------------------------------------
-- Ranks track the technique ladder, so a starting player has two species they
-- can plausibly fight and a long list they cannot.

INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed, description)
VALUES
    ('ash_moth', 'Ash Moth', 1, 'beast', 220, 18, 6, 26,
     'Wings of settled cinder. Harmless in ones, and never in ones.'),

    ('mire_toad', 'Mire Toad', 1, 'beast', 340, 15, 14, 8,
     'Sits in the shallows for a decade at a time. Everything it has ever eaten arrived voluntarily.'),

    ('stone_hide_boar', 'Stone Hide Boar', 2, 'beast', 620, 44, 38, 12,
     'A boar that has been shot at enough to grow a wall.'),

    ('hollow_reed_serpent', 'Hollow Reed Serpent', 2, 'beast', 480, 52, 16, 30,
     'Grows through the reed bed rather than among it. By the time the stalks move it has already struck.'),

    ('frost_maned_ape', 'Frost-Maned Ape', 3, 'elite', 1400, 110, 60, 18,
     'Descends from the ice shelf once a season. The mane is not fur.'),

    ('nine_distortion_wolf', 'Nine Distortion Wolf', 5, 'elite', 4200, 260, 140, 55,
     'Nine folds of warped space carried on its back. Edges arrive somewhere other than where they were aimed, which is a fact about the hide and not about the Path.'),

    ('void_ash_revenant', 'Void Ash Revenant', 7, 'boss', 18000, 900, 400, 40,
     'What is left standing after a soul has finished burning. There is no blood in it to reach for.'),

    ('heaven_scourge_leviathan', 'Heaven Scourge Leviathan', 9, 'world', 5000000, 4200, 1800, 70,
     'It surfaces on a schedule nobody set. A sect is not enough; a generation might be.');


-- ---------------------------------------------------------------------------
-- Creature typing
-- ---------------------------------------------------------------------------
-- Layer 2 of weakness resolution: whatever the chart already says about
-- attacking this Path. Dual-typed species take the strongest single
-- interaction rather than stacking, resolved once by creature_incoming_paths.

INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path_code, v.is_primary
FROM (VALUES
    ('ash_moth',                 'fire',      TRUE),
    ('mire_toad',                'water',     TRUE),
    ('stone_hide_boar',          'earth',     TRUE),
    ('hollow_reed_serpent',      'wood',      TRUE),
    ('hollow_reed_serpent',      'poison',    FALSE),
    ('frost_maned_ape',          'ice',       TRUE),
    ('frost_maned_ape',          'strength',  FALSE),
    ('nine_distortion_wolf',     'space',     TRUE),
    ('void_ash_revenant',        'soul',      TRUE),
    ('heaven_scourge_leviathan', 'water',     TRUE),
    ('heaven_scourge_leviathan', 'heaven',    FALSE)
) AS v (species_code, path_code, is_primary)
JOIN creature_species s ON s.code = v.species_code;


-- ---------------------------------------------------------------------------
-- Per-species overrides
-- ---------------------------------------------------------------------------
-- Layer 1: facts about this creature's body that the chart has no way to
-- derive from its Path, and the only place immunity can be said at all.
--
-- The wolf is the spec's own example - it resists Sword and Earth because of
-- what its hide does to an incoming edge, which has nothing to do with Space.
-- The revenant is here to give the pipeline's `matchup = -1` branch a target
-- that exists in live data rather than only in a test fixture.

INSERT INTO creature_path_modifiers (species_id, path_code, interaction, flavour_text)
SELECT s.species_id, v.path_code, v.interaction, v.flavour_text
FROM (VALUES
    ('nine_distortion_wolf', 'sword', 'resistance',
     'The edge lands nine inches to the left of where it was swung.'),
    ('nine_distortion_wolf', 'earth', 'resistance',
     'Weight arrives distributed across folds that are not all here.'),
    ('nine_distortion_wolf', 'space', 'resistance',
     'You cannot fold space around something already living inside nine folds of it.'),

    ('void_ash_revenant', 'blood', 'immunity',
     'There is nothing in it to bleed, and nothing of yours it wants.'),
    ('void_ash_revenant', 'soul', 'advantage',
     'It is all soul. That cuts both ways.'),

    ('frost_maned_ape', 'fire', 'advantage',
     'The mane is water that has forgotten how to move. Remind it.'),

    ('heaven_scourge_leviathan', 'heaven', 'immunity',
     'You do not invoke the will of heaven against the thing heaven sent.')
) AS v (species_code, path_code, interaction, flavour_text)
JOIN creature_species s ON s.code = v.species_code;
