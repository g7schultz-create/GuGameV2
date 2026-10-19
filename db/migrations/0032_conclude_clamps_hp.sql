-- 0032_conclude_clamps_hp
--
-- Ending a battle wrote the combatant's HP straight back onto the body:
--
--     UPDATE player_physique SET current_hp = me.current_hp
--
-- `battle_combatants.max_hp` is a SNAPSHOT taken when the fight opened - that
-- is 0007's contract, and it is the right one, because a fight should not
-- change shape because someone opened /equipment mid-round. But the BODY's
-- max_hp is live, and it can fall while a battle is open: unequip a manual
-- with an HP bonus and `apply_physique_xp` recomputes a smaller pool.
--
-- The write-back then carried a number larger than the cap and
-- `player_physique_hp_within_cap` rejected it - which does not merely fail the
-- command, it makes that battle IMPOSSIBLE TO CONCLUDE. The claim never
-- releases, so /hunt refuses forever with "you are already in a fight".
--
-- Found by the test suite restoring a pumped body while a fight was open,
-- which is the same sequence a player performs with two clicks.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION battle_conclude(p_battle_id BIGINT, p_status TEXT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    me         battle_combatants%ROWTYPE;
    it         battle_combatants%ROWTYPE;
    victory    BOOLEAN := (p_status = 'complete');
    drop_list  JSONB := '[]'::jsonb;
    d          RECORD;
    qty        BIGINT;
BEGIN
    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0;
    SELECT * INTO it FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 1;

    victory := victory AND it.current_hp <= 0;

    UPDATE battles b
    SET status      = p_status,
        winner_side = CASE
                          WHEN p_status <> 'complete' THEN NULL
                          WHEN it.current_hp <= 0 THEN 0
                          ELSE 1
                      END,
        ended_at    = now()
    WHERE b.battle_id = p_battle_id;

    -- Clamped, because the battle's pool and the body's pool are allowed to
    -- disagree by the time this runs.
    UPDATE player_physique pp
    SET current_hp = LEAST(me.current_hp, pp.max_hp)
    WHERE pp.player_id = me.player_id;

    DELETE FROM player_active_battle WHERE battle_id = p_battle_id;

    IF victory THEN
        UPDATE player_bestiary
        SET times_defeated = times_defeated + 1
        WHERE player_id = me.player_id AND species_id = it.species_id;

        FOR d IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity, m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = it.species_id
        LOOP
            IF random() < d.chance THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(me.player_id, d.material_code, qty);
                drop_list := drop_list || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty);
            END IF;
        END LOOP;
    END IF;

    RETURN drop_list;
END;
$$;
