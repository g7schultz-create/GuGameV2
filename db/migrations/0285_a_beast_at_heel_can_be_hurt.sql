-- 0285_a_beast_at_heel_can_be_hurt
--
-- 0276 through 0278 gave the beast at heel a blow. What they did not give it
-- was a body: `player_beasts` has no health column, so nothing in the game
-- could hurt it, nothing could put it down, and the only thing it did was add
-- a number to its owner's swing. What was asked for was an entity that comes
-- into battle with you. What shipped was a stat with a name on it.
--
-- This gives it a body.
--
-- THE POOL, AND WHY IT IS CAPPED AGAINST ITS OWNER. A beast's health is built
-- the same way its attack is - the species it hatched from, lifted by its
-- tier, its shell and its stage. Left there it would be absurd, because a
-- beast's strength tracks the egg it came out of and its owner's tracks realm
-- and gear, and those two have nothing to do with each other. Measured
-- against the six cultivators actually walking one, an uncapped pool would
-- have given grafv's tier 8 baby 12.5 times his own body, luckymate0_0's 13
-- times, and pashu0's nearly 6. Three players would have become effectively
-- unkillable by holding an egg they got out of a chest.
--
-- So the pool is capped at `pet_hp_cap` of its owner's own maximum, which is
-- exactly the reasoning behind `pet_share_cap` on the damage side, applied to
-- the other half of the creature. Under the cap the beast's own tier, shell
-- and stage still decide it: clearwest's sits at 0.28 of their body and
-- visha's at 0.42, so raising either is still worth doing.
--
-- COVER IS A SHARE, NOT A COIN FLIP. Every blow that would land on you lands
-- `pet_cover_share` of itself on the beast instead. A share rather than a
-- chance because a coin flip that occasionally eats a whole blow is the sort
-- of thing that reads as the game cheating, and because a share is visible on
-- every single hit - which is the complaint that started this.
--
-- It is taken AFTER the cultivator's own mitigation, so armour and Damage
-- Reduction protect the beast too. The alternative - the beast eating a share
-- of the raw blow - makes gear worth less exactly when you are wearing the
-- most of it.
--
-- DOWN IS NOT DEAD. At zero the beast stops covering and stops swinging until
-- it recovers. Nothing takes it away. A pet that can be permanently lost to
-- one bad dungeon is a different game than this one, and not one anybody
-- asked for.
--
-- RECOVERY IS REST. The thing you already do when your own body is short, now
-- also mends what is walking beside you. And a beast that has just grown a
-- stage comes up whole, because the new body is the point of the stage.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('pet_hp_scale', 0.5,
     'What a beast''s body is worth against the species it hatched from, once '
     'tier, shell and stage are counted. The companion of pet_attack_scale.'),
    ('pet_hp_cap', 0.6,
     'The most of its owner''s own maximum health a beast''s body may be. The '
     'same guardrail as pet_share_cap and for the same reason: a deep egg in '
     'a shallow cultivator''s hands would otherwise fight the battle for '
     'them, and here it would survive it for them too.'),
    ('pet_cover_share', 0.30,
     'How much of every blow meant for you lands on the beast instead. Taken '
     'after your own mitigation, so armour shields the beast as well.'),
    ('pet_rest_heal', 0.35,
     'How much of a beast''s maximum a rest returns to it.');


-- NULL is whole. It means a beast never has to be backfilled when the cap
-- underneath it moves - and the cap moves every time its owner's body grows.
ALTER TABLE player_beasts ADD COLUMN hp BIGINT;

COMMENT ON COLUMN player_beasts.hp IS
    'Health remaining. NULL means whole, which is what a beast is until something hits it.';


CREATE FUNCTION pet_max_hp(p_beast_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- Built like pet_attack, then held against its owner's own body.
    SELECT GREATEST(1, round(LEAST(
        cs.base_hp
        * power(game_config_value('creature_defense_scale_per_rank'),
                GREATEST(0, b.tier - cs.rank))
        * (1 + game_config_value('pet_rarity_step')
               * (SELECT count(*) FROM rarities r2
                  WHERE r2.sort_order < r.sort_order))
        * st.power
        * game_config_value('pet_hp_scale'),
        COALESCE(pp.max_hp, 0) * game_config_value('pet_hp_cap')
    )))::bigint
    FROM player_beasts b
    JOIN creature_species cs ON cs.species_id = b.species_id
    JOIN rarities r ON r.code = b.rarity
    JOIN beast_stages st ON st.code = b.stage
    LEFT JOIN player_physique pp ON pp.player_id = b.owner_id
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION pet_max_hp(BIGINT) IS
    'A beast''s body: its species lifted by tier, shell and stage, capped against its owner''s own maximum.';


CREATE FUNCTION pet_hp(p_beast_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- Clamped on the way out rather than on the way in, because the ceiling
    -- moves under a stored number every time its owner's body does.
    SELECT GREATEST(0, LEAST(COALESCE(b.hp, pet_max_hp(b.beast_id)),
                             pet_max_hp(b.beast_id)))
    FROM player_beasts b WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION pet_hp(BIGINT) IS
    'Health a beast has right now. NULL storage means whole.';


CREATE FUNCTION pet_standing(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- The one at your heel, if it is still up. `pet_at_heel` keeps answering
    -- which beast you chose, because a downed beast is still your beast and
    -- every screen that names it still has to.
    SELECT b.beast_id FROM player_beasts b
    WHERE b.owner_id = p_player_id AND b.at_heel AND pet_hp(b.beast_id) > 0;
$$;

COMMENT ON FUNCTION pet_standing(BIGINT) IS
    'The beast at your heel, only while it is still on its feet.';


CREATE FUNCTION pet_hurt(p_beast_id BIGINT, p_damage BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    have BIGINT;
    took BIGINT;
BEGIN
    IF p_beast_id IS NULL OR COALESCE(p_damage, 0) <= 0 THEN
        RETURN 0;
    END IF;

    -- Lock it: two lanes can be hitting the same beast, and a beast that goes
    -- to -3 because two rounds resolved at once is a bug nobody would find.
    PERFORM 1 FROM player_beasts WHERE beast_id = p_beast_id FOR UPDATE;

    have := pet_hp(p_beast_id);
    took := LEAST(p_damage, have);

    IF took <= 0 THEN
        RETURN 0;
    END IF;

    UPDATE player_beasts SET hp = have - took WHERE beast_id = p_beast_id;
    RETURN took;
END;
$$;

COMMENT ON FUNCTION pet_hurt(BIGINT, BIGINT) IS
    'Lands damage on a beast and returns what it actually absorbed, which is never more than it had.';


CREATE FUNCTION pet_mend(p_beast_id BIGINT, p_amount BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    have BIGINT;
    top  BIGINT;
    got  BIGINT;
BEGIN
    IF p_beast_id IS NULL OR COALESCE(p_amount, 0) <= 0 THEN
        RETURN 0;
    END IF;

    PERFORM 1 FROM player_beasts WHERE beast_id = p_beast_id FOR UPDATE;

    have := pet_hp(p_beast_id);
    top  := pet_max_hp(p_beast_id);
    got  := LEAST(p_amount, GREATEST(0, top - have));

    IF got <= 0 THEN
        RETURN 0;
    END IF;

    -- Back to NULL when it is whole, so the stored number never has to be
    -- chased upward as the cap above it grows.
    UPDATE player_beasts
    SET hp = CASE WHEN have + got >= top THEN NULL ELSE have + got END
    WHERE beast_id = p_beast_id;

    RETURN got;
END;
$$;

COMMENT ON FUNCTION pet_mend(BIGINT, BIGINT) IS
    'Returns health to a beast, up to whole. Stores NULL once it is whole again.';


-- ---------------------------------------------------------------------------
-- A downed beast does not swing
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'player_swing';

    IF body IS NULL THEN
        RAISE EXCEPTION 'player_swing is missing';
    END IF;

    -- Lift and patch. The body of this function is the single choke point all
    -- five combat lanes swing through and it is not getting retyped here.
    IF (length(body) - length(replace(body, 'pet_at_heel(p_player_id)', '')))
       / length('pet_at_heel(p_player_id)') <> 1 THEN
        RAISE EXCEPTION 'expected exactly one pet_at_heel in player_swing';
    END IF;

    EXECUTE replace(body, 'pet_at_heel(p_player_id)', 'pet_standing(p_player_id)');
END;
$$;


-- ---------------------------------------------------------------------------
-- The blow is shared with whatever is standing in front of you
-- ---------------------------------------------------------------------------

DROP FUNCTION player_take(BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, BOOLEAN);

CREATE FUNCTION player_take(
    p_player_id BIGINT, p_raw BIGINT, p_hp BIGINT, p_max_hp BIGINT,
    p_guarding BOOLEAN DEFAULT FALSE, p_may_ward BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (taken BIGINT, dodged BOOLEAN, warded BOOLEAN, reduced NUMERIC,
               covered BIGINT, pet_name TEXT, pet_down BOOLEAN)
LANGUAGE plpgsql
AS $$
DECLARE
    evade  NUMERIC;
    reduce NUMERIC;
    dmg    BIGINT;
    miss   BOOLEAN := FALSE;
    ward   BOOLEAN := FALSE;
    beast  BIGINT;
    share  BIGINT;
    soaked BIGINT := 0;
    pet_nm TEXT;
    fell   BOOLEAN := FALSE;
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

    -- ---- and the beast standing in front of it ----------------------------
    -- After your own mitigation, so what the beast eats is a share of what
    -- would really have hit you rather than a share of the raw swing.
    beast := pet_standing(p_player_id);
    IF beast IS NOT NULL AND dmg > 0 THEN
        share  := LEAST(dmg, GREATEST(1,
                    floor(dmg * game_config_value('pet_cover_share'))))::bigint;
        soaked := pet_hurt(beast, share);
        IF soaked > 0 THEN
            dmg  := GREATEST(0, dmg - soaked);
            fell := pet_hp(beast) <= 0;
            SELECT b.name INTO pet_nm FROM player_beasts b
            WHERE b.beast_id = beast;
        END IF;
    END IF;

    -- A killing blow lands where the body has already stopped being. Once a
    -- fight, which is why the caller has to say whether it is still owed.
    -- Measured on what reaches the cultivator, so a blow the beast turned
    -- into a survivable one never spends the ward.
    IF p_may_ward AND p_hp IS NOT NULL AND dmg >= p_hp AND p_hp > 0
       AND random() < player_stat(p_player_id, 'death_ward') THEN
        dmg  := p_hp - 1;
        ward := TRUE;
    END IF;

    RETURN QUERY SELECT dmg, miss, ward, reduce, soaked, pet_nm, fell;
END;
$$;

COMMENT ON FUNCTION player_take(BIGINT, BIGINT, BIGINT, BIGINT, BOOLEAN, BOOLEAN) IS
    'Everything that happens to a body being hit: evasion, guard, reduction, the beast that takes a share, and the ward on what is left.';


-- ---------------------------------------------------------------------------
-- A rest mends what is walking beside you
-- ---------------------------------------------------------------------------

DROP FUNCTION rest(BIGINT);

CREATE FUNCTION rest(p_player_id BIGINT)
RETURNS TABLE (healed BIGINT, offered BIGINT, current_hp BIGINT, max_hp BIGINT,
               full_up BOOLEAN, pet_healed BIGINT, pet_hp BIGINT,
               pet_max_hp BIGINT, pet_name TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    body   player_physique%ROWTYPE;
    lo     NUMERIC := game_config_value('rest_heal_min_pct');
    hi     NUMERIC := game_config_value('rest_heal_max_pct');
    gift   BIGINT;
    before BIGINT;
    after  BIGINT;
    beast  BIGINT;
    p_got  BIGINT := 0;
    p_now  BIGINT;
    p_top  BIGINT;
    p_name TEXT;
BEGIN
    SELECT * INTO body FROM player_physique
    WHERE player_id = p_player_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no body to rest', p_player_id;
    END IF;

    -- The beast first, and outside the full-body early return: a cultivator
    -- at full health with a beast on the floor still came here to rest, and
    -- sending them away with nothing is how the beast never gets up.
    beast := pet_at_heel(p_player_id);
    IF beast IS NOT NULL THEN
        p_top := pet_max_hp(beast);
        p_got := pet_mend(beast,
                    GREATEST(1, round(p_top * game_config_value('pet_rest_heal')))::bigint);
        p_now := pet_hp(beast);
        SELECT b.name INTO p_name FROM player_beasts b WHERE b.beast_id = beast;
    END IF;

    IF body.current_hp >= body.max_hp THEN
        RETURN QUERY SELECT 0::bigint, 0::bigint, body.current_hp, body.max_hp,
                            TRUE, p_got, p_now, p_top, p_name;
        RETURN;
    END IF;

    before := body.current_hp;
    gift   := GREATEST(1, round(body.max_hp * (lo + random() * (hi - lo))));

    UPDATE player_physique pp
    SET current_hp = LEAST(pp.max_hp, pp.current_hp + gift)
    WHERE pp.player_id = p_player_id
    RETURNING pp.current_hp INTO after;

    -- What it BANKED, not what it offered: the body's cap is why those differ.
    RETURN QUERY SELECT after - before, gift, after, body.max_hp,
                        after >= body.max_hp, p_got, p_now, p_top, p_name;
END;
$$;

COMMENT ON FUNCTION rest(BIGINT) IS
    'Returns health to a cultivator and to the beast at their heel.';


-- ---------------------------------------------------------------------------
-- A beast that grows a stage comes up whole
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'beast_grow';

    IF body IS NULL THEN
        RAISE EXCEPTION 'beast_grow is missing';
    END IF;

    IF (length(body) - length(replace(body, '    RETURN grown;', '')))
       / length('    RETURN grown;') <> 1 THEN
        RAISE EXCEPTION 'expected exactly one RETURN grown in beast_grow';
    END IF;

    EXECUTE replace(body, '    RETURN grown;',
        '    -- The new body is the whole point of the stage.' || chr(10) ||
        '    IF grown IS NOT NULL THEN' || chr(10) ||
        '        UPDATE player_beasts SET hp = NULL WHERE beast_id = p_beast_id;' || chr(10) ||
        '    END IF;' || chr(10) || chr(10) ||
        '    RETURN grown;');
END;
$$;


-- ---------------------------------------------------------------------------
-- Every beast has a body, and the cap binds where it was meant to
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    r      RECORD;
    capped INTEGER := 0;
BEGIN
    FOR r IN
        SELECT b.beast_id, b.name, b.tier, pet_max_hp(b.beast_id) AS top,
               pp.max_hp AS body
        FROM player_beasts b
        JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
        LEFT JOIN player_physique pp ON pp.player_id = b.owner_id
    LOOP
        IF r.top IS NULL OR r.top < 1 THEN
            RAISE EXCEPTION 'beast % (%) has no body at all', r.beast_id, r.name;
        END IF;

        -- Nothing may exceed the cap, and floating point is not an excuse.
        IF r.body IS NOT NULL AND r.top >
           ceil(r.body * game_config_value('pet_hp_cap')) THEN
            RAISE EXCEPTION
                'beast % has % health against an owner with % - the cap did not hold',
                r.beast_id, r.top, r.body;
        END IF;

        IF r.body IS NOT NULL
           AND r.top >= floor(r.body * game_config_value('pet_hp_cap')) THEN
            capped := capped + 1;
        END IF;
    END LOOP;

    RAISE NOTICE '% beasts sit at their owner''s cap', capped;
END;
$$;


-- ---------------------------------------------------------------------------
-- It covers, it goes down, it stops swinging, and a rest brings it back
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    beast BIGINT;
    top   BIGINT;
    sp    BIGINT;
    took  RECORD;
    swung RECORD;
    move  BIGINT;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    WHERE b.at_heel
    ORDER BY b.tier DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        top := pet_max_hp(beast);
        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

        IF pet_hp(beast) <> top THEN
            RAISE EXCEPTION 'a beast that has never been hit is not whole';
        END IF;

        -- It takes a share of the blow, and the cultivator takes less.
        SELECT * INTO took FROM player_take(who, top, 1000000000::bigint,
                                            1000000000::bigint, FALSE, FALSE);
        IF took.covered <= 0 THEN
            RAISE EXCEPTION 'the beast covered nothing';
        END IF;
        IF pet_hp(beast) >= top THEN
            RAISE EXCEPTION 'the beast covered a blow and is somehow untouched';
        END IF;
        IF took.pet_name IS NULL THEN
            RAISE EXCEPTION 'the beast covered a blow without being named';
        END IF;

        -- Put it on the floor.
        UPDATE player_beasts SET hp = 0 WHERE beast_id = beast;

        IF pet_standing(who) IS NOT NULL THEN
            RAISE EXCEPTION 'a beast on nought is still standing';
        END IF;
        IF pet_at_heel(who) IS NULL THEN
            RAISE EXCEPTION 'a downed beast stopped being yours';
        END IF;

        -- Down, it neither covers nor swings.
        SELECT * INTO took FROM player_take(who, 1000000::bigint,
                                            1000000000::bigint,
                                            1000000000::bigint, FALSE, FALSE);
        IF took.covered <> 0 THEN
            RAISE EXCEPTION 'a downed beast covered a blow';
        END IF;

        SELECT technique_id INTO move FROM player_techniques
        WHERE player_id = who LIMIT 1;
        IF move IS NOT NULL THEN
            SELECT * INTO swung FROM player_swing(who, move, sp,
                                                  5000000000::bigint, 0::bigint);
            IF COALESCE(swung.pet_dealt, 0) <> 0 THEN
                RAISE EXCEPTION 'a downed beast swung for %', swung.pet_dealt;
            END IF;
        END IF;

        -- And a rest puts it back on its feet.
        PERFORM rest(who);
        IF pet_hp(beast) <= 0 THEN
            RAISE EXCEPTION 'a rest left the beast on the floor';
        END IF;
        IF pet_standing(who) IS NULL THEN
            RAISE EXCEPTION 'a rested beast is still not standing';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- ---------------------------------------------------------------------------
-- Nobody's body moved
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    beasts INTEGER;
    heels  INTEGER;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE at_heel) INTO beasts, heels
    FROM player_beasts;

    IF EXISTS (SELECT 1 FROM player_beasts WHERE hp IS NOT NULL) THEN
        RAISE EXCEPTION 'a beast is carrying a wound it was never given';
    END IF;

    IF heels <> (SELECT count(DISTINCT owner_id) FROM player_beasts) THEN
        RAISE EXCEPTION 'somebody lost the beast that walks with them';
    END IF;

    RAISE NOTICE '% beasts have a body, % of them walking', beasts, heels;
END;
$$;
