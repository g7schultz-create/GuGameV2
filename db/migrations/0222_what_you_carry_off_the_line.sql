-- 0222_what_you_carry_off_the_line
--
-- Three chests, at contribution rather than at rank on a table.
--
-- THRESHOLDS, NOT A PODIUM. A leaderboard that pays the top three pays the
-- three people who needed it least, and on a sixteen-player server it tells
-- the other thirteen not to bother. Every chest is reachable by turning up and
-- swinging; the third one wants a real afternoon. Contribution counts healing
-- at twice the rate of damage, because a support build lands less of it and
-- none of it is wasted on overkill.
--
-- THE CHESTS ARE PAID EITHER WAY. Losing already costs something - the region
-- carries the scourge for six hours and everybody who gathers there pays it.
-- Taking the individual reward away as well would charge the same mistake
-- twice, and would mean the correct play on a tide going badly is to walk out,
-- which is the opposite of what a defence should reward.
--
-- WHAT IS IN THEM is minted through the systems that already exist: herbs by
-- `grant_material`, pages by `mint_page`, eggs by `roll_beast_egg`, Gu by the
-- world's own ceiling. A chest is not a fourth place that decides what a page
-- is worth.
--
-- CLAIMED, NOT PUSHED. `chest_taken` is the highest chest a defender has
-- opened, so claiming twice cannot pay twice and a claim that arrives during a
-- disconnect is not lost.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION horde_chests_earned(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT (CASE
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= game_config_value('horde_chest_three') THEN 3
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= game_config_value('horde_chest_two')   THEN 2
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= game_config_value('horde_chest_one')   THEN 1
        ELSE 0
    END)::smallint;
$$;


CREATE FUNCTION horde_chest_take(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    tide   RECORD;
    stood  RECORD;
    earned SMALLINT;
    chest  SMALLINT;
    got    JSONB := '{}'::jsonb;
    names  TEXT[] := '{}';
    pages  INTEGER := 0;
    eggs   TEXT[] := '{}';
    stones BIGINT := 0;
    worms  TEXT[] := '{}';
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

    IF earned <= stood.chest_taken THEN
        RAISE EXCEPTION 'you have opened everything you earned'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything earned and not yet taken, in one opening.
    FOR chest IN (stood.chest_taken + 1)..earned LOOP
        -- Stones scale with the chest and the depth of the tide.
        stones := stones + round(600 * chest * GREATEST(1, tide.rank))::bigint;

        -- Herbs of the region, two kinds a chest.
        FOR one IN
            SELECT m.code, m.name FROM materials m
            JOIN region_materials rm ON rm.material_code = m.code
            WHERE rm.region_code = tide.region_code
              AND m.tier IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
            ORDER BY random() LIMIT 2
        LOOP
            PERFORM grant_material(p_player_id, one.code,
                                   (30 * chest * GREATEST(1, tide.rank))::bigint);
            names := names || ((30 * chest * GREATEST(1, tide.rank))::bigint
                               || 'x ' || one.name);
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

    IF stones > 0 THEN
        PERFORM grant_material(p_player_id, 'spirit_stone', stones);
    END IF;

    UPDATE horde_contributions c
    SET chest_taken = earned
    WHERE c.horde_id = p_horde_id AND c.player_id = p_player_id;

    got := jsonb_build_object(
        'chests', earned - stood.chest_taken,
        'through', earned,
        'stones', stones,
        'herbs', to_jsonb(names),
        'pages', pages,
        'eggs', to_jsonb(eggs),
        'gu', to_jsonb(worms));

    RETURN got;
END;
$$;


CREATE VIEW horde_roll AS
SELECT c.horde_id, c.player_id, p.discord_name,
       c.damage_dealt, c.healing_done, c.beasts_slain, c.elites_slain,
       horde_contribution(c.horde_id, c.player_id) AS contribution,
       horde_chests_earned(c.horde_id, c.player_id) AS chests_earned,
       c.chest_taken, c.last_swing_at,
       rank() OVER (PARTITION BY c.horde_id
                    ORDER BY horde_contribution(c.horde_id, c.player_id) DESC)
           AS standing
FROM horde_contributions c
JOIN players p ON p.player_id = c.player_id;

COMMENT ON VIEW horde_roll IS
    'Who held the line and what they are owed. Ranked for reading, but the chests are thresholds - the ranking pays nobody.';


DO $$
DECLARE
    tide BIGINT;
    who  BIGINT;
    got  JSONB;
    n    INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to pay; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        tide := horde_open('northern', 4::smallint, NULL);

        -- Somebody who did the work of all three chests.
        INSERT INTO horde_contributions (horde_id, player_id, damage_dealt)
        VALUES (tide, who, game_config_value('horde_chest_three')::bigint + 1);

        IF horde_chests_earned(tide, who) <> 3 THEN
            RAISE EXCEPTION 'three chests of work earned %',
                horde_chests_earned(tide, who);
        END IF;

        -- Nothing opens while it is still being fought.
        BEGIN
            PERFORM horde_chest_take(tide, who);
            RAISE EXCEPTION 'a chest opened mid-tide';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        UPDATE beast_hordes SET ends_at = now() - interval '1 minute'
        WHERE horde_id = tide;
        PERFORM horde_settle(tide);

        got := horde_chest_take(tide, who);
        IF (got->>'chests')::int <> 3 THEN
            RAISE EXCEPTION 'opening three chests gave %', got->>'chests';
        END IF;
        IF (got->>'stones')::bigint <= 0 THEN
            RAISE EXCEPTION 'a chest held no stones';
        END IF;
        IF jsonb_array_length(got->'eggs') = 0 THEN
            RAISE EXCEPTION 'the second chest held no egg';
        END IF;
        IF jsonb_array_length(got->'gu') = 0 THEN
            RAISE EXCEPTION 'the third chest held no Gu';
        END IF;

        -- And it cannot be opened twice.
        BEGIN
            PERFORM horde_chest_take(tide, who);
            RAISE EXCEPTION 'the same chest opened twice';
        EXCEPTION
            WHEN check_violation THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
