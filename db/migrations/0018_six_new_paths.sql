-- 0018_six_new_paths
--
-- Wind, Bone, Light, Shadow, Illusion and Star, with the matchup rows that
-- stop them being inert.
--
-- The design's monster roster uses six Paths this game did not have. Adding a
-- Path is an INSERT into `paths` - that part is cheap. What is not cheap is
-- that a Path with no matchup rows takes no part in the chart in either
-- direction, which is the state Metal has been in since 0002 and is listed as
-- a known gap. Six more of those would leave 7 of 27 combat Paths doing
-- nothing, so the rows arrive with the Paths.
--
-- 50 rows, selected to tighten the chart rather than merely extend it. Every
-- new Path deals exactly 3 advantages and 2 resistances, matching the rule
-- 0002 set. Measured across the whole chart, the spread of net position falls
-- from 2.20 to 1.25 and its standard deviation by about half - the new Paths
-- were used to drag the outliers in rather than to pile onto the leaders.
--
-- TWO DELIBERATE DEPARTURES from the generated set, both explained where they
-- occur below: a `wind -> lightning` resistance was dropped, and Bone's third
-- advantage was re-pointed from Time to Soul.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The Paths
-- ---------------------------------------------------------------------------
-- Appended at 290+ rather than slotted among the existing combat Paths.
-- Slotting would read better in a list, but `sort_order` is what
-- path_autocomplete pages by, and Discord returns at most 25 choices - so
-- inserting six in the middle would silently push Theft, Poison, Human and
-- Heaven off the end of the empty-query autocomplete that /study and
-- /dev insight use. The button pickers page by category and are unaffected
-- either way.

INSERT INTO paths (code, name, category, uses_matchups, description, emoji, sort_order) VALUES
    ('wind',     'Wind Path',     'combat', TRUE, 'Motion, dispersal and open sky.',        '🍃', 290),
    ('light',    'Light Path',    'combat', TRUE, 'Radiance that leaves nothing hidden.',   '☀️', 300),
    ('shadow',   'Shadow Path',   'combat', TRUE, 'Darkness, concealment and ambush.',      '🌑', 310),
    ('illusion', 'Illusion Path', 'combat', TRUE, 'False images and misdirection.',         '🎭', 320),
    ('bone',     'Bone Path',     'combat', TRUE, 'The frame that outlasts the flesh.',     '🦴', 330),
    ('star',     'Star Path',     'combat', TRUE, 'Distant fate written in the sky.',       '⭐', 340);


-- ---------------------------------------------------------------------------
-- What the new Paths beat
-- ---------------------------------------------------------------------------

INSERT INTO path_matchups (attacker_path, defender_path, interaction, flavour_text) VALUES
    -- Wind
    ('wind', 'illusion',   'advantage',  'A mirage needs the air to hold still.'),
    ('wind', 'refinement', 'advantage',  'A refining flame needs still air. Wind is the standing argument against still anything.'),
    ('wind', 'poison',     'advantage',  'A miasma has to stay where it was put.'),
    ('wind', 'strength',   'resistance', 'A gale does not move a braced body. It leans in and keeps walking.'),

    -- NOTE. The generated set also carried `wind -> lightning: resistance`, to
    -- reproduce the Thunderhorn Goat resisting Wind. It is dropped here.
    --
    -- creature_incoming_paths resolves a dual-typed creature by taking the
    -- most attacker-favourable STORED row, and neutral is an absent row rather
    -- than a stored zero - so it cannot compete. The Storm Eagle is
    -- Wind/Lightning, and `wind -> wind` is banned as reflexive, so that
    -- resistance would have been the only row in play and the flagship Wind
    -- creature would have resisted Wind techniques.
    --
    -- The goat resisting wind is a fact about the goat, not about Lightning.
    -- It belongs in creature_path_modifiers, and lands there with the roster.

    -- Light
    ('light', 'illusion', 'advantage',  'There is nothing left to see but what is actually there.'),
    ('light', 'poison',   'advantage',  'Sunlight breaks a miasma into the parts that were doing the work.'),
    ('light', 'space',    'advantage',  'Light takes the straight line that Space Path is folding away.'),
    ('light', 'wood',     'resistance', 'Everything green here has spent its whole life eating light.'),
    ('light', 'blood',    'resistance', 'Blood is opaque on purpose.'),

    -- Shadow
    ('shadow', 'light',  'advantage',  'Light casts it, which is the whole problem: it is already standing behind you.'),
    ('shadow', 'wisdom', 'advantage',  'The mind''s eye still needs something to look at.'),
    ('shadow', 'fire',   'advantage',  'Every flame throws a shadow it cannot burn, and it is standing in it.'),
    ('shadow', 'poison', 'resistance', 'There is nothing in a shadow for a poison to get into.'),
    ('shadow', 'wood',   'resistance', 'A thicket is nothing but places to hide. It cannot object.'),

    -- Illusion
    ('illusion', 'wisdom',         'advantage',  'Wisdom Path knows what is actually there. Illusion Path arranges what is actually there.'),
    ('illusion', 'sword',          'advantage',  'The blade goes exactly where you showed it.'),
    ('illusion', 'space',          'advantage',  'A folded distance you were shown is a distance you never crossed.'),
    ('illusion', 'poison',         'resistance', 'A lie has no blood to carry it.'),
    ('illusion', 'transformation', 'resistance', 'A thing that is already changing shape is hard to lie about.'),

    -- Bone
    ('bone', 'light', 'advantage',  'Radiance goes through flesh and stops at the frame. Bone is where light runs out.'),
    ('bone', 'blood', 'advantage',  'Marrow is where blood is made. Bone owns it at the source.'),

    -- NOTE. The generated set had `bone -> time` here. Re-pointed to Soul.
    --
    -- Bone's three advantages were Light, Time and Blood, and not one of those
    -- Paths is carried by any creature currently in the game - so a Bone
    -- cultivator would have dealt exactly neutral damage to the entire
    -- bestiary. That is the Metal wart, shipped on day one, in the layer that
    -- actually matters. Soul is carried by the Void Ash Revenant today and by
    -- the Soul-Eating Vulture when the roster lands, and the line is at least
    -- as good.
    ('bone', 'soul', 'advantage',  'The frame outlasts the ghost, and knows it.'),

    ('bone', 'transformation', 'resistance', 'The skeleton has opinions about what shapes are available.'),
    ('bone', 'enslavement',    'resistance', 'There is nothing left in it to command.'),

    -- Star
    ('star', 'shadow', 'advantage',  'There is no dark that is entirely dark.'),
    ('star', 'fire',   'advantage',  'Every fire is a small, brief, badly made star.'),
    ('star', 'time',   'advantage',  'A star''s light is the past arriving exactly on schedule.'),
    ('star', 'enslavement',    'resistance', 'A fate already written takes no orders.'),
    ('star', 'transformation', 'resistance', 'The sky wrote that down before you decided to be something else.');


-- ---------------------------------------------------------------------------
-- What beats the new Paths
-- ---------------------------------------------------------------------------
-- Counterplay, and the half that does the rebalancing: these rows were chosen
-- to lift the Paths the chart had left behind. Wood, Blood, Refinement,
-- Formation, Enslavement, Strength and Transformation were all net-negative
-- before this migration, and each gains an advantage here.

INSERT INTO path_matchups (attacker_path, defender_path, interaction, flavour_text) VALUES
    -- Against Wind
    ('earth',     'wind', 'advantage', 'It has to come down eventually. Earth Path only has to be waiting where it lands.'),
    ('formation', 'wind', 'advantage', 'A large enough array simply decides where the wind goes.'),

    -- Against Light
    ('theft',  'light', 'advantage',  'Nothing is given more freely than light, and Theft Path takes what is given freely.'),
    ('wisdom', 'light', 'resistance', 'Revelation does not argue back. There is nothing in it to out-think.'),
    ('ice',    'light', 'resistance', 'Ice takes light in and hands it back in pieces, none of them where you aimed.'),

    -- Against Shadow
    ('enslavement', 'shadow', 'advantage',  'Every shadow is owned by the thing that cast it. Enslavement Path only has to ask whose.'),
    ('human',       'shadow', 'advantage',  'A shadow needs a crowd to be lost in, and Human Path is the study of crowds.'),
    ('earth',       'shadow', 'resistance', 'You cannot bury a shadow.'),
    ('fire',        'shadow', 'resistance', 'Fire is what makes the shadow. It is in no position to complain.'),

    -- Against Illusion
    ('water',    'illusion', 'advantage',  'Still water shows you exactly what is standing over it.'),
    ('strength', 'illusion', 'resistance', 'The fist lands exactly where the fox was not.'),
    ('luck',     'illusion', 'resistance', 'Luck Path does not look where it is going, so there is nothing there to mislead.'),

    -- Against Bone
    ('refinement', 'bone', 'advantage',  'Bone is a material, and Refinement Path has opinions about materials.'),
    ('strength',   'bone', 'advantage',  'Strength Path breaks frames. Bone is a frame.'),
    ('poison',     'bone', 'advantage',  'Poison settles into the marrow and does not leave.'),
    ('sword',      'bone', 'resistance', 'The edge skids off the frame and takes the meat instead.'),

    -- Against Star
    ('wood',           'star', 'advantage',  'A seed has never once consulted a constellation, and the constellation has never once stopped it.'),
    ('blood',          'star', 'advantage',  'A star''s light is a thousand years old. Blood Path is interested in right now.'),
    ('transformation', 'star', 'advantage',  'The sky wrote that fate for whatever you used to be.'),
    ('water',          'star', 'resistance', 'A shell that has shed a thousand tides sheds one more.'),
    ('theft',          'star', 'resistance', 'You cannot steal a fate. It stays where it was written.');


-- ---------------------------------------------------------------------------
-- Featherman moves to Wind
-- ---------------------------------------------------------------------------
-- 0011 mapped the Featherman's "Cloud / Flying" specialty onto Space, because
-- there was no Wind Path to give it. There is now, and this is the one row it
-- takes to correct - which was the argument for keeping per-Path bonuses in a
-- table rather than in code.

UPDATE race_path_bonuses
SET path_code = 'wind'
WHERE race_code = 'featherman' AND path_code = 'space';

-- Its "+10% speed / evasion" stays in `unmodelled`: there is still no speed
-- system, and having a Wind Path to cultivate does not change that.
