-- 0040_roster_material_paths
--
-- Eleven beast materials had no Path.
--
-- 0038 gave every material in 0017 a Path by hand, and 0020's starter roster
-- brought eleven more that the list never saw. A Path-less material is not an
-- error - it means "bulk, and no opinion", which is a real thing for a
-- material to be - so nothing failed. It just made eleven drops silently
-- worthless on a refining bench, which is the worst kind of wrong: the sort a
-- player has to work out from a number that never moves.
--
-- The rule that nothing shipped should be Path-less now lives in a test, so
-- the next roster to land says so before a player has to notice.
--
-- Forward-only. Do not edit once applied.

UPDATE materials m SET path_code = v.path
FROM (VALUES
    ('beast_horn',           'strength'),
    ('crab_carapace',        'water'),
    ('crystal_carapace',     'earth'),
    ('desert_scale',         'earth'),
    ('gilded_carapace',      'metal'),
    ('mirage_pelt',          'illusion'),
    ('moth_wing_dust',       'wind'),
    ('shark_tooth',          'water'),
    ('tortoise_shell_plate', 'earth'),
    ('turtle_shell',         'water'),
    ('vitality_sap',         'wood')
) AS v (code, path)
WHERE m.code = v.code;
