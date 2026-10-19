-- 0044_breakthrough
--
-- Two things: a kill says what it gave you, and a realm has to be taken.
--
-- THE BOTTLENECK. 0009 wrote it down plainly - "a breakthrough is a side
-- effect of the total crossing a threshold rather than an action the player
-- takes" - and that is now the wrong design. A realm should be crossed on
-- purpose, because a tribulation is coming to stand in the way of it, and a
-- tribulation cannot interrupt something that has already happened by the time
-- anybody looked.
--
-- So cultivation now FILLS AND STOPS. `apply_cultivation_xp` clamps the total
-- at the next realm's requirement, and `realm_id` moves in exactly one place:
-- `breakthrough()`. Time spent at a full bar buys nothing, which is what a
-- bottleneck is, and what makes the command worth pressing.
--
-- THIS RETIRES AN INVARIANT, deliberately. `realm_for_cultivation` was "the
-- definition of player_cultivation.realm_id" and is not any more: between
-- filling the bar and breaking through, the stored realm is one behind what
-- the total would derive. The clamp is what bounds that gap to one - a player
-- can never be two realms behind their own cultivation - and the function
-- stays because it is still the right answer to "what is this total worth".
--
-- WHERE THE TRIBULATION GOES. `breakthrough()` returns a row rather than void,
-- and the realm changes at one statement inside it. A tribulation is a check
-- before that statement and an outcome column on the way out; nothing that
-- calls this has to move.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A corpse says what it gave you
-- ---------------------------------------------------------------------------
-- The drop list already carried a name and a count. `materials` has had a
-- rarity since 0017 and a face since 0042, and the card was reading neither -
-- so a fang and a dragon scale arrived looking identical.

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
    -- disagree by the time this runs. See 0032.
    UPDATE player_physique pp
    SET current_hp = LEAST(me.current_hp, pp.max_hp)
    WHERE pp.player_id = me.player_id;

    DELETE FROM player_active_battle WHERE battle_id = p_battle_id;

    IF victory THEN
        UPDATE player_bestiary
        SET times_defeated = times_defeated + 1
        WHERE player_id = me.player_id AND species_id = it.species_id;

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
-- The ceiling
-- ---------------------------------------------------------------------------

CREATE FUNCTION cultivation_ceiling(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT next.cultivation_required
    FROM player_cultivation pc
    JOIN realms next ON next.realm_id = pc.realm_id + 1
    WHERE pc.player_id = p_player_id;
$$;

COMMENT ON FUNCTION cultivation_ceiling(BIGINT) IS
    'What this cultivator can hold before a breakthrough. NULL at the top of the ladder, where nothing is held back.';

CREATE FUNCTION ready_to_break_through(p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT pc.cultivation >= cultivation_ceiling(p_player_id)
         FROM player_cultivation pc WHERE pc.player_id = p_player_id),
        FALSE
    );
$$;


-- ---------------------------------------------------------------------------
-- apply_cultivation_xp, which no longer promotes anybody
-- ---------------------------------------------------------------------------
-- Still returns the realm, and every caller still reads it as "the realm
-- afterwards" - it is simply now always the realm before as well.

CREATE OR REPLACE FUNCTION apply_cultivation_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    ceiling BIGINT := cultivation_ceiling(p_player_id);
    realm   SMALLINT;
BEGIN
    UPDATE player_cultivation pc
    SET cultivation = CASE
            WHEN ceiling IS NULL THEN pc.cultivation + p_xp
            -- GREATEST guards the case where a total is somehow already past
            -- its own ceiling: a clamp must never take cultivation away.
            ELSE GREATEST(pc.cultivation, LEAST(pc.cultivation + p_xp, ceiling))
        END
    WHERE pc.player_id = p_player_id
    RETURNING pc.realm_id INTO realm;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    RETURN realm;
END;
$$;

COMMENT ON FUNCTION apply_cultivation_xp(BIGINT, BIGINT) IS
    'Adds cultivation, up to the next realm''s requirement and no further. The realm itself moves only in breakthrough().';


-- ---------------------------------------------------------------------------
-- breakthrough
-- ---------------------------------------------------------------------------
-- One realm, taken on purpose.
--
-- It returns what the new realm is worth rather than just the number, because
-- a command whose whole output is "you are now realm 4" reads as a formality.
-- The caps and the aperture were always a function of realm_id; this is the
-- first screen that has cause to say so.

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
    techniques_freed INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult    player_cultivation%ROWTYPE;
    was     realms%ROWTYPE;
    becomes realms%ROWTYPE;
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
              AND t.rank > was.rank AND t.rank <= becomes.rank);
END;
$$;

COMMENT ON FUNCTION breakthrough(BIGINT) IS
    'Takes the next realm. The only thing that moves realm_id - which is what leaves room for a tribulation to stand in the way of it.';
