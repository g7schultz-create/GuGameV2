-- 0215_the_deepest_rooms_pay_in_immortals
--
-- 0209 shut rank 6 and up out of the world's drops and 0213 held the dungeon
-- to the same line, on the grounds that a room handing out Immortal Gu while
-- every corpse in the game is barred from them would make
-- `gu_max_droppable_rank` a rule with a door beside it.
--
-- This is that door, opened on purpose and written down.
--
-- THE EXCEPTION IS NAMED, NOT SMUGGLED. `dungeon_jackpot_rank_bonus` is how
-- far above the world's ceiling the deepest rooms may reach, and it is 1. The
-- ceiling itself does not move: every corpse, every region table and every
-- other roll in the game still stops at rank 5, and the only thing that
-- reaches past it is a room whose OWN rank is past it. Set the bonus to 0 and
-- the door closes without touching anything else.
--
-- WHICH ROOM. Only one deep enough to be above the ceiling in the first place
-- - The Grave of Wills at rank 6 and the three below it. The rank 5 room can
-- clear all day and never see one, because a rank 5 room is not a rank 6
-- room. What it hands over is rank 6 exactly, so The First Burrow is not a
-- shortcut to rank 9 Gu; it is the same jackpot, guarded worse.
--
-- IT IS A JACKPOT, so it is rolled on its own and it is rare: 2% before
-- difficulty, against the 10% of the ordinary Gu roll. An Insane clear of the
-- rank 6 room is about one in fifteen. Weighted by rarity the way every other
-- Gu roll in the game is - mythic commonest, unique rarest - because a
-- jackpot that ignored rarity would make Unique the same thing as Mythic.
--
-- The ordinary Gu roll is untouched and still stops at the world's ceiling.
-- A clear can produce both.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_jackpot_rank_bonus', 1,
     'How far above gu_max_droppable_rank the deepest dungeons may reach, and '
     'the only exception to it in the game. A room may only reach past the '
     'ceiling if its own rank already is. Set to 0 to close the door.'),
    ('dungeon_jackpot_chance', 0.02,
     'Chance of the jackpot Gu per raider in a room deep enough to hold one, '
     'before difficulty. Deliberately a fifth of the ordinary Gu roll.');


CREATE OR REPLACE FUNCTION dungeon_spoils_for(
    p_player_id  BIGINT,
    p_rank       SMALLINT,
    p_scale      NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    lean    NUMERIC := sqrt(GREATEST(p_scale, 1));  -- difficulty, gently
    herbs   BIGINT  := round(game_config_value('dungeon_herb_per_rank')
                             * GREATEST(p_rank, 1) * p_scale);
    kinds   INTEGER := 2 + floor(random() * 2)::int;
    one     RECORD;
    got     JSONB := '{}'::jsonb;
    names   TEXT[] := '{}';
    n_pages INTEGER := 0;
    made    BIGINT;
    tier_hi SMALLINT;
    ceiling SMALLINT;
    jackpot SMALLINT;
BEGIN
    -- ---- herbs, always ---------------------------------------------------
    FOR one IN
        SELECT m.code, m.name FROM materials m
        WHERE m.tier IS NOT NULL AND m.tier <= GREATEST(p_rank, 1)
          AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
        ORDER BY random() LIMIT kinds
    LOOP
        -- Integer division on purpose: a pile of herbs is a count, and
        -- round() on a bigint would push the whole expression to a float that
        -- grant_material has no signature for.
        PERFORM grant_material(p_player_id, one.code,
                               GREATEST(1, herbs / kinds)::bigint);
        names := names || (GREATEST(1, herbs / kinds)::bigint || 'x ' || one.name);
    END LOOP;
    got := got || jsonb_build_object('herbs', to_jsonb(names));

    -- ---- pages -----------------------------------------------------------
    -- Pages stop at tier 7, so the top two rooms hand out the top page.
    tier_hi := LEAST(7, GREATEST(1, p_rank + 1))::smallint;
    IF random() < LEAST(0.95, game_config_value('dungeon_page_chance') * lean) THEN
        n_pages := 1 + floor(random() * GREATEST(1, round(lean)))::int;
        FOR i IN 1..n_pages LOOP
            PERFORM mint_page(p_player_id,
                              LEAST(tier_hi, GREATEST(1, p_rank))::smallint,
                              tier_hi, NULL, NULL, NULL);
        END LOOP;
    END IF;
    got := got || jsonb_build_object('pages', n_pages);

    -- ---- a piece ---------------------------------------------------------
    IF random() < LEAST(0.95, game_config_value('dungeon_equipment_chance') * lean) THEN
        made := dungeon_mint_equipment(p_player_id, p_rank, p_scale,
                                       coalesce(nullif(split_part(regexp_replace(
                                           (SELECT cs.name FROM dungeons d
                                            JOIN creature_species cs ON cs.species_id = d.species_id
                                            WHERE d.realm_rank = p_rank), '^The ', ''), ' ', 1), ''), 'Dungeon'));
        IF made IS NOT NULL THEN
            got := got || jsonb_build_object('equipment',
                (SELECT e.name FROM player_equipment e WHERE e.equipment_id = made));
        END IF;
    END IF;

    -- ---- a pill ----------------------------------------------------------
    IF random() < LEAST(0.95, game_config_value('dungeon_pill_chance') * lean) THEN
        made := dungeon_mint_pill(p_player_id, p_rank, p_scale);
        IF made IS NOT NULL THEN
            got := got || jsonb_build_object('pill',
                (SELECT pl.name FROM player_pills pl WHERE pl.pill_id = made));
        END IF;
    END IF;

    ceiling := game_config_value('gu_max_droppable_rank')::smallint;

    -- ---- a Gu ------------------------------------------------------------
    -- The ordinary roll still stops where the world stops.
    IF random() < LEAST(0.95, game_config_value('dungeon_gu_chance') * lean) THEN
        SELECT t.gu_type_id INTO made FROM gu_types t
        WHERE t.rank <= LEAST(GREATEST(p_rank, 1), ceiling)
        ORDER BY random() LIMIT 1;
        IF made IS NOT NULL THEN
            PERFORM grant_gu(p_player_id, made, NULL);
            got := got || jsonb_build_object('gu',
                (SELECT t.name FROM gu_types t WHERE t.gu_type_id = made));
        END IF;
    END IF;

    -- ---- the jackpot -----------------------------------------------------
    -- The one exception to the world's ceiling, and it is only open to a room
    -- that is already past it. What it hands over is that rank exactly, so
    -- the deepest room is not a shortcut past the others - it is the same
    -- prize, guarded worse.
    jackpot := ceiling + game_config_value('dungeon_jackpot_rank_bonus')::smallint;

    IF jackpot > ceiling AND p_rank >= jackpot
       AND random() < LEAST(0.95, game_config_value('dungeon_jackpot_chance') * lean)
    THEN
        -- Weighted by rarity, like every other Gu roll in the game. A jackpot
        -- that ignored rarity would make Unique mean the same as Mythic.
        SELECT t.gu_type_id INTO made
        FROM gu_types t
        JOIN rarities r ON r.code = t.rarity
        WHERE t.rank = jackpot
        ORDER BY -ln(random()) * r.sort_order
        LIMIT 1;

        IF made IS NOT NULL THEN
            PERFORM grant_gu(p_player_id, made, NULL);
            got := got || jsonb_build_object('jackpot',
                (SELECT t.name FROM gu_types t WHERE t.gu_type_id = made));
        END IF;
    END IF;

    RETURN got;
END;
$$;


-- ---------------------------------------------------------------------------
-- Opening the deep rooms until one pays
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who     BIGINT;
    got     JSONB;
    r       SMALLINT;
    n       INTEGER;
    hits    INTEGER := 0;
    ceiling SMALLINT := game_config_value('gu_max_droppable_rank')::smallint;
    jackpot SMALLINT;
BEGIN
    jackpot := ceiling + game_config_value('dungeon_jackpot_rank_bonus')::smallint;

    IF jackpot <> 6 THEN
        RAISE EXCEPTION 'the jackpot is rank % and rank 6 was the ask', jackpot;
    END IF;

    -- There has to be something to win, or the door opens onto a wall.
    SELECT count(*) INTO n FROM gu_types WHERE rank = jackpot;
    IF n = 0 THEN
        RAISE EXCEPTION 'nothing exists at rank % to be won', jackpot;
    END IF;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to loot for; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        -- The shallow rooms, hard, many times over. None of them may ever
        -- reach past the world's ceiling.
        FOR r IN 1..5 LOOP
            FOR i IN 1..40 LOOP
                PERFORM dungeon_spoils_for(who, r::smallint, 11.0);
            END LOOP;
        END LOOP;

        SELECT COALESCE(max(t.rank), 0) INTO n
        FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE g.owner_id = who;
        IF n > ceiling THEN
            RAISE EXCEPTION 'a rank % Gu came out of a room below the jackpot', n;
        END IF;

        -- And the deep ones do pay, given enough tries.
        FOR i IN 1..400 LOOP
            got := dungeon_spoils_for(who, jackpot, 11.0);
            IF got ? 'jackpot' THEN
                hits := hits + 1;
            END IF;
        END LOOP;

        IF hits = 0 THEN
            RAISE EXCEPTION 'four hundred clears of the deep room paid nothing';
        END IF;

        -- Never more than one rung past the ceiling, however deep the room.
        SELECT COALESCE(max(t.rank), 0) INTO n
        FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE g.owner_id = who;
        IF n > jackpot THEN
            RAISE EXCEPTION 'a rank % Gu was won from a rank % jackpot', n, jackpot;
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
