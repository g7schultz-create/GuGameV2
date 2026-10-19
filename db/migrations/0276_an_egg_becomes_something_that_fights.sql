-- 0276_an_egg_becomes_something_that_fights
--
-- `player_beast_eggs` has carried a `hatched_at` column since it was written
-- and nothing has ever set it. 132 eggs are sitting in inventories with a
-- species, a tier and a rarity apiece, and no destination - /eggs is a shelf
-- you look at.
--
-- So an egg becomes a beast, and the beast fights beside you.
--
-- WHAT IT HITS FOR. A pet is a creature of its species moved onto the tier of
-- the egg it came out of:
--
--     attack = base_attack x 4 ^ (tier - species rank) x rarity x pet_attack_scale
--
-- The 4 is `creature_defense_scale_per_rank`, the same quadrupling every
-- creature already climbs, so a tier 8 egg from a rank 1 beast produces
-- something that belongs at tier 8 rather than something that is still a
-- rank 1 beast. Rarity is a modest multiple on top - a Primordial shell is
-- worth more than a Dull one and that has to show somewhere.
--
-- The blow goes through the same defence divisor a cultivator's does (0259),
-- so a pet is softened by a deep creature's armour exactly as its owner is,
-- and its Path meets the defender's resistances on the same chart. It is a
-- combatant, not a damage bonus with a name.
--
-- Sized at roughly a tenth of what its owner deals. A companion should be
-- felt and not relied on; `pet_attack_scale` is the dial if that reads wrong
-- once people have them.
--
-- Levelling is deliberately absent. A pet's strength comes from the egg it
-- hatched from, which is a thing players already gather and already
-- understand, and adding experience on top would double the balance surface
-- before anybody has held one.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pet_attack_scale', 0.5,
     'What a hatched beast hits for, against what a creature of its tier '
     'would. Half, so a companion is felt beside a cultivator rather than '
     'fighting for them.'),
    ('pet_rarity_step', 0.15,
     'How much each step up the shell ladder adds to a beast''s attack. Nine '
     'bands from Dull to Primordial, so a Primordial hits about twice what a '
     'Dull one of the same tier does.');


CREATE TABLE player_beasts (
    beast_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id   BIGINT   NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    species_id BIGINT   NOT NULL REFERENCES creature_species (species_id),
    egg_id     BIGINT   UNIQUE REFERENCES player_beast_eggs (egg_id) ON DELETE SET NULL,
    name       TEXT     NOT NULL,
    tier       SMALLINT NOT NULL CHECK (tier BETWEEN 1 AND 9),
    rarity     TEXT     NOT NULL REFERENCES rarities (code),
    at_heel    BOOLEAN  NOT NULL DEFAULT FALSE,
    hatched_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_beasts_owner_idx ON player_beasts (owner_id);
CREATE INDEX player_beasts_species_idx ON player_beasts (species_id);

-- One at a time. A menagerie is a collection; what walks beside you is one
-- beast, the same way the aperture holds Gu and the slots hold manuals.
CREATE UNIQUE INDEX player_beasts_one_at_heel_idx
    ON player_beasts (owner_id) WHERE at_heel;

COMMENT ON TABLE player_beasts IS
    'Beasts hatched from eggs. `at_heel` is the one that comes into a fight, and only one may be.';


-- ---------------------------------------------------------------------------
-- What it hits for
-- ---------------------------------------------------------------------------

CREATE FUNCTION pet_attack(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1,
        cs.base_attack
        * power(game_config_value('creature_defense_scale_per_rank'),
                GREATEST(0, b.tier - cs.rank))
        * (1 + game_config_value('pet_rarity_step')
               * (SELECT count(*) FROM rarities r2
                  WHERE r2.sort_order < r.sort_order))
        * game_config_value('pet_attack_scale'))
    FROM player_beasts b
    JOIN creature_species cs ON cs.species_id = b.species_id
    JOIN rarities r ON r.code = b.rarity
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION pet_attack(BIGINT) IS
    'A hatched beast''s attack: its species moved onto the tier of the egg it came from, lifted by the shell it broke out of.';


CREATE FUNCTION pet_at_heel(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT b.beast_id FROM player_beasts b
    WHERE b.owner_id = p_player_id AND b.at_heel;
$$;

COMMENT ON FUNCTION pet_at_heel(BIGINT) IS
    'The beast that comes into a fight with this cultivator, or NULL. Every lane asks this and does nothing if the answer is nothing.';


CREATE FUNCTION pet_blow(
    p_beast_id BIGINT, p_defender_species_id BIGINT, p_defense BIGINT DEFAULT 0
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    atk     NUMERIC;
    mine    TEXT;
    matchup NUMERIC := 0;
    their   SMALLINT;
    scale   NUMERIC;
BEGIN
    atk := pet_attack(p_beast_id);
    IF atk IS NULL THEN
        RETURN 0;
    END IF;

    -- Its own Path against what the defender turns aside, read off the same
    -- chart a technique is read off.
    SELECT cp.path_code INTO mine
    FROM player_beasts b
    JOIN creature_paths cp ON cp.species_id = b.species_id
    WHERE b.beast_id = p_beast_id
    LIMIT 1;

    IF mine IS NOT NULL THEN
        SELECT COALESCE(mi.damage_modifier, 0) INTO matchup
        FROM creature_incoming_paths ci
        JOIN matchup_interactions mi ON mi.code = ci.interaction
        WHERE ci.species_id = p_defender_species_id AND ci.path_code = mine;
    END IF;

    -- Immunity is a rule about the Path, the same as it is for a cultivator.
    IF matchup <= -1 THEN
        RETURN 0;
    END IF;

    SELECT COALESCE(cs.rank, 1) INTO their
    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;

    scale := game_config_value('defense_scale')
             * power(game_config_value('creature_defense_scale_per_rank'),
                     GREATEST(0, COALESCE(their, 1) - 1));

    RETURN GREATEST(1, round(
        atk * (1 + COALESCE(matchup, 0))
        * scale / (scale + GREATEST(p_defense, 0))))::bigint;
END;
$$;

COMMENT ON FUNCTION pet_blow(BIGINT, BIGINT, BIGINT) IS
    'What the beast at heel takes off one creature. Softened by the defender''s armour on the same curve its owner is, and stopped dead by an immunity the same way.';


-- ---------------------------------------------------------------------------
-- Hatching
-- ---------------------------------------------------------------------------

CREATE FUNCTION hatch_egg(p_player_id BIGINT, p_egg_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    egg  RECORD;
    made BIGINT;
    solo BOOLEAN;
BEGIN
    SELECT e.*, cs.name AS species_name
    INTO egg
    FROM player_beast_eggs e
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE e.egg_id = p_egg_id AND e.owner_id = p_player_id
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that egg is not yours' USING ERRCODE = 'check_violation';
    END IF;
    IF egg.hatched_at IS NOT NULL THEN
        RAISE EXCEPTION 'that one has already hatched'
            USING ERRCODE = 'check_violation';
    END IF;

    -- The first one walks at your heel; anything after that waits its turn,
    -- because only one may.
    solo := NOT EXISTS (
        SELECT 1 FROM player_beasts b WHERE b.owner_id = p_player_id AND b.at_heel
    );

    INSERT INTO player_beasts
        (owner_id, species_id, egg_id, name, tier, rarity, at_heel)
    VALUES (p_player_id, egg.species_id, egg.egg_id,
            beast_egg_name(egg.species_id, egg.rarity),
            egg.tier, egg.rarity, solo)
    RETURNING beast_id INTO made;

    UPDATE player_beast_eggs SET hatched_at = now() WHERE egg_id = p_egg_id;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION hatch_egg(BIGINT, BIGINT) IS
    'Turns one egg into a beast. The first one hatched walks at your heel; the rest wait, because only one may.';


CREATE FUNCTION pet_call(p_player_id BIGINT, p_beast_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM player_beasts
        WHERE beast_id = p_beast_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that is not your beast' USING ERRCODE = 'check_violation';
    END IF;

    -- Sent away first, then called: the unique index allows exactly one, and
    -- doing it the other way round trips it.
    UPDATE player_beasts SET at_heel = FALSE
    WHERE owner_id = p_player_id AND at_heel AND beast_id <> p_beast_id;

    UPDATE player_beasts SET at_heel = TRUE WHERE beast_id = p_beast_id;
END;
$$;

COMMENT ON FUNCTION pet_call(BIGINT, BIGINT) IS
    'Puts one beast at your heel and sends the other away. Order matters: the unique index allows exactly one.';


CREATE VIEW player_beast_shelf AS
SELECT b.beast_id, b.owner_id, b.name, b.tier, b.rarity, b.at_heel,
       b.hatched_at,
       cs.name AS species, cs.rank AS species_rank, cs.kind AS species_kind,
       q.emoji, q.word AS shell,
       r.sort_order AS rarity_order,
       p.name AS path_name, p.emoji AS path_emoji,
       round(pet_attack(b.beast_id)) AS attack,
       reg.name AS found_in_name
FROM player_beasts b
JOIN creature_species cs ON cs.species_id = b.species_id
JOIN rarities r ON r.code = b.rarity
LEFT JOIN egg_qualities q ON q.rarity = b.rarity
LEFT JOIN creature_paths cp ON cp.species_id = b.species_id
LEFT JOIN paths p ON p.code = cp.path_code
LEFT JOIN player_beast_eggs e ON e.egg_id = b.egg_id
LEFT JOIN regions reg ON reg.code = e.found_in;


-- ---------------------------------------------------------------------------
-- An egg hatches, once, into something that hits
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    egg    BIGINT;
    beast  BIGINT;
    second BIGINT;
    hits   BIGINT;
    target BIGINT;
BEGIN
    SELECT e.owner_id, e.egg_id INTO who, egg
    FROM player_beast_eggs e
    JOIN players p ON p.player_id = e.owner_id
    WHERE e.hatched_at IS NULL AND p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY e.tier DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no eggs to hatch; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        beast := hatch_egg(who, egg);

        IF NOT (SELECT at_heel FROM player_beasts WHERE beast_id = beast) THEN
            RAISE EXCEPTION 'the first beast hatched did not come to heel';
        END IF;
        IF pet_at_heel(who) <> beast THEN
            RAISE EXCEPTION 'the beast at heel is not the one that hatched';
        END IF;

        -- Once only.
        BEGIN
            PERFORM hatch_egg(who, egg);
            RAISE EXCEPTION 'the same egg hatched twice';
        EXCEPTION
            WHEN SQLSTATE '23514' THEN NULL;
        END;

        -- It hits something, and an immunity still stops it dead.
        SELECT cs.species_id INTO target
        FROM creature_species cs WHERE cs.kind = 'beast' ORDER BY cs.rank LIMIT 1;

        hits := pet_blow(beast, target, 0);
        IF hits < 1 THEN
            RAISE EXCEPTION 'a hatched beast hits for nothing at all';
        END IF;

        -- A second one waits its turn rather than tripping the index.
        SELECT e.egg_id INTO second FROM player_beast_eggs e
        WHERE e.owner_id = who AND e.hatched_at IS NULL LIMIT 1;

        IF second IS NOT NULL THEN
            second := hatch_egg(who, second);
            IF (SELECT at_heel FROM player_beasts WHERE beast_id = second) THEN
                RAISE EXCEPTION 'two beasts came to heel at once';
            END IF;

            PERFORM pet_call(who, second);
            IF pet_at_heel(who) <> second THEN
                RAISE EXCEPTION 'calling the second one did not swap them';
            END IF;
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
