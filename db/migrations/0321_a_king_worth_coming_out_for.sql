-- 0321_a_king_worth_coming_out_for
--
-- 0320 set `horde_body_effort` at 0.25 without checking what that did to the
-- two things standing either side of a channel beast. Measured afterwards,
-- against the live room:
--
--     effort   normal        elite          King / elite   room-turns to
--                                                          empty the sea
--     0.10     273,279,662     956,478,818      3.43            73
--     0.15     409,919,494   1,434,718,228      2.29           110
--     0.20     546,559,325   1,912,957,637      1.71           146
--     0.25     683,199,156   2,391,197,046      1.37           183
--
-- TWO THINGS ARE WRONG AT 0.25. The King ends up 1.37 times an elite, so the
-- finale the whole channel organises around is barely heavier than a spawn
-- that turns up eighteen percent of the time. And emptying the sea takes 183
-- combined room-turns inside a two hour tide - which matters more than it
-- looks, because `horde_verdict` only lets the King rise once the sea is
-- empty. Beasts nobody can get through are not just slow; they are a finale
-- that never comes out.
--
-- 0.15 puts the King at 2.29 times an elite and the sea at 110 room-turns -
-- about one combined turn a minute, which a channel with a few people in it
-- clears comfortably. A channel beast is then two turns for the hardest
-- hitter present and an elite is seven, against 20,256 health and a single
-- blow of 116,554,557 before 0320. Still four orders of magnitude harder
-- than the thing that was being one-shot; just not so hard that the event
-- stops reaching its own ending.
--
-- The lesson is the ladder one this repo keeps teaching: a number that sits
-- between two others cannot be picked by looking at it alone.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 0.15,
    description = 'What share of a full world-beast pool one channel beast '
                  'carries, measured against the room the same way '
                  'boss_hp_pool measures a boss. Set so the King stays over '
                  'twice an elite and the sea still empties inside a tide - '
                  'the King cannot rise until it does.'
WHERE key = 'horde_body_effort';


-- ---------------------------------------------------------------------------
-- Normal, then elite, then King - with room between them
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    tide   BIGINT;
    moth   BIGINT;
    burst  BIGINT;
    normal BIGINT;
    elite  BIGINT;
    king   BIGINT;
    sea    NUMERIC;
BEGIN
    SELECT species_id INTO moth FROM creature_species WHERE code = 'ash_moth';

    SELECT COALESCE(sum(horde_walker_burst(p.player_id, moth)), 0) INTO burst
    FROM players p
    WHERE p.deleted_at IS NULL
      AND p.last_seen_at >= now() - make_interval(
              mins => game_config_value('boss_presence_minutes')::integer);

    INSERT INTO beast_hordes (region_code, rank, beasts_total, line_holds, ends_at)
    VALUES ('central', 5, 100, 30, now() + interval '2 hours')
    RETURNING horde_id INTO tide;

    normal := horde_body_pool(tide, moth, FALSE);
    elite  := horde_body_pool(tide, moth, TRUE);

    -- The same arithmetic `horde_king_rise` does, at this tide's rank.
    king := round(boss_hp_pool(moth)
                  * game_config_value('horde_king_effort')
                  * (1 + game_config_value('horde_king_rank_step') * 4))::bigint;

    IF elite <= normal THEN
        RAISE EXCEPTION 'an elite is no heavier than a common beast';
    END IF;

    -- The finale has to be worth organising around. Two to one against the
    -- commonest thing that is not a common beast.
    IF king < elite * 2 THEN
        RAISE EXCEPTION
            'the King (%) is less than twice an elite (%) - the finale is a spawn',
            king, elite;
    END IF;

    -- And the sea has to be emptiable, or the King never comes out at all.
    IF burst > 0 THEN
        sea := 70 * (normal * 0.82 + elite * 0.18) / burst;
        IF sea > 130 THEN
            RAISE EXCEPTION
                'emptying the sea wants % combined room-turns - the King will not rise',
                round(sea);
        END IF;
        RAISE NOTICE 'normal %, elite %, King % - sea in % room-turns',
            normal, elite, king, round(sea);
    ELSE
        RAISE NOTICE 'normal %, elite %, King % - nobody present to pace it against',
            normal, elite, king;
    END IF;

    DELETE FROM beast_hordes WHERE horde_id = tide;
END;
$probe$;
