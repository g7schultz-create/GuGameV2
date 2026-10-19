-- 0330_a_king_that_still_outlasts_one_burst
--
-- 0329 measured the King against the people who fought its tide instead of
-- against everyone who happened to be online. That is right, and it opened a
-- hole `test_the_king_survives_one_cultivators_burst` caught at once:
--
--     the room branch is a sum over horde_contributions,
--     and a sum over nothing is nothing.
--
-- A King whose tide recorded no contributors falls back to the region floor
-- alone, which is far below what one cultivator lands in a burst. The rule
-- exists because that already happened once - tide 3873's King rose with
-- 637,653 health and died inside a single tick to a 2,292,229 blow, and
-- nobody else in a room of seven got to touch the finale.
--
-- It is not only a test's construction. A sea empties by beasts ESCAPING as
-- well as by beasts dying - `horde_verdict` counts slain plus lost against
-- the total - so a tide that was largely missed can raise a King with almost
-- nobody in its contributions table, and that is exactly the tide where a
-- lone cultivator wandering in should not end the event on their own.
--
-- So the King keeps a floor of its own: whatever the hardest single
-- cultivator who might swing at it lands in one full burst, times
-- `horde_king_burst_margin`. One person is never enough, however thin the
-- line behind it was.
--
-- This does not touch the calibration 0329 set. On tide 8082 the fighters'
-- sum asks 2,636,309,110 and this floor asks 300,439,199 x 5 x 1.25 =
-- 1,877,744,994, so the sum still leads and that room still finishes on 94%.
-- The floor only speaks when the room branch has gone quiet.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_burst_margin', 1.25,
     'How far past one cultivator full burst a King must always sit. The '
     'finale is the room fight, so it cannot be decided before the room can '
     'reach it - tide 3873 rose a King that died in one tick to one person '
     'while six others watched.');


CREATE OR REPLACE FUNCTION horde_king_pool(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        -- The sea it came in behind, counted in the beasts that sea actually
        -- sends. 0326.
        GREATEST(1000, round(
            COALESCE((SELECT sum(cs.base_hp * cr.weight)
                             / NULLIF(sum(cr.weight), 0)
                      FROM creature_regions cr
                      JOIN creature_species cs ON cs.species_id = cr.species_id
                      WHERE cr.region_code = h.region_code AND cs.kind = 'beast'),
                     600)
            * horde_world_scale(p_horde_id)
            * game_config_value('horde_king_beasts'))),

        -- What the line can put into it: everyone who swung at this tide,
        -- asked for as many turns as the burst rule lets them land. 0329.
        round(COALESCE((
            SELECT sum(horde_walker_burst(c.player_id, p_species_id))
            FROM horde_contributions c WHERE c.horde_id = p_horde_id
        ), 0)
        * game_config_value('horde_king_burst')
        * game_config_value('horde_king_bursts_expected')
        * game_config_value('horde_king_effort')),

        -- And never less than one cultivator's whole burst with room to
        -- spare. A sum over an empty line is zero, and a finale nobody had
        -- to gather for is not a finale.
        round(COALESCE((
            SELECT max(horde_walker_burst(p.player_id, p_species_id))
            FROM players p
            WHERE p.deleted_at IS NULL
              AND (p.last_seen_at >= now() - make_interval(
                       mins => game_config_value('boss_presence_minutes')::integer)
                   OR EXISTS (SELECT 1 FROM horde_contributions c
                              WHERE c.horde_id = p_horde_id
                                AND c.player_id = p.player_id))
        ), 0)
        * game_config_value('horde_king_burst')
        * game_config_value('horde_king_burst_margin'))
    )::bigint
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;


-- ---------------------------------------------------------------------------
-- Both ends of it still hold
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    tide    BIGINT;
    bull    BIGINT;
    hardest NUMERIC;
    bare    BIGINT;
    lined   BIGINT;
BEGIN
    SELECT species_id INTO bull FROM creature_species WHERE code = 'thunder_horn_bull';

    SELECT max(horde_walker_burst(p.player_id, bull)) INTO hardest
    FROM players p
    WHERE p.deleted_at IS NULL
      AND p.last_seen_at >= now() - make_interval(
              mins => game_config_value('boss_presence_minutes')::integer);

    IF hardest IS NULL OR hardest = 0 THEN
        RAISE NOTICE 'nobody is present to measure a burst against';
        RETURN;
    END IF;

    INSERT INTO beast_hordes (region_code, rank, beasts_total, line_holds, ends_at)
    VALUES ('northern', 3, 100, 30, now() + interval '2 hours')
    RETURNING horde_id INTO tide;

    -- A tide nobody is recorded as having fought: the case 0329 broke.
    bare := horde_king_pool(tide, bull);
    IF bare <= hardest * game_config_value('horde_king_burst') THEN
        RAISE EXCEPTION
            'an unfought tide raises a King of % and one burst lands %',
            bare, round(hardest * game_config_value('horde_king_burst'));
    END IF;

    -- And with the line behind it, the fighters still decide the size.
    INSERT INTO horde_contributions (horde_id, player_id, last_swing_at)
    SELECT tide, c.player_id, now() FROM horde_contributions c WHERE c.horde_id = 8082
    ON CONFLICT DO NOTHING;

    lined := horde_king_pool(tide, bull);
    IF EXISTS (SELECT 1 FROM horde_contributions WHERE horde_id = tide)
       AND lined < bare THEN
        RAISE EXCEPTION 'a line behind the King made it smaller: % then % now',
            bare, lined;
    END IF;

    RAISE NOTICE 'unfought % / with the 8082 line %, one burst being %',
        bare, lined, round(hardest * game_config_value('horde_king_burst'));

    DELETE FROM horde_contributions WHERE horde_id = tide;
    DELETE FROM beast_hordes WHERE horde_id = tide;
END;
$probe$;
