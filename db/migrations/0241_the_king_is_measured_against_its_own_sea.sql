-- 0241_the_king_is_measured_against_its_own_sea
--
-- The King dies faster than the beasts it comes after.
--
-- 0240 sized a channel beast to the room. The King has always had a formula of
-- its own - `horde_king_hp_per_hand * hands * rank` - so it did not move, and
-- the finale is now the smallest thing on the field. At rank 3:
--
--     hands    King     elite in the channel    King as a share
--       1     27,000          97,138                0.28
--       3     81,000         145,706                0.56
--      10    270,000         315,697                0.86
--
-- At one hand the King is smaller than an ORDINARY channel beast. The thing
-- the whole room organises around, with a crown and a timer and its own
-- entrance, goes down quicker than the trash in front of it.
--
-- This is the split this project keeps paying for, written once more: two
-- places deciding one thing, and only one of them told. So there is one place
-- now. `horde_world_scale` is how big a body is in this tide - the rank, the
-- floor and the per-hand growth, together - and both the channel and the King
-- read it. Tuning 0240's dials moves the King with them from here on, which is
-- exactly what did not happen this morning.
--
-- AND THE KING IS COUNTED IN BEASTS, like everything else in this event has
-- been since 0227. Eight of what the region's average beast carries, so it is
-- a little over twice the biggest elite at every turnout instead of a ratio
-- that drifts with the room. `horde_king_hp_per_hand` is retired rather than
-- left sitting there meaning nothing.
--
-- Thirty minutes rather than twenty-five, because it is a great deal more
-- health and the King rising is the last thing anybody has to organise.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- One answer to "how big is a body in this tide"
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_world_scale(p_horde_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT (1 + h.rank * 0.6)
           * (game_config_value('horde_world_hp')
              + game_config_value('horde_world_hp_per_hand')
                * horde_hands(p_horde_id))
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_world_scale(BIGINT) IS
    'What a body in this tide is multiplied by: its depth, and the room that turned up. The channel and the King both read it, so they cannot drift apart the way they did between 0240 and 0241.';


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_beasts', 8,
     'The King''s health, counted in what the region''s average beast carries '
     'at this tide''s scale. Counted rather than set, so it stays a fixed '
     'multiple of the sea it comes after however the sea is tuned.');


-- ---------------------------------------------------------------------------
-- The channel reads it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_spawn';

    old := '    pool := GREATEST(1, round(species.base_hp
                              * (1 + tide.rank * 0.6)
                              * (game_config_value(''horde_world_hp'')
                                 + game_config_value(''horde_world_hp_per_hand'')
                                   * horde_hands(p_horde_id))
                              * CASE WHEN elite
                                     THEN game_config_value(''horde_elite_hp'')
                                     ELSE 1 END))::bigint;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_spawn no longer sizes a beast the 0240 way';
    END IF;

    EXECUTE replace(src, old,
        '    pool := GREATEST(1, round(species.base_hp
                              * horde_world_scale(p_horde_id)
                              * CASE WHEN elite
                                     THEN game_config_value(''horde_elite_hp'')
                                     ELSE 1 END))::bigint;');
END;
$$;


-- ---------------------------------------------------------------------------
-- And so does the King
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_king_rise';

    old := '    pool := GREATEST(1000,
        round(game_config_value(''horde_king_hp_per_hand'')
              * horde_hands(p_horde_id) * GREATEST(1, tide.rank)))::bigint;';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_king_rise no longer sizes the King the old way';
    END IF;

    EXECUTE replace(src, old,
        '    -- Counted in beasts of its own region, at the same scale the channel
    -- is sending them. Its own formula is what let it fall behind the trash
    -- it comes after when 0240 moved the channel and not the finale.
    pool := GREATEST(1000, round(
        COALESCE((SELECT avg(cs.base_hp)
                  FROM creature_regions cr
                  JOIN creature_species cs ON cs.species_id = cr.species_id
                  WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),
                 600)
        * horde_world_scale(p_horde_id)
        * game_config_value(''horde_king_beasts'')))::bigint;');
END;
$$;


UPDATE game_config SET value = 30,
    description = 'How long the King stands before it walks into the region. '
                  'Longer than a beast by far - it is the last thing anybody '
                  'has to organise around, and it carries eight of them.'
WHERE key = 'horde_king_minutes';

-- Retired rather than left meaning nothing. A dial nothing reads is the thing
-- this project keeps finding and deleting.
DELETE FROM game_config WHERE key = 'horde_king_hp_per_hand';


DO $$
DECLARE
    tide  BIGINT;
    king  BIGINT;
    who   BIGINT;
    n     INTEGER := 0;
    royal BIGINT;
    beast BIGINT;
BEGIN
    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 3::smallint, NULL);

        FOR who IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 3
        LOOP
            n := n + 1;
            INSERT INTO horde_contributions (horde_id, player_id, last_swing_at)
            VALUES (tide, who, now())
            ON CONFLICT (horde_id, player_id) DO UPDATE SET last_swing_at = now();
        END LOOP;

        -- The biggest thing the channel can send, for comparison.
        beast := round(
            COALESCE((SELECT avg(cs.base_hp) FROM creature_regions cr
                      JOIN creature_species cs ON cs.species_id = cr.species_id
                      WHERE cr.region_code = 'northern' AND cs.kind = 'beast'), 600)
            * horde_world_scale(tide)
            * game_config_value('horde_elite_hp'));

        UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = tide;
        king := horde_king_rise(tide);
        IF king IS NULL THEN
            RAISE EXCEPTION 'the King would not rise';
        END IF;
        SELECT e.max_hp INTO royal FROM horde_encounters e WHERE e.encounter_id = king;

        IF royal <= beast THEN
            RAISE EXCEPTION
                'the King carries % against an elite spawn''s %', royal, beast;
        END IF;

        -- Twice, not merely more: a finale that edges out the trash by a
        -- hair is the same complaint in a quieter voice.
        IF royal < beast * 2 THEN
            RAISE EXCEPTION
                'the King is only %x an elite spawn',
                round(royal::numeric / beast, 2);
        END IF;

        RAISE NOTICE 'King % against an elite spawn %', royal, beast;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
