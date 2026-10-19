-- 0049_the_middle_of_the_physique_ladder
--
-- Epic, Legendary and Mythic physiques.
--
-- 0048 filled the Divine band and left the physique roll jumping Rare to
-- Divine across three empty bands. Nothing was broken by that - a band with no
-- members contributes nothing and the rest renormalise - but 25.5% of the
-- physique roll's weight was sitting in bands that could never be awarded, and
-- a player who rolled well got Rare or nothing.
--
-- THE UNIQUE BAND STAYS EMPTY, AND THAT IS CORRECT. The spec's section 10.8
-- "Unique Physiques" lists Great Strength True Martial, Northern Dark Ice
-- Soul, Blazing Glory Lightning Brilliance and Carefree Wisdom Heart - which
-- are this game's `extreme` band, put outside the ladder by 0011 on purpose:
-- "The Ten Extreme sit outside the normal ladder by design. No root is
-- extreme; the band exists for physiques only." So the physique ladder runs
-- Common to Divine and then Extreme, and Unique is the roots-only band.
--
-- WHAT A TIER IS WORTH HERE, MEASURED OFF ITS NEIGHBOURS. Rare physiques give
-- 0.00 Path attainment and 0.15 damage; Divine gives 0.30 and 0.15; Extreme
-- gives 0.50 and 0.30. So attainment is what carries the ladder and damage
-- sits flat across the middle of it:
--
--     rare 0.00 -> epic 0.12 -> legendary 0.20 -> mythic 0.25 -> divine 0.30
--
-- with the second Path at half, as Divine does, and the stat multipliers
-- following the spec's own baselines: +14%, +18%, +22% on the stat the name
-- promises.
--
-- The descriptions and named mechanics here are starting points, not
-- decisions. They are rows: an UPDATE changes any of them without a migration
-- to the shape of anything.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Epic: one encounter trigger, +14%
-- ---------------------------------------------------------------------------

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, description)
VALUES
    ('heavenly_battle_body', 'Heavenly Battle Body', 'epic', 'strength', 1.1000,
     1.1400, 1.0500, 1.1400,
     0.0000, 0.1500, 0.0000,
     'Third Blow',
     'A body that finds the rhythm of a fight and then keeps it.',
     '{"Every third landed strike": "+12% damage", "Damage to beasts": "+4%"}'::jsonb,
     'Built for the part of a fight that comes after the first exchange.'),

    ('mountain_king_body', 'Mountain King Body', 'epic', 'earth', 1.1000,
     1.1400, 1.1400, 1.0000,
     0.0000, 0.1000, 0.0000,
     'Unmoved',
     'While it is still mostly whole, very little gets through.',
     '{"Damage taken above 60% HP": "-6%", "Mining yield": "+8%"}'::jsonb,
     'The mountain does not brace itself. It is simply where it was.'),

    ('endless_ocean_body', 'Endless Ocean Body', 'epic', 'water', 1.1000,
     1.1400, 1.0500, 1.0000,
     0.1000, 0.1000, 0.0000,
     'Returning Tide',
     'Qi comes back the way a tide does — not quickly, and not once.',
     '{"Guarding": "restores 6% of battle Qi, once an encounter"}'::jsonb,
     'It does not win quickly. It wins by still being there.'),

    ('phoenix_rebirth_body', 'Phoenix Rebirth Body', 'epic', 'fire', 1.1000,
     1.0500, 1.0000, 1.1400,
     0.0000, 0.1500, 0.0000,
     'Ashes First',
     'The worse it is going, the harder this body hits.',
     '{"Below 50% HP": "+11% strength", "On a kill": "5% battle Qi returned", "Guard": "5 points weaker"}'::jsonb,
     'Every account of one of these is told by somebody who nearly died.');


-- ---------------------------------------------------------------------------
-- Legendary: one build-defining passive, +18%
-- ---------------------------------------------------------------------------

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, description)
VALUES
    ('heaven_defying_body', 'Heaven Defying Body', 'legendary', 'heaven', 1.1500,
     1.1800, 1.1200, 1.1200,
     0.1500, 0.1000, 0.0000,
     'Refusal',
     'The heavens have a rate at which they take things back. This body argues.',
     '{"Breakthrough backlash": "reduced, never removed"}'::jsonb,
     'Not a body that heaven favours. A body heaven has not managed to correct.'),

    ('primordial_chaos_body', 'Primordial Chaos Body', 'legendary', 'qi', 1.1500,
     1.1800, 1.0800, 1.0800,
     0.2000, 0.1500, 0.0000,
     'Bottomless',
     'Holds more qi than the aperture it is standing in should allow.',
     '{"Battle Qi capacity": "+15%"}'::jsonb,
     'Whatever it was made of came before the rules about what bodies are made of.'),

    ('celestial_emperor_body', 'Celestial Emperor Body', 'legendary', 'star', 1.1500,
     1.1800, 1.1800, 1.0800,
     0.0000, 0.1500, 0.1000,
     'Rule of the Vault',
     'Whatever this body is worst at, it is briefly not worst at.',
     '{"At encounter start": "the lowest foundation stat gains 7%", "Manual study": "+8%"}'::jsonb,
     'It has no weakest point for long enough to matter.'),

    ('heavenly_giant_body', 'Heavenly Giant Body', 'legendary', 'strength', 1.1500,
     1.1800, 1.1000, 1.1800,
     0.0000, 0.2000, 0.0000,
     'Long Reach',
     'Nothing subtle. There is simply more of it than there is of you.',
     '{"Every third landed strike": "+12% damage", "Gu utility": "deliberately minimal"}'::jsonb,
     'The kind of body that ends an argument by being present during it.');


-- ---------------------------------------------------------------------------
-- Mythic: one powerful limited trigger, +22%
-- ---------------------------------------------------------------------------

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, description)
VALUES
    ('chaos_immortal_body', 'Chaos Immortal Body', 'mythic', 'heaven', 1.1800,
     1.2200, 1.1500, 1.1500,
     0.2000, 0.1500, 0.0000,
     'Nothing Settles',
     'Broad where a specialist is narrow, and never quite finished forming.',
     '{"Realm breakthroughs": "a 12% stronger vigour", "Severe deviation": "less likely"}'::jsonb,
     'It has not decided what it is yet, and it has had several centuries.'),

    ('eternal_dragon_body', 'Eternal Dragon Body', 'mythic', 'strength', 1.1800,
     1.2200, 1.1500, 1.2200,
     0.0000, 0.2500, 0.0000,
     'Scale and Sinew',
     'Strength that does not fall off with the years, because nothing in it ages.',
     '{"Every third landed strike": "+12% damage", "Damage to beasts": "+4%"}'::jsonb,
     'Dragons do not get weaker. That is most of what makes them dragons.'),

    ('void_sovereign_body', 'Void Sovereign Body', 'mythic', 'space', 1.1800,
     1.1200, 1.1000, 1.1000,
     0.1500, 0.0000, 0.1000,
     'Nowhere to Strike',
     'Distance is a suggestion, and so is being cornered.',
     '{"Evasion": "+14%", "A failed escape": "may be attempted once more"}'::jsonb,
     'Fights it loses are fights it was still standing at the end of.'),

    ('celestial_sovereign_body', 'Celestial Sovereign Body', 'mythic', 'star', 1.1800,
     1.2200, 1.2200, 1.1000,
     0.1000, 0.1500, 0.1500,
     'The Vault Turns',
     'Its worst stat is shored up the moment a fight begins.',
     '{"At encounter start": "the lowest foundation stat gains 9%", "Manual study": "+12%"}'::jsonb,
     'Read as a constellation is read: not one bright thing, but the shape.');


-- ---------------------------------------------------------------------------
-- The Path packages
-- ---------------------------------------------------------------------------
-- Attainment carries the ladder; damage sits flat across the middle of it and
-- jumps only at Extreme. The second Path takes half of the first, as every
-- band above Rare does.

INSERT INTO physique_path_bonuses (physique_id, path_code, attainment_bonus, damage_bonus)
SELECT p.physique_id, v.path, v.attainment, v.damage
FROM (VALUES
    -- Epic
    ('heavenly_battle_body',     'strength', 0.1200, 0.1500),
    ('heavenly_battle_body',     'heaven',   0.0600, 0.0800),
    ('mountain_king_body',       'earth',    0.1200, 0.1500),
    ('endless_ocean_body',       'water',    0.1200, 0.1500),
    ('phoenix_rebirth_body',     'fire',     0.1200, 0.1500),

    -- Legendary
    ('heaven_defying_body',      'heaven',   0.2000, 0.1500),
    ('heaven_defying_body',      'rule',     0.1000, 0.0800),
    ('primordial_chaos_body',    'qi',       0.2000, 0.1500),
    ('celestial_emperor_body',   'star',     0.2000, 0.1500),
    ('celestial_emperor_body',   'wisdom',   0.1000, 0.0800),
    ('heavenly_giant_body',      'strength', 0.2000, 0.1500),
    ('heavenly_giant_body',      'heaven',   0.1000, 0.0800),

    -- Mythic
    ('chaos_immortal_body',      'heaven',   0.2500, 0.1500),
    ('chaos_immortal_body',      'qi',       0.1200, 0.0800),
    ('eternal_dragon_body',      'strength', 0.2500, 0.1500),
    ('eternal_dragon_body',      'transformation', 0.1200, 0.0800),
    ('void_sovereign_body',      'space',    0.2500, 0.1500),
    ('celestial_sovereign_body', 'star',     0.2500, 0.1500),
    ('celestial_sovereign_body', 'wisdom',   0.1200, 0.0800)
) AS v (code, path, attainment, damage)
JOIN physiques p ON p.code = v.code;
