-- 0234_a_horde_pays_in_beasts
--
-- The chests for killing several hundred beasts paid almost entirely in herbs.
--
-- A full rank 5 clear handed over about three thousand plants across nine
-- kinds and not one tusk, scale, feather or horn - from an event whose whole
-- subject is beasts pouring out of a region. Herbs come from gathering, which
-- is a thing anybody can do standing still. Beast materials come from killing
-- things, which is the only thing this event is.
--
-- SO THE HORDE IS HOW YOU STOCK BEAST MATERIALS. They are the headline of
-- every chest now, drawn from `creature_drops` through the region's own
-- roster - the parts of the beasts that were actually in the tide, weighted by
-- how readily each one drops in the field. You fought them; you carry them
-- off. The herbs stay, at a fifth of what they were: a handful of the local
-- plants is a reasonable thing to find on a battlefield, and three thousand of
-- them was the chest pretending to be a gathering trip.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_chest_beast_parts', 15,
     'Beast materials of each kind in a ladder chest, times the chest number '
     'and the tide''s rank. The headline of the reward: this event is the way '
     'to stock them.'),
    ('horde_king_chest_beast_parts', 60,
     'Beast materials of each kind in the King''s chest, times the tide''s '
     'rank.');


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
    many   BIGINT;
    one    RECORD;
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

    -- Everything earned and not yet taken, in one opening.
    FOR chest IN (stood.chest_taken + 1)..earned LOOP
        -- Stones scale with the chest and the depth of the tide.
        stones := stones + round(600 * chest * GREATEST(1, tide.rank))::bigint;

        -- ---- what the beasts were made of, which is the point -------------
        many := (game_config_value('horde_chest_beast_parts')
                 * chest * GREATEST(1, tide.rank))::bigint;

        FOR one IN
            SELECT m.code, m.name FROM (
                SELECT cd.material_code, max(cd.chance) AS chance
                FROM creature_regions cr
                JOIN creature_drops cd ON cd.species_id = cr.species_id
                WHERE cr.region_code = tide.region_code
                GROUP BY cd.material_code
            ) d
            JOIN materials m ON m.code = d.material_code
            -- Weighted the way the field weights it: a part that rarely comes
            -- off a beast is rarely in the chest either.
            ORDER BY -ln(random()) / d.chance
            LIMIT 3
        LOOP
            PERFORM grant_material(p_player_id, one.code, many);
            parts := parts || (many || 'x ' || one.name);
        END LOOP;

        -- A region whose roster drops nothing still owes what was advertised.
        IF parts = '{}' THEN
            FOR one IN
                SELECT m.code, m.name FROM materials m
                WHERE m.category = 'beast' ORDER BY random() LIMIT 3
            LOOP
                PERFORM grant_material(p_player_id, one.code, many);
                parts := parts || (many || 'x ' || one.name);
            END LOOP;
        END IF;

        -- ---- and a handful of the local plants ----------------------------
        -- A fifth of what this was. Finding some greenery on a battlefield is
        -- reasonable; finding a season's gathering is the chest pretending to
        -- be something it is not.
        many := (6 * chest * GREATEST(1, tide.rank))::bigint;

        FOR one IN
            SELECT m.code, m.name FROM materials m
            JOIN region_materials rm ON rm.material_code = m.code
            WHERE rm.region_code = tide.region_code
              AND m.tier IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
            ORDER BY random() LIMIT 2
        LOOP
            PERFORM grant_material(p_player_id, one.code, many);
            names := names || (many || 'x ' || one.name);
        END LOOP;

        -- A page a chest, at the tide's own depth.
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
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
            WHERE t.rank <= LEAST(GREATEST(tide.rank, 1),
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
                                 * GREATEST(1, tide.rank))::bigint;

        many := (game_config_value('horde_king_chest_beast_parts')
                 * GREATEST(1, tide.rank))::bigint;

        FOR one IN
            SELECT m.code, m.name FROM (
                SELECT cd.material_code, max(cd.chance) AS chance
                FROM creature_regions cr
                JOIN creature_drops cd ON cd.species_id = cr.species_id
                WHERE cr.region_code = tide.region_code
                GROUP BY cd.material_code
            ) d
            JOIN materials m ON m.code = d.material_code
            ORDER BY -ln(random()) / d.chance
            LIMIT 4
        LOOP
            PERFORM grant_material(p_player_id, one.code, many);
            parts := parts || (many || 'x ' || one.name);
        END LOOP;

        many := (30 * GREATEST(1, tide.rank))::bigint;

        FOR one IN
            SELECT m.code, m.name FROM materials m
            JOIN region_materials rm ON rm.material_code = m.code
            WHERE rm.region_code = tide.region_code
              AND m.tier IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
            ORDER BY random() LIMIT 3
        LOOP
            PERFORM grant_material(p_player_id, one.code, many);
            names := names || (many || 'x ' || one.name);
        END LOOP;

        -- Two pages, a rung deeper than the tide itself.
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 2))::smallint,
                          NULL, NULL, tide.region_code);
        PERFORM mint_page(p_player_id,
                          LEAST(7, GREATEST(1, tide.rank + 1))::smallint,
                          LEAST(7, GREATEST(1, tide.rank + 2))::smallint,
                          NULL, NULL, tide.region_code);
        pages := pages + 2;

        -- An egg of the region, a rank above what the tide would give.
        made := roll_beast_egg(p_player_id, (tide.rank + 1)::smallint,
                               tide.region_code);
        IF made IS NOT NULL THEN
            eggs := eggs || (SELECT s.name FROM player_egg_shelf s
                             WHERE s.egg_id = made);
        END IF;

        -- And the Gu the King is actually for: past the world's drop ceiling,
        -- the same way the deepest dungeon room reaches a rank 6.
        ceil_r := LEAST(GREATEST(tide.rank, 1)
                        + game_config_value('horde_king_gu_bonus')::int,
                        game_config_value('gu_max_droppable_rank')::int
                        + game_config_value('horde_king_gu_bonus')::int)::smallint;

        -- The top rung available, not a roll across everything under it.
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
    mats  BIGINT;
    herb  BIGINT;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to open one; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 3::smallint, NULL);

        INSERT INTO horde_contributions (horde_id, player_id, damage_dealt)
        VALUES (tide, who, 0)
        ON CONFLICT (horde_id, player_id) DO UPDATE SET damage_dealt = 0;
        UPDATE horde_contributions SET damage_dealt = horde_chest_bar(tide, 3::smallint)
        WHERE horde_id = tide AND player_id = who;

        UPDATE beast_hordes SET status = 'won', ended_at = now() WHERE horde_id = tide;

        SELECT count(*) INTO mats FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = who AND m.category = 'beast';

        took := horde_chest_take(tide, who);

        IF jsonb_array_length(took -> 'parts') < 1 THEN
            RAISE EXCEPTION 'a horde chest held no beast materials';
        END IF;

        -- Everything named in `parts` is actually a beast material, so the
        -- screen is not calling herbs something else.
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements_text(took -> 'parts') AS said
            WHERE NOT EXISTS (
                SELECT 1 FROM materials m
                WHERE m.category = 'beast'
                  AND said.value LIKE '%' || m.name)) THEN
            RAISE EXCEPTION 'something in the beast parts is not a beast part';
        END IF;

        -- And the beasts outweigh the greenery, which is the whole change.
        SELECT sum(split_part(said.value, 'x ', 1)::bigint) INTO mats
        FROM jsonb_array_elements_text(took -> 'parts') AS said;
        SELECT COALESCE(sum(split_part(said.value, 'x ', 1)::bigint), 0) INTO herb
        FROM jsonb_array_elements_text(took -> 'herbs') AS said;

        IF mats <= herb THEN
            RAISE EXCEPTION 'the chest paid % in plants and only % in beasts',
                herb, mats;
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
