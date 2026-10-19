-- 0562_suppression_works_where_the_fight_is
--
-- Suppression is described as 'the chance a creature's chosen move never comes
-- out', and it is one of the strongest things a cultivator can carry: the
-- creature's whole attack lands for zero, up to 60% of turns at a full Gu
-- investment.
--
-- It was read by exactly one function. `battle_act`.
--
-- So it worked on a hunt, an ambush and a tribulation, and did NOTHING in a
-- dungeon, a delve, the horde gauntlet or against a world boss - every lane
-- that swings through `player_swing` instead. Thirteen functions go that way
-- and not one of them rolled it. A player reading the description has no way
-- to learn that it stops working the moment they walk into the Vault.
--
-- WHERE IT GOES. `compute_creature_damage` is the one place a creature's blow
-- against a cultivator is priced - `battle_act`, `delve_act`,
-- `dungeon_resolve_round`, `horde_gauntlet_swing` and `strike_boss` all call
-- it - so that is the chokepoint. But it is STABLE, and a stable function that
-- rolls `random()` is a function the planner may evaluate once and reuse. The
-- roll cannot live inside it.
--
-- So the RULE lives in one volatile helper and the five lanes call it.
-- `battle_act`'s own inline roll is replaced by the same helper, so there is
-- one definition of what suppression is rather than a first one and four
-- copies - which is how this effect came to be in one lane in the first place.
--
-- NOT SUPPRESSED, deliberately:
--
--   horde_gauntlet_swing's FIRST call to `compute_creature_damage` is not a
--   blow. It is a sizing calculation that the wave bite is divided by, and
--   suppressing it would divide by a suppressed number and make the gauntlet
--   hit HARDER. Only the second call, the one that reaches `player_take`, is
--   an attack.
--
--   A DUEL. `duel_resolve` has no creature in it - the thing swinging at you
--   is another cultivator, and silencing a person's chosen technique is a new
--   PvP mechanic rather than this one reaching further. Suppression says
--   'a creature's chosen move'. Extending it to people is a separate decision
--   about whether a duel should have crowd control in it at all.
--
--   A BETRAYAL in the Vault, for the same reason: the knife is a cultivator's
--   technique, priced by `compute_duel_damage`, not a creature's move.


CREATE OR REPLACE FUNCTION suppression_hushes(p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql
VOLATILE
AS $fn$
    -- VOLATILE and nothing else, because the roll is the whole function.
    -- `compute_creature_damage` would have been the tidier home and it is
    -- STABLE - a stable function carrying `random()` is one the planner is
    -- entitled to evaluate once and reuse across every raider in a round.
    SELECT random() < COALESCE(player_stat(p_player_id, 'suppression'), 0);
$fn$;

COMMENT ON FUNCTION suppression_hushes(BIGINT) IS
    'Whether this cultivator''s Suppression stops the creature''s move this turn. The one definition of the roll - `battle_act` held it inline until 0562 and the other four creature lanes had no copy at all, so the effect silently did nothing in every dungeon, delve, gauntlet and world boss fight.';


-- A multiplier, so a lane can apply the roll without declaring a variable and
-- without a second call changing its mind.
CREATE OR REPLACE FUNCTION suppression_bite(p_player_id BIGINT)
RETURNS INTEGER
LANGUAGE sql
VOLATILE
AS $fn$
    SELECT CASE WHEN suppression_hushes(p_player_id) THEN 0 ELSE 1 END;
$fn$;


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    -- ---- 1. battle_act: one definition instead of an inline copy ----------
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'battle_act' AND pronamespace = 'public'::regnamespace;

    IF position('AND random() < player_stat(me.player_id, ''suppression'');'
                IN src) = 0 THEN
        RAISE EXCEPTION 'battle_act does not roll suppression where it did';
    END IF;
    patched := replace(src,
        'AND random() < player_stat(me.player_id, ''suppression'');',
        'AND suppression_hushes(me.player_id);');
    EXECUTE patched;

    -- ---- 2. the dungeon ---------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'dungeon_resolve_round' AND pronamespace = 'public'::regnamespace;

    IF position('            target, hit.final_damage,' IN src) = 0 THEN
        RAISE EXCEPTION 'the dungeon does not hand the blow to player_take where it did';
    END IF;
    patched := replace(src,
        '            target, hit.final_damage,',
        '            -- SUPPRESSION REACHES THE ROOM (0562). It was read only by
            -- `battle_act`, so a raider carrying it was paying aperture for
            -- nothing in every dungeon they had ever entered.
            target, hit.final_damage * suppression_bite(target),');
    EXECUTE patched;

    -- ---- 3. the delve -----------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;

    IF position('            GREATEST(0, COALESCE(hit.final_damage, 0)),' IN src) = 0 THEN
        RAISE EXCEPTION 'the delve does not take the blow where it did';
    END IF;
    patched := replace(src,
        '            GREATEST(0, COALESCE(hit.final_damage, 0)),',
        '            -- 0562: suppression reaches the delve too.
            GREATEST(0, COALESCE(hit.final_damage, 0))
                * suppression_bite(p_player_id),');
    EXECUTE patched;

    -- ---- 4. the gauntlet, and only its real blow --------------------------
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'horde_gauntlet_swing' AND pronamespace = 'public'::regnamespace;

    IF position('            run.player_id, bit.final_damage, body, run.max_hp,' IN src) = 0 THEN
        RAISE EXCEPTION 'the gauntlet does not land its bite where it did';
    END IF;
    patched := replace(src,
        '            run.player_id, bit.final_damage, body, run.max_hp,',
        '            -- 0562. The sizing call further up is NOT suppressed: the
            -- wave bite is divided by it, so a suppressed divisor would make
            -- the gauntlet hit harder.
            run.player_id, bit.final_damage * suppression_bite(run.player_id),
            body, run.max_hp,');
    EXECUTE patched;

    -- ---- 5. the world boss ------------------------------------------------
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'strike_boss' AND pronamespace = 'public'::regnamespace;

    IF position('            p_player_id, raw_bite, body.current_hp, body.max_hp, FALSE,'
                IN src) = 0 THEN
        RAISE EXCEPTION 'the world boss does not bite where it did';
    END IF;
    patched := replace(src,
        '            p_player_id, raw_bite, body.current_hp, body.max_hp, FALSE,',
        '            -- 0562: suppression reaches the world boss.
            p_player_id, raw_bite * suppression_bite(p_player_id),
            body.current_hp, body.max_hp, FALSE,');
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_fn   TEXT;
    v_miss TEXT := '';
    v_n    INTEGER;
    v_hush INTEGER := 0;
    i      INTEGER;
    v_who  BIGINT;
BEGIN
    -- 1. EVERY CREATURE LANE NOW ROLLS IT, named rather than counted so the
    --    failure says which one was missed.
    FOREACH v_fn IN ARRAY ARRAY['battle_act', 'dungeon_resolve_round',
                                'delve_act', 'horde_gauntlet_swing',
                                'strike_boss'] LOOP
        IF (SELECT pg_get_functiondef(oid) FROM pg_proc
            WHERE proname = v_fn AND pronamespace = 'public'::regnamespace)
           !~ 'suppression_(hushes|bite)' THEN
            v_miss := v_miss || ' ' || v_fn;
        END IF;
    END LOOP;
    IF v_miss <> '' THEN
        RAISE EXCEPTION 'these lanes still ignore suppression:%', v_miss;
    END IF;

    -- 2. AND THERE IS ONLY ONE DEFINITION OF THE ROLL. `battle_act` held it
    --    inline, which is how four lanes came to have no copy.
    IF (SELECT pg_get_functiondef(oid) FROM pg_proc
        WHERE proname = 'battle_act' AND pronamespace = 'public'::regnamespace)
       ~ 'random\(\) < player_stat' THEN
        RAISE EXCEPTION 'battle_act still rolls suppression on its own';
    END IF;

    -- 3. THE GAUNTLET'S SIZING CALL IS UNTOUCHED. Suppressing it would divide
    --    the wave bite by a suppressed number and hit HARDER.
    IF (SELECT pg_get_functiondef(oid) FROM pg_proc
        WHERE proname = 'horde_gauntlet_swing'
          AND pronamespace = 'public'::regnamespace)
       !~ 'GREATEST\(1, \(SELECT b\.final_damage' THEN
        RAISE EXCEPTION 'the gauntlet sizing call was altered';
    END IF;

    -- 4. THE ROLL IS A ROLL. A helper that always says no would pass every
    --    check above and change nothing in play.
    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id > 0
      AND player_stat(p.player_id, 'suppression') > 0
    ORDER BY player_stat(p.player_id, 'suppression') DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody carries suppression, so the roll was not exercised';
    ELSE
        FOR i IN 1..200 LOOP
            IF suppression_hushes(v_who) THEN v_hush := v_hush + 1; END IF;
        END LOOP;
        IF v_hush = 0 OR v_hush = 200 THEN
            RAISE EXCEPTION
                'suppression came back % times in 200 for a cultivator holding '
                '% - that is not a roll', v_hush,
                round(player_stat(v_who, 'suppression'), 3);
        END IF;
        RAISE NOTICE
            'suppression at % hushed % of 200 rolls',
            round(player_stat(v_who, 'suppression'), 3), v_hush;
    END IF;

    -- 5. AND SOMEBODY WITH NONE IS NEVER HUSHED.
    SELECT p.player_id INTO v_who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id > 0
      AND COALESCE(player_stat(p.player_id, 'suppression'), 0) = 0
    LIMIT 1;
    IF v_who IS NOT NULL THEN
        FOR i IN 1..100 LOOP
            IF suppression_hushes(v_who) THEN
                RAISE EXCEPTION
                    'a cultivator with no suppression suppressed something';
            END IF;
        END LOOP;
    END IF;
END
$probe$;
