-- 0243_one_body_takes_every_blow
--
-- Damage Reduction does nothing in a dungeon. Neither does Evasion, nor
-- Braced, nor Death Ward.
--
-- 0225 found six offensive axes read in exactly one place - `battle_act` - and
-- gave the game one swing. It fixed the half of the problem that was about
-- hitting. The half about BEING hit was left exactly as it was, and it is the
-- same shape: `dodge`, `damage_reduction`, `braced` and `death_ward` are read
-- by the duel and by nothing else. A dungeon boss and a gauntlet beast take a
-- raw number off your health and your entire defensive kit is a decoration.
--
-- A cultivator who spent a fortune on Damage Reduction gear is right to ask
-- why raising its cap would help. The cap was never the constraint.
--
-- SO THE BLOW IS ONE FUNCTION NOW. `player_take` is what happens when
-- something hits a cultivator - the dodge roll, the reduction stack, the guard,
-- the ward - and `battle_act`, `dungeon_resolve_round` and `horde_gauntlet_swing`
-- all call it. `player_swing` and `player_take` are the two halves of a blow,
-- and a seventh axis on either side is now one edit.
--
-- THE WARD NEEDS SOMEWHERE TO REMEMBER. Death Ward fires once a fight, which
-- the duel keeps on `battle_combatants.ward_used`. A dungeon raider and a
-- gauntlet run had nowhere to write it, so they get a column each - the
-- alternative is a ward that fires on every blow, which is not the effect the
-- Gu describes.
--
-- The shield stays in the duel. It is granted at the door out of
-- `battle_shield_for` and spent across a fight, and neither of the other two
-- has a pool to spend - that is a thing to give them deliberately rather than
-- by dragging it along with this.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE dungeon_raiders  ADD COLUMN ward_used BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE horde_gauntlets  ADD COLUMN ward_used BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN dungeon_raiders.ward_used IS
    'Death Ward fires once a fight. Without somewhere to remember that, it either never fires here or fires on every blow.';


-- ---------------------------------------------------------------------------
-- One blow, landing on one body
-- ---------------------------------------------------------------------------

CREATE FUNCTION player_take(
    p_player_id BIGINT,
    p_raw       BIGINT,
    p_hp        BIGINT,
    p_max_hp    BIGINT,
    p_guarding  BOOLEAN DEFAULT FALSE,
    p_may_ward  BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    taken   BIGINT,
    dodged  BOOLEAN,
    warded  BOOLEAN,
    reduced NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    evade  NUMERIC;
    reduce NUMERIC;
    dmg    BIGINT;
    miss   BOOLEAN := FALSE;
    ward   BOOLEAN := FALSE;
BEGIN
    dmg    := GREATEST(0, COALESCE(p_raw, 0));
    evade  := player_stat(p_player_id, 'dodge');
    reduce := player_stat(p_player_id, 'damage_reduction');

    -- Some bodies are hardest to hurt while they are still mostly whole.
    IF p_hp IS NOT NULL AND p_max_hp IS NOT NULL AND p_max_hp > 0
       AND p_hp * 100 >= p_max_hp * game_config_value('braced_hp_threshold') THEN
        reduce := reduce + player_stat(p_player_id, 'braced');
    END IF;
    reduce := LEAST(game_config_value('damage_reduction_ceiling'), reduce);

    IF random() < evade THEN
        miss := TRUE;
        dmg  := 0;
    ELSE
        -- Multiplicative with Guard, per the design's guardrail: two halvings
        -- must not add up to taking nothing.
        IF p_guarding THEN
            dmg := floor(dmg * (1 - game_config_value('guard_damage_reduction')));
        END IF;
        IF reduce > 0 THEN
            dmg := floor(dmg * (1 - reduce));
        END IF;
        dmg := GREATEST(0, dmg);
    END IF;

    -- A killing blow lands where the body has already stopped being. Once a
    -- fight, which is why the caller has to say whether it is still owed.
    IF p_may_ward AND p_hp IS NOT NULL AND dmg >= p_hp AND p_hp > 0
       AND random() < player_stat(p_player_id, 'death_ward') THEN
        dmg  := p_hp - 1;
        ward := TRUE;
    END IF;

    RETURN QUERY SELECT dmg, miss, ward, reduce;
END;
$$;

COMMENT ON FUNCTION player_take(BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, BOOLEAN) IS
    'Everything that happens to a cultivator being hit: the dodge, the reduction stack, the guard, the ward. The other half of `player_swing`, and the only place these four axes are read.';


-- ---------------------------------------------------------------------------
-- The duel reads it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'battle_act';

    old := '    guarded := (p_action = ''guard'');
    evade   := player_stat(me.player_id, ''dodge'');
    reduce  := player_stat(me.player_id, ''damage_reduction'');

    -- Some bodies are hardest to hurt while they are still mostly whole.
    IF p_hp * 100 >= me.max_hp * game_config_value(''braced_hp_threshold'') THEN
        reduce := reduce + player_stat(me.player_id, ''braced'');
    END IF;
    reduce := LEAST(game_config_value(''damage_reduction_ceiling''), reduce);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer stacks its defences the old way';
    END IF;
    src := replace(src, old, '    guarded := (p_action = ''guard'');');

    old := '    dmg_in := CASE WHEN hushed THEN 0 ELSE hit.final_damage END;

    IF random() < evade THEN
        was_dodged := TRUE;
        dmg_in := 0;
        said := trim(both '' '' FROM said || '' You are not where the blow goes.'');
    ELSE
        -- Multiplicative with Guard, per the design''s guardrail: two halvings
        -- must not add up to taking nothing.
        IF guarded THEN
            dmg_in := floor(dmg_in * (1 - game_config_value(''guard_damage_reduction'')));
        END IF;
        IF reduce > 0 THEN
            dmg_in := floor(dmg_in * (1 - reduce));
        END IF;
        dmg_in := GREATEST(0, dmg_in);
    END IF;

    -- A killing blow lands where the body has already stopped being. Once,
    -- and the fight remembers that it was spent.
    IF dmg_in >= p_hp AND p_hp > 0 AND NOT me.ward_used
       AND random() < player_stat(me.player_id, ''death_ward'') THEN
        dmg_in := p_hp - 1;
        warded := TRUE;
        said   := trim(both '' '' FROM said ||
                       '' The blow lands where you have already stopped being.'');
    END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer applies a blow the old way';
    END IF;

    src := replace(src, old,
'    -- Everything that happens to a body being hit now lives in `player_take`,
    -- so the dungeon and the gauntlet get the same four axes this does. What
    -- is left here is the duel''s own business: the log and the shield.
    SELECT * INTO took FROM player_take(
        me.player_id,
        CASE WHEN hushed THEN 0 ELSE hit.final_damage END,
        p_hp, me.max_hp, guarded, NOT me.ward_used);

    dmg_in     := took.taken;
    was_dodged := took.dodged;
    warded     := took.warded;
    reduce     := took.reduced;

    IF was_dodged THEN
        said := trim(both '' '' FROM said || '' You are not where the blow goes.'');
    END IF;
    IF warded THEN
        said := trim(both '' '' FROM said ||
                     '' The blow lands where you have already stopped being.'');
    END IF;');

    -- One more declaration for the record it now reads.
    old := '    was_dodged BOOLEAN := FALSE;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act no longer declares was_dodged';
    END IF;
    src := replace(src, old, '    was_dodged BOOLEAN := FALSE;
    took       RECORD;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- And so does a dungeon round
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round';

    old := '            taken := GREATEST(0, hit.final_damage);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer takes a blow the old way';
    END IF;

    src := replace(src, old,
'            -- The raider''s own defences, which this room ignored entirely
            -- until 0243. A boss took a raw number off a body that had paid
            -- for Damage Reduction, Evasion and a Death Ward.
            SELECT * INTO took FROM player_take(
                target, hit.final_damage,
                (SELECT x.current_hp FROM dungeon_raiders x
                 WHERE x.run_id = p_run_id AND x.player_id = target),
                (SELECT x.max_hp FROM dungeon_raiders x
                 WHERE x.run_id = p_run_id AND x.player_id = target),
                FALSE,
                NOT (SELECT x.ward_used FROM dungeon_raiders x
                     WHERE x.run_id = p_run_id AND x.player_id = target));

            taken := took.taken;

            IF took.warded THEN
                UPDATE dungeon_raiders x SET ward_used = TRUE
                WHERE x.run_id = p_run_id AND x.player_id = target;
            END IF;');

    old := '    hit     RECORD;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer declares its hit';
    END IF;
    src := replace(src, old, '    hit     RECORD;
    took    RECORD;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- And so does a wave on the line
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_gauntlet_swing';

    old := '        hurt := GREATEST(0, bit.final_damage);
        IF brace THEN
            hurt := GREATEST(0,
                floor(hurt * (1 - game_config_value(''guard_damage_reduction''))));
        END IF;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_swing no longer takes a blow the old way';
    END IF;

    src := replace(src, old,
'        -- The guard was the only defence this lane knew about. Everything
        -- else a cultivator wears applies here now too.
        SELECT * INTO took FROM player_take(
            run.player_id, bit.final_damage, body, run.max_hp,
            brace, NOT run.ward_used);

        hurt := took.taken;

        IF took.warded THEN
            UPDATE horde_gauntlets SET ward_used = TRUE
            WHERE gauntlet_id = p_gauntlet_id;
        END IF;');

    old := '    bit       RECORD;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_gauntlet_swing no longer declares its bite';
    END IF;
    src := replace(src, old, '    bit       RECORD;
    took      RECORD;');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- Now the caps mean something, so they can be raised
-- ---------------------------------------------------------------------------
-- Damage Reduction binds today: equipment alone reaches 1.20 across the slots
-- against a cap of 0.50. Extra Strikes does not bind at any aperture on this
-- server - the largest is 10, which fits one Gu - so raising it is a ceiling
-- for a cultivator nobody has grown into yet rather than a change anybody will
-- feel this week. The combined stack is still clamped by
-- `damage_reduction_ceiling`, so no blow becomes nothing.

UPDATE gu_effects SET cap = 0.7500 WHERE code = 'damage_reduction';
UPDATE gu_effects SET cap = 3.0000 WHERE code = 'multi_hit';


DO $$
DECLARE
    readers TEXT;
BEGIN
    -- The four axes may be read in one place and nowhere else.
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO readers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.prosrc LIKE '%''dodge''%' OR p.prosrc LIKE '%''braced''%'
           OR p.prosrc LIKE '%''death_ward''%');

    IF readers <> 'player_take' THEN
        RAISE EXCEPTION 'the defences are read by %, not by player_take alone', readers;
    END IF;

    -- And every fight that can hurt a cultivator has to go through it.
    FOR readers IN
        SELECT unnest(ARRAY['battle_act', 'dungeon_resolve_round',
                            'horde_gauntlet_swing'])
    LOOP
        IF position('player_take(' IN
                    (SELECT prosrc FROM pg_proc WHERE proname = readers)) = 0 THEN
            RAISE EXCEPTION '% still takes a blow on its own', readers;
        END IF;
    END LOOP;

    -- A reduction that reached 1 would make a blow nothing at all.
    IF game_config_value('damage_reduction_ceiling') >= 1 THEN
        RAISE EXCEPTION 'the reduction ceiling no longer leaves a blow anything';
    END IF;
END;
$$;
