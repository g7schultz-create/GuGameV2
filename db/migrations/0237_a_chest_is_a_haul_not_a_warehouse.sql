-- 0237_a_chest_is_a_haul_not_a_warehouse
--
-- 0234 made the horde pay in beast materials and did not check the number
-- against anything else in the game.
--
-- Measured at rank 5: a full four chest opening handed over about 2,550 beast
-- materials and 810 herbs. A hard dungeon clear at the same depth gives 175
-- materials. A hunt kill gives 1.8. So one horde was nineteen dungeons, or
-- fourteen hundred kills - for an event that also pays stones, pages, eggs and
-- two Gu. Every other way of getting a tusk became pointless in an afternoon.
--
-- SO THE PILE IS THE THING THAT SHRINKS, by about nine times, landing a full
-- clear at roughly twice a hard dungeon. The horde should be the best source
-- of beast materials in the game - it is a two hour event that needs a room -
-- but "best" is a multiple near two, not near twenty.
--
-- AND A CHEST IS A HAUL, so it stops being a fixed list. Three kinds at
-- exactly 15 x N x rank every single time is a receipt, not a reward: the same
-- three commons at the same three numbers, opening after opening. Now each
-- chest rolls how many kinds it holds and splits its pile across them
-- unevenly, and the pick is weighted by the square root of the field chance
-- rather than the chance itself - so the uncommon parts actually surface
-- instead of losing every roll to Beast Blood.
--
-- The pile is what is controlled, not the per-kind number. More kinds means
-- less of each, which is what keeps the total honest however the roll lands.
-- It is the shape `dungeon_spoils_for` already uses for its herbs.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 5,
    description = 'The beast material pile in a ladder chest, times the chest '
                  'number and the tide''s rank - split across however many '
                  'kinds that chest happens to roll. The pile is the dial; the '
                  'per-kind number falls out of it.'
WHERE key = 'horde_chest_beast_parts';

UPDATE game_config SET value = 20,
    description = 'The beast material pile in the King''s chest, times the '
                  'tide''s rank.'
WHERE key = 'horde_king_chest_beast_parts';

INSERT INTO game_config (key, value, description) VALUES
    ('horde_chest_herbs', 2,
     'The herb pile in a ladder chest, times the chest number and the rank. '
     'A handful of local greenery off a battlefield - gathering is where herbs '
     'come from.'),
    ('horde_king_chest_herbs', 10,
     'The herb pile in the King''s chest, times the tide''s rank.');


-- ---------------------------------------------------------------------------
-- Spilling a pile across a random handful of kinds
-- ---------------------------------------------------------------------------
-- Four copies of this loop had accumulated in `horde_chest_take`. One place,
-- so the next change to how a chest pays does not have to be made four times.

CREATE FUNCTION horde_spill_parts(
    p_player_id BIGINT, p_region TEXT, p_pile BIGINT, p_kinds INTEGER
)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $$
DECLARE
    said TEXT[] := '{}';
    each BIGINT;
    one  RECORD;
BEGIN
    FOR one IN
        SELECT m.code, m.name FROM (
            SELECT cd.material_code, max(cd.chance) AS chance
            FROM creature_regions cr
            JOIN creature_drops cd ON cd.species_id = cr.species_id
            WHERE cr.region_code = p_region
            GROUP BY cd.material_code
        ) d
        JOIN materials m ON m.code = d.material_code
        -- sqrt, not the chance itself. Weighting by the raw field chance meant
        -- a part that drops one time in twenty lost every roll to one that
        -- drops four in five, and the chests read as the same three commons
        -- forever. This still favours the common ones, by about half as much.
        ORDER BY -ln(random()) / sqrt(d.chance)
        LIMIT p_kinds
    LOOP
        -- Uneven on purpose: three identical numbers is what made an opening
        -- look printed. The pile is what is controlled, not the shares.
        each := GREATEST(1, round(p_pile::numeric / p_kinds
                                  * (0.6 + random() * 0.8)))::bigint;
        PERFORM grant_material(p_player_id, one.code, each);
        said := said || (each || 'x ' || one.name);
    END LOOP;

    -- A region whose roster drops nothing still owes what was advertised.
    IF said = '{}' THEN
        FOR one IN
            SELECT m.code, m.name FROM materials m
            WHERE m.category = 'beast' ORDER BY random() LIMIT p_kinds
        LOOP
            each := GREATEST(1, round(p_pile::numeric / p_kinds
                                      * (0.6 + random() * 0.8)))::bigint;
            PERFORM grant_material(p_player_id, one.code, each);
            said := said || (each || 'x ' || one.name);
        END LOOP;
    END IF;

    RETURN said;
END;
$$;

COMMENT ON FUNCTION horde_spill_parts(BIGINT, TEXT, BIGINT, INTEGER) IS
    'Split a pile of beast materials across a handful of the region''s own kinds, unevenly. The pile is the controlled number; what it is divided into is the roll.';


CREATE FUNCTION horde_spill_herbs(
    p_player_id BIGINT, p_region TEXT, p_pile BIGINT, p_kinds INTEGER
)
RETURNS TEXT[]
LANGUAGE plpgsql
AS $$
DECLARE
    said TEXT[] := '{}';
    each BIGINT;
    one  RECORD;
BEGIN
    FOR one IN
        SELECT m.code, m.name FROM materials m
        JOIN region_materials rm ON rm.material_code = m.code
        WHERE rm.region_code = p_region
          AND m.tier IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
        ORDER BY random() LIMIT p_kinds
    LOOP
        each := GREATEST(1, round(p_pile::numeric / p_kinds
                                  * (0.6 + random() * 0.8)))::bigint;
        PERFORM grant_material(p_player_id, one.code, each);
        said := said || (each || 'x ' || one.name);
    END LOOP;

    RETURN said;
END;
$$;


-- ---------------------------------------------------------------------------
-- The chest
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION horde_chest_take(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    tide   RECORD;
    stood  RECORD;
    earned SMALLINT;
    chest  SMALLINT;
    crown  BOOLEAN;
    got    JSONB := '{}'::jsonb;
    names  TEXT[] := '{}';
    parts  TEXT[] := '{}';
    pages  INTEGER := 0;
    eggs   TEXT[] := '{}';
    stones BIGINT := 0;
    worms  TEXT[] := '{}';
    ceil_r SMALLINT;
    deep   INTEGER;
    made   BIGINT;
BEGIN
    SELECT * INTO tide FROM beast_hordes WHERE horde_id = p_horde_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'there was no such tide' USING ERRCODE = 'check_violation';
    END IF;
    IF tide.status NOT IN ('won', 'lost') THEN
        RAISE EXCEPTION 'the tide is not over yet' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO stood FROM horde_contributions c
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you were not on that line' USING ERRCODE = 'check_violation';
    END IF;

    earned := horde_chests_earned(p_horde_id, p_player_id);
    crown  := horde_king_chest_due(p_horde_id, p_player_id);

    IF earned <= stood.chest_taken AND NOT crown THEN
        RAISE EXCEPTION 'you have opened everything you earned'
            USING ERRCODE = 'check_violation';
    END IF;

    deep := GREATEST(1, tide.rank);

    -- Everything earned and not yet taken, in one opening.
    FOR chest IN (stood.chest_taken + 1)..earned LOOP
        stones := stones + round(600 * chest * deep)::bigint;

        -- Two to four kinds of beast material, and one or two of greenery.
        parts := parts || horde_spill_parts(
            p_player_id, tide.region_code,
            (game_config_value('horde_chest_beast_parts') * chest * deep)::bigint,
            2 + floor(random() * 3)::int);

        names := names || horde_spill_herbs(
            p_player_id, tide.region_code,
            (game_config_value('horde_chest_herbs') * chest * deep)::bigint,
            1 + floor(random() * 2)::int);

        -- A page a chest, at the tide's own depth.
        PERFORM mint_page(p_player_id,
                          LEAST(7, deep)::smallint,
                          LEAST(7, deep + 1)::smallint,
                          NULL, NULL, tide.region_code);
        pages := pages + 1;

        -- An egg from the second chest, of the region's own beasts.
        IF chest >= 2 THEN
            made := roll_beast_egg(p_player_id, tide.rank, tide.region_code);
            IF made IS NOT NULL THEN
                eggs := eggs || (SELECT s.name FROM player_egg_shelf s
                                 WHERE s.egg_id = made);
            END IF;
        END IF;

        -- And a Gu from the third, inside the world's own ceiling.
        IF chest >= 3 THEN
            SELECT t.gu_type_id INTO made FROM gu_types t
            JOIN rarities r ON r.code = t.rarity
            WHERE t.rank <= LEAST(deep,
                                  game_config_value('gu_max_droppable_rank'))
            ORDER BY -ln(random()) * r.sort_order
            LIMIT 1;
            IF made IS NOT NULL THEN
                PERFORM grant_gu(p_player_id, made, tide.region_code);
                worms := worms || (SELECT t.name FROM gu_types t
                                   WHERE t.gu_type_id = made);
            END IF;
        END IF;
    END LOOP;

    -- ---- and the King's, which is not a threshold -------------------------
    IF crown THEN
        stones := stones + round(game_config_value('horde_king_chest_stones')
                                 * deep)::bigint;

        parts := parts || horde_spill_parts(
            p_player_id, tide.region_code,
            (game_config_value('horde_king_chest_beast_parts') * deep)::bigint,
            3 + floor(random() * 4)::int);

        names := names || horde_spill_herbs(
            p_player_id, tide.region_code,
            (game_config_value('horde_king_chest_herbs') * deep)::bigint,
            2 + floor(random() * 2)::int);

        -- Two pages, a rung deeper than the tide itself.
        PERFORM mint_page(p_player_id,
                          LEAST(7, deep + 1)::smallint,
                          LEAST(7, deep + 2)::smallint,
                          NULL, NULL, tide.region_code);
        PERFORM mint_page(p_player_id,
                          LEAST(7, deep + 1)::smallint,
                          LEAST(7, deep + 2)::smallint,
                          NULL, NULL, tide.region_code);
        pages := pages + 2;

        -- An egg of the region, a rank above what the tide would give.
        made := roll_beast_egg(p_player_id, (tide.rank + 1)::smallint,
                               tide.region_code);
        IF made IS NOT NULL THEN
            eggs := eggs || (SELECT s.name FROM player_egg_shelf s
                             WHERE s.egg_id = made);
        END IF;

        -- And the Gu the King is actually for: past the world's drop ceiling.
        ceil_r := LEAST(deep + game_config_value('horde_king_gu_bonus')::int,
                        game_config_value('gu_max_droppable_rank')::int
                        + game_config_value('horde_king_gu_bonus')::int)::smallint;

        SELECT t.gu_type_id INTO made FROM gu_types t
        JOIN rarities r ON r.code = t.rarity
        WHERE t.rank = ceil_r
        ORDER BY -ln(random()) * r.sort_order
        LIMIT 1;

        IF made IS NULL THEN
            SELECT t.gu_type_id INTO made FROM gu_types t
            JOIN rarities r ON r.code = t.rarity
            WHERE t.rank <= ceil_r
            ORDER BY t.rank DESC, -ln(random()) * r.sort_order
            LIMIT 1;
        END IF;

        IF made IS NOT NULL THEN
            PERFORM grant_gu(p_player_id, made, tide.region_code);
            worms := worms || (SELECT t.name FROM gu_types t
                               WHERE t.gu_type_id = made);
        END IF;

        UPDATE horde_contributions c
        SET king_chest_taken = TRUE
        WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;
    END IF;

    IF stones > 0 THEN
        PERFORM grant_material(p_player_id, 'spirit_stone', stones);
    END IF;

    UPDATE horde_contributions c
    SET chest_taken = earned
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;

    got := jsonb_build_object(
        'chests', GREATEST(0, earned - stood.chest_taken)
                  + CASE WHEN crown THEN 1 ELSE 0 END,
        'through', earned,
        'king', crown,
        'stones', stones,
        'parts', to_jsonb(parts),
        'herbs', to_jsonb(names),
        'pages', pages,
        'eggs', to_jsonb(eggs),
        'gu', to_jsonb(worms));

    RETURN got;
END;
$$;


DO $$
DECLARE
    tide  BIGINT;
    who   BIGINT;
    took  JSONB;
    haul  BIGINT;
    room  BIGINT;
    seen  TEXT := '';
    twice BOOLEAN := FALSE;
    n     INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to open one; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- A hard dungeon clear at the same depth, for scale.
        room := round(game_config_value('dungeon_herb_per_rank') * 5 * 2.5);

        FOR n IN 1..6 LOOP
            UPDATE beast_hordes SET status = 'won', ended_at = now()
            WHERE status IN ('fighting', 'king');
            tide := horde_open('northern', 5::smallint, NULL);

            INSERT INTO horde_contributions (horde_id, player_id, damage_dealt)
            VALUES (tide, who, 0)
            ON CONFLICT (horde_id, player_id) DO UPDATE SET damage_dealt = 0;
            UPDATE horde_contributions
            SET damage_dealt = horde_chest_bar(tide, 3::smallint)
            WHERE horde_id = tide AND player_id = who;
            UPDATE beast_hordes SET status = 'won', ended_at = now()
            WHERE horde_id = tide;

            took := horde_chest_take(tide, who);

            SELECT COALESCE(sum(split_part(x.value, 'x ', 1)::bigint), 0)
            INTO haul
            FROM (SELECT jsonb_array_elements_text(took -> 'parts') AS value
                  UNION ALL
                  SELECT jsonb_array_elements_text(took -> 'herbs')) x;

            -- Three ladder chests should land near twice a hard dungeon, not
            -- near twenty times it.
            IF haul > room * 6 THEN
                RAISE EXCEPTION
                    'a three chest haul is % materials against a dungeon''s %',
                    haul, room;
            END IF;

            -- And it must not read the same twice running.
            IF seen <> '' AND seen <> (took -> 'parts')::text THEN
                twice := TRUE;
            END IF;
            seen := (took -> 'parts')::text;
        END LOOP;

        IF NOT twice THEN
            RAISE EXCEPTION 'six openings all spilled the identical parts';
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
