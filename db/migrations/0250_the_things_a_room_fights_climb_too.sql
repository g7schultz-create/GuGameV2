-- 0250_the_things_a_room_fights_climb_too
--
-- The world beast is now smaller than a creature you can hunt alone.
--
-- 0249 restacked every kind onto a four-times-a-rank ladder by anchoring each
-- kind on its own lowest rank - and skipped any kind standing at a single
-- rank, because a kind with one rank has no ladder to be wrong about. That was
-- true and incomplete: `boss` exists only at rank 7 and `world` only at rank 9,
-- so both sat still while the roster around them quadrupled per rank. The rank
-- 7 boss carries 82,438 against a rank 7 beast's 1,179,648, and the hardiest
-- huntable creature now outweighs the world beast outright.
--
-- The invariant that caught it is worth stating: the split between /hunt and
-- /boss is supposed to be about being out of reach.
--
-- SO THEY ARE PLACED ON THE CURVE RATHER THAN CLIMBING IT. Both are pinned to
-- the beast of their own rank: eight times its health, because a world beast
-- is a thing a room gangs up on and a lone cultivator should not be able to
-- chew through it - and its ordinary attack and defence, because
-- `boss_bite_cap` already limits what one of its blows may take and a boss
-- that hit eight times as hard would simply delete whoever it looked at.
--
-- Their real encounter health is computed by `boss_hp_pool` and
-- `dungeon_boss_hp` from who is actually online, so these are the species'
-- standing rather than the size of any particular fight. They still have to be
-- right, because that standing is what tells a cultivator which of these is
-- not for them.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('world_beast_body_multiple', 8,
     'How many beasts of its own rank a world beast is built out of. Health '
     'only - its blows stay on the ordinary curve, because a boss that hit '
     'eight times as hard would delete whoever it looked at.');


DO $$
DECLARE
    step  NUMERIC := power(game_config_value('stat_step_per_rank'), 2);
    heavy NUMERIC := game_config_value('world_beast_body_multiple');
    k     RECORD;
    hp0   NUMERIC;
    at0   NUMERIC;
    df0   NUMERIC;
    low   SMALLINT;
    moved INTEGER := 0;
BEGIN
    -- The beast ladder is the spine everything else is measured against.
    SELECT min(cs.rank) INTO low FROM creature_species cs WHERE cs.kind = 'beast';
    SELECT avg(cs.base_hp), avg(cs.base_attack), avg(cs.base_defense)
    INTO hp0, at0, df0
    FROM creature_species cs WHERE cs.kind = 'beast' AND cs.rank = low;

    IF hp0 IS NULL THEN
        RAISE NOTICE 'no beast ladder to measure against; the tests carry it';
        RETURN;
    END IF;

    FOR k IN
        SELECT cs.kind, cs.rank,
               avg(cs.base_hp) AS hp, avg(cs.base_attack) AS atk,
               avg(cs.base_defense) AS def
        FROM creature_species cs
        WHERE cs.kind IN ('world', 'boss')
        GROUP BY cs.kind, cs.rank
    LOOP
        UPDATE creature_species cs
        SET base_hp = GREATEST(1, round(cs.base_hp
                * (hp0 * power(step, k.rank - low) * heavy) / GREATEST(k.hp, 1))),
            base_attack = GREATEST(1, round(cs.base_attack
                * (at0 * power(step, k.rank - low)) / GREATEST(k.atk, 1))),
            base_defense = GREATEST(0, round(cs.base_defense
                * (df0 * power(step, k.rank - low)) / GREATEST(k.def, 1)))
        WHERE cs.kind = k.kind AND cs.rank = k.rank;

        moved := moved + 1;
    END LOOP;

    RAISE NOTICE 'placed % world/boss groups on the curve', moved;
END;
$$;


DO $$
DECLARE
    weakest BIGINT;
    hardest BIGINT;
BEGIN
    SELECT min(cs.base_hp) INTO weakest
    FROM creature_species cs WHERE cs.kind IN ('world', 'boss');

    SELECT max(cs.base_hp) INTO hardest
    FROM creature_species cs WHERE cs.kind IN ('beast', 'elite', 'rogue');

    IF weakest IS NULL OR hardest IS NULL THEN
        RAISE NOTICE 'nothing to compare; the tests carry it';
        RETURN;
    END IF;

    IF weakest <= hardest THEN
        RAISE EXCEPTION
            'the weakest world beast has % and the hardiest huntable creature %',
            weakest, hardest;
    END IF;

    -- And its blows stayed on the ordinary curve rather than following its body.
    IF EXISTS (
        SELECT 1 FROM creature_species w
        WHERE w.kind IN ('world', 'boss')
          AND w.base_attack > 20 * (
              SELECT max(cs.base_attack) FROM creature_species cs
              WHERE cs.kind = 'beast' AND cs.rank = w.rank)
    ) THEN
        RAISE EXCEPTION 'a world beast hits far past the curve for its rank';
    END IF;
END;
$$;
