-- 0303_a_room_is_where_a_taunt_means_something
--
-- The dungeon. The lane that makes three of the five effect kinds worth
-- having at all, because it is the only fight in this game where more than
-- one cultivator swings and something CHOOSES which of them to maul.
--
-- TAUNT, AND WHY IT IS A WEIGHT RATHER THAN A REDIRECT. The room picked its
-- victim with `ORDER BY random()`. A taunt that simply seized that pick would
-- make one technique mean "nobody else is ever hit", which is not a choice,
-- it is an off switch. So it weights the draw instead, using the same
-- exponential race `gather` has used to pick a herb since the beginning:
--
--     ORDER BY -ln(random()) / (1 + taunt)
--
-- A cultivator at taunt 1.00 is twice as likely to be chosen as one standing
-- next to them at zero. Still a roll. The boss can still walk past you, and
-- that is the point - a tank in this game is somebody who changes the odds
-- for the room, not somebody who removes the room from the fight.
--
-- THE TICK IS AT THE TOP, EVEN THOUGH THIS LANE HAS ONE EXIT. The hunt had to
-- tick at the top because it returns from four places; this one could tick
-- wherever it liked. It ticks at the top anyway, because `effect_apply` banks
-- an extra round on the understanding that the next action spends one before
-- reading it - and a lane that ticked afterward instead would quietly give
-- every buff four rounds where the hunt gives three. One rule everywhere is
-- worth more than one lane's tidiness.
--
-- REGEN MENDS EVERY RAIDER CARRYING IT, before the round resolves, for the
-- same reason it does in a hunt: health that arrives after the boss has swung
-- was not there when it was needed.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    body  TEXT;
    top   TEXT :=
'    IF run.status <> ''fighting'' THEN
        RAISE EXCEPTION ''that fight is not running''
            USING ERRCODE = ''check_violation'';
    END IF;';
    swing TEXT :=
'            one.current_hp, one.max_hp, run.round_no::integer);';
    pick  TEXT :=
'        SELECT x.player_id INTO target
        FROM dungeon_raiders x
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY random()
        LIMIT 1;';
    take  TEXT :=
'                NOT (SELECT x.ward_used FROM dungeon_raiders x
                     WHERE x.run_id = p_run_id AND x.player_id = target));';
    fin   TEXT :=
'    IF ending <> ''fighting'' THEN
        PERFORM dungeon_pay_out(p_run_id);
    END IF;';
    a     TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'dungeon_resolve_round';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_resolve_round is missing';
    END IF;

    FOREACH a IN ARRAY ARRAY[top, swing, pick, take, fin] LOOP
        IF (length(body) - length(replace(body, a, ''))) / length(a) <> 1 THEN
            RAISE EXCEPTION 'dungeon: anchor is not unique: %', left(a, 60);
        END IF;
    END LOOP;

    -- One round off everything, and mending, before the round is resolved.
    body := replace(body, top, top || '

    PERFORM effect_tick(''dungeon'', p_run_id);

    UPDATE dungeon_raiders x
    SET current_hp = LEAST(x.max_hp, x.current_hp + GREATEST(1, floor(x.max_hp
            * effect_value(''dungeon'', p_run_id, x.player_id, ''regen''))))
    WHERE x.run_id = p_run_id AND x.current_hp > 0
      AND effect_value(''dungeon'', p_run_id, x.player_id, ''regen'') > 0;');

    body := replace(body, swing,
'            one.current_hp, one.max_hp, run.round_no::integer,
            ''dungeon'', p_run_id);');

    -- A weighted draw, not a seizure.
    body := replace(body, pick,
'        SELECT x.player_id INTO target
        FROM dungeon_raiders x
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY -ln(random())
                 / (1 + effect_value(''dungeon'', p_run_id, x.player_id, ''taunt''))
        LIMIT 1;');

    body := replace(body, take,
'                NOT (SELECT x.ward_used FROM dungeon_raiders x
                     WHERE x.run_id = p_run_id AND x.player_id = target),
                ''dungeon'', p_run_id);');

    body := replace(body, fin,
'    IF ending <> ''fighting'' THEN
        PERFORM effect_clear(''dungeon'', p_run_id);
        PERFORM dungeon_pay_out(p_run_id);
    END IF;');

    EXECUTE body;
END;
$$;


-- ---------------------------------------------------------------------------
-- The room reads the fight it is in
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
BEGIN
    SELECT prosrc INTO src FROM pg_proc WHERE proname = 'dungeon_resolve_round';

    IF src NOT LIKE '%''dungeon'', p_run_id);%' THEN
        RAISE EXCEPTION 'the room never tells the choke points which run it is';
    END IF;
    IF src NOT LIKE '%effect_tick(''dungeon'', p_run_id)%' THEN
        RAISE EXCEPTION 'the room never spends a round off anything';
    END IF;
    IF src NOT LIKE '%effect_clear(''dungeon'', p_run_id)%' THEN
        RAISE EXCEPTION 'a finished run keeps what it was carrying';
    END IF;
    IF src LIKE '%ORDER BY random()
        LIMIT 1%' THEN
        RAISE EXCEPTION 'the room still picks its victim without reading a taunt';
    END IF;
    IF src NOT LIKE '%''taunt''%' THEN
        RAISE EXCEPTION 'the room does not read a taunt at all';
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- A taunt shifts the odds without owning them
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    a     BIGINT;
    b     BIGINT;
    drawn BIGINT;
    for_a INTEGER := 0;
    i     INTEGER;
BEGIN
    SELECT player_id INTO a FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 ORDER BY player_id LIMIT 1;
    SELECT player_id INTO b FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 AND player_id <> a
    ORDER BY player_id LIMIT 1;

    IF a IS NULL OR b IS NULL THEN
        RAISE NOTICE 'fewer than two cultivators; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- The same draw the room makes, over two standing raiders, one of
        -- whom is Marked to the cap.
        PERFORM effect_apply('dungeon', -3, a, 'taunt', 1.00, 5);

        FOR i IN 1..600 LOOP
            SELECT v.who INTO drawn
            FROM (VALUES (a), (b)) AS v(who)
            ORDER BY -ln(random())
                     / (1 + effect_value('dungeon', -3, v.who, 'taunt'))
            LIMIT 1;
            IF drawn = a THEN
                for_a := for_a + 1;
            END IF;
        END LOOP;

        -- Twice as likely is about 400 of 600. Loose bounds: this is proving
        -- the weight is read and is not absolute, not pinning a distribution.
        IF for_a <= 330 THEN
            RAISE EXCEPTION
                'the Marked raider was chosen % times in 600 - the taunt is not read',
                for_a;
        END IF;
        IF for_a >= 580 THEN
            RAISE EXCEPTION
                'the Marked raider was chosen % times in 600 - the taunt is an off switch',
                for_a;
        END IF;

        RAISE NOTICE 'Marked drew % of 600 against an unmarked raider', for_a;

        PERFORM effect_clear('dungeon', -3);
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
