-- 0055_bodies_for_the_unclaimed_paths
--
-- Seventeen Paths that no physique favoured.
--
-- The same hole as 0054's, one table over, and slightly larger: nine Paths had
-- neither a root nor a physique, and eight more had a root and no body -
-- Dream, Formation, Luck, Metal, Refinement, Theft, Time and Wood among them.
-- Metal has had a root since the Common band shipped and has never once had a
-- body built for it.
--
-- WHAT A BAND IS ALLOWED TO BE WORTH. These slot under each band's existing
-- ceiling rather than over it, because the ladder tests measure the best member
-- of a band and a newcomer that redefined the top would push every band above
-- it. So Common tops out at 1.06 against the band's 1.07, Rare at 1.14 against
-- 1.15, and so on - new coverage, not new power.
--
-- Path attainment follows the same rule: Common through Rare give damage and
-- no attainment, which is what every Rare physique already does, and Epic is
-- the first band where a body deepens a Path rather than only hitting with it.
--
-- Forward-only. Do not edit once applied.

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, description)
VALUES
    -- Common.
    ('orchard_body', 'Orchard Body', 'common', 'wood', 1.0500,
     1.0600, 1.0000, 1.0000, 0.0000, 0.0500, 0.0000,
     NULL, NULL,
     '{"Food and herb consumables": "restore a little more"}'::jsonb,
     'A body that has eaten well its whole life and has nothing else to show for it.'),

    ('mirage_lantern_body', 'Mirage Lantern Body', 'common', 'light', 1.0500,
     1.0000, 1.0000, 1.0600, 0.0000, 0.0500, 0.0000,
     NULL, NULL,
     '{"Being seen clearly": "harder at distance"}'::jsonb,
     'Lit from somewhere that is not quite where the body is.'),

    -- Uncommon.
    ('cutpurse_body', 'Cutpurse Body', 'uncommon', 'theft', 1.0800,
     1.0000, 1.0200, 1.0900, 0.0000, 0.0800, 0.0000,
     'Light Fingers',
     'Quick in the way that matters, which is the last six inches.',
     '{"Materials taken from a kill": "occasionally one more"}'::jsonb,
     'Nobody trains this. Some people simply grow up needing it.'),

    ('iron_kiln_body', 'Iron Kiln Body', 'uncommon', 'metal', 1.0800,
     1.0200, 1.0900, 1.0000, 0.0000, 0.0800, 0.0000,
     'Fired Not Forged',
     'A body that has been through heat and came out harder for it.',
     '{"Refining failures": "cost less of what went in"}'::jsonb,
     'Metal has had a root since the beginning and never a body. This is the body.'),

    -- Rare.
    ('charnel_body', 'Charnel Body', 'rare', 'poison', 1.1000,
     1.1400, 1.0500, 1.0000, 0.0000, 0.1200, 0.0000,
     'Already Spoiled',
     'There is not much left in here for a venom to ruin.',
     '{"Poison and rot": "take hold more slowly"}'::jsonb,
     'It smells wrong and it has never once been sick.'),

    ('night_wandering_body', 'Night Wandering Body', 'rare', 'shadow', 1.1000,
     1.0000, 1.0500, 1.1400, 0.0000, 0.1200, 0.0000,
     'Awake in the Wrong Hours',
     'Rests badly and gains something for it.',
     '{"Cultivation while others sleep": "a little faster"}'::jsonb,
     'The body is asleep. Something in it is not, and it has been busy.'),

    -- Epic.
    ('puppet_array_body', 'Puppet Array Body', 'epic', 'enslavement', 1.1000,
     1.1500, 1.0800, 1.0500, 0.0000, 0.1000, 0.0500,
     'Threads and Anchors',
     'Holds more at once than one mind should be able to hold.',
     '{"A bound creature and a formation": "may be held together"}'::jsonb,
     'Something in the marrow keeps count so the cultivator does not have to.'),

    ('long_odds_body', 'Long Odds Body', 'epic', 'luck', 1.1000,
     1.0500, 1.0800, 1.1500, 0.0500, 0.0500, 0.0500,
     'The Second Roll',
     'Improbable things happen to it at an improbable rate.',
     '{"A rarity roll": "one further chance at the better band"}'::jsonb,
     'Nothing about this body is reliable, which is not the same as nothing about it being good.'),

    -- Legendary.
    ('ink_skin_body', 'Ink Skin Body', 'legendary', 'painting', 1.1500,
     1.1700, 1.1200, 1.1000, 0.0000, 0.1500, 0.1000,
     'Drawn, Not Born',
     'What is written on this body is a description of it, and the description wins.',
     '{"A wound": "may be redrawn rather than healed"}'::jsonb,
     'Somebody painted a person and the paint disagreed about being a picture.');

INSERT INTO physique_path_bonuses (physique_id, path_code, attainment_bonus, damage_bonus)
SELECT p.physique_id, v.path, v.attainment, v.damage
FROM (VALUES
    -- Common through Rare give damage and no attainment, as every Rare
    -- physique already does. A body of that grade hits with a Path; it does
    -- not deepen one.
    ('orchard_body',          'wood',        0.0000, 0.0500),
    ('orchard_body',          'food',        0.0000, 0.0300),
    ('mirage_lantern_body',   'light',       0.0000, 0.0500),
    ('mirage_lantern_body',   'illusion',    0.0000, 0.0300),

    ('cutpurse_body',         'theft',       0.0000, 0.0800),
    ('cutpurse_body',         'wind',        0.0000, 0.0400),
    ('iron_kiln_body',        'metal',       0.0000, 0.0800),
    ('iron_kiln_body',        'refinement',  0.0000, 0.0400),

    ('charnel_body',          'poison',      0.0000, 0.1200),
    ('charnel_body',          'bone',        0.0000, 0.0600),
    ('night_wandering_body',  'shadow',      0.0000, 0.1200),
    ('night_wandering_body',  'dream',       0.0000, 0.0600),

    -- Epic upward, a body deepens the Path it is built around.
    ('puppet_array_body',     'enslavement', 0.1200, 0.1500),
    ('puppet_array_body',     'formation',   0.0600, 0.0800),
    ('long_odds_body',        'luck',        0.1200, 0.1500),
    ('long_odds_body',        'time',        0.0600, 0.0800),

    ('ink_skin_body',         'painting',    0.2000, 0.1500),
    ('ink_skin_body',         'illusion',    0.1000, 0.0800)
) AS v (code, path, attainment, damage)
JOIN physiques p ON p.code = v.code;
