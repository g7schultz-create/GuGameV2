-- 0301_the_hunt_carries_what_a_technique_left_on_you
--
-- The first lane. `battle_act` tells the choke points which fight this is, so
-- anything standing on the cultivator is worth something; spends a round off
-- everything at the top of each action; lets `regen` mend; and drops the lot
-- when the fight ends.
--
-- THE TICK GOES AT THE TOP OF AN ACTION, NOT THE BOTTOM. `battle_act` returns
-- from four different places, so the bottom is four bottoms and the one that
-- got missed would be a buff that never expired. The top is one line, and it
-- gives the arithmetic people expect: a three-turn guard raised on turn five
-- covers five, six and seven, because turn five has already had its tick.
--
-- CLEARING GOES IN `battle_conclude`, FOR THE SAME REASON. Three of those
-- four returns conclude the fight and each calls it; putting the clear inside
-- it means a fight cannot end without dropping what it was carrying, however
-- it ended - won, fled, or expired out from under everybody.
--
-- REGEN IS APPLIED BEFORE THE ACTION RESOLVES, so the health it returns is
-- health you have while the creature swings back. A mend that arrived after
-- the blow would be worth nothing on the turn you most needed it.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    body  TEXT;
    start TEXT :=
'    p_hp := me.current_hp;
    c_hp := it.current_hp;';
    swing TEXT :=
'            me.player_id, p_technique_id, it.species_id,
            c_hp, (it.snapshot ->> ''base_defense'')::bigint,
            p_hp, me.max_hp, fight.turn_number);';
    take  TEXT :=
'        p_hp, me.max_hp, guarded, NOT me.ward_used);';
    mend  NUMERIC;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'battle_act';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    IF (length(body) - length(replace(body, start, ''))) / length(start) <> 1 THEN
        RAISE EXCEPTION 'the top of the round is not where it was';
    END IF;
    IF (length(body) - length(replace(body, swing, ''))) / length(swing) <> 1 THEN
        RAISE EXCEPTION 'the swing call is not where it was';
    END IF;
    IF (length(body) - length(replace(body, take, ''))) / length(take) <> 1 THEN
        RAISE EXCEPTION 'the take call is not where it was';
    END IF;

    -- One round of everything standing, spent before anything is read.
    body := replace(body, start,
'    -- A round has passed since the last action, so spend it off anything
    -- lasting before this action reads any of it. At the top because this
    -- function returns from four places and the bottom is four bottoms.
    PERFORM effect_tick(''battle'', p_battle_id);

    p_hp := me.current_hp;
    c_hp := it.current_hp;

    -- Mending, before the action resolves: health that arrives after the
    -- creature has swung is worth nothing on the turn it was needed.
    IF effect_value(''battle'', p_battle_id, me.player_id, ''regen'') > 0 THEN
        p_hp := LEAST(me.max_hp, p_hp + GREATEST(1, floor(me.max_hp
                * effect_value(''battle'', p_battle_id, me.player_id, ''regen''))))::bigint;
        UPDATE battle_combatants bc SET current_hp = p_hp
        WHERE bc.battle_id = p_battle_id AND bc.combatant_no = 0;
    END IF;');

    body := replace(body, swing,
'            me.player_id, p_technique_id, it.species_id,
            c_hp, (it.snapshot ->> ''base_defense'')::bigint,
            p_hp, me.max_hp, fight.turn_number, ''battle'', p_battle_id);');

    body := replace(body, take,
'        p_hp, me.max_hp, guarded, NOT me.ward_used, ''battle'', p_battle_id);');

    DROP FUNCTION battle_act(BIGINT, TEXT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- A fight that ends drops what it was carrying, however it ended
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body   TEXT;
    anchor TEXT := 'BEGIN
    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'battle_conclude';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_conclude is missing';
    END IF;
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the top of battle_conclude is not where it was';
    END IF;

    body := replace(body, anchor,
'BEGIN
    -- Won, fled or expired: whichever way this fight ended, nothing it was
    -- carrying survives it.
    PERFORM effect_clear(''battle'', p_battle_id);

    SELECT * INTO me FROM battle_combatants
    WHERE battle_id = p_battle_id AND combatant_no = 0;');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The lane says which fight it is, in both directions
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
BEGIN
    SELECT prosrc INTO src FROM pg_proc WHERE proname = 'battle_act';

    IF src NOT LIKE '%fight.turn_number, ''battle'', p_battle_id)%' THEN
        RAISE EXCEPTION 'the hunt does not tell player_swing which fight it is';
    END IF;
    IF src NOT LIKE '%NOT me.ward_used, ''battle'', p_battle_id)%' THEN
        RAISE EXCEPTION 'the hunt does not tell player_take which fight it is';
    END IF;
    IF src NOT LIKE '%effect_tick(''battle'', p_battle_id)%' THEN
        RAISE EXCEPTION 'the hunt never spends a round off anything';
    END IF;

    IF (SELECT prosrc FROM pg_proc WHERE proname = 'battle_conclude')
       NOT LIKE '%effect_clear(''battle'', p_battle_id)%' THEN
        RAISE EXCEPTION 'a finished hunt keeps what it was carrying';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A ward raised in a hunt is worth something, expires, and does not outlive
-- the fight
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    sp    BIGINT;
    b_id  BIGINT;
    move  BIGINT;
    got   RECORD;
    left1 SMALLINT;
BEGIN
    SELECT p.player_id, dungeon_default_move(p.player_id) INTO who, move
    FROM players p
    WHERE p.deleted_at IS NULL AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can swing; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE battles SET status = 'expired', ended_at = now()
        WHERE status = 'active'
          AND battle_id IN (SELECT battle_id FROM battle_combatants
                            WHERE player_id = who);

        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;
        b_id := battle_open(who, sp);

        -- A target that outlasts the swing, so the fight runs more than a turn.
        UPDATE battle_combatants
        SET current_hp = 9223372036854775807 / 4,
            max_hp     = 9223372036854775807 / 4
        WHERE battle_id = b_id AND combatant_no = 1;

        -- Three rounds of ward, then spend two of them.
        PERFORM effect_apply('battle', b_id, who, 'defence_up', 0.30, 3);
        SELECT * INTO got FROM battle_act(b_id, 'attack', move);

        SELECT turns_left INTO left1 FROM battle_effects
        WHERE scope = 'battle' AND scope_id = b_id AND effect_code = 'defence_up';
        IF left1 IS NULL THEN
            RAISE EXCEPTION 'the ward was gone after one round';
        END IF;
        IF left1 <> 2 THEN
            RAISE EXCEPTION 'a three round ward had % left after one', left1;
        END IF;

        -- And concluding the fight takes it away.
        PERFORM battle_conclude(b_id, 'expired');
        IF EXISTS (SELECT 1 FROM battle_effects
                   WHERE scope = 'battle' AND scope_id = b_id) THEN
            RAISE EXCEPTION 'the ward outlived the fight';
        END IF;

        RAISE NOTICE 'a hunt carried a ward for its three rounds and dropped it';

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
