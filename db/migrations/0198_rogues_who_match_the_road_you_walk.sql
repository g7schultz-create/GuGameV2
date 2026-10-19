-- 0198_rogues_who_match_the_road_you_walk
--
-- `rogue_pages` already gives better pages to a higher-ranked rogue: a rank N
-- rogue carries tier N to N+2. That half was right. The half that was missing
-- is that `spawn_rogue(region)` NEVER LOOKED AT THE PLAYER - it drew from the
-- region's whole rogue list by region weight alone, and in northern all eight
-- carry weight 10. So a Nascent Soul cultivator was ambushed by a rank 1 Herb
-- Thief three times in eight, and carried home tier 1-3 pages for it.
--
-- The page stock says so plainly. Across every cultivator alive:
--
--     tier 1    996        tier 5    105
--     tier 2  1,319        tier 6     27
--     tier 3  1,170        tier 7      6
--     tier 4    501
--
-- Tier 7 pages are almost mythical, and a tier 8 manual wants 224 power that
-- only tier 5+ pages can supply.
--
-- So a rogue is now drawn near the rank of whoever they ambush. The region
-- weight still decides WHICH rogue of a rank shows up; a falloff decides how
-- far below the player the game is willing to reach:
--
--     rank R      x 1.00      what you should mostly meet
--     rank R-1    x 0.35
--     rank R-2    x 0.12
--     rank R-3    x 0.04      still possible, barely
--     rank R+1    x 0.25      the ambush that goes badly
--
-- ONE RANK ABOVE IS ALLOWED, DELIBERATELY. It is the only reason a cultivator
-- at the top of the ladder has anything left to be surprised by, and it is
-- what makes the rank 5 rogues below reachable the day they are added rather
-- than content nobody can meet.
--
-- Two rogues at rank 5 come with it, and no more. Nobody is past rank 4, so
-- R+1 reaches exactly 5; a rank 6 rogue would be a row that exists and can
-- never be met, which is the failure this codebase keeps having to undo.
--
-- I wrote four here on the first pass - two at rank 5 and two at rank 6 - and
-- the invariant at the bottom of this file rejected the migration. It was
-- right. Rank 6 gets written the day somebody reaches rank 5, and the same
-- check will fail until they do.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('rogue_rank_falloff', 0.35,
     'Weight multiplier per rank a rogue sits BELOW the cultivator they would '
     'ambush. 0.35 means one rank down is a third as likely, two ranks down a '
     'ninth - present, but not what you mostly meet.'),
    ('rogue_overmatch_weight', 0.25,
     'Weight for a rogue one rank ABOVE the cultivator. The fight that goes '
     'badly, and the only way to see pages from above your own realm.');


-- The four who wander past Nascent Soul. Stats continue the curve the eight
-- below them already draw: about 1.65x HP and 1.5x attack per rank.
INSERT INTO creature_species
    (code, name, rank, kind, base_hp, base_attack, base_defense, base_speed,
     description)
VALUES
    ('rogue_severed_elder', 'Severed Sect Elder', 5, 'rogue',
     2300, 110, 66, 36,
     'His sect was erased and he was not, which he has never explained. He '
     'carries their entire library in his head and none of it on paper.'),

    ('rogue_ruin_wanderer', 'Nine Ruins Wanderer', 5, 'rogue',
     2150, 118, 58, 44,
     'Walks between the places where something went wrong, arriving neither '
     'early enough to prevent it nor late enough to be innocent.');


INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path_code, v.is_primary
FROM (VALUES
    ('rogue_severed_elder',   'rule',      TRUE),
    ('rogue_severed_elder',   'wisdom',    FALSE),
    ('rogue_ruin_wanderer',   'space',     TRUE),
    ('rogue_ruin_wanderer',   'time',      FALSE)
) AS v(code, path_code, is_primary)
JOIN creature_species s ON s.code = v.code;


-- The three regions that already carry rank 3 and 4 rogues. Central and
-- eastern stop at rank 2 and are left alone: they are the shallow end.
INSERT INTO creature_regions (species_id, region_code, weight)
SELECT s.species_id, r.region_code, 10.0000
FROM creature_species s
CROSS JOIN (VALUES ('northern'), ('southern'), ('western')) AS r(region_code)
WHERE s.code IN ('rogue_severed_elder', 'rogue_ruin_wanderer');


INSERT INTO creature_drops (species_id, material_code, chance,
                            min_quantity, max_quantity)
SELECT s.species_id, v.material_code, v.chance, v.lo, v.hi
FROM (VALUES
    ('rogue_severed_elder', 'soul_crystal', 0.5000, 2, 4),
    ('rogue_ruin_wanderer', 'soul_crystal', 0.5000, 2, 4)
) AS v(code, material_code, chance, lo, hi)
JOIN creature_species s ON s.code = v.code;


-- The old one took a region and nothing else, which is the whole bug.
DROP FUNCTION spawn_rogue(TEXT);

CREATE FUNCTION spawn_rogue(p_region TEXT, p_player_id BIGINT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    found BIGINT;
    mine  SMALLINT;
BEGIN
    IF random() >= game_config_value('rogue_spawn_chance') THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(r.rank, 1) INTO mine
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;

    mine := COALESCE(mine, 1);

    -- The region weight still decides which rogue OF A RANK turns up; the
    -- falloff decides how far below the cultivator the game reaches. One rank
    -- above is allowed and rare.
    SELECT s.species_id INTO found
    FROM creature_regions cr
    JOIN creature_species s ON s.species_id = cr.species_id
    WHERE cr.region_code = p_region
      AND s.kind = 'rogue'
      AND s.rank <= mine + 1
    ORDER BY -ln(random()) / (cr.weight * CASE
        WHEN s.rank > mine THEN game_config_value('rogue_overmatch_weight')
        ELSE power(game_config_value('rogue_rank_falloff'), mine - s.rank)
    END)
    LIMIT 1;

    -- A region with nothing at or below the cultivator's rank should not
    -- silently stop ambushing them.
    IF found IS NULL THEN
        SELECT s.species_id INTO found
        FROM creature_regions cr
        JOIN creature_species s ON s.species_id = cr.species_id
        WHERE cr.region_code = p_region AND s.kind = 'rogue'
        ORDER BY s.rank, -ln(random()) / cr.weight
        LIMIT 1;
    END IF;

    RETURN found;
END;
$$;

COMMENT ON FUNCTION spawn_rogue(TEXT, BIGINT) IS
    'A rogue near the ambushed cultivator''s own rank. Their rank decides the '
    'tier of the pages they were carrying, through rogue_pages.';


DO $$
DECLARE
    thin  TEXT;
    top   SMALLINT;
    who   BIGINT;
    where_ TEXT;
    high  NUMERIC;
    low   NUMERIC;
    n     INTEGER := 400;
BEGIN
    -- No rogue may exist that nobody could ever meet. R+1 is the reach, so
    -- the highest rogue must be within one rank of the highest cultivator.
    SELECT max(r.rank) INTO top
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0;

    SELECT string_agg(s.name || ' (rank ' || s.rank || ')', ', ') INTO thin
    FROM creature_species s
    WHERE s.kind = 'rogue' AND s.rank > COALESCE(top, 1) + 1;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION
            'nobody can meet these rogues - the best cultivator is rank %: %',
            top, thin;
    END IF;

    -- And every rogue must be findable somewhere, or it is the same fault in
    -- the other direction.
    SELECT string_agg(s.name, ', ') INTO thin
    FROM creature_species s
    WHERE s.kind = 'rogue'
      AND NOT EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.species_id = s.species_id);

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these rogues live nowhere: %', thin;
    END IF;

    -- Every rogue's page range must be inside what a page can be.
    SELECT string_agg(s.name, ', ') INTO thin
    FROM creature_species s
    WHERE s.kind = 'rogue'
      AND s.rank > 7;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'a rogue above rank 7 cannot carry pages: %', thin;
    END IF;

    -- ---- and it actually changes who turns up ----------------------------
    SELECT p.player_id, COALESCE(pl.region_code, 'northern') INTO who, where_
    FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    LEFT JOIN player_location pl ON pl.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY r.rank DESC, p.player_id
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no live cultivator; tests carry it';
        RETURN;
    END IF;

    -- Sampled through `spawn_rogue` itself rather than through a copy of its
    -- ORDER BY. A copy would be a second implementation of the rule, and the
    -- first thing to disagree with it - and the first draft of this probe
    -- inlined the ordering, was evaluated once by the planner because nothing
    -- correlated it to the series, and reported an average of exactly 1.00.
    --
    -- The 10% ambush roll means most calls return NULL; those are not
    -- ambushes and are not counted.
    SELECT avg(sp.rank) INTO high
    FROM (SELECT spawn_rogue(where_, who) AS sid
          FROM generate_series(1, n * 20)) drew
    JOIN creature_species sp ON sp.species_id = drew.sid;

    -- What the old rule gave: flat region weight over everything present.
    SELECT avg(sp.rank) INTO low
    FROM creature_regions cr
    JOIN creature_species sp ON sp.species_id = cr.species_id
    WHERE cr.region_code = where_ AND sp.kind = 'rogue';

    IF high IS NULL THEN
        RAISE EXCEPTION 'no ambush landed in % samples', n * 20;
    END IF;

    IF high <= low THEN
        RAISE EXCEPTION
            'rogues are no better matched than before: % against a flat %',
            round(high, 2), round(low, 2);
    END IF;

    RAISE NOTICE 'ambushes in % now average rank % against a flat %',
        where_, round(high, 2), round(low, 2);
END;
$$;
