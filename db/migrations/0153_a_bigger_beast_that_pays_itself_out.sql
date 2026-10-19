-- 0153_a_bigger_beast_that_pays_itself_out
--
-- Three things.
--
-- FIVE TIMES THE HEALTH, WITH ONE DIAL. The pool is
--
--     roster power x strikes each x effort
--
-- so `boss_strikes_each` is in it twice over: it sizes the beast AND it is the
-- ceiling on what the roster can physically deal. Raising it fivefold gives
-- exactly five times the health and leaves the ratio between the two exactly
-- where it was - 34,605 becomes 173,025 against a ceiling of 288,375, still
-- sixty per cent. Raising the effort instead would have made a beast this
-- roster cannot kill however long it stands, which is the Leviathan's five
-- million all over again.
--
-- IT PAYS ITSELF OUT. `claim_boss_reward` stays, because it is where a payout
-- is decided and rolled - but nobody has to press anything now. The moment a
-- beast falls, or the moment one that ran out its clock is retired, every
-- cultivator who struck it is settled. A share that had to be claimed was a
-- share somebody would forget, and forgetting is not a game mechanic.
--
-- It is still exactly once: `rewarded_at` is what makes it so, and settling
-- walks only the strikers who have none.
--
-- AND IT ANNOUNCES ITS OWN ARRIVAL. A beast standing where nobody knows about
-- it is the same problem the kill announcement solved from the other end.
-- `spawn_announced_at` is on the encounter rather than in the bot's memory so
-- a restart cannot post it twice or forget to post it at all.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 125,
    description = 'Strikes one cultivator gets at one world beast. Five times what it was, which is also five times the beast - the pool is roster x strikes x effort, so this dial sizes the beast and caps what the roster can deal to it, and moving it alone keeps those two in step.'
WHERE key = 'boss_strikes_each';


ALTER TABLE boss_encounters ADD COLUMN spawn_announced_at TIMESTAMPTZ;

COMMENT ON COLUMN boss_encounters.spawn_announced_at IS
    'When its arrival was posted. On the row rather than in the bot''s memory, so a restart neither posts it twice nor forgets it.';


-- ---------------------------------------------------------------------------
-- claim_boss_reward, aimable at one encounter
-- ---------------------------------------------------------------------------
-- Settling a whole field needs to say WHICH beast. Without that it would pick
-- "the most recent unrewarded one for this player", which is right by accident
-- and wrong the moment somebody has an older share outstanding.

DROP FUNCTION claim_boss_reward(BIGINT);

CREATE FUNCTION claim_boss_reward(
    p_player_id BIGINT, p_encounter_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    encounter_id BIGINT,
    beast_name   TEXT,
    outcome      TEXT,
    my_damage    BIGINT,
    my_share     NUMERIC,
    stones       BIGINT,
    jade         BIGINT,
    spoils       JSONB,
    manual       TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    owed   RECORD;
    dealt  BIGINT;
    share  NUMERIC;
    weight NUMERIC;
    paid   BIGINT;
    coin   BIGINT := 0;
    d      RECORD;
    loot   JSONB := '[]'::jsonb;
    book   BIGINT;
    book_name TEXT;
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
      AND (p_encounter_id IS NULL OR e.encounter_id = p_encounter_id)
    ORDER BY e.ended_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have nothing owing from a world beast'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(bs.damage), 0) INTO dealt
    FROM boss_strikes bs WHERE bs.encounter_id = owed.encounter_id;

    share  := CASE WHEN dealt > 0 THEN owed.damage::numeric / dealt ELSE 0 END;
    weight := LEAST(1, 0.35 + 0.65 * share);

    paid := GREATEST(1, round(owed.damage * game_config_value('boss_stones_per_hp')
                              * CASE WHEN owed.status = 'slain' THEN 1 ELSE 0.5 END));
    PERFORM grant_material(p_player_id, 'spirit_stone', paid);

    coin := game_config_value('boss_jade_min')
            + floor(random() * (game_config_value('boss_jade_max')
                                - game_config_value('boss_jade_min') + 1));
    IF owed.status <> 'slain' THEN
        coin := GREATEST(1, round(coin / 2.0));
    END IF;
    PERFORM grant_jade(p_player_id, coin, 'world_beast');

    IF owed.status = 'slain' THEN
        FOR d IN
            SELECT x.material_code, m.name, m.emoji,
                   sum(
                       CASE WHEN random() < x.chance * weight
                            THEN x.min_quantity
                                 + floor(random()
                                         * (x.max_quantity - x.min_quantity + 1))
                            ELSE 0 END
                   )::integer AS quantity
            FROM (
                SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity
                FROM creature_drops cd WHERE cd.species_id = owed.species_id
                UNION ALL
                SELECT bd.material_code, bd.chance, bd.min_quantity, bd.max_quantity
                FROM boss_drops bd WHERE bd.species_id = owed.species_id
            ) x
            JOIN materials m ON m.code = x.material_code
            GROUP BY x.material_code, m.name, m.emoji
        LOOP
            IF d.quantity > 0 THEN
                PERFORM grant_material(p_player_id, d.material_code, d.quantity);
                loot := loot || jsonb_build_object(
                    'code', d.material_code, 'name', d.name,
                    'emoji', d.emoji, 'quantity', d.quantity);
            END IF;
        END LOOP;

        IF random() < game_config_value('boss_manual_chance') * weight THEN
            SELECT m.manual_id, m.name INTO book, book_name
            FROM manuals m
            WHERE m.code IS NOT NULL
              AND m.archetype = 'technique'
              AND NOT EXISTS (
                  SELECT 1 FROM player_manuals pm
                  WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
              )
            ORDER BY random()
            LIMIT 1;

            IF book IS NOT NULL THEN
                INSERT INTO player_manuals (player_id, manual_id)
                VALUES (p_player_id, book)
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;
    END IF;

    UPDATE boss_strikes bs
    SET rewarded_at = now(),
        stones_paid = paid,
        jade_paid   = coin,
        spoils      = loot,
        manual_won  = book_name
    WHERE bs.encounter_id = owed.encounter_id AND bs.player_id = p_player_id;

    RETURN QUERY SELECT owed.encounter_id, owed.name, owed.status,
                        owed.damage, round(share, 4), paid, coin, loot, book_name;
END;
$$;


-- ---------------------------------------------------------------------------
-- settle_boss
-- ---------------------------------------------------------------------------

CREATE FUNCTION settle_boss(p_encounter_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    who  RECORD;
    paid INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM boss_encounters e
                   WHERE e.encounter_id = p_encounter_id AND e.status <> 'open') THEN
        RETURN 0;
    END IF;

    FOR who IN
        SELECT bs.player_id FROM boss_strikes bs
        WHERE bs.encounter_id = p_encounter_id AND bs.rewarded_at IS NULL
        ORDER BY bs.damage DESC
    LOOP
        PERFORM claim_boss_reward(who.player_id, p_encounter_id);
        paid := paid + 1;
    END LOOP;

    RETURN paid;
END;
$$;

COMMENT ON FUNCTION settle_boss(BIGINT) IS
    'Pays every unsettled striker of one finished beast. Called the moment it falls or is retired, so nobody has to remember to claim.';


-- ---------------------------------------------------------------------------
-- The two moments a beast finishes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION boss_open_if_due()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live   BIGINT;
    lapsed BIGINT;
    rested BOOLEAN;
    chosen BIGINT;
    made   BIGINT;
    pool   BIGINT;
BEGIN
    -- A beast that stood out its welcome leaves - and is settled on the way
    -- out, so an escape pays what it owes without anybody pressing anything.
    FOR lapsed IN
        SELECT encounter_id FROM boss_encounters
        WHERE status = 'open' AND closes_at <= now()
    LOOP
        UPDATE boss_encounters
        SET status = 'escaped', ended_at = now()
        WHERE encounter_id = lapsed;
        PERFORM settle_boss(lapsed);
    END LOOP;

    SELECT encounter_id INTO live
    FROM boss_encounters WHERE status = 'open';

    IF live IS NOT NULL THEN
        RETURN live;
    END IF;

    SELECT COALESCE(max(ended_at), 'epoch'::timestamptz)
           <= now() - make_interval(hours => game_config_value('boss_rest_hours')::int)
    INTO rested
    FROM boss_encounters;

    IF NOT rested THEN
        RETURN NULL;
    END IF;

    SELECT cs.species_id INTO chosen
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
    ORDER BY random()
    LIMIT 1;

    IF chosen IS NULL THEN
        RETURN NULL;
    END IF;

    pool := boss_hp_pool();

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, closes_at)
    SELECT chosen,
           COALESCE((SELECT cr.region_code FROM creature_regions cr
                     WHERE cr.species_id = chosen ORDER BY random() LIMIT 1),
                    (SELECT r.code FROM regions r ORDER BY r.code LIMIT 1)),
           pool, pool,
           now() + make_interval(hours => game_config_value('boss_hours')::int)
    ON CONFLICT DO NOTHING
    RETURNING encounter_id INTO made;

    IF made IS NULL THEN
        SELECT encounter_id INTO made
        FROM boss_encounters WHERE status = 'open';
    END IF;

    RETURN made;
END;
$$;


CREATE OR REPLACE FUNCTION strike_boss(
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
    live      RECORD;
    body      RECORD;
    move      BIGINT;
    move_name TEXT;
    hit       RECORD;
    back      BIGINT;
    spent     INTEGER;
    allowed   INTEGER := game_config_value('boss_strikes_each')::integer;
    left_hp   BIGINT;
    killed    BOOLEAN := FALSE;
    mine      BIGINT;
BEGIN
    PERFORM boss_open_if_due();

    SELECT e.encounter_id, e.species_id, e.current_hp, e.max_hp,
           cs.name, cs.base_defense
    INTO live
    FROM boss_encounters e
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE e.status = 'open'
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

    back := 0;
    IF NOT killed THEN
        SELECT LEAST(
                   gc.final_damage,
                   GREATEST(1, floor(body.max_hp
                                     * game_config_value('boss_bite_cap')))
               )::bigint
        INTO back
        FROM compute_creature_damage(live.species_id, p_player_id) gc;

        UPDATE player_physique pp
        SET current_hp = GREATEST(0, pp.current_hp - back)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp INTO body.current_hp;
    END IF;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage, taken)
    VALUES (live.encounter_id, p_player_id, 1, hit.final_damage, back)
    ON CONFLICT ON CONSTRAINT boss_strikes_pkey DO UPDATE SET
        strikes     = boss_strikes.strikes + 1,
        damage      = boss_strikes.damage + EXCLUDED.damage,
        taken       = boss_strikes.taken + EXCLUDED.taken,
        last_struck = now()
    RETURNING boss_strikes.damage INTO mine;

    -- Settled here, after this striker's own blow is on the ledger, so the
    -- killing shares are computed with the killing blow counted.
    IF killed THEN
        PERFORM settle_boss(live.encounter_id);
    END IF;

    RETURN QUERY SELECT
        live.encounter_id, live.name, move_name,
        hit.final_damage, back, hit.matchup_modifier,
        left_hp, live.max_hp,
        body.current_hp, body.max_hp,
        allowed - spent - 1, killed, mine;
END;
$$;


CREATE FUNCTION boss_awaiting_announcement()
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT e.encounter_id FROM boss_encounters e
    WHERE e.status = 'open' AND e.spawn_announced_at IS NULL
    LIMIT 1;
$$;

CREATE FUNCTION boss_spawn_announced(p_encounter_id BIGINT)
RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE boss_encounters SET spawn_announced_at = now()
    WHERE encounter_id = p_encounter_id AND spawn_announced_at IS NULL;
$$;


-- ---------------------------------------------------------------------------
-- Five times, and nobody left owed
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    ghost  BIGINT;
    beast  BIGINT;
    owed   INTEGER;
    stones BIGINT;
BEGIN
    IF game_config_value('boss_strikes_each') <> 125 THEN
        RAISE EXCEPTION 'the allowance is % and the beast is sized from it',
            game_config_value('boss_strikes_each');
    END IF;

    INSERT INTO players (discord_id, discord_name)
    VALUES (-999153, 'migration 0153 probe') RETURNING player_id INTO ghost;
    PERFORM grant_material(ghost, 'spirit_stone', 0);

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, status, closes_at, ended_at)
    SELECT cs.species_id, 'western', 100, 0, 'slain',
           now() + interval '1 day', now()
    FROM creature_species cs WHERE cs.kind = 'boss' LIMIT 1
    RETURNING encounter_id INTO beast;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage)
    VALUES (beast, ghost, 5, 400);

    owed := settle_boss(beast);
    IF owed <> 1 THEN
        RAISE EXCEPTION 'settling paid % strikers, not the one there was', owed;
    END IF;

    SELECT bs.stones_paid INTO stones FROM boss_strikes bs
    WHERE bs.encounter_id = beast AND bs.player_id = ghost;
    IF stones IS NULL OR stones <= 0 THEN
        RAISE EXCEPTION 'a settled striker was paid nothing';
    END IF;

    -- And settling twice pays nothing twice.
    IF settle_boss(beast) <> 0 THEN
        RAISE EXCEPTION 'settling a second time paid somebody again';
    END IF;

    DELETE FROM boss_strikes WHERE encounter_id = beast;
    DELETE FROM boss_encounters WHERE encounter_id = beast;
    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM jade_ledger WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
