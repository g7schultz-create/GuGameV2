-- 0344_the_shadow_demon_king_and_the_gu_that_never_dropped
--
-- Three things, and the first of them is a bug I shipped two migrations ago.
--
-- THE HUNDRED AND SIXTY-SIX WERE UNREACHABLE. 0340 taught the trigger on
-- `gu_region_drops` that a gated region may hold Immortal Gu, and 0341 put
-- them there. But the trigger only guards what goes INTO the table;
-- `roll_gu_drop` does its own clamp when it reads back out:
--
--     AND t.rank <= LEAST(GREATEST(p_rank, 1),
--                         game_config_value('gu_max_droppable_rank'))
--
-- - a flat 5, whatever region it is standing in. So every rank 6, 7 and 8 Gu
-- in Black Heaven was a row that could be inserted, could be seen in the
-- region index, and could never be handed to anybody. The gate was moved and
-- the reader was not, which is the oldest mistake in this codebase and one
-- the probes in 0340 walked straight past, because they tested the INSERT.
--
-- The reader now asks the same question the trigger asks: what does THIS
-- region hand out. The `p_rank` term is untouched - a rank 3 beast still does
-- not cough up a rank 8 Gu, in a heaven or anywhere else.
--
-- THE KING'S OWN GU. 'Shadow Demon King -> Soul Demon King Gu' is a thing a
-- species IS known for rather than a thing a region scatters, so it hangs off
-- `creature_species` as one nullable column rather than a table of its own.
-- `claim_boss_reward` already had the shape for it - it grants a manual on a
-- roll in exactly the same place - so the Gu goes in beside that.
--
-- AND THE GU ITSELF WAS ALREADY IN THE CATALOGUE. The first draft of this
-- migration created it and was refused by the unique index on gu_types.code:
-- Soul Demon King Gu has been sitting at id 2603 since the catalogue was
-- written - rank 6, soul, unique, attack, with its effects and its recipe
-- already on it - waiting for something to drop it. That is the whole point
-- of a catalogue, and the right answer was to point at it rather than mint a
-- second one with the same name.
--
-- AND SOMETHING NO HUNT CAN YIELD. `test_a_world_beast_holds_something_no_
-- hunt_can_yield` has held since a rank 9 leviathan paid out three rare beast
-- materials worth two Spirit Stones: `boss_drops` exists as a SECOND table so
-- that a hunt can never roll what a boss holds. The King had creature_drops
-- and no boss_drops, so felling it paid what walking into a wolf pays.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The reader learns what the trigger already knew
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION roll_gu_drop(
    p_player_id BIGINT, p_region TEXT, p_rank SMALLINT DEFAULT 1
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    picked BIGINT;
    cap    NUMERIC;
BEGIN
    IF random() >= game_config_value('gu_drop_chance') THEN
        RETURN NULL;
    END IF;

    -- What this region hands out, which is not the same everywhere since
    -- 0340: behind a door that asks for immortality, Immortal Gu.
    SELECT CASE WHEN COALESCE(r.min_rank, 1) > 1
                THEN game_config_value('gu_max_immortal_droppable_rank')
                ELSE game_config_value('gu_max_droppable_rank') END
    INTO cap
    FROM regions r WHERE r.code = p_region;

    -- Nothing hands out a Gu of a higher rank than the thing guarding it.
    SELECT d.gu_type_id INTO picked
    FROM gu_region_drops d
    JOIN gu_types t ON t.gu_type_id = d.gu_type_id
    WHERE d.region_code = p_region
      AND t.rank <= LEAST(GREATEST(p_rank, 1), COALESCE(cap, 1))
    ORDER BY -ln(random()) / d.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN grant_gu(p_player_id, picked, p_region);
END;
$fn$;


ALTER TABLE creature_species
    ADD COLUMN signature_gu_type_id BIGINT
        REFERENCES gu_types(gu_type_id) ON DELETE SET NULL;

COMMENT ON COLUMN creature_species.signature_gu_type_id IS
    'The Gu this creature is known for, handed over when it is felled. NULL for everything that is not known for one.';

UPDATE creature_species
SET signature_gu_type_id = (SELECT gu_type_id FROM gu_types WHERE code = 'soul_demon_king_gu')
WHERE code = 'shadow_demon_king';


-- Something a hunt can never roll.
INSERT INTO boss_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, v.code, v.chance, v.lo, v.hi
FROM creature_species cs
JOIN (VALUES
    ('dark_heaven_lotus_seed', 0.80, 2, 5),
    ('void_boundary_fragment', 0.60, 1, 3)
) AS v (code, chance, lo, hi) ON TRUE
WHERE cs.code = 'shadow_demon_king';


-- ---------------------------------------------------------------------------
-- And the King hands its own Gu over
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor :=
'        IF random() < game_config_value(''boss_manual_chance'') * weight THEN';

    swap := concat(
'        -- What this one was known for. Not a roll: a King has exactly one', chr(10),
'        -- of these and the person who brought it down gets it.', chr(10),
'        IF owed.signature_gu_type_id IS NOT NULL THEN', chr(10),
'            PERFORM grant_gu(p_player_id, owed.signature_gu_type_id,', chr(10),
'                             owed.region_code);', chr(10),
'        END IF;', chr(10),
chr(10),
anchor);

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'claim_boss_reward';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'claim_boss_reward no longer rolls its manual where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Reachable, exclusive, and the King is worth felling
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    king BIGINT;
    n    INTEGER;
    best SMALLINT;
BEGIN
    -- The thing 0340 and 0341 believed and never checked: can an Immortal Gu
    -- actually come out of Black Heaven?
    SELECT max(t.rank) INTO best
    FROM gu_region_drops d
    JOIN gu_types t ON t.gu_type_id = d.gu_type_id
    JOIN regions r ON r.code = d.region_code
    WHERE d.region_code = 'black_heaven'
      AND t.rank <= LEAST(9, CASE WHEN r.min_rank > 1
                                  THEN game_config_value('gu_max_immortal_droppable_rank')
                                  ELSE game_config_value('gu_max_droppable_rank') END);
    IF COALESCE(best, 0) < 6 THEN
        RAISE EXCEPTION
            'the best Gu Black Heaven can actually hand out is rank % - still shut',
            COALESCE(best, 0);
    END IF;

    -- ...and the mortal world still cannot.
    SELECT max(t.rank) INTO best
    FROM gu_region_drops d
    JOIN gu_types t ON t.gu_type_id = d.gu_type_id
    JOIN regions r ON r.code = d.region_code
    WHERE r.min_rank = 1
      AND t.rank <= game_config_value('gu_max_droppable_rank');
    IF best > game_config_value('gu_max_droppable_rank') THEN
        RAISE EXCEPTION 'the mortal world hands out rank %', best;
    END IF;

    SELECT species_id INTO king FROM creature_species WHERE code = 'shadow_demon_king';

    IF (SELECT signature_gu_type_id FROM creature_species WHERE species_id = king) IS NULL THEN
        RAISE EXCEPTION 'the King is known for nothing';
    END IF;

    SELECT count(*) INTO n
    FROM boss_drops bd
    WHERE bd.species_id = king
      AND NOT EXISTS (SELECT 1 FROM creature_drops cd
                      WHERE cd.species_id = bd.species_id
                        AND cd.material_code = bd.material_code);
    IF n < 1 THEN
        RAISE EXCEPTION 'the King holds nothing a hunt could not also yield';
    END IF;

    RAISE NOTICE 'Black Heaven hands out Immortal Gu, and the King hands out its own';
END;
$probe$;
