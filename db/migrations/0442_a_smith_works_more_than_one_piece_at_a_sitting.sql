-- 0442_a_smith_works_more_than_one_piece_at_a_sitting
--
-- `forge_many`, which the anvil has wanted since fusion arrived. A fuse needs
-- TWO pieces of the same slot, level and rank, and the only way to get a
-- second one was to press Forge again, and again, and again. The update that
-- made duplicates valuable made forging them one at a time tedious.
--
-- Built to match `refine_many` and `brew_many` rather than to its own taste:
-- the same `p_times` argument, the same per-profession run ladder, the same
-- everything-before-anything material check, the same summary shape. A third
-- batch function that worked a fourth way would be the thing to explain.
--
-- THE LADDER. `forge_runs`, eight steps at the same levels `gu_refine_runs`
-- and `alchemy_brews` use - 8, 18, 30, 44, 60, 78, 98, 120 - over a base of 2.
-- So a smith works two at a sitting until level 8 and ten at level 120. The
-- levels are copied deliberately: three professions that each pick their own
-- thresholds is three things to remember, and there is no reason for smithing
-- to breathe differently from refining.
--
-- EVERYTHING BEFORE ANYTHING, which is the whole reason this is a function and
-- not a loop in the bot. `forge` refuses when the ore runs out, so a bot-side
-- loop of ten would forge six, fail on the seventh and leave the player having
-- spent six lots of materials on a run they asked for as one action. The
-- shortfall is found first, named, and nothing is spent. `refine_many` carries
-- a comment saying exactly this and it is the same mistake here.
--
-- IT REPORTS WHAT IT MADE rather than what happened to it. Ten forgings is ten
-- lines of nothing anybody reads; what a smith wants back is the best piece,
-- how many held, and what it cost. The `made` array carries every piece so the
-- screen can show them, ordered best first.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES (
    'forge_base_runs', 2,
    'How many pieces a smith works at one sitting before the forge_runs ladder adds to it. Two, the same base Gu refining and alchemy use.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


INSERT INTO profession_steps (ladder, step, level_required) VALUES
    ('forge_runs', 1,   8),
    ('forge_runs', 2,  18),
    ('forge_runs', 3,  30),
    ('forge_runs', 4,  44),
    ('forge_runs', 5,  60),
    ('forge_runs', 6,  78),
    ('forge_runs', 7,  98),
    ('forge_runs', 8, 120);


CREATE OR REPLACE FUNCTION smith_max_runs(p_level smallint)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    SELECT (game_config_value('forge_base_runs')
            + ladder_steps('forge_runs', p_level))::smallint;
$fn$;

COMMENT ON FUNCTION smith_max_runs(smallint) IS
    'How many pieces a smith may work at one sitting. Two at the start and ten at level 120, on the same ladder Gu refining and alchemy climb.';


-- ---------------------------------------------------------------------------
-- The sitting
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION forge_many(
    p_player_id bigint,
    p_slot      text,
    p_ores      text[],
    p_ore_qtys  integer[],
    p_parts     text[],
    p_part_qtys integer[],
    p_times     integer DEFAULT 1)
RETURNS TABLE(
    attempts     integer,
    succeeded    integer,
    ruined       integer,
    spent_total  bigint,
    handed_back  bigint,
    exp_gained   bigint,
    level_after  smallint,
    best_harmony smallint,
    worst_harmony smallint,
    made         jsonb)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_skill SMALLINT;
    v_cap   SMALLINT;
    v_one   RECORD;
    v_short RECORD;
    v_ids   BIGINT[] := '{}';
    v_ok    INTEGER := 0;
    v_bad   INTEGER := 0;
    v_spent BIGINT := 0;
    v_back  BIGINT := 0;
    v_exp   BIGINT := 0;
    v_lvl   SMALLINT;
    v_best  SMALLINT := 0;
    v_worst SMALLINT := 150;
    i       INTEGER;
BEGIN
    IF COALESCE(p_times, 1) < 1 THEN
        RAISE EXCEPTION 'a sitting of no forgings is not a sitting'
            USING ERRCODE = 'check_violation';
    END IF;

    v_skill := profession_level(p_player_id, 'blacksmithing');
    v_cap   := smith_max_runs(v_skill);

    IF p_times > v_cap THEN
        RAISE EXCEPTION
            'your Blacksmithing works % at a sitting, not %', v_cap, p_times
            USING ERRCODE = 'check_violation';
    END IF;

    -- Everything, before anything. `forge` refuses on its own when the ore
    -- runs out, so a loop of ten would forge six and leave the seventh to
    -- fail with six lots of materials already spent on one asked-for action.
    SELECT w.code, material_name(w.code) AS name,
           w.quantity * p_times AS wanted,
           COALESCE((SELECT pm.quantity FROM player_materials pm
                     WHERE pm.player_id = p_player_id
                       AND pm.material_code = w.code), 0) AS held
    INTO v_short
    FROM (
        SELECT u.code, u.quantity
        FROM unnest(COALESCE(p_ores, '{}'::text[]),
                    COALESCE(p_ore_qtys, '{}'::integer[])) AS u (code, quantity)
        UNION ALL
        SELECT u.code, u.quantity
        FROM unnest(COALESCE(p_parts, '{}'::text[]),
                    COALESCE(p_part_qtys, '{}'::integer[])) AS u (code, quantity)
    ) w
    WHERE COALESCE((SELECT pm.quantity FROM player_materials pm
                    WHERE pm.player_id = p_player_id
                      AND pm.material_code = w.code), 0) < w.quantity * p_times
    ORDER BY w.code
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION
            '% forgings need % %, and you have %',
            p_times, v_short.wanted, v_short.name, v_short.held
            USING ERRCODE = 'check_violation';
    END IF;

    FOR i IN 1..p_times LOOP
        SELECT * INTO v_one
        FROM forge(p_player_id, p_slot, p_ores, p_ore_qtys,
                   p_parts, p_part_qtys);

        v_exp   := v_exp + COALESCE(v_one.exp_gained, 0);
        v_lvl   := v_one.level_after;
        v_spent := v_spent + COALESCE(v_one.spent_total, 0);
        v_back  := v_back + COALESCE(v_one.handed_back, 0);
        v_best  := GREATEST(v_best, COALESCE(v_one.harmony, 0));
        v_worst := LEAST(v_worst, COALESCE(v_one.harmony, 150));

        IF v_one.succeeded THEN
            v_ok  := v_ok + 1;
            v_ids := v_ids || v_one.equipment_id;
        ELSE
            v_bad := v_bad + 1;
        END IF;
    END LOOP;

    -- Every piece is its own row with its own rarity, quality and stats, and
    -- fusion eats them one at a time - so there is no merge step here, for the
    -- same reason `refine_many` has none.
    RETURN QUERY
    SELECT p_times, v_ok, v_bad, v_spent, v_back, v_exp,
           COALESCE(v_lvl, v_skill), v_best, v_worst,
           COALESCE(
               (SELECT jsonb_agg(jsonb_build_object(
                    'equipment_id', pe.equipment_id, 'name', pe.name,
                    'slot', pe.slot, 'tier', pe.tier, 'rarity', pe.rarity,
                    'quality', pe.quality, 'level', pe.level, 'rank', pe.rank,
                    'harmony', pe.harmony)
                    ORDER BY r.sort_order DESC, pe.harmony DESC)
                FROM player_equipment pe
                JOIN rarities r ON r.code = pe.rarity
                WHERE pe.equipment_id = ANY (v_ids)),
               '[]'::jsonb);
END;
$fn$;

COMMENT ON FUNCTION forge_many(bigint, text, text[], integer[], text[], integer[], integer) IS
    'A whole sitting at the anvil. Checks every material for the whole run before spending any of it, so a run that cannot finish costs nothing rather than most of it.';


-- ---------------------------------------------------------------------------
-- A run that cannot finish costs nothing, and one that can reports what it made
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who    BIGINT;
    v_before BIGINT;
    v_after  BIGINT;
    v_gear   INTEGER;
    v_said   TEXT;
    r        RECORD;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL
        ORDER BY profession_level(p.player_id, 'blacksmithing') DESC LIMIT 1;
        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- THE HEART OF IT: a run the player cannot afford must spend nothing.
        -- Give them exactly one forging's worth and ask for five.
        PERFORM grant_material(v_who, 'spirit_iron', 1000);
        SELECT COALESCE((SELECT pm.quantity FROM player_materials pm
                         WHERE pm.player_id = v_who
                           AND pm.material_code = 'spirit_iron'), 0)
        INTO v_before;
        SELECT count(*) INTO v_gear FROM player_equipment WHERE owner_id = v_who;

        BEGIN
            PERFORM forge_many(v_who, 'armour', ARRAY['spirit_iron'],
                               ARRAY[(v_before / 2)::integer],
                               ARRAY['dragon_scale'], ARRAY[1], 5);
            RAISE EXCEPTION 'a run nobody could afford was allowed to start';
        EXCEPTION WHEN check_violation THEN
            v_said := SQLERRM;
        END;

        SELECT COALESCE((SELECT pm.quantity FROM player_materials pm
                         WHERE pm.player_id = v_who
                           AND pm.material_code = 'spirit_iron'), 0)
        INTO v_after;
        IF v_after <> v_before THEN
            RAISE EXCEPTION
                'a refused run still spent %: % -> %',
                v_before - v_after, v_before, v_after;
        END IF;
        IF (SELECT count(*) FROM player_equipment WHERE owner_id = v_who)
           <> v_gear THEN
            RAISE EXCEPTION 'a refused run still made something';
        END IF;
        IF v_said NOT LIKE '%forgings need%' THEN
            RAISE EXCEPTION 'the refusal did not say what was short: %', v_said;
        END IF;

        -- And a run that CAN finish makes what it says it made. With a beast
        -- part in it: `forge` refuses ore alone - "ore alone is an ingot" -
        -- and the first draft of this probe was refused for exactly that.
        PERFORM grant_material(v_who, 'dragon_scale', 500);
        SELECT * INTO r FROM forge_many(v_who, 'armour', ARRAY['spirit_iron'],
                                        ARRAY[20], ARRAY['dragon_scale'],
                                        ARRAY[10], 3);
        IF r.attempts <> 3 THEN
            RAISE EXCEPTION 'asked for 3 and attempted %', r.attempts;
        END IF;
        IF r.succeeded + r.ruined <> 3 THEN
            RAISE EXCEPTION
                'three attempts came back as % made and % ruined',
                r.succeeded, r.ruined;
        END IF;
        IF jsonb_array_length(r.made) <> r.succeeded THEN
            RAISE EXCEPTION
                'reported % made but listed %',
                r.succeeded, jsonb_array_length(r.made);
        END IF;

        -- A sitting longer than the smith works is refused by the ladder
        -- rather than by running out of something.
        BEGIN
            PERFORM forge_many(v_who, 'armour', ARRAY['spirit_iron'], ARRAY[1],
                               ARRAY['dragon_scale'], ARRAY[1],
                               smith_max_runs(profession_level(v_who, 'blacksmithing')) + 1);
            RAISE EXCEPTION 'a smith worked more pieces than their level allows';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT s.level_required,
               game_config_value('forge_base_runs')::integer
                 + row_number() OVER (ORDER BY s.level_required) AS runs
        FROM profession_steps s WHERE s.ladder = 'forge_runs'
        ORDER BY s.level_required
    LOOP
        RAISE NOTICE 'Blacksmithing % works % at a sitting',
            lpad(r.level_required::text, 3), r.runs;
    END LOOP;
END;
$probe$;
