-- 0579_the_vault_pays_notes_half_the_time
--
-- `dungeon_notes_chance` 0.35 -> 0.50, as asked.
--
-- WHY IT WANTED RAISING. 0578 capped the delve at one set a corpse, which was
-- the right fix for four - but twenty-four rolls at 12% means at least one
-- lands 95.3% of the time, so a deep-tile rogue is very nearly a guaranteed
-- set. Against that, clearing the whole Vault of Unclaimed Dao for a 35%
-- chance at one was the slower road by a wide margin:
--
--     a rogue in a delve      ~0.96 sets a kill
--     the whole Vault         0.35 sets a clear
--
-- At 0.50 the Vault is half the rate of a single rogue kill rather than a
-- third of it, for something that costs a 9.2-billion-stone door, a key and a
-- party to walk into.
--
-- It is per RAIDER, not per run - `dungeon_spoils_for` is called once for each
-- cultivator taking a share - so a four-Venerable party now expects two sets
-- out of a clear rather than one and a half.
--
-- The gate above the roll is unchanged: past the realm ladder (rank 19 and up)
-- and only to somebody who has already carved a Dao. Nothing a mortal can
-- reach pays these out.


UPDATE game_config
SET value = 0.50,
    description = 'The chance a cleared room past the realm ladder holds Ancient Venerable Notes, per raider taking a share. Raised from 0.35 in 0579: a delve rogue is very nearly a guaranteed set since 0578 capped the twenty-four-roll table rather than thinning it, and the Vault costs a door, a key and a party.'
WHERE key = 'dungeon_notes_chance';


DO $probe$
DECLARE
    v_chance NUMERIC;
    v_who    BIGINT;
    v_hits   INTEGER := 0;
    v_runs   CONSTANT INTEGER := 200;
BEGIN
    v_chance := game_config_value('dungeon_notes_chance');
    IF v_chance <> 0.50 THEN
        RAISE EXCEPTION 'the Vault pays notes at % and should be 0.50', v_chance;
    END IF;

    -- ROLLED, NOT JUST READ. The number is only worth setting if the room
    -- actually consults it, and `dungeon_spoils_for` is where that happens.
    -- Somebody who has carved a Dao, because the gate demands one.
    SELECT d.player_id INTO v_who FROM player_dao d LIMIT 1;
    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody has carved a Dao, so no room was cleared here';
        RETURN;
    END IF;

    -- IN A SUBTRANSACTION THAT IS THROWN AWAY. Two hundred clears hand out two
    -- hundred clears' worth of notes, essence, eggs and stones to a live
    -- character; the rollback is the whole point of the wrapper.
    BEGIN
        FOR i IN 1..v_runs LOOP
            IF dungeon_spoils_for(v_who, 19::smallint, 1.0) ? 'notes' THEN
                v_hits := v_hits + 1;
            END IF;
        END LOOP;

        -- Deliberately loose. This is a coin, and 200 flips cannot reliably
        -- tell 0.50 from 0.35 - the UPDATE above is what guarantees the rate.
        -- What this catches is the room having stopped reading the config at
        -- all, or the gate above the roll having closed.
        IF v_hits < v_runs * v_chance * 0.7
           OR v_hits > v_runs * v_chance * 1.3 THEN
            RAISE EXCEPTION
                'the room paid notes % times in % clears against a chance of %',
                v_hits, v_runs, v_chance;
        END IF;

        RAISE NOTICE
            'the Vault paid notes % times in % clears (about % expected)',
            v_hits, v_runs, round(v_runs * v_chance);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
