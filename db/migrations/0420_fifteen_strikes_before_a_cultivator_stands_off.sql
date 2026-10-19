-- 0420_fifteen_strikes_before_a_cultivator_stands_off
--
-- `horde_king_burst` is five: five strikes on the King and then seven minutes
-- of standing off. On the tide this was asked about, all six fighters were
-- sitting at exactly five - every one of them spent, watching a King on 63 per
-- cent of its health with nothing to do but wait. Raised to fifteen.
--
-- WHAT THIS ACTUALLY CHANGES, which is not the same in every region, and is
-- worth writing down because the number does two jobs. `horde_king_pool` sizes
-- a King as the GREATEST of three terms, and the burst appears in two of them:
--
--     regional        the region's own beasts times horde_king_beasts
--                     - does NOT read the burst
--     line            what everybody who swung can land, times burst
--                     times bursts_expected times effort
--     one-cultivator  the deepest single fighter, times burst times margin
--
-- Where the LINE term binds - shallow regions, big turnouts - tripling the
-- burst triples the King, and the fight is the same length in strikes with a
-- third of the waiting. That is the change everybody wants.
--
-- Where the REGIONAL term binds it does not scale, and the King simply falls
-- three times faster. On the tide that prompted this, that was the binding
-- term by a wide margin: 42.99 trillion regional against 14.33 line and 8.96
-- one-cultivator. Black Heaven beasts are enormous and the region floor runs
-- away from what a room can actually put in. So in the deep regions this is a
-- real difficulty cut and not only a convenience.
--
-- That is a defensible place to end up - a King nobody can reach is a wall
-- with a timer, and `horde_king_line_reach` exists because 0377 had already
-- found the regional term running away once. But it is a difficulty change
-- wearing the clothes of a quality-of-life one, and the next person reading
-- this config should not have to rediscover which.
--
-- The world beast's own `boss_strike_burst` is deliberately untouched. It is a
-- different fight on a different clock, and nothing about this asked for it.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 15, description =
    'Strikes a cultivator may land on the King before standing off. Fifteen since 0420. It is read twice: once as the wall a fighter hits, and once inside `horde_king_pool` as part of what the King is sized against - so in regions where the LINE term binds, raising it raises the King to match, and where the REGIONAL floor binds it is a straight difficulty cut. See 0420 for which is which.'
WHERE key = 'horde_king_burst';


-- ---------------------------------------------------------------------------
-- A room gets further before it has to wait
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_burst NUMERIC := game_config_value('horde_king_burst');
    r       RECORD;
BEGIN
    IF v_burst <> 15 THEN
        RAISE EXCEPTION 'the burst is % rather than fifteen', v_burst;
    END IF;

    -- The world beast is a different fight and must not have moved with it.
    IF game_config_value('boss_strike_burst') <> 5 THEN
        RAISE EXCEPTION
            'the world beast burst moved too, and nothing asked it to';
    END IF;

    -- The margin rule still has to hold: a King must sit past one cultivator's
    -- whole burst, and that burst just tripled. If the margin no longer clears
    -- it, the finale can be decided before the room arrives - which is the
    -- thing `horde_king_burst_margin` was added to stop.
    IF game_config_value('horde_king_burst_margin') <= 1 THEN
        RAISE EXCEPTION
            'a King no longer has to outlast one cultivator''s burst';
    END IF;

    -- Nobody is left standing off against a King that is already dead.
    UPDATE horde_contributions c
    SET king_burst_used = 0, king_resumes_at = NULL
    WHERE c.king_burst_used > 0
      AND EXISTS (SELECT 1 FROM horde_encounters e
                  WHERE e.horde_id = c.horde_id
                    AND e.kind = 'king'
                    AND e.status <> 'alive');

    FOR r IN
        SELECT h.horde_id, h.status, h.region_code,
               count(*) FILTER (WHERE c.king_damage > 0) AS met_the_king
        FROM beast_hordes h
        LEFT JOIN horde_contributions c ON c.horde_id = h.horde_id
        WHERE h.horde_id IN (SELECT horde_id FROM horde_encounters
                             WHERE kind = 'king')
        GROUP BY h.horde_id, h.status, h.region_code
        ORDER BY h.horde_id DESC LIMIT 3
    LOOP
        RAISE NOTICE 'tide % in % is %, % met the King',
            r.horde_id, rpad(r.region_code, 14), r.status, r.met_the_king;
    END LOOP;

    RAISE NOTICE
        'a cultivator now lands % strikes before the % minute stand-off',
        v_burst, game_config_value('horde_king_cooldown_minutes');
END;
$probe$;
