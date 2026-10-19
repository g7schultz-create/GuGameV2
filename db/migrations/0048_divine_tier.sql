-- 0048_divine_tier
--
-- A Divine band, between Mythic and Unique.
--
-- WHERE IT GOES WAS ALREADY DECIDED. The design spec's own ladder reads
-- Common, Uncommon, Rare, Epic, Legendary, Mythic, Divine, Unique - sections
-- 7.7 and 10.7 are titled "Divine Roots" and "Divine Physiques" and have been
-- sitting there unbuilt. This is that slot, not a new invention, so the roots
-- and physiques below are the spec's own names and identities rather than
-- something made up to fill a gap.
--
-- A BAND WITH NO MEMBERS NEVER COMES UP. 0011 wrote that down and Mythic has
-- been proving it ever since: 1.4 roll weight, zero roots, zero physiques,
-- and not one character has ever rolled it. Adding the rarity row alone would
-- have been a no-op, so this adds four roots and four physiques with it.
--
-- HOW A TIER SHOWS ITS RANK HERE. The spec's tier baselines are written as
-- "+30% cultivation speed", and this game has never given a root one: all
-- twenty-three carry 0 in every flat rate column and put their identity in
-- `root_path_bonuses`. That is the spec's own correction, from its opening
-- pages - higher rarity should be "strategically distinct rather than
-- numerically dominant". So Divine roots are the widest and deepest Path
-- packages in the game, and not the only roots that make numbers bigger.
-- Physiques do carry flat multipliers, so those follow the physique baseline:
-- +25% on the stat the name promises.
--
-- WHAT IS NOT WIRED SAYS SO. Breakthrough backlash, secret-realm clues and
-- flee rerolls have nowhere to land yet, so they go in `unmodelled`, which
-- /profile renders in italics under "designed but not yet wired to a system".
-- A tier this rare must not lie about what it does.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The band
-- ---------------------------------------------------------------------------
-- Rarer than Mythic, commoner than a Venerable's inheritance. Weight is a
-- weight, so the eight bands renormalise around it without a number moving.

INSERT INTO rarities (code, name, roll_weight, colour, sort_order) VALUES
    ('divine', 'Divine', 0.5000, 12185855, 65);


-- ---------------------------------------------------------------------------
-- Divine roots
-- ---------------------------------------------------------------------------
-- Legendary is one Path at 0.30 attainment and 0.20 damage. Unique is one at
-- 0.50 with a second at 0.20. Divine sits between: a primary Path deeper than
-- Legendary, and a real second Path at half of it - which is the spec's
-- "secondary resonance receives half the listed thematic benefit", expressed
-- in the only currency this schema has.

INSERT INTO roots (code, name, rarity, description, special_name, special_text, unmodelled, sort_order) VALUES
    ('heavens_will_root', 'Heaven''s Will Root', 'divine',
     'Heaven does not speak. It arranges, and a cultivator carrying this is one of the arrangements.',
     'Mandate of Heaven',
     'The heavens are slower to punish what they arranged themselves.',
     '{"Breakthrough backlash": "reduced, never removed"}'::jsonb,
     172),

    ('dao_ancestor_root', 'Dao Ancestor Root', 'divine',
     'Not a mind that learns quickly. A mind that was already there when the thing was made.',
     'Ancestral Comprehension',
     'Insight into a Path comes faster than the hours spent on it can explain.',
     '{"Manual previews": "reveal one further flaw", "Insight Dust": "+8%"}'::jsonb,
     173),

    ('heaven_and_earth_root', 'Heaven and Earth Root', 'divine',
     'The oldest pairing there is. What it builds does not move, and neither does the cultivator.',
     'Unshifting Ground',
     'A foundation that a failed step costs less to keep.',
     '{"Mining yield": "+8%", "Qi lost to a failed breakthrough": "-4%"}'::jsonb,
     174),

    ('infinite_dao_root', 'Infinite Dao Root', 'divine',
     'Every road is shorter than it looks to whoever is holding the map.',
     'The Shorter Road',
     'Ways through are found that were not there for anybody else.',
     '{"Secret realm clues": "+8%", "Mismatched manual penalty": "-12%"}'::jsonb,
     175);

INSERT INTO root_path_bonuses (root_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('heavens_will_root',     'heaven', 0.4000, 0.2500),
    ('heavens_will_root',     'rule',   0.2000, 0.1200),

    ('dao_ancestor_root',     'wisdom', 0.4000, 0.2500),
    ('dao_ancestor_root',     'heaven', 0.2000, 0.1200),

    ('heaven_and_earth_root', 'earth',  0.4000, 0.2500),
    ('heaven_and_earth_root', 'heaven', 0.2000, 0.1200),

    ('infinite_dao_root',     'space',  0.4000, 0.2500),
    ('infinite_dao_root',     'heaven', 0.2000, 0.1200);


-- ---------------------------------------------------------------------------
-- Divine physiques
-- ---------------------------------------------------------------------------
-- The spec's physique baseline for this tier is "+25% thematic foundation
-- stat, one cross-system rule". The name decides which stat gets the 25%:
-- Heaven and Earth is a wall, Infinite Immortal is not there to be hit, and
-- Primordial Origin refuses to specialise at all - which is its whole point,
-- and its drawback.

INSERT INTO physiques
    (code, name, tier, affinity_path, affinity_bonus,
     hp_multiplier, defense_multiplier, strength_multiplier,
     cultivation_rate_bonus, physique_rate_bonus, attainment_rate_bonus,
     special_name, special_text, unmodelled, description)
VALUES
    ('heaven_and_earth_physique', 'Heaven and Earth Physique', 'divine', 'earth', 1.2000,
     1.2500, 1.2500, 1.0000,
     0.0000, 0.2000, 0.0000,
     'Weight of the World',
     'Harder to move than most things are to break.',
     '{"Damage taken above 60% HP": "-9%", "Healing below 30% HP": "-3%"}'::jsonb,
     'A body that has agreed with the ground about which of them gives way.'),

    ('infinite_immortal_body', 'Infinite Immortal Body', 'divine', 'space', 1.2000,
     1.1000, 1.0500, 1.0500,
     0.1500, 0.0000, 0.0000,
     'No Fixed Position',
     'Where it was is not where it is.',
     '{"Evasion": "+12%", "A failed escape": "may be attempted once more"}'::jsonb,
     'It is not that the blow misses. It is that the body was never quite there.'),

    ('primordial_origin_body', 'Primordial Origin Body', 'divine', 'human', 1.2000,
     1.1500, 1.1500, 1.1500,
     0.1000, 0.1000, 0.1000,
     'Nothing Refused',
     'Every pillar advances, and none of them leads.',
     '{"Every realm crossed": "two foundation stats rise permanently"}'::jsonb,
     'The body before anyone decided what a body was for. It can become anything, which is also the most that can be said for it.'),

    ('supreme_dao_physique', 'Supreme Dao Physique', 'divine', 'heaven', 1.2000,
     1.2000, 1.1500, 1.2500,
     0.2000, 0.0000, 0.0000,
     'Broad as the Dao',
     'Strong everywhere a specialist is not.',
     '{"Realm breakthroughs": "a stronger temporary vigour"}'::jsonb,
     'It does nothing better than the body built for that one thing, and there is nothing it does badly.');

INSERT INTO physique_path_bonuses (physique_id, path_code, attainment_bonus, damage_bonus)
SELECT p.physique_id, v.path, v.attainment, v.damage
FROM (VALUES
    ('heaven_and_earth_physique', 'earth',  0.3000, 0.1500),
    ('heaven_and_earth_physique', 'heaven', 0.1500, 0.0800),

    ('infinite_immortal_body',    'space',  0.3000, 0.1500),
    ('infinite_immortal_body',    'heaven', 0.1500, 0.0800),

    ('primordial_origin_body',    'human',  0.3000, 0.1500),
    ('primordial_origin_body',    'heaven', 0.1500, 0.0800),

    ('supreme_dao_physique',      'heaven', 0.3000, 0.1500),
    ('supreme_dao_physique',      'rule',   0.1500, 0.0800)
) AS v (code, path, attainment, damage)
JOIN physiques p ON p.code = v.code;
