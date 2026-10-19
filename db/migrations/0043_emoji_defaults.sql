-- 0043_emoji_defaults
--
-- Three more Python escapes sitting in SQL defaults.
--
-- 0042 corrected the two on the Gu tables and left a test asserting no emoji
-- column defaults to a `\N{...}` escape. The test immediately named three
-- more: `paths.emoji`, `regions.emoji` and `page_types.emoji`, all written the
-- same way and all storing the literal characters rather than the character.
--
-- No row has ever worn one - every Path, region and page type was seeded with
-- an explicit emoji - so this is entirely a trap for the next row somebody
-- adds without one. The same character each escape was reaching for is now
-- the default, spelled the way PostgreSQL reads it.
--
-- Forward-only. Do not edit once applied.

ALTER TABLE paths      ALTER COLUMN emoji SET DEFAULT '▪️';
ALTER TABLE regions    ALTER COLUMN emoji SET DEFAULT '📍';
ALTER TABLE page_types ALTER COLUMN emoji SET DEFAULT '📄';
