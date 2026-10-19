-- 0014_path_emoji
--
-- One emoji per Path, for the buttons in /focus and anywhere else a Path is
-- named in a hurry.
--
-- In a row rather than a dict in the bot, for the same reason `rarities.colour`
-- is a column: it is per-row display data, and the alternative is a lookup
-- table in Python that has to be edited in lockstep with every INSERT into
-- `paths`. Adding a Path is supposed to be an INSERT and nothing else - a
-- second place to remember is exactly the coupling this schema keeps avoiding.
--
-- NOT NULL with a default, so a Path added later renders as a plain marker
-- instead of an empty button, which Discord rejects outright.
--
-- Forward-only. Do not edit once applied.

ALTER TABLE paths
    ADD COLUMN emoji TEXT NOT NULL DEFAULT '\N{BLACK SMALL SQUARE}';

COMMENT ON COLUMN paths.emoji IS
    'Single emoji for buttons and menus. Must be one Discord-renderable glyph; the default is a neutral marker rather than empty, which Discord refuses.';

UPDATE paths SET emoji = v.emoji
FROM (VALUES
    ('fire',           '🔥'),
    ('water',          '💧'),
    ('ice',            '🧊'),
    ('wood',           '🌿'),
    ('lightning',      '⚡'),
    ('earth',          '🪨'),
    ('metal',          '🔩'),
    ('sword',          '🗡️'),
    ('strength',       '💪'),
    ('blood',          '🩸'),
    ('soul',           '👻'),
    ('wisdom',         '📖'),
    ('space',          '🌀'),
    ('time',           '⏳'),
    ('luck',           '🍀'),
    ('refinement',     '🧪'),
    ('formation',      '🔯'),
    ('enslavement',    '🔗'),
    ('transformation', '🦋'),
    ('theft',          '🥷'),
    ('poison',         '☠️'),
    ('human',          '🧍'),
    ('heaven',         '🌩️'),
    ('qi',             '💨'),
    ('dream',          '🌙'),
    ('painting',       '🎨'),
    ('food',           '🍚'),
    ('rule',           '📜')
) AS v (code, emoji)
WHERE paths.code = v.code;
