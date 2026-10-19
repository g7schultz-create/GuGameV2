-- 0496_the_lid_i_raised_never_reached_the_fight
--
-- 0492 made the Gu effect lid rise with the realm and changed exactly one
-- reader: the `player_gu_stats` view. It missed the reader that matters.
--
--     gu_stat(sylvrime, 'crit_damage')      7.80   <- the view, new lid
--     player_stat(sylvrime, 'crit_damage')  2.00   <- combat, FLAT cap
--
-- `player_stat` is `LEAST((SELECT ef.cap FROM gu_effects ef ...), sum of
-- eight sources)`. It reads the flat `cap` column directly, so every fight in
-- the game still clamps to 2.00 crit_damage and 3.00 multi_hit. Which means:
--
--   1. 0492 and 0493 are INERT. The rank 9 worms I gave crit_damage 2.90 and
--      multi_hit 3.40 contribute nothing a fight can see. The user asked for
--      tier 9 Gu to be powerful and they are not.
--   2. The /gu screen now LIES. It reads `gu_stat`, so it has been telling
--      sylvrime they carry 7.80 crit_damage while their blows are computed at
--      2.00. I introduced that.
--   3. And nobody was buffed, so no content broke. I reported last turn that
--      0493 had handed the rank 9 owners a large live buff and that rank 18
--      encounters now needed to move. The buff never happened. The boss
--      imbalance I measured afterwards - one cultivator bursting 7.58e15 at a
--      2.42e15 pool - is real but PRE-EXISTING, not something I caused.
--
-- A guard moved and a reader did not, for the fifth time in this programme,
-- and this time I wrote the guard.
--
-- THE FIX IS ONE DEFINITION. `player_stat` asks `gu_effect_cap(effect,
-- player)` the same way the view does, and `gu_effects.cap` stops being read
-- from two places with two meanings.
--
-- WHAT IT MOVES, measured on the uncapped eight-source totals rather than
-- predicted:
--
--     cultivator      crit uncapped -> lid      strikes        damage
--     sylvrime        8.17  2.00 -> 8.17        8.36 -> 7.20    ~5.2x
--     real._.yoru     7.80  2.00 -> 7.80        7.46 -> 6.80    ~4.6x
--     ._.visha._.     7.57  2.00 -> 7.57        7.60 -> 7.20    ~4.8x
--     clearwest       6.83  2.00 -> 6.83        3.65 -> 3.65    ~3.4x
--     shinonn._.      2.32  2.00 -> 2.32        3.35 -> 3.35    ~1.2x
--     pashu0, miyuki  below the flat cap already               unchanged
--
-- Four cultivators gain four to five times their output and four gain
-- nothing, which is the shape the user asked for: it is exactly the people
-- who went and got rank 9 worms. It is also a LARGE live change and the
-- biggest single damage move in this programme, so it is reported per
-- cultivator by the probe rather than summarised.
--
-- CONTENT MOSTLY FOLLOWS ON ITS OWN, which is why this is safe to do in one
-- step. Every lane but one sizes itself off the player:
--
--     boss_hp_pool        reads player_blow_multiple -> player_stat   auto
--     horde_walker_burst  reads player_stat                           auto
--     trial_boss_hp       rehearses through trial_rehearse            auto
--     delve               rehearses through delve_rehearse            auto
--     dungeon_boss_hp     base_hp x difficulty x party step        DOES NOT
--
-- The dungeon is the one fixed formula and it gets 0497. Everything else
-- resizes the moment this lands, because the people who built those lanes
-- sized them against the player instead of against a number.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('player_stat(bigint,text)'::regprocedure);

    -- The flat read, on one line. Lifted and patched rather than retyped,
    -- because the eight sources below it are the whole stat system.
    anchor := '        (SELECT ef.cap FROM gu_effects ef WHERE ef.code = p_effect),';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the flat cap read in player_stat is not there exactly once';
    END IF;

    src := replace(src, anchor,
        '        -- One definition of the lid, shared with player_gu_stats.' || chr(10) ||
        '        -- This read used to be `ef.cap` - the flat column - so the' || chr(10) ||
        '        -- realm-scaled lid 0492 introduced never reached a fight and' || chr(10) ||
        '        -- the /gu screen reported a number combat did not use.' || chr(10) ||
        '        gu_effect_cap(p_effect, p_player_id),');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The two readers agree, and the drift is named per cultivator
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_disagree TEXT;
    v_moved    TEXT;
    v_n        INTEGER;
    r          RECORD;
BEGIN
    -- The patch landed and nothing else in the body moved.
    IF pg_get_functiondef('player_stat(bigint,text)'::regprocedure)
       NOT LIKE '%gu_effect_cap(p_effect, p_player_id)%' THEN
        RAISE EXCEPTION 'player_stat still reads the flat cap';
    END IF;
    IF pg_get_functiondef('player_stat(bigint,text)'::regprocedure)
       NOT LIKE '%servant_stat(p_player_id, p_effect)%' THEN
        RAISE EXCEPTION 'a source went missing from player_stat';
    END IF;

    -- THE THING THAT WAS WRONG: the screen and the fight must not disagree.
    -- player_stat can exceed gu_stat, because seven other sources feed it; it
    -- must never be clamped BELOW what the worms alone already give.
    SELECT string_agg(x.line, ', ') INTO v_disagree FROM (
        SELECT p.discord_name || ' ' || e.code || ': worms give '
               || round(gu_stat(p.player_id, e.code), 2)
               || ' but the fight uses '
               || round(player_stat(p.player_id, e.code), 2) AS line
        FROM players p
        CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND e.code IN ('crit_damage', 'multi_hit')
          AND gu_stat(p.player_id, e.code) > player_stat(p.player_id, e.code) + 0.001
    ) x;
    IF v_disagree IS NOT NULL THEN
        RAISE EXCEPTION 'the screen still outruns the fight: %', v_disagree;
    END IF;

    -- No cultivator is above their own lid on any effect, which is what a lid
    -- is for.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND player_stat(p.player_id, e.code)
          > gu_effect_cap(e.code, p.player_id) + 0.001;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% readings sit above their own lid', v_n;
    END IF;

    -- Nobody falls. A lid that only rises cannot take anything away, and if
    -- it did the right response would be to stop rather than to report it.
    FOR r IN
        SELECT p.player_id, p.discord_name, e.code,
               player_stat(p.player_id, e.code) AS now_at,
               LEAST(e.cap,
                     gu_stat(p.player_id, e.code) + equipment_stat(p.player_id, e.code)
                     + physique_stat(p.player_id, e.code) + root_stat(p.player_id, e.code)
                     + dwelling_stat(p.player_id, e.code) + manual_stat(p.player_id, e.code)
                     + destiny_stat(p.player_id, e.code) + servant_stat(p.player_id, e.code)
               ) AS was_at
        FROM players p CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL AND e.code IN ('crit_damage', 'multi_hit')
    LOOP
        IF r.now_at < r.was_at - 0.001 THEN
            RAISE EXCEPTION
                'player % lost % on %: % became %',
                r.discord_name, r.was_at - r.now_at, r.code, r.was_at, r.now_at;
        END IF;
    END LOOP;

    -- And the blow multiple, which is what every content lane sizes off, has
    -- stopped being the same number for everybody. It read 6.625 for all four
    -- of the top cultivators because all four were pinned at both flat caps.
    SELECT count(DISTINCT round(player_blow_multiple(p.player_id), 3)) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_gu_equipped q WHERE q.player_id = p.player_id);
    IF v_n < 2 THEN
        RAISE EXCEPTION
            'every cultivator still has the same blow multiple - the lid did not reach it';
    END IF;

    SELECT string_agg(x.line, ' | ') INTO v_moved FROM (
        SELECT p.discord_name || ' x' || round(
                   player_blow_multiple(p.player_id)
                   / NULLIF((1 + LEAST(3.0, player_stat(p.player_id,'multi_hit'))
                                 * game_config_value('gu_multi_hit_power'))
                            * (1 + player_stat(p.player_id,'crit_rate')
                                   * (game_config_value('gu_crit_damage_base')
                                      + LEAST(2.0, player_stat(p.player_id,'crit_damage')))), 0)
               , 2) AS line
        FROM players p
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_gu_equipped q WHERE q.player_id = p.player_id)
        ORDER BY player_blow_multiple(p.player_id) DESC
        LIMIT 6
    ) x;

    RAISE NOTICE 'damage multiple against the old flat caps: %', v_moved;
END;
$probe$;
