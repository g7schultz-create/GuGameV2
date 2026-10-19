-- 0238_a_heavier_haul_off_the_line
--
-- 0237 cut the horde's materials by about nine times, from nineteen dungeons
-- down to two. Two is too far in the other direction for a two hour event that
-- needs a room to turn up for it.
--
-- Beast materials double and herbs triple, which lands a full four chest
-- opening at roughly five hard dungeon clears instead of two. Herbs move
-- further because 0234 cut them to a fifth on the argument that gathering is
-- where plants come from - true, and it left a battlefield paying less
-- greenery than a walk in the same region.
--
-- WHAT DOES NOT CHANGE IS HOW IT IS ROLLED. The pile is still the dial; how
-- many kinds a chest holds and how the pile splits between them are still the
-- roll, and the pick is still weighted by the square root of the field chance
-- so the uncommon parts keep surfacing. This migration moves four numbers and
-- touches nothing about the shape.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 10
WHERE key = 'horde_chest_beast_parts';

UPDATE game_config SET value = 40
WHERE key = 'horde_king_chest_beast_parts';

UPDATE game_config SET value = 6
WHERE key = 'horde_chest_herbs';

UPDATE game_config SET value = 30
WHERE key = 'horde_king_chest_herbs';


DO $$
DECLARE
    said RECORD;
BEGIN
    FOR said IN
        SELECT key, value FROM game_config
        WHERE key IN ('horde_chest_beast_parts', 'horde_king_chest_beast_parts',
                      'horde_chest_herbs', 'horde_king_chest_herbs')
    LOOP
        IF said.value <= 0 THEN
            RAISE EXCEPTION '% is %, which pays nothing', said.key, said.value;
        END IF;
    END LOOP;

    -- The parts still outweigh the greenery. A horde that paid more plants
    -- than beasts would be 0234 undone.
    IF (SELECT game_config_value('horde_chest_herbs'))
       >= (SELECT game_config_value('horde_chest_beast_parts')) THEN
        RAISE EXCEPTION 'a ladder chest now pays more greenery than beasts';
    END IF;
    IF (SELECT game_config_value('horde_king_chest_herbs'))
       >= (SELECT game_config_value('horde_king_chest_beast_parts')) THEN
        RAISE EXCEPTION 'the King now pays more greenery than beasts';
    END IF;

    -- And the spill is still a roll rather than a list.
    IF position('sqrt(d.chance)' IN
                (SELECT pg_get_functiondef(oid) FROM pg_proc
                 WHERE proname = 'horde_spill_parts')) = 0 THEN
        RAISE EXCEPTION 'the pick is no longer weighted so uncommons surface';
    END IF;
END;
$$;
