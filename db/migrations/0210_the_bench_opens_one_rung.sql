-- 0210_the_bench_opens_one_rung
--
-- 0209 shut rank 6 and up out of the world's DROPS and said so three times
-- over. It left the other door alone: refinement is gated by Gu Refiner level
-- and nothing else, so rank 9 was makeable by anyone who reached level 65.
--
-- Rank 6 is now deliberately open at the bench and 7, 8 and 9 are shut.
--
-- TWO DOORS, TWO CEILINGS. `gu_max_refinable_rank` is its own config rather
-- than a second reader of `gu_max_droppable_rank`, because dropping and making
-- are different achievements and this migration is the proof: they are 5 and
-- 6 today and the whole point is that they moved apart. Opening rank 7 later
-- is one UPDATE and it will not drag the drop table with it.
--
-- THE WORLD IS ASKED BEFORE THE PERSON. `refine_gu` checks the ceiling ahead
-- of the level, because when both are in the way only one of them is worth
-- telling somebody about. "A Wisdom Gu takes Gu Refiner level 52 and you are
-- 19" invites a grind that would not have worked; rank 8 is shut whatever the
-- refiner's level.
--
-- ONE FLAG, ONE MEANING. `gu_recipe_book.level_ok` becomes "the bench will
-- take this", world and level together, rather than "your level suffices" -
-- otherwise a level 65 refiner reading a rank 9 recipe would be told it was
-- In Reach while the bench refused it. The screen draws three states from that
-- flag and they have to be the three states that are real.
--
-- Nothing anybody can do today changes: rank 6 already asks for Gu Refiner
-- level 30, and the deepest refiner in the game is 19. This says where the
-- wall is, and moves it by one.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('gu_max_refinable_rank', 6,
     'The highest rank of Gu the bench will attempt. Separate from '
     'gu_max_droppable_rank on purpose: what the world hands out and what a '
     'refiner may make are different questions. Raise this to open rank 7.');


-- ---------------------------------------------------------------------------
-- refine_gu asks the world first
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
    new TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'refine_gu';

    old := '    skill := profession_level(p_player_id, ''gu_refining'');';
    -- One % each: this is a plain string literal, not a format() template,
    -- so it lands in the generated body exactly as written and RAISE reads it
    -- there.
    new := '    -- The ceiling the world set, before the one the refiner has
    -- reached. When both are in the way only one of them is worth telling
    -- somebody about: no amount of levelling opens a rank the bench has not
    -- been given.
    IF recipe.rank > game_config_value(''gu_max_refinable_rank'') THEN
        RAISE EXCEPTION
            ''a % is rank %, and the bench has not been opened past rank %'',
            recipe.gu_name, recipe.rank,
            game_config_value(''gu_max_refinable_rank'')
            USING ERRCODE = ''check_violation'';
    END IF;

    skill := profession_level(p_player_id, ''gu_refining'');';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'refine_gu no longer reads the refiner level the old way';
    END IF;

    EXECUTE replace(src, old, new);
END;
$$;


-- ---------------------------------------------------------------------------
-- The book says which door is shut
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION gu_recipe_book(p_player_id BIGINT)
RETURNS TABLE (
    gu_type_id BIGINT, gu_code TEXT, gu_name TEXT, emoji TEXT, rank SMALLINT,
    rarity TEXT, path_code TEXT, path_name TEXT, path_emoji TEXT, size SMALLINT,
    required_level SMALLINT, base_name TEXT, base_quantity INTEGER,
    base_held BIGINT, secondary_name TEXT, secondary_quantity INTEGER,
    secondary_held BIGINT, level_ok BOOLEAN, have_materials BOOLEAN,
    ready BOOLEAN, blocker TEXT
)
LANGUAGE sql STABLE
AS $$
    WITH standing AS (
        SELECT c.*,
               p.name AS path_name, p.emoji AS path_emoji,
               material_name(c.base_material) AS base_name,
               material_name(c.secondary_material) AS secondary_name,
               COALESCE(bm.quantity, 0) AS base_held,
               COALESCE(sm.quantity, 0) AS secondary_held,
               profession_level(p_player_id, 'gu_refining') AS level,
               game_config_value('gu_max_refinable_rank') AS ceiling
        FROM gu_recipe_costs c
        JOIN paths p ON p.code = c.path_code
        LEFT JOIN player_materials bm
               ON bm.player_id = p_player_id AND bm.material_code = c.base_material
        LEFT JOIN player_materials sm
               ON sm.player_id = p_player_id AND sm.material_code = c.secondary_material
    ),
    judged AS (
        SELECT s.*,
               -- "The bench will take this", which is the world and the
               -- refiner together. The screen draws three states off this and
               -- they have to be the three states that are real.
               (s.level >= s.required_level AND s.rank <= s.ceiling) AS level_ok,
               (s.base_held >= s.base_quantity
                AND s.secondary_held >= s.secondary_quantity) AS have_materials
        FROM standing s
    )
    SELECT
        j.gu_type_id, j.gu_code, j.gu_name, j.emoji, j.rank, j.rarity,
        j.path_code, j.path_name, j.path_emoji, j.size, j.required_level,
        j.base_name, j.base_quantity, j.base_held,
        j.secondary_name, j.secondary_quantity, j.secondary_held,
        j.level_ok, j.have_materials,
        (j.level_ok AND j.have_materials),
        CASE
            -- The shut door before the personal one, for the same reason
            -- refine_gu checks them in that order.
            WHEN j.rank > j.ceiling
                THEN 'rank ' || j.rank || ', and the bench stops at rank '
                     || j.ceiling
            WHEN j.level < j.required_level
                THEN 'Gu Refiner level ' || j.required_level
            WHEN j.have_materials THEN NULL
            -- The larger shortfall first: it is the one that decides whether
            -- the trip out is worth making.
            ELSE (
                SELECT string_agg(short, ', ' ORDER BY missing DESC)
                FROM (
                    SELECT j.base_quantity - j.base_held AS missing,
                           (j.base_quantity - j.base_held) || ' more '
                           || j.base_name AS short
                    WHERE j.base_held < j.base_quantity
                    UNION ALL
                    SELECT j.secondary_quantity - j.secondary_held,
                           (j.secondary_quantity - j.secondary_held) || ' more '
                           || j.secondary_name
                    WHERE j.secondary_held < j.secondary_quantity
                ) shortfall
            )
        END
    FROM judged j
    -- What you can start, then what only wants a trip out, then what wants a
    -- level. Within each, the cheap ones first: a book is read from the front.
    ORDER BY (j.level_ok AND j.have_materials) DESC, j.level_ok DESC,
             j.required_level, j.rank, j.gu_name;
$$;


-- ---------------------------------------------------------------------------
-- Asking the bench rather than trusting it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    six   BIGINT;
    seven BIGINT;
    n     BIGINT;
BEGIN
    IF game_config_value('gu_max_refinable_rank')
       <= game_config_value('gu_max_droppable_rank') THEN
        RAISE EXCEPTION 'the bench opens no further than the world, which makes it pointless';
    END IF;

    SELECT gu_type_id INTO six   FROM gu_types WHERE rank = 6 ORDER BY gu_type_id LIMIT 1;
    SELECT gu_type_id INTO seven FROM gu_types WHERE rank = 7 ORDER BY gu_type_id LIMIT 1;
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;

    IF who IS NULL OR six IS NULL OR seven IS NULL THEN
        RAISE NOTICE 'nothing to probe with; the tests carry it';
        RETURN;
    END IF;

    -- A refiner with every advantage, inside a subtransaction that is thrown
    -- away. Level 65 is past every gate the level ladder has, so whatever
    -- refuses rank 7 here refuses it for the world's reason and not theirs.
    BEGIN
        INSERT INTO player_professions (player_id, profession, exp, level)
        VALUES (who, 'gu_refining', 64 * 150, 65)
        ON CONFLICT (player_id, profession) DO UPDATE
            SET exp = 64 * 150, level = 65;

        INSERT INTO player_materials (player_id, material_code, quantity)
        SELECT who, code, 50000 FROM materials
        ON CONFLICT (player_id, material_code) DO UPDATE SET quantity = 50000;

        BEGIN
            PERFORM refine_gu(who, seven);
            RAISE EXCEPTION 'the bench made a rank 7 Gu';
        EXCEPTION
            WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%bench has not been opened%' THEN
                    RAISE EXCEPTION 'rank 7 was refused, but for the wrong reason: %', SQLERRM;
                END IF;
        END;

        -- And rank 6 gets past both gates. It may still fail on harmony -
        -- that is the bench working - but it must not be refused.
        PERFORM refine_gu(who, six);

        -- The book agrees with the bench, which is the whole point of one flag.
        SELECT count(*) INTO n FROM gu_recipe_book(who) b
        WHERE b.rank > game_config_value('gu_max_refinable_rank') AND b.level_ok;
        IF n > 0 THEN
            RAISE EXCEPTION '% shut recipes are drawn as within reach', n;
        END IF;

        SELECT count(*) INTO n FROM gu_recipe_book(who) b
        WHERE b.rank = 6 AND NOT b.level_ok;
        IF n > 0 THEN
            RAISE EXCEPTION '% rank 6 recipes are shut to a level 65 refiner', n;
        END IF;

        SELECT count(*) INTO n FROM gu_recipe_book(who) b
        WHERE NOT b.ready AND b.blocker IS NULL;
        IF n > 0 THEN
            RAISE EXCEPTION '% recipes are blocked by nothing anybody can read', n;
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
