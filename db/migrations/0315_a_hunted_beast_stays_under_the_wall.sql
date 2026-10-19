-- 0315_a_hunted_beast_stays_under_the_wall
--
-- 0314 put two rank 9 beasts in the hunt draw at 17.2 and 18.9 million, and
-- `test_a_world_beast_is_not_something_you_blunder_into` refused them: the
-- weakest thing in the 'world'/'boss' kinds holds 9,431,148, so the hardiest
-- huntable creature was suddenly TWICE what /boss is built around. The split
-- between the two commands stopped being about reach.
--
-- That rule is not arbitrary. The Leviathan sat in the Eastern Sea hunt draw
-- from 0010 to 0139 - five million health at weight 1.0, so roughly one hunt
-- in a hundred and twenty-five threw a Qi Condensation cultivator at a wall,
-- and `player_active_battle` being one-per-player kept them in front of it.
-- 0314's `spawn_beast` stops a newcomer being SHOWN one, but the rule is
-- about the shape of the ladder rather than about who gets shown what, and it
-- is right: nothing you can blunder into should outweigh the thing the whole
-- server turns up for.
--
-- My own probe in 0314 checked the new beasts against the DUNGEON bosses and
-- passed, because a rank 9 dungeon boss holds 56 million. It never thought to
-- check the 'boss' kind, which is the smaller and more important number. The
-- repo's rule knew about both.
--
-- So the two rank 9 beasts come down under the wall. The curve from rank 7 to
-- 9 compresses - about 2.4x a rank rather than 4x - which is the honest cost
-- of having a ceiling there at all, and the ceiling matters more than the
-- multiple.
--
-- Forward-only. Do not edit once applied.


UPDATE creature_species SET base_hp = 8400000, base_attack = 1120000, base_defense = 400000
WHERE code = 'primordial_dragon_whale';

UPDATE creature_species SET base_hp = 8900000, base_attack = 1180000, base_defense = 370000
WHERE code = 'sovereign_ninetail_fox';


-- ---------------------------------------------------------------------------
-- Nothing you can walk into outweighs what you have to organise for
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    reachable BIGINT;
    walls     BIGINT;
BEGIN
    SELECT max(cs.base_hp) INTO reachable
    FROM creature_species cs
    WHERE cs.kind NOT IN ('world', 'boss')
      AND EXISTS (SELECT 1 FROM creature_regions cr
                  WHERE cr.species_id = cs.species_id);

    SELECT min(cs.base_hp) INTO walls
    FROM creature_species cs WHERE cs.kind IN ('world', 'boss');

    IF walls <= reachable THEN
        RAISE EXCEPTION
            'the weakest wall holds % and the hardiest huntable creature %',
            walls, reachable;
    END IF;

    -- And the ladder still climbs: every rank of beast heavier than the last.
    IF EXISTS (
        SELECT 1 FROM creature_species a
        JOIN creature_species b ON b.kind = 'beast' AND b.rank = a.rank - 1
        WHERE a.kind = 'beast'
        GROUP BY a.rank
        HAVING min((SELECT max(base_hp) FROM creature_species
                    WHERE kind = 'beast' AND rank = a.rank))
             <= max((SELECT max(base_hp) FROM creature_species
                     WHERE kind = 'beast' AND rank = a.rank - 1))
    ) THEN
        RAISE EXCEPTION 'a rank of beast is no heavier than the rank below it';
    END IF;

    RAISE NOTICE
        'hardiest huntable %, weakest wall % - the split holds',
        reachable, walls;
END;
$$;
