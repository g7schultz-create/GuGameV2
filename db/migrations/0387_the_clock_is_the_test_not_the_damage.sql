-- 0387_the_clock_is_the_test_not_the_damage
--
-- 0386 sized every tribulation at 0.35 of the departing realm's dungeon boss
-- and reasoned about it in raw attack against raw health. Driven against the
-- three cultivators actually standing at a great realm door, that sizing tests
-- nothing:
--
--     m_i_y_u_k_i (11 -> 12)   passed in 1 turn, untouched
--     clearwest   (10 -> 11)   passed in 11 turns, untouched
--     grafv       ( 5 ->  6)   passed in 1 turn
--
-- WHY NOTHING TOUCHES THEM, WHICH IS A FACT ABOUT THE GAME AND NOT ABOUT THIS
-- FEATURE. A cultivator who has kept up carries four mitigations that compound:
--
--     dodge               0.34 - 0.40        the blow misses
--     damage_reduction    0.75 (ceiling 0.9) what lands is quartered
--     pet_cover_share     0.30               the beast eats a third of that
--     life on hit                            and the next swing pays it back
--
-- Together those turn 1.93M of tribulation into 337K reaching the body, which
-- clearwest heals off on their own next swing. The trace is unambiguous: six
-- turns of the sky hitting as hard as it can, and their health ends the round
-- higher than it started.
--
-- So attack cannot be the test, and raising it cannot be the fix. The stack
-- above is worth 87 per cent at rank 10 and nothing at all at rank 1 - every
-- number large enough to threaten an immortal kills a novice on their first
-- crossing, and there is only one share for all seventeen doors.
--
-- THE CLOCK IS THE TEST. `battle_turn_cap` is 50, an expired fight concludes
-- as a failure, and 0363 already named this as the game's difficulty axis at
-- depth: hard is a race not a loss. A tribulation is therefore a question
-- about damage output - can you break it before it runs out the sky's
-- patience - and that question scales cleanly, because a player's damage and
-- the trial's health both climb with the realm.
--
-- 0.35 -> 0.65 puts the marginal cultivator at 24 turns of the 50. Measured
-- again at that value:
--
--     m_i_y_u_k_i  1 - 2 turns        comfortably strong enough
--     clearwest    20 - 24 turns      passes, with half the sky's patience gone
--     rank 1       about 4 turns, and 40 per cent of their health left, because
--                  down there none of the mitigations above exist yet
--
-- Which is the band that was asked for: anybody at less than about half their
-- realm's expected output runs out of turns and is told to go and get stronger.
--
-- The attack share is deliberately left where it is. It is pressure and
-- flavour, the thing that makes it feel like a tribulation rather than a
-- practice dummy - and at rank 1, where none of the mitigations exist yet, it
-- is genuinely dangerous. It is simply not the thing being measured.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 0.65,
    description = 'A tribulation''s health as a share of the dungeon boss of the realm being left. This is the whole test: a cultivator who cannot break it inside battle_turn_cap turns is not strong enough to cross. Attack is pressure; health is the question.'
WHERE key = 'tribulation_hp_share';


-- Re-cut from the same formula rather than typed, so the seventeen stay on the
-- curve they claim to be a share of.
UPDATE creature_species cs
SET base_hp = GREATEST(1, round(boss.base_hp
                                * game_config_value('tribulation_hp_share')))::bigint
FROM tribulations tb
JOIN dungeons d ON d.realm_rank = tb.rank - 1
JOIN creature_species boss ON boss.species_id = d.species_id
WHERE cs.species_id = tb.species_id;


-- ---------------------------------------------------------------------------
-- And the sky stops calling itself "the The Frost That Finds the Marrow"
-- ---------------------------------------------------------------------------
--
-- Every trial's name begins with an article, so the sentence that refuses one
-- printed two. Caught by the probe in 0386 the first time it ran against grafv.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'tribulation_face';

    IF body IS NULL THEN
        RAISE EXCEPTION 'tribulation_face is missing';
    END IF;

    anchor := '            ''the % is not open to you yet - you are short of %'',';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'tribulation_face no longer refuses an unopened door there';
    END IF;

    EXECUTE replace(body, anchor,
        '            ''% is not open to you yet - you are short of %'',');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every door is a race, and every race is winnable by somebody who built
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r     RECORD;
    v_cap NUMERIC := game_config_value('battle_turn_cap');
    v_bad TEXT;
BEGIN
    -- Still on the curve, after being re-cut.
    SELECT string_agg(tb.rank::text, ', ') INTO v_bad
    FROM tribulations tb
    JOIN creature_species cs ON cs.species_id = tb.species_id
    JOIN dungeons d ON d.realm_rank = tb.rank - 1
    JOIN creature_species boss ON boss.species_id = d.species_id
    WHERE abs(cs.base_hp::numeric
              - round(boss.base_hp * game_config_value('tribulation_hp_share'))) > 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these tribulations drifted off the share: %', v_bad;
    END IF;

    -- And still harder every rung.
    SELECT string_agg(t.rank::text, ', ') INTO v_bad
    FROM (
        SELECT tb.rank, cs.base_hp,
               lag(cs.base_hp) OVER (ORDER BY tb.rank) AS below
        FROM tribulations tb JOIN creature_species cs ON cs.species_id = tb.species_id
    ) t
    WHERE t.below IS NOT NULL AND t.base_hp <= t.below;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these tribulations are no harder than the one below: %', v_bad;
    END IF;

    -- THE POINT: for everybody standing at a door right now, how much of the
    -- sky's patience the trial actually costs them. A trial nobody can finish
    -- inside the cap is a wall, and a trial finished in one turn is a cutscene.
    FOR r IN
        SELECT p.discord_name, was.rank AS from_rank, cs.name AS trial,
               cs.base_hp,
               (SELECT max(cd.final_damage)
                FROM player_usable_techniques u
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, u.technique_id, cs.species_id,
                    player_external_multiplier(p.player_id, u.technique_id),
                    cs.base_defense) cd
                WHERE u.player_id = p.player_id) AS hit
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms was ON was.realm_id = pc.realm_id
        JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1
        JOIN tribulations tb ON tb.rank = nxt.rank
        JOIN creature_species cs ON cs.species_id = tb.species_id
        WHERE nxt.rank > was.rank AND p.deleted_at IS NULL
        ORDER BY was.rank DESC
    LOOP
        IF COALESCE(r.hit, 0) <= 0 THEN
            RAISE NOTICE '% carries nothing that hurts %', r.discord_name, r.trial;
            CONTINUE;
        END IF;

        IF ceil(r.base_hp::numeric / r.hit) > v_cap THEN
            RAISE EXCEPTION
                '% cannot finish % inside % turns - that is a wall, not a door',
                r.discord_name, r.trial, v_cap;
        END IF;

        RAISE NOTICE '% : % of % turns against %',
            rpad(r.discord_name, 14), ceil(r.base_hp::numeric / r.hit), v_cap,
            r.trial;
    END LOOP;
END;
$probe$;
