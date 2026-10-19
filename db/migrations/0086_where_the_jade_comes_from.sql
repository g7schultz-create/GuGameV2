-- 0086_where_the_jade_comes_from
--
-- Three faucets, and neither function needed a new idea to carry them.
--
-- `battle_conclude` already increments `times_defeated` and already knows
-- whether the thing it just killed was a rogue, so both of the kill faucets
-- are read off state it was maintaining anyway. The first-kill payout is
-- decided by the RETURNING of that same UPDATE - a row coming back with
-- `times_defeated = 1` is, by definition, a first kill, and no second query
-- can disagree with it.
--
-- `breakthrough` already reports what it banked, three times over. This is the
-- fourth column of that kind and the third migration to add one.
--
-- WHAT THE PLAYER IS TOLD. Every one of these appears on a card: the
-- breakthrough card names the jade beside the realm, and a purse or a
-- first-kill bounty rides in the drops list the battle screen already renders.
-- Money that arrived silently would be money nobody knows they have.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- battle_conclude, from 0044_breakthrough
-- ---------------------------------------------------------------------------
-- Two faucets, both read off state this function already maintained.

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
            purse := game_config_value('jade_first_kill');
            IF purse > 0 THEN
                PERFORM grant_jade(me.player_id, purse, 'first_kill');
                drop_list := drop_list || jsonb_build_object(
                    'code', 'spirit_jade', 'name', 'Spirit Jade',
                    'quantity', purse, 'emoji', '\U0001F49A', 'rarity', 'rare',
                    'note', 'the first ' || species.name || ' you have killed');
            END IF;
        END IF;

        -- A rogue is a person, and people carry money. The only repeatable
        -- faucet in the game, and therefore the one held smallest.
        IF species.kind = 'rogue'
           AND random() < game_config_value('jade_rogue_chance') THEN
            purse := game_config_value('jade_rogue_purse');
            IF purse > 0 THEN
                PERFORM grant_jade(me.player_id, purse, 'rogue_purse');
                drop_list := drop_list || jsonb_build_object(
                    'code', 'spirit_jade', 'name', 'Spirit Jade',
                    'quantity', purse, 'emoji', '\U0001F49A', 'rarity', 'rare',
                    'note', 'off the body');
            END IF;
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

-- ---------------------------------------------------------------------------
-- breakthrough, from 0076_a_body_that_shores_up_its_weakest_pillar
-- ---------------------------------------------------------------------------
-- A fourth column of the kind 0045 started. The return type changes, so
-- this is a DROP and a CREATE.

DROP FUNCTION breakthrough(BIGINT);

CREATE FUNCTION breakthrough(p_player_id BIGINT)
RETURNS TABLE (
    realm_before     SMALLINT,
    realm_after      SMALLINT,
    name_before      TEXT,
    name_after       TEXT,
    rank_before      SMALLINT,
    rank_after       SMALLINT,
    stage_after      TEXT,
    cultivation      BIGINT,
    next_ceiling     BIGINT,
    qi_capacity      BIGINT,
    essence_capacity BIGINT,
    gu_capacity      SMALLINT,
    aperture_gained  SMALLINT,
    techniques_freed INTEGER,
    tempering_gained BIGINT,
    body_levels      SMALLINT,
    founded_stat     TEXT,
    founded_by       NUMERIC,
    jade_gained      BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult      player_cultivation%ROWTYPE;
    was       realms%ROWTYPE;
    becomes   realms%ROWTYPE;
    tempering BIGINT := 0;
    body_was  SMALLINT;
    body_now  SMALLINT;
    founding  NUMERIC := 0;
    weakest   TEXT;
    jade      BIGINT := 0;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    SELECT * INTO was FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    IF becomes.realm_id IS NULL THEN
        RAISE EXCEPTION 'there is nothing above % in this world', was.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF cult.cultivation < becomes.cultivation_required THEN
        RAISE EXCEPTION
            'you hold % of the % needed to break into %',
            cult.cultivation, becomes.cultivation_required, becomes.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.
    UPDATE player_cultivation pc
    SET realm_id = becomes.realm_id
    WHERE pc.player_id = p_player_id;

    -- A body that grows on the crossing itself. Measured in body levels
    -- because that is the currency the promise is written in - "foundation
    -- stats rise permanently" is what a body level IS.
    SELECT pp.body_level INTO body_was
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    tempering := round(player_stat(p_player_id, 'realm_tempering')
                       * game_config_value('physique_xp_per_level'));

    -- Whichever pillar is currently lowest, and only that one. Read BEFORE
    -- the grant, so a body does not measure itself against the growth it is
    -- about to receive.
    founding := player_stat(p_player_id, 'realm_foundation');
    IF founding > 0 THEN
        weakest := weakest_foundation(p_player_id);
        INSERT INTO player_foundation_bonuses (player_id, stat, bonus)
        VALUES (p_player_id, weakest, founding)
        ON CONFLICT (player_id, stat) DO UPDATE
            SET bonus = player_foundation_bonuses.bonus + EXCLUDED.bonus;
    END IF;

    -- The one faucet a player can plan around: twenty-six crossings, known
    -- in advance, and worth the same every time.
    jade := game_config_value('jade_per_realm');
    IF jade > 0 THEN
        PERFORM grant_jade(p_player_id, jade, 'breakthrough');
    END IF;

    -- Unconditional, and zero XP is a no-op that still recomputes: the
    -- founding above has to reach the stored stats before this function
    -- reports what the body became.
    PERFORM apply_physique_xp(p_player_id, tempering);

    SELECT pp.body_level INTO body_now
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    RETURN QUERY
    SELECT was.realm_id, becomes.realm_id,
           was.name, becomes.name,
           was.rank, becomes.rank, becomes.stage,
           cult.cultivation,
           (SELECT after.cultivation_required FROM realms after
            WHERE after.realm_id = becomes.realm_id + 1),
           becomes.qi_capacity, becomes.essence_capacity,
           becomes.gu_capacity,
           (becomes.gu_capacity - was.gu_capacity)::smallint,
           (SELECT count(*)::integer FROM techniques t
            WHERE t.created_by IS NULL
              AND t.rank > was.rank AND t.rank <= becomes.rank),
           tempering,
           COALESCE(body_now - body_was, 0)::smallint,
           weakest,
           founding,
           jade;
END;
$$;
