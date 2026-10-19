-- 0090_one_purse_per_body
--
-- Two bugs in the jade faucets, both visible on one screen.
--
-- THE EMOJI WAS NEVER AN EMOJI. 0086 wrote `'\U0001F49A'` into the JSON it
-- builds, and Postgres has no such escape in an ordinary string literal - it
-- is ten characters of backslash-U-zero-zero. The drop line read
--
--     \U0001F49A Spirit Jade x1
--
-- The fix is not a better literal. `materials` already holds the emoji and the
-- rarity for Spirit Jade, and hardcoding a copy beside it was a second place
-- to be wrong, which is exactly what it turned out to be. It is read off the
-- row now.
--
-- AND IT LISTED ITSELF TWICE. Killing the first rogue of a species fires both
-- faucets, and each appended its own line - so a single body handed back two
-- separate one-jade entries. The ledger still records them separately, because
-- tuning has to know which tap ran; the player is looking at a corpse and
-- wants one number.
--
-- THE PURSE IS ALSO TOO GENEROUS. It was the one repeatable faucet in the game
-- and it was set at 35%, which for a rogue turning up in roughly one world
-- action in ten is a steady drip into every account forever. Three percent.
--
-- Forward-only. Do not edit once applied.

UPDATE game_config SET value = 0.03,
    description = 'Chance a beaten rogue was carrying any at all. The only repeatable faucet, so it is deliberately thin.'
WHERE key = 'jade_rogue_chance';


-- ---------------------------------------------------------------------------
-- battle_conclude, from 0086_where_the_jade_comes_from
-- ---------------------------------------------------------------------------

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
    kills      INTEGER;
    purse      BIGINT := 0;
    bounty     BIGINT := 0;
    jade_face  TEXT;
    jade_band  TEXT;
    species    creature_species%ROWTYPE;
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
    -- disagree by the time this runs. See 0032.
    UPDATE player_physique pp
    SET current_hp = LEAST(me.current_hp, pp.max_hp)
    WHERE pp.player_id = me.player_id;

    DELETE FROM player_active_battle WHERE battle_id = p_battle_id;

    IF victory THEN
        -- The count comes back from the UPDATE that made it. Asking a second
        -- time would be asking a question this statement has already answered,
        -- and the two could disagree.
        UPDATE player_bestiary
        SET times_defeated = times_defeated + 1
        WHERE player_id = me.player_id AND species_id = it.species_id
        RETURNING times_defeated INTO kills;

        SELECT * INTO species FROM creature_species WHERE species_id = it.species_id;

        -- The first of a species, once in a character's life, sixty-two times.
        IF kills = 1 THEN
            bounty := game_config_value('jade_first_kill');
            IF bounty > 0 THEN
                PERFORM grant_jade(me.player_id, bounty, 'first_kill');
                purse := purse + bounty;
            END IF;
        END IF;

        -- A rogue is a person, and people carry money. The only repeatable
        -- faucet in the game, and therefore the one held smallest.
        IF species.kind = 'rogue'
           AND random() < game_config_value('jade_rogue_chance') THEN
            bounty := game_config_value('jade_rogue_purse');
            IF bounty > 0 THEN
                PERFORM grant_jade(me.player_id, bounty, 'rogue_purse');
                purse := purse + bounty;
            END IF;
        END IF;

        -- ONE line, however many faucets contributed to it. The ledger keeps
        -- them apart because tuning needs to know which tap ran; the player is
        -- looking at a body and wants to know what came off it.
        --
        -- And the picture is read off `materials` rather than written out
        -- here: the row already knows what Spirit Jade looks like, and a
        -- second copy is a second chance to be wrong - which it was.
        IF purse > 0 THEN
            SELECT m.emoji, m.rarity INTO jade_face, jade_band
            FROM materials m WHERE m.code = 'spirit_jade';

            drop_list := drop_list || jsonb_build_object(
                'code', 'spirit_jade', 'name', 'Spirit Jade',
                'quantity', purse, 'emoji', jade_face, 'rarity', jade_band);
        END IF;

        FOR d IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity,
                   m.name, m.emoji, m.rarity
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = it.species_id
        LOOP
            IF random() < d.chance THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(me.player_id, d.material_code, qty);
                drop_list := drop_list || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty,
                    'emoji', d.emoji, 'rarity', d.rarity);
            END IF;
        END LOOP;
    END IF;

    RETURN drop_list;
END;
$$;
