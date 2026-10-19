-- 0554_a_body_is_measured_once
--
-- Players were told "You have nothing left to fight with" by a rogue
-- cultivator while standing at full health. The message was a lie, and the
-- fight really was refused.
--
-- `battle_open` sizes the creature by calling `creature_body_for` TWICE:
--
--     creature_body_for(p_player_id, p_species_id),   -- max_hp
--     creature_body_for(p_player_id, p_species_id),   -- current_hp
--
-- and that function is VOLATILE on purpose. It rehearses a real `player_swing`
-- against the species to find out what this cultivator actually does per round,
-- so it rolls crits and extra strikes like any other swing. Two calls are two
-- different numbers. Measured twelve times for one rank 17 cultivator:
--
--     max_hp=7,389,145,543,635   current_hp=19,547,486,335,197   <- fails
--     max_hp=14,268,524,365,890  current_hp=2,847,052,713,213
--     max_hp=7,389,145,543,635   current_hp=7,389,145,543,635
--     max_hp=3,336,365,279,781   current_hp=7,389,145,543,635    <- fails
--     ...
--     TEN of twelve pairs differed. FIVE of twelve had current_hp > max_hp.
--
-- `battle_combatants_hp_within_cap` is `current_hp <= max_hp`, so those five
-- rolled back the whole INSERT - about two fights in five simply refusing to
-- start, at random, for anybody whose build has real crit or multi-hit
-- variance. Beasts as well as rogues: this is every `battle_open`.
--
-- WHY NOBODY SAW IT. A CHECK constraint failure is SQLSTATE 23514, which is
-- `check_violation` - the same class the game raises its player-facing
-- refusals with. `open_battle` in the cog reads it as one:
--
--     except psycopg.errors.CheckViolation as exc:
--         if "already in a battle" in str(exc): ...
--         raise GameError("You have nothing left to fight with. ...")
--
-- so a constraint violation inside the function came out as a sentence about
-- the player's health. The bug was invisible for as long as the message was
-- confident. The cog is fixed alongside this to say what actually happened.
--
-- THE FIX IS TO MEASURE ONCE. Not to make `creature_body_for` deterministic -
-- rehearsing a real swing is the whole point of it, and the comment in
-- `battle_open` records what the alternative cost:
--
--     'Was `species.base_hp` twice, which left a rank 18 rogue one-shot four
--      thousand times over.'
--
-- That change was right. It just left the call doubled, and a doubled call to
-- a volatile function is two different answers to one question.
--
-- A creature opens at FULL health, so `max_hp` and `current_hp` are the same
-- number by definition. One variable, assigned once, used twice.


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
    anchor  TEXT :=
'            -- Sized to the cultivator in so far as this thing is
            -- their peer, and never below the bestiary''s own body.
            -- Was `species.base_hp` twice, which left a rank 18
            -- rogue one-shot four thousand times over.
            creature_body_for(p_player_id, p_species_id),
            creature_body_for(p_player_id, p_species_id),';
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'battle_open' AND pronamespace = 'public'::regnamespace;

    IF position(anchor IN src) = 0 THEN
        RAISE EXCEPTION
            'battle_open does not size the creature where it used to';
    END IF;

    patched := replace(src, anchor,
'            -- Sized to the cultivator in so far as this thing is
            -- their peer, and never below the bestiary''s own body.
            -- Was `species.base_hp` twice, which left a rank 18
            -- rogue one-shot four thousand times over.
            --
            -- MEASURED ONCE. `creature_body_for` is VOLATILE - it rehearses a
            -- real `player_swing` to find what this cultivator does per round,
            -- so it rolls crits and extra strikes - and calling it twice gave
            -- two different numbers. When the second came out larger,
            -- `battle_combatants_hp_within_cap` rejected the row and the fight
            -- refused to start: two in five, at random. See 0554.
            --
            -- A creature opens at full health, so these are the same number by
            -- definition rather than by coincidence.
            body_hp,
            body_hp,');

    -- And the variable it needs.
    patched := replace(patched,
'    max_qi   BIGINT;
    b_id     BIGINT;',
'    max_qi   BIGINT;
    b_id     BIGINT;
    body_hp  BIGINT;');

    patched := replace(patched,
'    max_qi := player_max_qi(p_player_id);',
'    max_qi := player_max_qi(p_player_id);

    -- Once, before the row is built. See the note beside its use below.
    body_hp := creature_body_for(p_player_id, p_species_id);');

    IF patched = src THEN
        RAISE EXCEPTION 'the battle_open patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_calls INTEGER;
    v_p     BIGINT;
    v_sp    BIGINT;
    v_b     BIGINT;
    v_i     INTEGER;
    v_fail  INTEGER := 0;
    v_mx    BIGINT;
    v_cur   BIGINT;
    v_seen  INTEGER := 0;
BEGIN
    -- 1. THE CALL IS NO LONGER DOUBLED.
    SELECT (length(pg_get_functiondef(p.oid))
            - length(replace(pg_get_functiondef(p.oid),
                             'creature_body_for(', '')))
           / length('creature_body_for(')
    INTO v_calls
    FROM pg_proc p
    WHERE p.proname = 'battle_open' AND p.pronamespace = 'public'::regnamespace;

    IF v_calls <> 1 THEN
        RAISE EXCEPTION
            'battle_open calls creature_body_for % time(s) - a volatile '
            'function asked twice is two different answers', v_calls;
    END IF;

    -- 2. AND A FIGHT STARTS EVERY TIME. Thirty openings against the deepest
    --    rogue for the cultivator this was reported on; before the patch the
    --    expectation was about twelve failures.
    SELECT p.player_id INTO v_p
    FROM players p JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id > 0 AND pp.current_hp > 0
    ORDER BY player_standing(p.player_id) DESC, pp.max_hp DESC
    LIMIT 1;

    SELECT s.species_id INTO v_sp FROM creature_species s
    WHERE s.kind = 'rogue' ORDER BY s.rank DESC, s.species_id LIMIT 1;

    IF v_p IS NULL OR v_sp IS NULL THEN
        RAISE NOTICE
            'no cultivator or no rogue to open a fight with, so nothing asserted';
    ELSE
        BEGIN
            FOR v_i IN 1..30 LOOP
                DELETE FROM player_active_battle WHERE player_id = v_p;
                BEGIN
                    v_b := battle_open(v_p, v_sp);
                    v_seen := v_seen + 1;

                    -- And the creature really does open at full health, which
                    -- is the invariant the doubled call was breaking.
                    SELECT c.max_hp, c.current_hp INTO v_mx, v_cur
                    FROM battle_combatants c
                    WHERE c.battle_id = v_b AND c.combatant_no = 1;

                    IF v_cur <> v_mx THEN
                        RAISE EXCEPTION
                            'a creature opened at % of % health', v_cur, v_mx;
                    END IF;
                EXCEPTION WHEN check_violation THEN
                    v_fail := v_fail + 1;
                END;
            END LOOP;

            IF v_fail > 0 THEN
                RAISE EXCEPTION
                    '% of 30 fights still refused to start', v_fail;
            END IF;
            IF v_seen <> 30 THEN
                RAISE EXCEPTION
                    'only % of 30 openings were counted', v_seen;
            END IF;

            RAISE NOTICE
                '30 of 30 fights opened, every creature at full health';

            RAISE EXCEPTION 'probe-ok';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
        END;
    END IF;
END
$probe$;
