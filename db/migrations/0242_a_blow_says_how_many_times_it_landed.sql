-- 0242_a_blow_says_how_many_times_it_landed
--
-- "Does extra strike work?" It does, and nobody could tell.
--
-- 0225 gave the whole game one swing and `player_swing` is still the only
-- function in this database that reads `multi_hit`. Measured over 600 swings
-- at a 0.5394 stat: 306 of them struck twice, and a double landed 1.55 times
-- the damage of a single - exactly 1 + `gu_multi_hit_power`. The mechanic is
-- correct in all four fights.
--
-- It is the SCREENS that never said so. `player_swing` hands back how many
-- times it landed and how many of those bit, and:
--
--   * `battle_act` returns `strikes` and `crits` and the duel's round log
--     renders neither;
--   * `dungeon_resolve_round` puts only `damage` in its line, dropping both;
--   * `horde_strike` does not even return them.
--
-- The gauntlet is the one place that says it, because it was written after the
-- effect existed. So a cultivator wearing a Gu called Extra Strikes swings,
-- sees one number, and has no way to know whether the thing they bought does
-- anything - which is how a working feature gets reported as broken.
--
-- An effect that fires invisibly is the same failure as an effect that does
-- not fire. This migration makes the two fights that compute it say it; the
-- screens follow.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The channel says it
-- ---------------------------------------------------------------------------
-- The return type grows, so this is a DROP and a CREATE rather than a replace.
-- Lifted and patched so the body cannot drift from what is running.

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'horde_strike';

    old := ' RETURNS TABLE(dealt bigint, hp_left bigint, max_hp bigint, killed boolean, beast_name text, kind text, bounty bigint)';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer returns what it used to';
    END IF;
    src := replace(src, old,
        ' RETURNS TABLE(dealt bigint, hp_left bigint, max_hp bigint, killed boolean, beast_name text, kind text, bounty bigint, strikes smallint, crits smallint)');

    old := '    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid;';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'horde_strike no longer returns the swing the old way';
    END IF;
    src := replace(src, old,
        '    RETURN QUERY SELECT hurt,
                        GREATEST(0, met.hp - hurt), met.max_hp, down,
                        met.species_name, met.kind, paid,
                        swung.strikes, swung.crits;');

    DROP FUNCTION horde_strike(BIGINT, BIGINT);
    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- And so does a dungeon round
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round';

    old := '        lines := lines || jsonb_build_object(
            ''who'', one.discord_name,
            ''kind'', ''strike'',
            ''move'', (SELECT t.name FROM techniques t WHERE t.technique_id = move),
            ''damage'', dealt,
            ''chosen'', one.intent_id IS NOT NULL);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_resolve_round no longer logs a strike the old way';
    END IF;

    EXECUTE replace(src, old,
        '        lines := lines || jsonb_build_object(
            ''who'', one.discord_name,
            ''kind'', ''strike'',
            ''move'', (SELECT t.name FROM techniques t WHERE t.technique_id = move),
            ''damage'', dealt,
            -- The swing already worked these out. Dropping them here is why
            -- a build assembled around extra strikes looked identical to one
            -- without, from the only screen that reports the fight.
            ''strikes'', swung.strikes,
            ''crits'', swung.crits,
            ''chosen'', one.intent_id IS NOT NULL);');
END;
$$;


DO $$
DECLARE
    who   BIGINT;
    tide  BIGINT;
    made  BIGINT;
    hit   RECORD;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody who can swing; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        UPDATE beast_hordes SET status = 'won', ended_at = now()
        WHERE status IN ('fighting', 'king');
        tide := horde_open('northern', 2::smallint, NULL);
        made := horde_spawn(tide);

        SELECT * INTO hit FROM horde_strike(made, who);

        IF hit.strikes IS NULL THEN
            RAISE EXCEPTION 'a channel strike still will not say how often it landed';
        END IF;
        IF hit.strikes < 1 THEN
            RAISE EXCEPTION 'a swing that dealt % landed % times', hit.dealt, hit.strikes;
        END IF;
        IF hit.crits IS NULL THEN
            RAISE EXCEPTION 'a channel strike will not say whether it bit';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
