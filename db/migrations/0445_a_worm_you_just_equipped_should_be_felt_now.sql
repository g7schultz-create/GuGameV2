-- 0445_a_worm_you_just_equipped_should_be_felt_now
--
-- A bug 0443 introduced, found by a test asking a question 0443 did not think
-- to ask.
--
-- Before 0443, a Gu granting `attack_power` reached damage through
-- `player_external_multiplier`, which calls `player_stat` live - so equipping
-- one was felt on the very next swing. 0443 moved that grant onto
-- `base_strength`, which is far better in every way except one: it lands in
-- `player_physique.strength`, and that is a STORED column written by
-- `apply_physique_xp`. Nothing recomputes the body when a Gu goes on.
--
--     equip / unequip            recompute  (0066 made sure of it)
--     equipping a Gu             DOES NOT
--     a servant coming to attend DOES NOT
--
-- So a cultivator who slotted a Sinew Gu would see nothing happen until they
-- next trained, took a pill or changed armour. That is precisely the
-- "gear that does nothing until you train" fault `equip()` was fixed for, and
-- the conversion walked two more sources into it.
--
-- A TRIGGER RATHER THAN THREE PATCHED CALLERS. Gu are equipped by a bare
-- INSERT from the bot - there is no `equip_gu` function to fix - and a preset
-- load, a trade and anything written next all reach the same table. Patching
-- the callers I can find today is how this fault got here. The table itself
-- is the one place every path has to go through.
--
-- IT FIRES PER ROW, and a preset load of six Gu therefore recomputes six
-- times. That is wasteful and it is the right trade: `apply_physique_xp` is
-- idempotent, the alternative is a statement-level trigger that has to work
-- out which players were touched, and a body that is briefly recomputed twice
-- is invisible while a body that is never recomputed is a bug report.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION recompute_body_on_loadout_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_who BIGINT;
BEGIN
    v_who := COALESCE(NEW.player_id, OLD.player_id);
    IF v_who IS NOT NULL
       AND EXISTS (SELECT 1 FROM player_physique WHERE player_id = v_who) THEN
        PERFORM apply_physique_xp(v_who, 0);
    END IF;
    RETURN NULL;
END;
$fn$;

COMMENT ON FUNCTION recompute_body_on_loadout_change() IS
    'Rewrites the stored body after anything that changes what a cultivator is carrying. Since 0443 a Gu and a servant can grant base stats, and a base stat only reaches a fight through player_physique - which is written rather than read live.';


CREATE TRIGGER player_gu_equipped_recomputes_the_body
    AFTER INSERT OR DELETE ON player_gu_equipped
    FOR EACH ROW EXECUTE FUNCTION recompute_body_on_loadout_change();

CREATE TRIGGER player_servant_attending_recomputes_the_body
    AFTER INSERT OR DELETE ON player_servant_attending
    FOR EACH ROW EXECUTE FUNCTION recompute_body_on_loadout_change();


-- ---------------------------------------------------------------------------
-- A Sinew worm is felt the moment it goes on
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who    BIGINT;
    v_gu     BIGINT;
    v_type   BIGINT;
    v_before BIGINT;
    v_after  BIGINT;
    r        RECORD;
BEGIN
    BEGIN
        -- Somebody with a body, and a Gu type that grants sinew.
        -- Somebody with room in their aperture. The first draft took the
        -- strongest cultivator in the game and `enforce_gu_capacity` refused
        -- the insert - their aperture was already full, which says nothing
        -- about whether the trigger works.
        SELECT pp.player_id INTO v_who FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND pp.strength > 0
          AND NOT EXISTS (SELECT 1 FROM player_gu_equipped e
                          WHERE e.player_id = pp.player_id)
        ORDER BY pp.strength DESC LIMIT 1;

        -- The SHALLOWEST sinew worm, not the strongest. A rank 9 Gu costs 9
        -- of an aperture that holds 6, and the second draft of this probe was
        -- refused for that - which again says nothing about the trigger.
        SELECT e.gu_type_id INTO v_type
        FROM gu_type_effects e
        JOIN gu_types t ON t.gu_type_id = e.gu_type_id
        WHERE e.effect_code = 'base_strength'
        ORDER BY t.rank ASC, e.magnitude DESC LIMIT 1;

        IF v_who IS NULL OR v_type IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT pp.strength INTO v_before FROM player_physique pp
        WHERE pp.player_id = v_who;

        INSERT INTO player_gu (owner_id, gu_type_id, stars, harmony)
        VALUES (v_who, v_type, 1, 100)
        RETURNING gu_id INTO v_gu;

        INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (v_gu, v_who);

        SELECT pp.strength INTO v_after FROM player_physique pp
        WHERE pp.player_id = v_who;

        IF v_after <= v_before THEN
            RAISE EXCEPTION
                'a Sinew worm was equipped and the body did not move: % -> %',
                v_before, v_after;
        END IF;

        -- And taking it off puts the body back.
        DELETE FROM player_gu_equipped WHERE gu_id = v_gu;
        SELECT pp.strength INTO v_after FROM player_physique pp
        WHERE pp.player_id = v_who;
        IF v_after <> v_before THEN
            RAISE EXCEPTION
                'taking the worm off left the body at % rather than %',
                v_after, v_before;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Every table that can change what somebody carries, and whether the body
    -- is rewritten when it does. Listed so the next one added is noticed.
    FOR r IN
        SELECT t.relname,
               EXISTS (SELECT 1 FROM pg_trigger g
                       WHERE g.tgrelid = t.oid AND NOT g.tgisinternal
                         AND g.tgfoid = 'recompute_body_on_loadout_change'::regproc)
               AS by_trigger
        FROM pg_class t
        WHERE t.relname IN ('player_gu_equipped', 'player_servant_attending',
                            'player_equipped', 'player_manual_slots')
          AND t.relnamespace = 'public'::regnamespace
        ORDER BY t.relname
    LOOP
        RAISE NOTICE '% : recomputed by trigger = %',
            rpad(r.relname, 26), r.by_trigger;
    END LOOP;
END;
$probe$;
