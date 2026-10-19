-- 0051_bodies_stop_repeating_themselves
--
-- Five duplicated mechanics across sixteen bodies.
--
-- The design review named one family. Querying `unmodelled` found five, three
-- of them near-total - two bodies claiming the identical pair of effects at
-- two different bands, which is one body wearing two names.
--
-- WHERE IT CAME FROM. The spec's catalogs are templated by "Foundation focus":
-- "A broad high-tier root that strengthens law comprehension and cross-system
-- balance" appears verbatim six times in section 7.7 alone, and the physique
-- sections do the same. 0048 and 0049 transcribed them faithfully and imported
-- the template with them. Fidelity to that document was the wrong instinct -
-- it is a tier-baseline generator, not a catalog of distinct things.
--
-- WHAT EACH BAND OWNS NOW. One mechanic, one body. The replacements are picked
-- so the ladder reads as an escalation of KIND rather than of size, which is
-- the review's actual complaint:
--
--   Epic       improves your character
--   Legendary  specialises your build
--   Mythic     can define your build
--   Divine     bends a rule the game otherwise enforces
--
-- Every replacement also aims at a system that exists, so none of them is
-- waiting on a subsystem nobody has written.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- "Every third landed strike", claimed by three bodies
-- ---------------------------------------------------------------------------
-- Epic keeps it. A counter is the right weight for the band, and the other two
-- were larger copies of it rather than different ideas.

UPDATE physiques SET
    special_name = 'Long Reach',
    special_text = 'Reach that goes through a guard rather than around it.',
    unmodelled   = '{"Armour penetration": "+15%"}'::jsonb,
    description  = 'The kind of body that ends an argument by being present during it.'
WHERE code = 'heavenly_giant_body';

-- Strength that ignores defence rather than repeating a rhythm. 0037 made
-- defence subtract from EVERY strike of a multi-hit, so this pulls the giant
-- toward big single blows - the opposite corner from the Gu build that swings
-- three times, and a real reason to choose one.

UPDATE physiques SET
    special_name = 'Dragon Might',
    special_text = 'Every blow given or taken feeds it, and what it feeds keeps growing while the fight lasts.',
    unmodelled   = '{"Dealing or taking damage": "builds Dragon Might", "Each stack": "strength and defence", "At full stacks": "a heightened state, and Transformation techniques gain an effect"}'::jsonb
WHERE code = 'eternal_dragon_body';


-- ---------------------------------------------------------------------------
-- Evasion and the flee reroll, claimed twice with identical wording
-- ---------------------------------------------------------------------------
-- The Mythic body keeps them: not being hit and not being caught is its whole
-- identity, and it should own it alone. The Divine one has to bend a rule
-- instead of holding more of the same.

UPDATE physiques SET
    special_text = 'A killing blow lands where the body has already stopped being.',
    unmodelled   = '{"Once a battle": "a lethal blow leaves 1 HP and breaks the engagement instead", "Space techniques": "a chance to cost no Qi"}'::jsonb,
    description  = 'It is not that the blow misses. It is that there was nothing at the end of it.'
WHERE code = 'infinite_immortal_body';


-- ---------------------------------------------------------------------------
-- The encounter-start stat and manual study, claimed twice
-- ---------------------------------------------------------------------------
-- Legendary keeps the stat. Mythic gets the thing a Star and Wisdom body
-- should actually be for: reading the creature rather than reinforcing itself.
-- Weakness discovery already exists - Observe spends a round on it, and the
-- bestiary remembers - so this is a body that skips a step the game already
-- charges everyone else for.

UPDATE physiques SET
    special_name = 'Read at a Glance',
    special_text = 'The shape of a thing is legible before it moves.',
    unmodelled   = '{"At encounter start": "the creature''s weakness is already known, without spending Observe"}'::jsonb,
    description  = 'Read the way a constellation is read: not one bright thing, but the shape between them.'
WHERE code = 'celestial_sovereign_body';


-- ---------------------------------------------------------------------------
-- Damage taken above 60% HP, claimed twice
-- ---------------------------------------------------------------------------
-- Epic keeps the threshold. The Divine earth body gets the rule-bending
-- version: 0037 lets armour penetration erase defence outright, and this puts
-- a floor under it. That pushes directly against the Gu penetration axis
-- rather than scaling a number the Epic body already owns.

UPDATE physiques SET
    special_text = 'Armour that cannot be argued all the way down.',
    unmodelled   = '{"Armour penetration against this body": "cannot take defence below half", "Healing below 30% HP": "-3%"}'::jsonb
WHERE code = 'heaven_and_earth_physique';


-- ---------------------------------------------------------------------------
-- The breakthrough vigour, claimed twice
-- ---------------------------------------------------------------------------
-- Neither could have worked: breakthroughs cannot fail yet, so there is no
-- backlash to soften and no deviation to make less severe. The Mythic body
-- takes something the matchup chart can answer today.
--
-- The Divine one is wired for real in 0053.

UPDATE physiques SET
    special_text = 'Too unfinished a thing to be countered cleanly.',
    unmodelled   = '{"Path resistances against this body": "bite less"}'::jsonb
WHERE code = 'chaos_immortal_body';
