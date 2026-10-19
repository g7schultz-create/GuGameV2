-- 0164_a_beast_that_can_actually_be_killed
--
-- The beast standing right now has 187,275 HP and 99% of it left. One
-- cultivator swung at it four times in two days. It will expire, as the two
-- before it did.
--
-- `boss_hp_pool` summed each active player's best `base_power` and multiplied
-- by `boss_strikes_each` (125) and `boss_effort` (0.60). Two things wrong
-- with that, and they compound:
--
--   base_power is not damage. It is the figure before attainment, the Path
--   matchup, the beast's defense and its resistances. clearwest - the
--   strongest cultivator alive - lands 452. The whole roster of eleven lands
--   about 3,500 between them in a round where everybody swings once.
--
--   125 is the CAP on a player's strikes, not a number anybody reaches. The
--   bite cap is 18% of max HP, so a cultivator gets about five and a half
--   swings before `/rest`. Using the ceiling as the expectation inflated the
--   pool by roughly twentyfold.
--
-- 187,275 against 3,500 a round is fifty-three rounds of the entire roster
-- swinging, inside a 48-hour window. It was never going to die.
--
-- So the pool is derived from what is actually delivered against the species
-- that was rolled, and the cap stops standing in for the expectation:
--
--   `boss_strikes_each`    125, unchanged - the ceiling, an anti-grief limit
--   `boss_swings_expected`  12, new      - what a cultivator really lands
--
-- Same beast, about 25,000 HP, seven full-roster rounds. It scales itself
-- from here: when clearwest lands thousands a swing instead of hundreds, the
-- pool follows without anybody retuning it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('boss_swings_expected', 12,
     'Swings a cultivator really lands on one beast across its window. The '
     'bite cap is 18% of max HP, so about five and a half from full, twice '
     'over with rest. Distinct from boss_strikes_each, which is the ceiling.');


-- The species is rolled before the pool is asked for, so the pool can be
-- asked the only question that matters: what does this roster actually do to
-- THIS beast. A pool computed against nothing in particular was how a
-- creature immune to half the roster got the same health bar as one nobody
-- resists.
DROP FUNCTION boss_hp_pool();

CREATE FUNCTION boss_hp_pool(p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        game_config_value('boss_hp_floor'),
        round(COALESCE((
            SELECT sum(best.dealt)
            FROM players p
            JOIN LATERAL (
                -- The same pick `strike_boss` makes: the move that actually
                -- lands hardest, not the one with the biggest number on it.
                SELECT max(would.final_damage) AS dealt
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, t.technique_id, p_species_id,
                    player_external_multiplier(p.player_id, t.technique_id),
                    0) AS would
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.dealt IS NOT NULL AND best.dealt > 0
            WHERE p.deleted_at IS NULL
              AND p.last_seen_at >= now() - interval '7 days'
        ), 0)
        * game_config_value('boss_swings_expected')
        * game_config_value('boss_effort'))
    )::bigint;
$$;


CREATE OR REPLACE FUNCTION boss_open_if_due()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    live   BIGINT;
    lapsed BIGINT;
    rested BOOLEAN;
    chosen BIGINT;
    made   BIGINT;
    pool   BIGINT;
BEGIN
    -- A beast that stood out its welcome leaves - and is settled on the way
    -- out, so an escape pays what it owes without anybody pressing anything.
    FOR lapsed IN
        SELECT encounter_id FROM boss_encounters
        WHERE status = 'open' AND closes_at <= now()
    LOOP
        UPDATE boss_encounters
        SET status = 'escaped', ended_at = now()
        WHERE encounter_id = lapsed;
        PERFORM settle_boss(lapsed);
    END LOOP;

    SELECT encounter_id INTO live
    FROM boss_encounters WHERE status = 'open';

    IF live IS NOT NULL THEN
        RETURN live;
    END IF;

    SELECT COALESCE(max(ended_at), 'epoch'::timestamptz)
           <= now() - make_interval(hours => game_config_value('boss_rest_hours')::int)
    INTO rested
    FROM boss_encounters;

    IF NOT rested THEN
        RETURN NULL;
    END IF;

    SELECT cs.species_id INTO chosen
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
    ORDER BY random()
    LIMIT 1;

    IF chosen IS NULL THEN
        RETURN NULL;
    END IF;

    -- Sized against the beast that was actually rolled.
    pool := boss_hp_pool(chosen);

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, closes_at)
    SELECT chosen,
           COALESCE((SELECT cr.region_code FROM creature_regions cr
                     WHERE cr.species_id = chosen ORDER BY random() LIMIT 1),
                    (SELECT r.code FROM regions r ORDER BY r.code LIMIT 1)),
           pool, pool,
           now() + make_interval(hours => game_config_value('boss_hours')::int)
    ON CONFLICT DO NOTHING
    RETURNING encounter_id INTO made;

    IF made IS NULL THEN
        SELECT encounter_id INTO made
        FROM boss_encounters WHERE status = 'open';
    END IF;

    RETURN made;
END;
$$;


-- The one standing now was sized by the old arithmetic and would otherwise
-- run its remaining day and a half unkillable. Resized in place, with the
-- damage already dealt to it kept - clearwest earned those 1,808 and should
-- not have them handed back.

-- A LATERAL in the FROM clause cannot see the row being updated, so the pool
-- is asked for twice. It is STABLE and there is at most one open beast.
UPDATE boss_encounters e
SET max_hp     = boss_hp_pool(e.species_id),
    current_hp = GREATEST(
        1, boss_hp_pool(e.species_id) - (e.max_hp - e.current_hp))
WHERE e.status = 'open';


-- The check that would have caught this the day it was written: a beast the
-- roster cannot finish is not content. Rounds-to-kill is the pool over what
-- everybody together lands in one round, and it may not exceed the swings a
-- cultivator is actually expected to take.

DO $$
DECLARE
    worst   TEXT;
    floored BIGINT;
BEGIN
    floored := game_config_value('boss_hp_floor');

    SELECT string_agg(
               cs.name || ' (' || round(pool.hp / GREATEST(1, roster.round_dmg))
                       || ' rounds)', ', ')
    INTO worst
    FROM creature_species cs
    CROSS JOIN LATERAL (SELECT boss_hp_pool(cs.species_id) AS hp) pool
    CROSS JOIN LATERAL (
        SELECT COALESCE(sum(best.dealt), 0) AS round_dmg
        FROM players p
        JOIN LATERAL (
            SELECT max(would.final_damage) AS dealt
            FROM player_usable_techniques u
            JOIN techniques t ON t.technique_id = u.technique_id
            CROSS JOIN LATERAL compute_technique_damage(
                p.player_id, t.technique_id, cs.species_id,
                player_external_multiplier(p.player_id, t.technique_id),
                0) AS would
            WHERE u.player_id = p.player_id AND t.base_power > 0
        ) best ON best.dealt IS NOT NULL AND best.dealt > 0
        WHERE p.deleted_at IS NULL
          AND p.last_seen_at >= now() - interval '7 days'
    ) roster
    WHERE cs.kind IN ('world', 'boss')
      -- The floor is a deliberate override for an empty or feeble roster and
      -- is allowed to be out of reach; the derived pool is not.
      AND pool.hp > floored
      AND pool.hp > roster.round_dmg * game_config_value('boss_swings_expected');

    IF worst IS NOT NULL THEN
        RAISE EXCEPTION 'these beasts outlast what the roster can land: %', worst;
    END IF;

    IF EXISTS (SELECT 1 FROM boss_encounters
               WHERE status = 'open' AND current_hp > max_hp) THEN
        RAISE EXCEPTION 'the standing beast was resized to more than full';
    END IF;
END;
$$;
