-- 0140_striking_it_and_being_paid_for_it
--
-- The two verbs 0139's tables were built for.
--
-- A STRIKE runs `compute_technique_damage` - the same pipeline a hunt runs, so
-- attainment, matchup, Gu, equipment and physique all count, and a Fire
-- cultivator swinging at something that shrugs off Fire finds out the same way
-- they would anywhere else. The beast answers with `compute_creature_damage`,
-- against the striker's real HP, so a strike is a risk and /rest is the thing
-- that buys another one.
--
-- WITH NO DEFENSE, AND THAT IS DELIBERATE. `boss_hp_pool` sizes the beast from
-- the roster's raw technique power. Applying the species' own defense on top -
-- 1,800 on the Leviathan, against a formula of raw x scale / (scale + defense)
-- - would turn a 320-power strike into about seventeen points and make the HP
-- the screen shows a lie about how many blows it takes. The pool IS the
-- difficulty here, and it is the number a player can see and plan against.
-- Matchup, attainment, Gu and gear all still count, so what you bring still
-- decides what you do.
--
-- THE PICK IS BY WHAT ACTUALLY LANDS. A world beast can be outright immune to
-- a Path. Choosing the strongest technique by base power would hand somebody
-- their best move against something that ignores it, spend the strike, and
-- report nothing - so the pick asks the damage pipeline about each candidate
-- and takes the one that does the most.
--
-- A SHARE is of damage actually dealt, not of the pool. A beast that escapes
-- still owes everyone who bled for it, at half rate; the shares still sum to
-- one, because the divisor is what was dealt rather than what was needed.
--
-- The drop table is the beast's own, from `creature_drops`. Chance is weighted
-- by contribution and floored, so somebody who landed two strikes has a real
-- if slim chance at Dragon Whale Bone and somebody who landed none has none:
--
--     chance x (0.35 + 0.65 x share), clamped to the table's own chance
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- strike_boss
-- ---------------------------------------------------------------------------

CREATE FUNCTION strike_boss(
    p_player_id    BIGINT,
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    encounter_id  BIGINT,
    beast_name    TEXT,
    technique     TEXT,
    dealt         BIGINT,
    taken         BIGINT,
    matchup       NUMERIC,
    boss_hp       BIGINT,
    boss_max_hp   BIGINT,
    my_hp         BIGINT,
    my_max_hp     BIGINT,
    strikes_left  INTEGER,
    slain         BOOLEAN,
    my_damage     BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    live     RECORD;
    body     RECORD;
    move     BIGINT;
    move_name TEXT;
    hit      RECORD;
    back     BIGINT;
    spent    INTEGER;
    allowed  INTEGER := game_config_value('boss_strikes_each')::integer;
    left_hp  BIGINT;
    killed   BOOLEAN := FALSE;
    mine     BIGINT;
BEGIN
    PERFORM boss_open_if_due();

    SELECT e.encounter_id, e.species_id, e.current_hp, e.max_hp,
           cs.name, cs.base_defense
    INTO live
    FROM boss_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE e.status = 'open'
    -- The row is about to be written to and two strikes landing at once must
    -- not both read the same HP. Everything after this is serialised per beast.
    FOR UPDATE OF e;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'nothing is standing. **/boss** to see when the next one comes'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(bs.strikes, 0) INTO spent
    FROM (SELECT 1) _ LEFT JOIN boss_strikes bs
      ON bs.encounter_id = live.encounter_id AND bs.player_id = p_player_id;

    IF spent >= allowed THEN
        RAISE EXCEPTION 'you have spent all % of your strikes on this one', allowed
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT pp.current_hp, pp.max_hp INTO body
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    IF body IS NULL OR body.current_hp <= 0 THEN
        RAISE EXCEPTION 'you have nothing left to swing with - **/rest**'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Whichever of their moves actually lands hardest on THIS beast, asked of
    -- the damage pipeline rather than guessed from base power. A named
    -- technique is honoured as given; the player asked for it.
    SELECT t.technique_id, t.name INTO move, move_name
    FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    LEFT JOIN player_loadout l
           ON l.player_id = u.player_id AND l.technique_id = u.technique_id
    CROSS JOIN LATERAL compute_technique_damage(
        p_player_id, t.technique_id, live.species_id,
        player_external_multiplier(p_player_id, t.technique_id), 0) AS would
    WHERE u.player_id = p_player_id
      AND t.base_power > 0
      AND (p_technique_id IS NULL OR t.technique_id = p_technique_id)
    ORDER BY would.final_damage DESC, l.slot_index NULLS LAST, t.base_power DESC
    LIMIT 1;

    IF move IS NULL THEN
        RAISE EXCEPTION 'you know no technique that could hurt it'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO hit FROM compute_technique_damage(
        p_player_id, move, live.species_id,
        player_external_multiplier(p_player_id, move), 0);

    -- Immune to everything they hold. Refused rather than swallowed, because a
    -- strike spent for nothing teaches the player only that the button is
    -- broken - and the Path is the thing they can actually do something about.
    IF hit.final_damage <= 0 THEN
        RAISE EXCEPTION
            'it turns aside everything you know - bring another Path'
            USING ERRCODE = 'check_violation';
    END IF;

    left_hp := GREATEST(0, live.current_hp - hit.final_damage);
    killed  := left_hp = 0;

    UPDATE boss_encounters e
    SET current_hp = left_hp,
        status     = CASE WHEN killed THEN 'slain' ELSE e.status END,
        ended_at   = CASE WHEN killed THEN now() ELSE e.ended_at END,
        slayer_id  = CASE WHEN killed THEN p_player_id ELSE e.slayer_id END
    WHERE e.encounter_id = live.encounter_id;

    -- What it does back. A dead beast does not get a parting shot.
    back := 0;
    IF NOT killed THEN
        SELECT gc.final_damage INTO back
        FROM compute_creature_damage(live.species_id, p_player_id) gc;

        UPDATE player_physique pp
        SET current_hp = GREATEST(0, pp.current_hp - back)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO body.current_hp;
    END IF;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage, taken)
    VALUES (live.encounter_id, p_player_id, 1, hit.final_damage, back)
    -- ON CONSTRAINT, not (encounter_id, player_id): `encounter_id` is also an
    -- OUT parameter of this function, and a conflict target resolves the name
    -- against the variable first. The same trap 0114 fell into.
    ON CONFLICT ON CONSTRAINT boss_strikes_pkey DO UPDATE SET
        strikes     = boss_strikes.strikes + 1,
        damage      = boss_strikes.damage + EXCLUDED.damage,
        taken       = boss_strikes.taken + EXCLUDED.taken,
        last_struck = now()
    RETURNING boss_strikes.damage INTO mine;

    RETURN QUERY SELECT
        live.encounter_id, live.name, move_name,
        hit.final_damage, back, hit.matchup_modifier,
        left_hp, live.max_hp,
        body.current_hp, body.max_hp,
        allowed - spent - 1, killed, mine;
END;
$$;

COMMENT ON FUNCTION strike_boss(BIGINT, BIGINT) IS
    'One blow at the standing world beast, through the same damage pipeline a hunt uses. Takes the row FOR UPDATE so two strikes cannot read the same HP.';


-- ---------------------------------------------------------------------------
-- claim_boss_reward
-- ---------------------------------------------------------------------------

CREATE FUNCTION claim_boss_reward(p_player_id BIGINT)
RETURNS TABLE (
    encounter_id BIGINT,
    beast_name   TEXT,
    outcome      TEXT,
    my_damage    BIGINT,
    my_share     NUMERIC,
    stones       BIGINT,
    jade         BIGINT,
    spoils       JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    owed   RECORD;
    dealt  BIGINT;
    share  NUMERIC;
    paid   BIGINT;
    coin   BIGINT := 0;
    d      RECORD;
    qty    INTEGER;
    loot   JSONB := '[]'::jsonb;
BEGIN
    SELECT e.encounter_id, e.species_id, e.status, e.slayer_id,
           cs.name, bs.damage
    INTO owed
    FROM boss_strikes bs
    JOIN boss_encounters e ON e.encounter_id = bs.encounter_id
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE bs.player_id = p_player_id
      AND bs.rewarded_at IS NULL
      AND e.status <> 'open'
    ORDER BY e.ended_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have nothing owing from a world beast'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(bs.damage), 0) INTO dealt
    FROM boss_strikes bs WHERE bs.encounter_id = owed.encounter_id;

    share := CASE WHEN dealt > 0 THEN owed.damage::numeric / dealt ELSE 0 END;

    -- A beast that got away still owes what it was bled for, at half.
    paid := GREATEST(1, round(owed.damage * game_config_value('boss_stones_per_hp')
                              * CASE WHEN owed.status = 'slain' THEN 1 ELSE 0.5 END));
    PERFORM grant_material(p_player_id, 'spirit_stone', paid);

    IF owed.status = 'slain' THEN
        IF owed.slayer_id = p_player_id THEN
            coin := game_config_value('boss_jade_slayer')::bigint;
            PERFORM grant_jade(p_player_id, coin, 'boss_slayer');
        END IF;

        FOR d IN
            SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity,
                   m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = owed.species_id
        LOOP
            -- Weighted by contribution and floored, so two strikes is a slim
            -- chance rather than none and the whole roster is not paid the
            -- same for wildly different work.
            IF random() < d.chance * LEAST(1, 0.35 + 0.65 * share) THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(p_player_id, d.material_code, qty);
                loot := loot || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty);
            END IF;
        END LOOP;
    END IF;

    UPDATE boss_strikes bs SET rewarded_at = now()
    WHERE bs.encounter_id = owed.encounter_id AND bs.player_id = p_player_id;

    RETURN QUERY SELECT owed.encounter_id, owed.name, owed.status,
                        owed.damage, round(share, 4), paid, coin, loot;
END;
$$;

COMMENT ON FUNCTION claim_boss_reward(BIGINT) IS
    'Pays one cultivator their share of a finished world beast, once. `rewarded_at` is what makes it once.';


-- ---------------------------------------------------------------------------
-- Both have to survive being called
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    ghost BIGINT;
    blow  RECORD;
    pay   RECORD;
    beast BIGINT;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999140, 'migration 0140 probe')
    RETURNING player_id INTO ghost;

    INSERT INTO player_cultivation (player_id, cultivation, realm_id)
    VALUES (ghost, 0, 1);
    INSERT INTO player_physique (player_id, physique_id, body_level, max_hp, current_hp)
    VALUES (ghost, (SELECT physique_id FROM physiques LIMIT 1), 1, 100000, 100000);
    -- Every rank 1 attack, so the pick has something that lands whichever
    -- beast turns up and this probe tests the boss rather than the chart.
    INSERT INTO player_techniques (player_id, technique_id)
    SELECT ghost, technique_id FROM techniques
    WHERE code IS NOT NULL AND grade = 'basic' AND rank = 1 AND base_power > 0;

    beast := boss_open_if_due();
    IF beast IS NULL THEN
        RAISE EXCEPTION 'no beast could be opened, so nothing below was tested';
    END IF;

    SELECT * INTO blow FROM strike_boss(ghost);
    IF blow.dealt <= 0 THEN
        RAISE EXCEPTION 'a strike did no damage at all';
    END IF;
    IF blow.strikes_left <> game_config_value('boss_strikes_each')::integer - 1 THEN
        RAISE EXCEPTION 'a strike did not count against the allowance';
    END IF;

    -- Spend the rest, then check the refusal.
    FOR i IN 2..game_config_value('boss_strikes_each')::integer LOOP
        PERFORM strike_boss(ghost);
    END LOOP;

    BEGIN
        PERFORM strike_boss(ghost);
        RAISE EXCEPTION 'a sixth strike was allowed';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    -- Retire it so a share can be claimed, then claim it exactly once.
    UPDATE boss_encounters SET status = 'escaped', ended_at = now()
    WHERE encounter_id = beast AND status = 'open';

    SELECT * INTO pay FROM claim_boss_reward(ghost);
    IF pay.stones <= 0 THEN
        RAISE EXCEPTION 'a share paid nothing';
    END IF;

    BEGIN
        PERFORM claim_boss_reward(ghost);
        RAISE EXCEPTION 'a share was claimed twice';
    EXCEPTION WHEN check_violation THEN
        NULL;
    END;

    DELETE FROM boss_encounters WHERE encounter_id = beast;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM player_techniques WHERE player_id = ghost;
    DELETE FROM player_physique WHERE player_id = ghost;
    DELETE FROM player_cultivation WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
