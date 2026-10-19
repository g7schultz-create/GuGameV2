-- 0052_mythic_roots
--
-- The last band that could not award a root.
--
-- Mythic has had 1.4 roll weight and nothing to give since 0011. These four
-- close it, and the ladder is then complete on both sides: every rarity can
-- award both a root and a physique except Unique and Extreme, which are each
-- other's halves by design.
--
-- TWO OF THE REVIEW'S FOUR ARRIVE UNCHANGED. Two do not, and checking them
-- against the roster is why:
--
--   * Voidwalker Root was Space/Theft. `thieving_heavens_inheritor` is Unique
--     and is theft+space - the same pair one band up, so a Mythic version
--     would have been a strictly weaker copy of a Venerable's inheritance.
--     Repathed onto Space/Formation, which no root claims.
--   * Ancient Sword Heart Root sat one band above `primordial_sword_heart`,
--     which is Sword. Two names for one thing. The Sword/Rule concept is a
--     real differentiator and is kept; the name is not.
--
-- And the Dream root is renamed off "Heavenly", which already prefixes four
-- roots and was the review's own naming complaint.
--
-- MYTHIC SITS AT 0.35 / 0.22. Legendary is 0.30 / 0.20 and Divine is
-- 0.40 / 0.25, so this drops into the gap without reopening either. A second
-- Path at half is the convention from Divine downward.
--
-- Forward-only. Do not edit once applied.

INSERT INTO roots (code, name, rarity, description, special_name, special_text, unmodelled, sort_order) VALUES
    ('dream_sea_root', 'Dream Sea Root', 'mythic',
     'Sleep is not time lost to a cultivator who can work in it.',
     'Night Study',
     'What is understood while asleep is understood on waking, and the hours were going to pass anyway.',
     '{"A dream realm": "attainment in a Path pursued while asleep"}'::jsonb,
     171),

    ('ten_thousand_flame_root', 'Ten Thousand Flame Root', 'mythic',
     'Ten thousand fires, and the root has an opinion about every one of them.',
     'Every Fire Is One Fire',
     'Flame answers whether it was lit for warmth, for war, or for the crucible.',
     '{"Fire pages": "hold together more readily in a refinement"}'::jsonb,
     176),

    ('blade_decree_root', 'Blade Decree Root', 'mythic',
     'A sword that cuts because it is entitled to, which is a different thing from cutting well.',
     'The Cut Is the Law',
     'What it severs stays severed, and argues about it afterwards with nobody.',
     '{"A severed technique": "cannot be resumed the same round"}'::jsonb,
     177),

    ('void_lattice_root', 'Void Lattice Root', 'mythic',
     'Space is not empty to this one. It is a structure, and structures have doors.',
     'Gates Without Walls',
     'Arrays laid across distance rather than across ground.',
     '{"Formations": "may be anchored at a distance", "Travel": "shorter than the map allows"}'::jsonb,
     178);

INSERT INTO root_path_bonuses (root_code, path_code, attainment_bonus, damage_bonus) VALUES
    ('dream_sea_root',          'dream',     0.3500, 0.2200),
    ('dream_sea_root',          'wisdom',    0.1700, 0.1100),

    ('ten_thousand_flame_root', 'fire',      0.3500, 0.2200),
    ('ten_thousand_flame_root', 'refinement',0.1700, 0.1100),

    ('blade_decree_root',       'sword',     0.3500, 0.2200),
    ('blade_decree_root',       'rule',      0.1700, 0.1100),

    ('void_lattice_root',       'space',     0.3500, 0.2200),
    ('void_lattice_root',       'formation', 0.1700, 0.1100);
