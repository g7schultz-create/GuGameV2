-- 0497_the_dungeon_stops_guessing_what_a_party_hits_for
--
-- 0496 let the realm-scaled lid reach combat, and every content lane resized
-- itself except one. The boss pool reads `player_blow_multiple`, the horde
-- reads `player_stat`, the Trial and the delve rehearse. The dungeon reads a
-- number:
--
--     base_hp x difficulty hp_scale x (1 + step x (raiders - 1))
--
-- No term in that mentions the party. So the deepest room in the game, The
-- Last Apricot at realm 18, holds 2.950e13 on insane with six raiders - and
-- one cultivator's single swing is now 2.35e15. Seventy-nine times the whole
-- boss, from one blow, before anybody else in the party moves.
--
-- AND IT WAS ALREADY BROKEN BEFORE I TOUCHED ANYTHING. At the old flat caps
-- that same swing was 5.055e14, which is still seventeen times the boss. The
-- spec says "the deepest dungeon in the game dies to three cultivators in a
-- single round"; it dies to one of them in a fraction of one swing, and has
-- for a while. 0496 made an existing hole deeper rather than digging it.
--
-- WHICH IS WHY THIS IS NOT A MULTIPLIER. Multiplying `base_hp` by eighty
-- would fit today's roster and be wrong again the next time anything moves -
-- and this is the second time this month a fitted number has rotted. 0454 hit
-- exactly this in the Trial and the answer there was to stop guessing:
-- rehearse the party through the real damage pipeline in a subtransaction and
-- roll it back. 0467 did the same for the delve. The dungeon is the last lane
-- still working from a formula, so it gets the same treatment, copied rather
-- than reinvented - `dungeon_rehearse` is `trial_rehearse` with the party
-- read from `dungeon_raiders`.
--
-- WHAT A ROOM IS WORTH IS STILL A DESIGN CHOICE. The rehearsal says what the
-- party does in a round; `dungeon_rounds_expected` says how many rounds a
-- room should last, and difficulty still multiplies. So `insane` is still
-- 6.5x `normal` and the knobs stay where they were - they just multiply
-- something true now.
--
-- THE FLOOR MATTERS MORE THAN IT LOOKS. A party nobody can rehearse - no
-- technique between them - must not get a boss with 1 HP, and must not get
-- one sized off the old formula either, because the old formula is the thing
-- being replaced. It falls back to the formula ONLY in that case, which is
-- the same choice `trial_boss_hp` made.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A round of the real pipeline, then rolled back
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_rehearse(p_run_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_def  BIGINT;
    v_sum  BIGINT := 0;
    v_n    INTEGER;
    v_move BIGINT;
    one    RECORD;
    swung  RECORD;
    i      INTEGER;
BEGIN
    v_n := GREATEST(1, game_config_value('dungeon_rehearsal_rounds')::int);
    SELECT s.base_defense INTO v_def FROM creature_species s
    WHERE s.species_id = p_species_id;
    IF v_def IS NULL THEN
        RETURN 0;
    END IF;

    BEGIN
        FOR i IN 1..v_n LOOP
            FOR one IN
                SELECT r.player_id, COALESCE(pp.max_hp, 1) AS max_hp
                FROM dungeon_raiders r
                LEFT JOIN player_physique pp ON pp.player_id = r.player_id
                WHERE r.run_id = p_run_id
                ORDER BY r.player_id
            LOOP
                v_move := dungeon_default_move(one.player_id);
                CONTINUE WHEN v_move IS NULL;

                -- Against an unkillable target, so no rehearsal ends early
                -- and drags the mean down.
                SELECT * INTO swung FROM player_swing(
                    one.player_id, v_move, p_species_id,
                    9223372036854775807::bigint, v_def,
                    GREATEST(1, one.max_hp), GREATEST(1, one.max_hp),
                    i, 'rehearsal', -p_run_id);

                v_sum := v_sum + GREATEST(0, swung.dealt);
            END LOOP;
        END LOOP;

        -- Undone here, including every battle_effect the rehearsed techniques
        -- wrote. The sum survives because it is a variable, not a row.
        RAISE EXCEPTION 'rehearsal-done';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rehearsal-done' THEN RAISE; END IF;
    END;

    RETURN GREATEST(0, v_sum / v_n);
END;
$fn$;

COMMENT ON FUNCTION dungeon_rehearse(BIGINT, BIGINT) IS
    'What this run''s raiders actually do to this creature in one round, measured by swinging them through the real pipeline and rolling it back. The same trick trial_rehearse uses, because no fitted ratio survives a second party.';


INSERT INTO game_config (key, value) VALUES
    ('dungeon_rehearsal_rounds', 3),
    ('dungeon_rounds_expected',  8)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ---------------------------------------------------------------------------
-- A pool sized off the party that walked in
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_boss_pool(p_run_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_run     RECORD;
    v_round   BIGINT;
    v_raiders INTEGER;
BEGIN
    SELECT r.run_id, r.dungeon_id, r.difficulty, dg.species_id
    INTO v_run
    FROM dungeon_runs r
    JOIN dungeons dg ON dg.dungeon_id = r.dungeon_id
    WHERE r.run_id = p_run_id;

    IF v_run IS NULL THEN
        RETURN 1;
    END IF;

    SELECT count(*) INTO v_raiders FROM dungeon_raiders WHERE run_id = p_run_id;
    v_round := dungeon_rehearse(p_run_id, v_run.species_id);

    -- A party with nothing to throw cannot be rehearsed. Only then does the
    -- old formula answer, because the old formula is what is being replaced.
    IF COALESCE(v_round, 0) <= 0 THEN
        RETURN dungeon_boss_hp(v_run.dungeon_id::SMALLINT, v_run.difficulty,
                               GREATEST(1, v_raiders));
    END IF;

    RETURN GREATEST(1, round(
        v_round
        * game_config_value('dungeon_rounds_expected')
        * (SELECT d.hp_scale FROM dungeon_difficulties d WHERE d.code = v_run.difficulty)
    ))::BIGINT;
END;
$fn$;

COMMENT ON FUNCTION dungeon_boss_pool(BIGINT) IS
    'The HP a dungeon boss opens with, from a rehearsal of the actual raiders times the rounds a room should last times its difficulty. dungeon_boss_hp is kept as the fallback for a party that cannot be rehearsed at all.';


-- ---------------------------------------------------------------------------
-- And dungeon_begin uses it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
    hits   INTEGER;
BEGIN
    src := pg_get_functiondef(
        (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'dungeon_begin'));

    hits := (length(src) - length(replace(src, 'dungeon_boss_hp(', '')))
            / length('dungeon_boss_hp(');
    IF hits <> 1 THEN
        RAISE EXCEPTION 'dungeon_begin calls dungeon_boss_hp % times, expected once', hits;
    END IF;

    -- Find the call and swap the whole argument list for the run id. Done by
    -- locating the call and its closing paren rather than by matching the
    -- arguments, which span lines and are formatted unpredictably.
    DECLARE
        at_call INTEGER := strpos(src, 'dungeon_boss_hp(');
        depth   INTEGER := 0;
        i       INTEGER;
        ch      TEXT;
        at_end  INTEGER := 0;
    BEGIN
        FOR i IN (at_call + length('dungeon_boss_hp(') - 1) .. length(src) LOOP
            ch := substr(src, i, 1);
            IF ch = '(' THEN depth := depth + 1;
            ELSIF ch = ')' THEN
                depth := depth - 1;
                IF depth = 0 THEN at_end := i; EXIT; END IF;
            END IF;
        END LOOP;

        IF at_end = 0 THEN
            RAISE EXCEPTION 'could not find the end of the dungeon_boss_hp call';
        END IF;

        src := substr(src, 1, at_call - 1)
               || 'dungeon_boss_pool(v_run_id)'
               || substr(src, at_end + 1);
    END;

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A room that outlasts a swing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_src   TEXT;
    v_pool  BIGINT;
    v_old   BIGINT;
    v_swing BIGINT;
    v_run   BIGINT;
    v_dg    SMALLINT;
    v_pid   BIGINT;
    v_n     INTEGER;
BEGIN
    v_src := pg_get_functiondef(
        (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'dungeon_begin'));
    IF v_src NOT LIKE '%dungeon_boss_pool(v_run_id)%' THEN
        RAISE EXCEPTION 'dungeon_begin still sizes its boss off the formula';
    END IF;
    IF v_src LIKE '%dungeon_boss_hp(%' THEN
        RAISE EXCEPTION 'dungeon_begin still calls the old formula as well';
    END IF;

    -- The deepest room, against the hardest-hitting cultivator alive. The
    -- rehearsal has to come out above a single swing by a wide margin, which
    -- the formula did not.
    SELECT dg.dungeon_id INTO v_dg FROM dungeons dg
    JOIN creature_species s ON s.species_id = dg.species_id
    ORDER BY s.base_hp DESC LIMIT 1;

    SELECT p.player_id INTO v_pid FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
    ORDER BY player_blow_multiple(p.player_id) DESC LIMIT 1;

    BEGIN
        INSERT INTO dungeon_runs (dungeon_id, difficulty, leader_id, status)
        VALUES (v_dg, 'insane', v_pid, 'forming') RETURNING run_id INTO v_run;
        INSERT INTO dungeon_raiders (run_id, player_id)
        VALUES (v_run, v_pid);

        v_pool := dungeon_boss_pool(v_run);
        v_old  := dungeon_boss_hp(v_dg, 'insane', 1);

        SELECT GREATEST(1, (player_swing(
                   v_pid, dungeon_default_move(v_pid),
                   (SELECT species_id FROM dungeons WHERE dungeon_id = v_dg),
                   9223372036854775807::bigint, 0::bigint)).dealt)
        INTO v_swing;

        IF v_pool <= v_swing THEN
            RAISE EXCEPTION
                'the deepest room holds % and one swing is % - it still dies instantly',
                v_pool, v_swing;
        END IF;

        -- And it is sized off the party, not off the table: the new pool has
        -- to be far above what the formula gave for the same room.
        IF v_pool <= v_old * 5 THEN
            RAISE EXCEPTION
                'the rehearsed pool (%) is not meaningfully above the formula (%)',
                v_pool, v_old;
        END IF;

        -- A room should last several rounds for the party that opened it.
        IF v_pool < v_swing * 4 THEN
            RAISE EXCEPTION
                'the deepest room lasts under four swings: % against %',
                v_pool, v_swing;
        END IF;

        RAISE NOTICE
            'deepest room: formula gave %, rehearsal gives %, one swing is %',
            v_old, v_pool, v_swing;

        -- A party with nothing to throw still gets a boss rather than 1 HP.
        DELETE FROM dungeon_raiders WHERE run_id = v_run;
        IF dungeon_boss_pool(v_run) < 1 THEN
            RAISE EXCEPTION 'an unrehearsable party got a boss with no HP';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- The rehearsal leaves nothing behind, like the other two.
    SELECT count(*) INTO v_n FROM battle_effects WHERE scope = 'rehearsal';
    IF v_n > 0 THEN
        RAISE EXCEPTION '% rehearsal effects survived a rollback', v_n;
    END IF;
END;
$probe$;
