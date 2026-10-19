-- 0416_servants_go_out_and_bring_back_what_nobody_can_pick_any_more
--
-- Third of four, and the one that answers the problem: an immortal cannot go
-- back and pick grass, and 344 Gu recipes still want Centipede Venom.
--
-- WHAT THEY BRING. The mortal band only - `gathering` and `beast` materials at
-- common or uncommon, 155 of them. A servant's realm and stars raise HOW MUCH
-- comes home, never what KIND does, so this is a supply line for the things
-- that stopped being reachable rather than a second route to the things the
-- horde and the deep regions already pay. The one exception is
-- `servant_rare_chance`: a small roll per collection for something better,
-- capped at what the servant's own realm could plausibly reach. A supply line
-- with nothing to hope for is a spreadsheet.
--
-- HOW MANY GO OUT. `servant_farm_slots` starts at two and takes another every
-- `servant_slot_per_ranks` ranks, to a ceiling. So a collection is worth more
-- than one card, and the supply scales with the cultivator who needs it - a
-- rank 18 immortal is exactly the person who cannot pick their own grass.
--
-- THE CLOCK is `blessed_land_settle`'s, deliberately: hours since
-- `settled_at`, forfeit anything past `passive_cap_hours`, pay whole units and
-- advance the clock BY WHAT WAS PAID rather than to now(), so the remainder
-- of a part-hour is not quietly eaten. Four passive systems in this game have
-- had to learn that separately; this one is copying the one that got it right.
--
-- WHAT THEY EAT. A servant climbs the realms a cultivator does and is fed what
-- a cultivator is fed: cultivation pills, insight pills, and past the immortal
-- door, essence. Two things keep that from being a second cultivation grind:
--
--   * `servant_cultivation_discount` - a servant needs a tenth of what a
--     person does for the same realm. They are staff, not disciples.
--   * A servant may not out-rank the cultivator holding their contract. It is
--     thematically right, and it stops a lucky T7 becoming a farm that has
--     nothing to do with how far its owner has actually come.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_farm_slots_base', 2,
     'Servants a cultivator may have out working before any realm is counted.'),
    ('servant_slot_per_ranks', 4,
     'Ranks climbed per extra farming slot. At 4 a rank 18 immortal works six.'),
    ('servant_farm_slots_max', 6,
     'The most servants that may ever be out at once, whatever the realm.'),
    ('servant_realm_step', 0.15,
     'What each rank of a servant''s own realm adds to their hourly haul. Feeding a servant is the long lever; stars are the short one.'),
    ('servant_rare_chance', 0.05,
     'Chance per whole hour worked that a servant turns up something above the mortal band, capped at what their own realm could reach.'),
    ('servant_cultivation_discount', 0.10,
     'What share of a cultivator''s cultivation a servant needs for the same realm. A tenth: they are staff, not disciples, and feeding them should not be a second climb.');


-- ---------------------------------------------------------------------------
-- How many hands you may have out
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_farm_slots(p_player_id bigint)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(
        game_config_value('servant_farm_slots_max'),
        game_config_value('servant_farm_slots_base')
        + floor(COALESCE((SELECT r.rank FROM player_cultivation pc
                          JOIN realms r ON r.realm_id = pc.realm_id
                          WHERE pc.player_id = p_player_id), 1)
                / game_config_value('servant_slot_per_ranks'))
    )::integer;
$$;

COMMENT ON FUNCTION servant_farm_slots(bigint) IS
    'Servants a cultivator may have out working at once. Grows with their realm, because the deeper they are the less able they are to pick their own grass.';


-- ---------------------------------------------------------------------------
-- What one servant is worth in an hour
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_haul_per_hour(p_player_servant_id bigint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT t.farm_per_hour
           * servant_star_scale(ps.stars)
           * (1 + servant_collection_bonus(ps.player_id))
           * (1 + r.rank * game_config_value('servant_realm_step'))
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    JOIN servant_tiers t ON t.tier = s.tier
    JOIN realms r ON r.realm_id = ps.realm_id
    WHERE ps.player_servant_id = p_player_servant_id;
$$;

COMMENT ON FUNCTION servant_haul_per_hour(bigint) IS
    'Mortal materials one servant brings home per hour: their tier, raised by their stars, by the breadth of the collection they belong to, and by their own realm.';


-- ---------------------------------------------------------------------------
-- Sending one out, and calling one back
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_send(p_player_id bigint, p_player_servant_id bigint,
                             p_out boolean)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    it   RECORD;
    v_n  INTEGER;
BEGIN
    SELECT ps.*, s.name INTO it
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id
    FOR UPDATE OF ps;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_out AND NOT it.farming THEN
        SELECT count(*)::integer INTO v_n FROM player_servants ps
        WHERE ps.player_id = p_player_id AND ps.farming;

        IF v_n >= servant_farm_slots(p_player_id) THEN
            RAISE EXCEPTION
                'you can keep % servant(s) at work, and % are already out',
                servant_farm_slots(p_player_id), v_n
                USING ERRCODE = 'check_violation';
        END IF;

        -- The clock starts now. Sending somebody out must not pay for the
        -- hours they spent sitting at home.
        UPDATE player_servants
        SET farming = TRUE, settled_at = now()
        WHERE player_servant_id = p_player_servant_id;
        RETURN it.name || ' goes out.';
    END IF;

    IF NOT p_out AND it.farming THEN
        -- Settled first, so calling somebody back never throws away a haul
        -- they had already earned.
        PERFORM servant_settle(p_player_id);
        UPDATE player_servants SET farming = FALSE
        WHERE player_servant_id = p_player_servant_id;
        RETURN it.name || ' comes home.';
    END IF;

    RETURN it.name || CASE WHEN it.farming THEN ' is already out.'
                           ELSE ' is already home.' END;
END;
$$;


-- ---------------------------------------------------------------------------
-- And what they bring back
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_settle(p_player_id bigint)
RETURNS TABLE (
    servant_name TEXT,
    hours        NUMERIC,
    brought      BIGINT,
    haul         TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    one     RECORD;
    cap     NUMERIC := game_config_value('passive_cap_hours');
    elapsed NUMERIC;
    whole   INTEGER;
    made    BIGINT;
    said    TEXT[];
    pick    RECORD;
    v_rank  SMALLINT;
BEGIN
    FOR one IN
        SELECT ps.player_servant_id, ps.settled_at, s.name,
               (SELECT r.rank FROM realms r WHERE r.realm_id = ps.realm_id) AS rank
        FROM player_servants ps
        JOIN servants s ON s.servant_code = ps.servant_code
        WHERE ps.player_id = p_player_id AND ps.farming
        ORDER BY ps.player_servant_id
        FOR UPDATE OF ps
    LOOP
        elapsed := EXTRACT(EPOCH FROM (now() - one.settled_at)) / 3600.0;

        -- Sleeping through a fortnight pays a day. Forfeited BEFORE the hours
        -- are counted, so the overflow cannot be banked by the arithmetic.
        IF elapsed > cap THEN
            UPDATE player_servants
            SET settled_at = now() - make_interval(secs => cap * 3600)
            WHERE player_servant_id = one.player_servant_id;
            elapsed := cap;
        END IF;

        whole := floor(elapsed)::integer;
        CONTINUE WHEN whole < 1;

        made := round(servant_haul_per_hour(one.player_servant_id) * whole)::bigint;
        CONTINUE WHEN made < 1;

        said   := '{}';
        v_rank := GREATEST(1, one.rank);

        -- The mortal band, which is the whole point: what a cultivator who
        -- has left the mortal realms can no longer go and pick.
        SELECT m.code, m.name INTO pick
        FROM materials m
        WHERE m.category IN ('gathering', 'beast')
          AND m.rarity IN ('common', 'uncommon')
        ORDER BY random() LIMIT 1;

        PERFORM grant_material(p_player_id, pick.code, made);
        said := said || (made || 'x ' || pick.name);

        -- And the hope. One roll per whole hour worked, for something above
        -- the band - never past what the servant's own realm could reach.
        IF random() < 1 - power(1 - game_config_value('servant_rare_chance'),
                                whole) THEN
            SELECT m.code, m.name INTO pick
            FROM materials m
            JOIN rarities ra ON ra.code = m.rarity
            WHERE m.category IN ('gathering', 'beast')
              AND m.rarity NOT IN ('common', 'uncommon')
              AND ra.sort_order <= 2 + v_rank
            ORDER BY random() LIMIT 1;

            IF pick.code IS NOT NULL THEN
                PERFORM grant_material(p_player_id, pick.code, 1);
                said := said || ('1x ' || pick.name);
            END IF;
        END IF;

        -- Advanced BY what was paid, not to now(): the remainder of a part
        -- hour belongs to the next settling.
        UPDATE player_servants
        SET settled_at = settled_at + make_interval(secs => whole * 3600)
        WHERE player_servant_id = one.player_servant_id;

        RETURN QUERY SELECT one.name, whole::numeric, made,
                            array_to_string(said, ', ');
    END LOOP;
END;
$$;

COMMENT ON FUNCTION servant_settle(bigint) IS
    'Counts every working servant''s hours and pays them. Same clock as `blessed_land_settle`, including advancing by what was paid so a part hour is not eaten.';


-- ---------------------------------------------------------------------------
-- Feeding one
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_realm_cost(p_realm_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT ceil(r.cultivation_required
                * game_config_value('servant_cultivation_discount'))::bigint
    FROM realms r WHERE r.realm_id = p_realm_id;
$$;


CREATE FUNCTION servant_feed(p_player_id bigint, p_player_servant_id bigint,
                             p_pill_id bigint, p_quantity integer DEFAULT 1)
RETURNS TABLE (
    servant_name TEXT,
    fed          TEXT,
    gained       BIGINT,
    cultivation  BIGINT,
    realm_name   TEXT,
    rose         BOOLEAN,
    wants        BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it      RECORD;
    pill    RECORD;
    worth   BIGINT;
    ceiling SMALLINT;
    grew    BOOLEAN := FALSE;
    nextr   RECORD;
BEGIN
    SELECT ps.*, s.name INTO it
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id
    FOR UPDATE OF ps;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO pill FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that pill is not yours' USING ERRCODE = 'check_violation';
    END IF;
    IF pill.kind NOT IN ('cultivation', 'insight') THEN
        RAISE EXCEPTION
            'a servant grows on Cultivation and Insight pills, not %', pill.name
            USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_quantity, 0) < 1 OR pill.quantity < p_quantity THEN
        RAISE EXCEPTION 'you hold % of those', pill.quantity
            USING ERRCODE = 'check_violation';
    END IF;

    -- A servant may not out-rank the hand that holds their contract.
    SELECT r.rank INTO ceiling FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id WHERE pc.player_id = p_player_id;

    IF (SELECT r.rank FROM realms r WHERE r.realm_id = it.realm_id)
       >= COALESCE(ceiling, 1)
       AND (SELECT r.rank FROM realms r WHERE r.realm_id = it.realm_id + 1)
           > COALESCE(ceiling, 1) THEN
        RAISE EXCEPTION
            '% cannot be raised past the realm you stand in yourself', it.name
            USING ERRCODE = 'check_violation';
    END IF;

    worth := pill_cultivation_worth(p_player_id, pill.tier, pill.magnitude,
                                    pill.harmony, pill.potency) * p_quantity;

    UPDATE player_pills SET quantity = quantity - p_quantity
    WHERE pill_id = p_pill_id;
    DELETE FROM player_pills WHERE pill_id = p_pill_id AND quantity <= 0;

    UPDATE player_servants ps
    SET cultivation = ps.cultivation + worth
    WHERE ps.player_servant_id = p_player_servant_id;

    -- As many realms as that paid for, stopping at the owner's own.
    LOOP
        SELECT r.realm_id, r.name, r.rank INTO nextr
        FROM realms r WHERE r.realm_id = it.realm_id + 1;

        EXIT WHEN nextr.realm_id IS NULL;
        EXIT WHEN nextr.rank > COALESCE(ceiling, 1);
        EXIT WHEN (SELECT ps.cultivation FROM player_servants ps
                   WHERE ps.player_servant_id = p_player_servant_id)
                  < servant_realm_cost(nextr.realm_id);

        UPDATE player_servants ps
        SET realm_id = nextr.realm_id
        WHERE ps.player_servant_id = p_player_servant_id;
        it.realm_id := nextr.realm_id;
        grew := TRUE;
    END LOOP;

    RETURN QUERY
    SELECT it.name, pill.name, worth, ps.cultivation, r.name, grew,
           COALESCE(servant_realm_cost(ps.realm_id + 1), 0)
    FROM player_servants ps
    JOIN realms r ON r.realm_id = ps.realm_id
    WHERE ps.player_servant_id = p_player_servant_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- An hour out is a handful of what nobody could pick
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_id   BIGINT;
    v_had  BIGINT;
    v_rows INTEGER := 0;
    r      RECORD;
BEGIN
    -- Slots must grow and must stop growing.
    IF servant_farm_slots(-1::bigint) < game_config_value('servant_farm_slots_base') THEN
        RAISE EXCEPTION 'a realmless cultivator gets fewer than the base slots';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        PERFORM grant_material(v_who, 'spirit_jade', 1000);
        PERFORM servant_roll(v_who);

        SELECT ps.player_servant_id INTO v_id FROM player_servants ps
        WHERE ps.player_id = v_who ORDER BY ps.player_servant_id DESC LIMIT 1;

        PERFORM servant_send(v_who, v_id, TRUE);

        -- Nothing is owed the instant they leave.
        SELECT count(*) INTO v_rows FROM servant_settle(v_who);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'a servant was paid for hours they had not worked';
        END IF;

        -- Five hours later they have something.
        UPDATE player_servants SET settled_at = now() - interval '5 hours'
        WHERE player_servant_id = v_id;

        SELECT sum(s.brought) INTO v_had FROM servant_settle(v_who) s;
        IF COALESCE(v_had, 0) < 1 THEN
            RAISE EXCEPTION 'five hours of work brought back nothing';
        END IF;

        -- And the clock moved by what was paid, not to now.
        IF (SELECT settled_at FROM player_servants WHERE player_servant_id = v_id)
           > now() THEN
            RAISE EXCEPTION 'settling pushed the clock into the future';
        END IF;

        -- Paid once. A second settling in the same breath owes nothing.
        SELECT count(*) INTO v_rows FROM servant_settle(v_who);
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'the same hours paid twice';
        END IF;

        RAISE NOTICE 'five hours of one servant brought back % materials', v_had;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT t.tier, t.rarity, t.farm_per_hour AS at_one_star,
               round(t.farm_per_hour * servant_star_scale(5::smallint)
                     * (1 + 18 * game_config_value('servant_realm_step')), 1)
                 AS five_star_immortal
        FROM servant_tiers t ORDER BY t.tier
    LOOP
        RAISE NOTICE 'T% %: % an hour new, % an hour at five stars and rank 18',
            r.tier, rpad(r.rarity, 10), r.at_one_star, r.five_star_immortal;
    END LOOP;
END;
$probe$;
