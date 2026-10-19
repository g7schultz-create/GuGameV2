-- 0216_something_to_hatch_later
--
-- Beast eggs, ahead of the pets that will open them.
--
-- A thing that does nothing is normally the worst kind of content, and 0036
-- was explicit about it: an effect nothing reads is marked as such rather than
-- quietly doing nothing. This is the exception the rule allows for, and the
-- reason is timing. Pets are coming; eggs found before they arrive are worth
-- having, and eggs that only start dropping the day pets ship mean everybody
-- starts from nothing on that day. Collecting now IS the preparation.
--
-- So the egg is honest about it everywhere it is drawn: it says what is in it,
-- what grade it is, and that nothing hatches it yet.
--
-- TIER IS NOT THE BEAST'S RANK. 48 of the game's 52 huntable creatures are
-- rank 1 or 2, so tying an egg's grade to what laid it would make almost every
-- egg a tier 1 and the ladder pointless. Tier comes from WHERE it was found -
-- a rank 6 room leaves a tier 6 egg of whatever beast - so the same Ironhide
-- Boar egg is a different prize out of a different room. Rarity is rolled, and
-- the deeper the tier the further up the rarity ladder it can reach.
--
-- ONLY BEASTS AND ELITES lay eggs. A rogue cultivator does not, and neither
-- does a dungeon boss - those are not species you breed, they are people and
-- calamities respectively.
--
-- `hatched_at` is here and unused, for the same reason `player_gu.harmony` was
-- in 0036: adding it afterwards would mean every egg found before pets ship
-- was a different shape from every egg found after.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What a grade is called
-- ---------------------------------------------------------------------------

CREATE TABLE egg_qualities (
    rarity TEXT PRIMARY KEY REFERENCES rarities (code) ON DELETE RESTRICT,
    word   TEXT NOT NULL,
    emoji  TEXT NOT NULL DEFAULT '🥚'
);

INSERT INTO egg_qualities (rarity, word, emoji) VALUES
    ('common',    'Dull',       '🥚'),
    ('uncommon',  'Mottled',    '🥚'),
    ('rare',      'Veined',     '🐣'),
    ('epic',      'Lustrous',   '🐣'),
    ('legendary', 'Goldshell',  '🐤'),
    ('mythic',    'Starshell',  '🐤'),
    ('divine',    'Dawnlit',    '🦅'),
    ('unique',    'Unsplit',    '🦅'),
    ('extreme',   'Primordial', '🐉');

COMMENT ON TABLE egg_qualities IS
    'The word and the glyph a grade of egg is drawn with. Every rarity has one, so an egg of any grade can be named.';


-- ---------------------------------------------------------------------------
-- The eggs themselves
-- ---------------------------------------------------------------------------

CREATE TABLE player_beast_eggs (
    egg_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    owner_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    species_id BIGINT NOT NULL REFERENCES creature_species (species_id)
                                ON DELETE RESTRICT,

    -- Where it was found, not what laid it. See the header.
    tier       SMALLINT NOT NULL CHECK (tier BETWEEN 1 AND 9),
    rarity     TEXT NOT NULL REFERENCES rarities (code) ON DELETE RESTRICT,

    found_in   TEXT REFERENCES regions (code) ON DELETE SET NULL,
    got_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Reserved for the pet system. Nothing sets it, and a query that reads it
    -- today is reading NULL on purpose.
    hatched_at TIMESTAMPTZ
);

CREATE INDEX player_beast_eggs_owner_idx   ON player_beast_eggs (owner_id);
CREATE INDEX player_beast_eggs_species_idx ON player_beast_eggs (species_id);
CREATE INDEX player_beast_eggs_unhatched_idx
    ON player_beast_eggs (owner_id) WHERE hatched_at IS NULL;

COMMENT ON COLUMN player_beast_eggs.hatched_at IS
    'Unread until pets exist. Stored now so an egg found today is the same shape as one found the day they ship.';


CREATE FUNCTION beast_egg_name(p_species_id BIGINT, p_rarity TEXT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(q.word || ' ', '') || cs.name || ' Egg'
    FROM creature_species cs
    LEFT JOIN egg_qualities q ON q.rarity = p_rarity
    WHERE cs.species_id = p_species_id;
$$;


CREATE VIEW player_egg_shelf AS
SELECT e.egg_id, e.owner_id, e.species_id,
       beast_egg_name(e.species_id, e.rarity) AS name,
       cs.name AS beast, cs.kind AS beast_kind, cs.rank AS beast_rank,
       e.tier, e.rarity, r.sort_order AS rarity_order,
       q.emoji, e.found_in, reg.name AS found_in_name, e.got_at
FROM player_beast_eggs e
JOIN creature_species cs ON cs.species_id = e.species_id
JOIN rarities r          ON r.code = e.rarity
LEFT JOIN egg_qualities q ON q.rarity = e.rarity
LEFT JOIN regions reg     ON reg.code = e.found_in
WHERE e.hatched_at IS NULL;

COMMENT ON VIEW player_egg_shelf IS
    'Every unhatched egg a cultivator holds, named and graded. Nothing hatches them yet - that is the pet system, and this is what it will read.';


-- ---------------------------------------------------------------------------
-- Finding one
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('egg_rarity_reach_per_tier', 10,
     'How far up the rarity ladder each tier of egg may reach, in rarity '
     'sort_order. At 10 a tier 1 egg tops out Uncommon and a tier 7 reaches '
     'Extreme.');


CREATE FUNCTION grant_beast_egg(
    p_player_id  BIGINT,
    p_species_id BIGINT,
    p_tier       SMALLINT,
    p_rarity     TEXT,
    p_region     TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    INSERT INTO player_beast_eggs (owner_id, species_id, tier, rarity, found_in)
    VALUES (p_player_id, p_species_id,
            GREATEST(1, LEAST(9, p_tier))::smallint, p_rarity, p_region)
    RETURNING player_beast_eggs.egg_id INTO made;

    RETURN made;
END;
$$;


CREATE FUNCTION roll_beast_egg(
    p_player_id BIGINT,
    p_tier      SMALLINT,
    p_region    TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    grade   SMALLINT := GREATEST(1, LEAST(9, p_tier));
    reach   NUMERIC;
    who     BIGINT;
    band    TEXT;
BEGIN
    -- Only things that lay eggs. A rogue cultivator is a person and a dungeon
    -- boss is a calamity; neither is a species you keep.
    SELECT cs.species_id INTO who
    FROM creature_species cs
    WHERE cs.kind IN ('beast', 'elite')
      AND (p_region IS NULL
           OR EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.species_id = cs.species_id
                        AND cr.region_code = p_region))
    ORDER BY random() LIMIT 1;

    -- A region with nothing in it should not silently hand over a beast that
    -- does not live there; take anything rather than nothing.
    IF who IS NULL THEN
        SELECT cs.species_id INTO who FROM creature_species cs
        WHERE cs.kind IN ('beast', 'elite') ORDER BY random() LIMIT 1;
    END IF;
    IF who IS NULL THEN
        RETURN NULL;
    END IF;

    reach := 10 + grade * game_config_value('egg_rarity_reach_per_tier');

    -- Weighted toward the plain end, the way every other roll in this game
    -- is: the ceiling rises with the tier, the floor never does.
    SELECT r.code INTO band FROM rarities r
    WHERE r.sort_order <= reach
    ORDER BY -ln(random()) * r.sort_order
    LIMIT 1;

    IF band IS NULL THEN
        band := 'common';
    END IF;

    RETURN grant_beast_egg(p_player_id, who, grade, band, p_region);
END;
$$;


-- ---------------------------------------------------------------------------
-- Asking whether any of that holds
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    n     INTEGER;
    made  BIGINT;
    tops  TEXT;
BEGIN
    -- Every rarity can name an egg, or a lucky roll produces "Ironhide Boar
    -- Egg" with no grade on it and no way to tell it from a common one.
    SELECT count(*) INTO n FROM rarities r
    WHERE NOT EXISTS (SELECT 1 FROM egg_qualities q WHERE q.rarity = r.code);
    IF n > 0 THEN
        RAISE EXCEPTION '% rarities cannot name an egg', n;
    END IF;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to find an egg; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- Every tier lays something, in every region, and never a person.
        FOR i IN 1..9 LOOP
            made := roll_beast_egg(who, i::smallint, NULL);
            IF made IS NULL THEN
                RAISE EXCEPTION 'tier % produced no egg', i;
            END IF;
        END LOOP;

        FOR tops IN SELECT code FROM regions LOOP
            FOR i IN 1..10 LOOP
                PERFORM roll_beast_egg(who, 5::smallint, tops);
            END LOOP;
        END LOOP;

        SELECT count(*) INTO n
        FROM player_beast_eggs e
        JOIN creature_species cs ON cs.species_id = e.species_id
        WHERE e.owner_id = who AND cs.kind NOT IN ('beast', 'elite');
        IF n > 0 THEN
            RAISE EXCEPTION '% eggs hold something that does not lay eggs', n;
        END IF;

        -- A tier 1 egg must never be Extreme, or the ladder is decoration.
        SELECT count(*) INTO n FROM player_beast_eggs e
        JOIN rarities r ON r.code = e.rarity
        WHERE e.owner_id = who
          AND r.sort_order > 10 + e.tier * game_config_value('egg_rarity_reach_per_tier');
        IF n > 0 THEN
            RAISE EXCEPTION '% eggs are graded above what their tier reaches', n;
        END IF;

        -- And every one of them can be drawn.
        SELECT count(*) INTO n FROM player_egg_shelf s
        WHERE s.owner_id = who AND (s.name IS NULL OR s.emoji IS NULL);
        IF n > 0 THEN
            RAISE EXCEPTION '% eggs cannot be named or drawn', n;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
