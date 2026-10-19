-- 0286_the_beast_says_what_it_did
--
-- `player_swing` has returned `pet_dealt` and `pet_name` since 0278, and as
-- of 0285 `player_take` returns what the beast covered. Not one lane passed
-- any of it upward. Every signature stopped at the cultivator, so the numbers
-- were computed, folded into the totals, and thrown away before Discord ever
-- saw them - which is why the report that started this was "I don't see their
-- attack in boss fight". It was there. Nothing printed it.
--
-- This widens three lanes to carry it: the world beast, the gauntlet, and the
-- ordinary tide. `battle_act` and the dungeon are their own migration because
-- one has four return sites and the other answers in jsonb, and doing all
-- five in one go is how 0277 broke every swing in the game.
--
-- EVERY PATCH HERE IS A LIFT. `pg_get_functiondef`, an asserted replace, and
-- EXECUTE. Nothing is retyped from memory. That rule exists because breaking
-- it once took live combat down for four minutes.
--
-- WHY A SEPARATE VARIABLE FOR THE COVER. In `strike_boss` and
-- `horde_gauntlet_swing` the `took` record is only assigned on the branch
-- where something actually swings back - kill the boss outright, or go down
-- before it answers, and `took` is never assigned at all. Reading
-- `took.covered` at the return would then raise, so the cover is copied into
-- a plain variable that starts at zero on the branch that has it.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The world beast
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'strike_boss';

    IF body IS NULL THEN
        RAISE EXCEPTION 'strike_boss is missing';
    END IF;

    -- Four anchors, each of which must appear exactly once.
    IF (length(body) - length(replace(body, '    took      RECORD;', '')))
       / length('    took      RECORD;') <> 1 THEN
        RAISE EXCEPTION 'strike_boss: took declaration is not unique';
    END IF;
    IF (length(body) - length(replace(body, '        back := took.taken;', '')))
       / length('        back := took.taken;') <> 1 THEN
        RAISE EXCEPTION 'strike_boss: the bite anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, 'strikes_left integer, slain boolean, my_damage bigint)', '')))
       / length('strikes_left integer, slain boolean, my_damage bigint)') <> 1 THEN
        RAISE EXCEPTION 'strike_boss: the signature anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, '        allowed - spent - 1, killed, mine;', '')))
       / length('        allowed - spent - 1, killed, mine;') <> 1 THEN
        RAISE EXCEPTION 'strike_boss: the return anchor is not unique';
    END IF;

    body := replace(body, '    took      RECORD;',
        '    took      RECORD;' || chr(10) ||
        '    pet_took  BIGINT := 0;' || chr(10) ||
        '    pet_fell  BOOLEAN := FALSE;');

    body := replace(body, '        back := took.taken;',
        '        back := took.taken;' || chr(10) ||
        '        pet_took := COALESCE(took.covered, 0);' || chr(10) ||
        '        pet_fell := COALESCE(took.pet_down, FALSE);');

    body := replace(body,
        'strikes_left integer, slain boolean, my_damage bigint)',
        'strikes_left integer, slain boolean, my_damage bigint, ' ||
        'pet_dealt bigint, pet_name text, pet_covered bigint, pet_down boolean)');

    body := replace(body, '        allowed - spent - 1, killed, mine;',
        '        allowed - spent - 1, killed, mine,' || chr(10) ||
        '        COALESCE(swung.pet_dealt, 0), swung.pet_name, pet_took, pet_fell;');

    DROP FUNCTION strike_boss(BIGINT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The gauntlet
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_gauntlet_swing';

    IF body IS NULL THEN
        RAISE EXCEPTION 'horde_gauntlet_swing is missing';
    END IF;

    IF (length(body) - length(replace(body, '    took      RECORD;', '')))
       / length('    took      RECORD;') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: took declaration is not unique';
    END IF;
    IF (length(body) - length(replace(body, '        hurt := took.taken;', '')))
       / length('        hurt := took.taken;') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the bite anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, 'run_status text, sea_left integer)', '')))
       / length('run_status text, sea_left integer)') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the signature anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, '        horde_sea_left(run.horde_id);', '')))
       / length('        horde_sea_left(run.horde_id);') <> 1 THEN
        RAISE EXCEPTION 'gauntlet: the return anchor is not unique';
    END IF;

    body := replace(body, '    took      RECORD;',
        '    took      RECORD;' || chr(10) ||
        '    pet_took  BIGINT := 0;' || chr(10) ||
        '    pet_fell  BOOLEAN := FALSE;');

    body := replace(body, '        hurt := took.taken;',
        '        hurt := took.taken;' || chr(10) ||
        '        pet_took := COALESCE(took.covered, 0);' || chr(10) ||
        '        pet_fell := COALESCE(took.pet_down, FALSE);');

    body := replace(body, 'run_status text, sea_left integer)',
        'run_status text, sea_left integer, ' ||
        'pet_dealt bigint, pet_name text, pet_covered bigint, pet_down boolean)');

    body := replace(body, '        horde_sea_left(run.horde_id);',
        '        horde_sea_left(run.horde_id),' || chr(10) ||
        '        COALESCE(swung.pet_dealt, 0), swung.pet_name, pet_took, pet_fell;');

    DROP FUNCTION horde_gauntlet_swing(BIGINT, TEXT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The ordinary tide. Nothing swings back here, so the beast only attacks.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_strike';

    IF body IS NULL THEN
        RAISE EXCEPTION 'horde_strike is missing';
    END IF;

    IF (length(body) - length(replace(body, 'strikes smallint, crits smallint)', '')))
       / length('strikes smallint, crits smallint)') <> 1 THEN
        RAISE EXCEPTION 'tide: the signature anchor is not unique';
    END IF;
    IF (length(body) - length(replace(body, '                        swung.strikes, swung.crits;', '')))
       / length('                        swung.strikes, swung.crits;') <> 1 THEN
        RAISE EXCEPTION 'tide: the return anchor is not unique';
    END IF;

    body := replace(body, 'strikes smallint, crits smallint)',
        'strikes smallint, crits smallint, pet_dealt bigint, pet_name text)');

    body := replace(body, '                        swung.strikes, swung.crits;',
        '                        swung.strikes, swung.crits,' || chr(10) ||
        '                        COALESCE(swung.pet_dealt, 0), swung.pet_name;');

    DROP FUNCTION horde_strike(BIGINT, BIGINT);
    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The shelf says what a beast has left in it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW player_beast_shelf AS
SELECT b.beast_id, b.owner_id, b.name, b.tier, b.rarity, b.at_heel,
       b.hatched_at,
       cs.name AS species, cs.rank AS species_rank, cs.kind AS species_kind,
       q.emoji, q.word AS shell,
       r.sort_order AS rarity_order,
       p.name AS path_name, p.emoji AS path_emoji,
       round(pet_attack(b.beast_id)) AS attack,
       reg.name AS found_in_name,
       b.stage, b.fed,
       st.name AS stage_name, st.sort_order AS stage_order, st.power AS stage_power,
       beast_feed_needed(b.beast_id) AS wants,
       round(beast_render_value(b.beast_id)) AS worth_as_food,
       pet_hp(b.beast_id) AS hp,
       pet_max_hp(b.beast_id) AS max_hp,
       (pet_hp(b.beast_id) <= 0) AS is_down
FROM player_beasts b
JOIN creature_species cs ON cs.species_id = b.species_id
JOIN rarities r ON r.code = b.rarity
JOIN beast_stages st ON st.code = b.stage
LEFT JOIN egg_qualities q ON q.rarity = b.rarity
LEFT JOIN paths p ON p.code = pet_path(b.beast_id)
LEFT JOIN player_beast_eggs e ON e.egg_id = b.egg_id
LEFT JOIN regions reg ON reg.code = e.found_in;


-- ---------------------------------------------------------------------------
-- The three lanes carry it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    missing TEXT := '';
BEGIN
    IF pg_get_function_result(
           (SELECT oid FROM pg_proc WHERE proname = 'strike_boss'))
       NOT LIKE '%pet_dealt%' THEN
        missing := missing || ' strike_boss';
    END IF;
    IF pg_get_function_result(
           (SELECT oid FROM pg_proc WHERE proname = 'horde_gauntlet_swing'))
       NOT LIKE '%pet_covered%' THEN
        missing := missing || ' horde_gauntlet_swing';
    END IF;
    IF pg_get_function_result(
           (SELECT oid FROM pg_proc WHERE proname = 'horde_strike'))
       NOT LIKE '%pet_dealt%' THEN
        missing := missing || ' horde_strike';
    END IF;

    IF missing <> '' THEN
        RAISE EXCEPTION 'these lanes still swallow the beast:%', missing;
    END IF;

    -- And the shelf answers for a body as well as a blow.
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'player_beast_shelf' AND column_name = 'max_hp'
    ) THEN
        RAISE EXCEPTION 'the shelf does not say what a beast has left';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- The world beast still answers, and now says what the beast beside you did
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    got   RECORD;
BEGIN
    SELECT b.owner_id INTO who
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    JOIN player_techniques pt ON pt.player_id = b.owner_id
    WHERE b.at_heel
    GROUP BY b.owner_id
    ORDER BY max(b.tier) DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast and knows a technique; the tests carry this';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM boss_encounters WHERE status = 'active') THEN
        RAISE NOTICE 'no beast is standing to swing at; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        SELECT * INTO got FROM strike_boss(who, NULL);

        IF got.pet_dealt IS NULL THEN
            RAISE EXCEPTION 'the boss lane returned a null for the beast''s blow';
        END IF;
        IF got.pet_dealt > 0 AND got.pet_name IS NULL THEN
            RAISE EXCEPTION 'the beast hit for % and would not give its name',
                got.pet_dealt;
        END IF;

        RAISE NOTICE 'the beast beside % struck the world beast for %',
            who, got.pet_dealt;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
