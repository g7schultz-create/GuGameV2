-- 0147_a_ledger_of_what_everyone_got
--
-- The world beast is meant to be the thing the whole server did together, and
-- until now the only person who ever saw a payout was the person receiving it.
-- `claim_boss_reward` computed stones, Jade, spoils and sometimes a manual,
-- handed them over, and remembered none of it - `rewarded_at` recorded THAT a
-- share was paid and nothing about what it was.
--
-- So the ledger keeps the payout. That is what lets the kill be announced with
-- everyone's haul in it, and it is worth having on its own: "what did the
-- Leviathan actually pay out last week" is currently unanswerable.
--
-- A claim is still exactly once - `rewarded_at` is still what makes it so.
-- These columns are what it paid, written at the same moment.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE boss_strikes
    ADD COLUMN stones_paid BIGINT  NOT NULL DEFAULT 0 CHECK (stones_paid >= 0),
    ADD COLUMN jade_paid   BIGINT  NOT NULL DEFAULT 0 CHECK (jade_paid >= 0),
    ADD COLUMN spoils      JSONB   NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN manual_won  TEXT;

COMMENT ON COLUMN boss_strikes.spoils IS
    'What the carcass yielded this cultivator, as the claim rolled it. Kept so the kill can be announced with everyone''s haul rather than only their damage.';


-- Where the kill was announced, so the message can be edited as the shares are
-- taken rather than the channel filling with one post per claimant.
ALTER TABLE boss_encounters
    ADD COLUMN announce_channel_id BIGINT,
    ADD COLUMN announce_message_id BIGINT,
    ADD CONSTRAINT boss_announce_is_whole
        CHECK ((announce_channel_id IS NULL) = (announce_message_id IS NULL));

COMMENT ON COLUMN boss_encounters.announce_message_id IS
    'The kill announcement, if one was posted. Stored so later claims edit that message instead of posting again - and so a restart cannot lose track of it.';


-- ---------------------------------------------------------------------------
-- claim_boss_reward, writing down what it paid
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION claim_boss_reward(p_player_id BIGINT)
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
    qty    INTEGER;
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
            SELECT x.material_code, x.chance, x.min_quantity, x.max_quantity,
                   m.name, m.emoji
            FROM (
                SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity
                FROM creature_drops cd WHERE cd.species_id = owed.species_id
                UNION ALL
                SELECT bd.material_code, bd.chance, bd.min_quantity, bd.max_quantity
                FROM boss_drops bd WHERE bd.species_id = owed.species_id
            ) x
            JOIN materials m ON m.code = x.material_code
        LOOP
            IF random() < d.chance * weight THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(p_player_id, d.material_code, qty);
                -- The emoji goes in too: the announcement reads this rather
                -- than looking every material up again to draw one line.
                loot := loot || jsonb_build_object(
                    'code', d.material_code, 'name', d.name,
                    'emoji', d.emoji, 'quantity', qty);
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
-- boss_haul
-- ---------------------------------------------------------------------------
-- What everybody got, for the announcement. Includes people who have not
-- claimed yet - "waiting" is information the channel wants, because it is a
-- nudge to whoever has a share sitting there.

CREATE FUNCTION boss_haul(p_encounter_id BIGINT)
RETURNS TABLE (
    player_id    BIGINT,
    discord_name TEXT,
    damage       BIGINT,
    share        NUMERIC,
    claimed      BOOLEAN,
    stones       BIGINT,
    jade         BIGINT,
    spoils       JSONB,
    manual       TEXT
)
LANGUAGE sql STABLE
AS $$
    SELECT bs.player_id, p.discord_name, bs.damage,
           round(bs.damage::numeric / NULLIF(sum(bs.damage) OVER (), 0), 4),
           bs.rewarded_at IS NOT NULL,
           bs.stones_paid, bs.jade_paid, bs.spoils, bs.manual_won
    FROM boss_strikes bs
    JOIN players p ON p.player_id = bs.player_id
    WHERE bs.encounter_id = p_encounter_id
    ORDER BY bs.damage DESC, p.discord_name;
$$;

COMMENT ON FUNCTION boss_haul(BIGINT) IS
    'Everyone who struck one world beast and what it paid them, claimed or not yet. What the kill announcement is drawn from.';


CREATE FUNCTION boss_announced(
    p_encounter_id BIGINT, p_channel_id BIGINT, p_message_id BIGINT
) RETURNS VOID
LANGUAGE sql
AS $$
    UPDATE boss_encounters
    SET announce_channel_id = p_channel_id, announce_message_id = p_message_id
    WHERE encounter_id = p_encounter_id;
$$;

COMMENT ON FUNCTION boss_announced(BIGINT, BIGINT, BIGINT) IS
    'Remembers where a kill was announced, so later claims edit that message rather than posting again.';


DO $$
DECLARE
    ghost BIGINT;
    beast BIGINT;
    pay   RECORD;
    seen  RECORD;
BEGIN
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999147, 'migration 0147 probe') RETURNING player_id INTO ghost;

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, status, closes_at, ended_at,
         slayer_id)
    SELECT cs.species_id, 'western', 100, 0, 'slain',
           now() + interval '1 day', now(), ghost
    FROM creature_species cs WHERE cs.kind = 'boss' LIMIT 1
    RETURNING encounter_id INTO beast;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage)
    VALUES (beast, ghost, 5, 400);

    SELECT * INTO seen FROM boss_haul(beast);
    IF seen.claimed THEN
        RAISE EXCEPTION 'an unclaimed share reported as claimed';
    END IF;

    SELECT * INTO pay FROM claim_boss_reward(ghost);
    SELECT * INTO seen FROM boss_haul(beast);

    IF NOT seen.claimed THEN
        RAISE EXCEPTION 'a claimed share still reports as waiting';
    END IF;
    IF seen.stones <> pay.stones OR seen.jade <> pay.jade THEN
        RAISE EXCEPTION 'the ledger says % stones and % jade; the claim said % and %',
            seen.stones, seen.jade, pay.stones, pay.jade;
    END IF;
    IF seen.spoils <> pay.spoils THEN
        RAISE EXCEPTION 'the ledger and the claim disagree about the spoils';
    END IF;

    PERFORM boss_announced(beast, 123, 456);
    IF (SELECT announce_message_id FROM boss_encounters WHERE encounter_id = beast)
       <> 456 THEN
        RAISE EXCEPTION 'the announcement was not remembered';
    END IF;

    DELETE FROM boss_strikes WHERE encounter_id = beast;
    DELETE FROM boss_encounters WHERE encounter_id = beast;
    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
