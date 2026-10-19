-- 0075_foresight_is_a_chance_like_the_other_one
--
-- A number on a screen has to be the number the engine uses.
--
-- 0071 shipped two trigger effects. `death_ward` reads as a chance and rolls
-- like one. `foresight` read as a chance, was written to `physique_effects` as
-- 0.95, and was then consumed by `IF ... > 0` - so any value above zero meant
-- always, and the 95% on the sheet was decoration. This schema has spent
-- several migrations on exactly that failure in the other direction: 0045 and
-- 0058 both reported what a function offered rather than what it deposited.
--
-- So foresight rolls. And because the one body carrying it is the body whose
-- whole idea is that it does not have to look, its step is raised until the
-- Mythic band reaches the ceiling - which makes it a certainty for Celestial
-- Sovereign and leaves the effect honest for anything smaller that grants it
-- later.
--
-- Forward-only. Do not edit once applied.

UPDATE gu_effects SET step = 0.0600 WHERE code = 'foresight';

-- Recomputed off the ladder rather than typed, the same way 0070 seeded it.
UPDATE physique_effects pe
SET magnitude = round(e.step * pw.ranks, 4)
FROM physiques p, physique_power pw, gu_effects e
WHERE pe.physique_id = p.physique_id
  AND pw.tier = p.tier
  AND e.code = pe.effect_code
  AND pe.effect_code = 'foresight';

CREATE OR REPLACE FUNCTION battle_open(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    species  creature_species%ROWTYPE;
    body     player_physique%ROWTYPE;
    max_qi   BIGINT;
    b_id     BIGINT;
BEGIN
    SELECT * INTO STRICT species FROM creature_species WHERE species_id = p_species_id;
    SELECT * INTO STRICT body FROM player_physique WHERE player_id = p_player_id;

    IF body.current_hp <= 0 THEN
        RAISE EXCEPTION 'no strength left to fight' USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM player_active_battle WHERE player_id = p_player_id) THEN
        RAISE EXCEPTION 'already in a battle' USING ERRCODE = 'check_violation';
    END IF;

    max_qi := player_max_qi(p_player_id);

    INSERT INTO battles (kind, status, rng_seed)
    VALUES ('pve', 'active', floor(random() * 9223372036854775806)::bigint)
    RETURNING battles.battle_id INTO b_id;

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp, current_qi)
    VALUES (b_id, 0, 0, p_player_id,
            jsonb_build_object('max_hp', body.max_hp, 'defense', body.defense,
                               'strength', body.strength, 'max_qi', max_qi),
            body.max_hp, body.current_hp, max_qi);

    INSERT INTO battle_combatants
        (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp,
         intent_move_id)
    VALUES (b_id, 1, 1, p_species_id,
            jsonb_build_object('base_attack', species.base_attack,
                               'base_defense', species.base_defense,
                               'rank', species.rank),
            species.base_hp, species.base_hp,
            roll_creature_intent(p_species_id));

    INSERT INTO player_active_battle (player_id, battle_id) VALUES (p_player_id, b_id);

    INSERT INTO player_bestiary (player_id, species_id, times_encountered)
    VALUES (p_player_id, p_species_id, 1)
    ON CONFLICT (player_id, species_id) DO UPDATE
        SET times_encountered = player_bestiary.times_encountered + 1,
            last_seen_at      = now();

    -- A body that reads a thing before it moves already knows the weakness, so
    -- it is written down at the door rather than revealed by spending a turn
    -- on Observe. 'insight' is what that kind of discovery is.
    --
    -- AFTER the bestiary row, and that is the whole point of this migration:
    -- `player_bestiary_paths` carries a COMPOSITE foreign key to
    -- (player_id, species_id) in `player_bestiary`, so a path recorded for a
    -- creature the player has no bestiary entry for is a foreign key
    -- violation - and this runs inside battle_open, so the violation is not a
    -- missing note. It is a body that cannot start a fight.
    IF random() < player_stat(p_player_id, 'foresight') THEN
        INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via)
        SELECT p_player_id, p_species_id, cip.path_code, 'insight'
        FROM creature_incoming_paths cip
        WHERE cip.species_id = p_species_id AND cip.interaction = 'advantage'
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN b_id;
END;
$$;
