-- 0296_a_beasts_blow_is_not_one_of_your_strikes
--
-- `/fight` has been raising on every swing where the beast at heel actually
-- landed something:
--
--     invalid input syntax for type integer: "pet"
--     PL/pgSQL function battle_act(bigint,text,bigint) line 116
--
-- 0277 gave the beast an entry in `player_swing`'s blow-by-blow so the log
-- could name it, and wrote that entry as
--
--     'strike', 'pet',  'damage', beast_hit,  'pet', beast_nm, ...
--
-- `strike` is the strike NUMBER everywhere else in that array - an integer -
-- and `battle_act` reads it as one, `CASE WHEN (b ->> 'strike')::int = 1`, to
-- decide which strike of the flurry carries the qi cost. Casting the word
-- "pet" to integer is the error, and it takes the whole INSERT with it, so
-- the swing that produced it never completes.
--
-- WHY IT WENT UNNOTICED FOR A DAY. The pet only appends that entry when it
-- lands damage, and it only lands damage when the target survives the
-- cultivator's own blow. Every hunt I tested had the target dying first, so
-- the entry was never written and the crash never fired. It is the one lane
-- I had already reported as never getting a pet contribution - which is
-- exactly what made it look like the safe one.
--
-- THE FIX IS TO SKIP IT, NOT TO RENUMBER IT. `battle_actions` is a table of
-- the cultivator's own technique strikes: every row carries the technique id,
-- its base power, its attainment bonus and its matchup. A beast's blow has
-- none of those and belongs in none of those columns. Giving the entry an
-- integer strike number would stop the crash and start writing rows that
-- claim the beast used your technique.
--
-- `player_swing` is left exactly as it is. Its array is the record of what
-- the swing did, the beast included, and `battle_act` is the only thing in
-- the database that iterates it - so the filter goes where the assumption is.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    body   TEXT;
    anchor TEXT := '        FROM jsonb_array_elements(swung.blows) AS b;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'battle_act';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_act is missing';
    END IF;

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the blow-by-blow insert is not where it was';
    END IF;

    body := replace(body, anchor,
'        FROM jsonb_array_elements(swung.blows) AS b
        -- The beast at heel has an entry in here too, and it is not one of
        -- your strikes: no technique, no base power, no attainment. It is
        -- reported through pet_dealt and the round log instead.
        WHERE NOT jsonb_exists(b, ''pet'');');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The filter is in, and nothing else about the swing moved
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'battle_act')
       NOT LIKE '%jsonb_exists(b, ''pet'')%' THEN
        RAISE EXCEPTION 'battle_act still writes the beast as a technique strike';
    END IF;

    -- `player_swing` keeps its record of what the beast did. The fix belongs
    -- to the reader that assumed every entry was a strike.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'player_swing')
       NOT LIKE '%''strike'', ''pet''%' THEN
        RAISE EXCEPTION 'the beast stopped being written into the blow-by-blow';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A swing the beast actually lands, which is the one that was raising
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    beast BIGINT;
    sp    BIGINT;
    b_id  BIGINT;
    move  BIGINT;
    got   RECORD;
    rows  INTEGER;
BEGIN
    SELECT b.owner_id, b.beast_id INTO who, beast
    FROM player_beasts b
    JOIN players p ON p.player_id = b.owner_id AND p.deleted_at IS NULL
    WHERE b.at_heel AND dungeon_default_move(b.owner_id) IS NOT NULL
    ORDER BY b.tier DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody walks a beast and knows a technique; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        UPDATE player_beasts SET hp = NULL WHERE beast_id = beast;
        UPDATE battles SET status = 'expired', ended_at = now()
        WHERE status = 'active'
          AND battle_id IN (SELECT battle_id FROM battle_combatants
                            WHERE player_id = who);

        SELECT species_id INTO sp FROM creature_species
        WHERE kind = 'beast' ORDER BY rank DESC LIMIT 1;

        move := dungeon_default_move(who);
        b_id := battle_open(who, sp);

        -- The whole point: a target that OUTLASTS the cultivator's own blow,
        -- because that is the only case in which the beast swings at all and
        -- therefore the only case that was ever broken. Left to its own
        -- health a hunt creature dies first and the bug hides.
        UPDATE battle_combatants
        SET current_hp = 9223372036854775807 / 4,
            max_hp     = 9223372036854775807 / 4
        WHERE battle_id = b_id AND combatant_no = 1;

        SELECT * INTO got FROM battle_act(b_id, 'attack', move);

        IF COALESCE(got.pet_dealt, 0) <= 0 THEN
            RAISE EXCEPTION
                'the beast did not swing, so this proved nothing';
        END IF;

        -- And the beast is not in the ledger of the cultivator's strikes.
        SELECT count(*) INTO rows
        FROM battle_actions a
        WHERE a.battle_id = b_id AND jsonb_exists(a.detail, 'pet');

        IF rows > 0 THEN
            RAISE EXCEPTION
                '% beast blow(s) were written in as technique strikes', rows;
        END IF;

        RAISE NOTICE
            'the beast landed % and the swing completed', got.pet_dealt;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
