-- 0468_a_thing_that_cannot_hurt_you_is_not_strong
--
-- The first delve fight, against the thing from the deep:
--
--     round 1 | dealt 19.5T | took 1 | beast 273T | me 523042298996/523042298997
--     round 2 | dealt 43.6T | took 1 | beast 230T | me 523042298996/523042298997
--     ...
--     round 9 | dealt 26.5T | took 0 | beast   0  | me 523042298997/523042298997
--
-- One point of damage a round, against five hundred and twenty-three billion.
-- The cultivator finished the fight at full health because the single point it
-- had taken regenerated. Nine rounds of nothing happening.
--
-- 0467 sized the beast's BODY by rehearsal, for exactly the reason that its
-- bite now needs the same treatment: `compute_creature_damage` reads
-- `creature_species` numbers that have not moved while cultivators grew by
-- factors of a hundred thousand. I fixed the half of it I had just been
-- burned on and left the other half reading a table I already knew was stale.
--
-- SO A BITE IS A SHARE OF YOU. The same device the Peer Trial's threats use,
-- and for the same reason: a share costs the same proportion at realm 3 as at
-- realm 18, so one number works at every depth of the game.
--
--     a beast          6 per cent of your maximum a round
--     the deep thing   9
--
-- Against bodies sized at four rounds and ten, that is a quarter of you for a
-- beast and very nearly all of you for the deep one - which is what "very very
-- strong" has to mean if it is to mean anything.
--
-- THE OLD NUMBER IS KEPT AS A FLOOR. `GREATEST` of the share and what
-- `compute_creature_damage` says, so nothing is ever made gentler than it was,
-- and a creature that somehow outgrows the share still hits for what it is
-- worth.
--
-- AND IT STILL READS YOUR DEFENCE, because the share is of your maximum and
-- the floor is the computed figure - a cultivator who has built defence takes
-- the smaller of the two paths down, not a flat tax that armour cannot touch.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE delve_tile_kinds
    ADD COLUMN bite NUMERIC(5,3) NOT NULL DEFAULT 0;

COMMENT ON COLUMN delve_tile_kinds.bite IS
    'What this tile''s creature takes out of a cultivator in a round, as a share of their own maximum. A share rather than a number because creature damage has not kept pace with cultivation and a flat figure is worth nothing at depth. Zero for tiles that are not a fight.';

UPDATE delve_tile_kinds SET bite = 0.060 WHERE kind = 'beast';
UPDATE delve_tile_kinds SET bite = 0.090 WHERE kind = 'deep';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_strike' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_strike is missing';
    END IF;

    anchor := concat(
'        v_taken := GREATEST(0, COALESCE(hit.final_damage, 0));');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_strike no longer takes its bite where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        -- 0468: a share of you, with the computed figure kept as a floor.', chr(10),
'        -- The bestiary''s own numbers are worth a single point against a', chr(10),
'        -- realm 18 body, so the share is what makes a beast a beast.', chr(10),
'        v_taken := GREATEST(', chr(10),
'            GREATEST(0, COALESCE(hit.final_damage, 0)),', chr(10),
'            GREATEST(1, round(v_max * COALESCE(', chr(10),
'                (SELECT k.bite FROM delve_tile_kinds k', chr(10),
'                 WHERE k.kind = f.tile_kind), 0)))::bigint);'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- It can actually hurt somebody now
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p     BIGINT;
    v_id    BIGINT;
    at      RECORD;
    r       RECORD;
    v_max   BIGINT;
    v_worst BIGINT := 0;
    n       INTEGER := 0;
BEGIN
    -- Both fighting tiles bite, and the deep one bites harder.
    IF (SELECT k.bite FROM delve_tile_kinds k WHERE k.kind = 'beast') <= 0 THEN
        RAISE EXCEPTION 'an ordinary beast still cannot hurt anybody';
    END IF;
    IF (SELECT k.bite FROM delve_tile_kinds k WHERE k.kind = 'deep')
       <= (SELECT k.bite FROM delve_tile_kinds k WHERE k.kind = 'beast') THEN
        RAISE EXCEPTION 'the thing from the deep bites no harder than a boar';
    END IF;

    -- Nothing that is not a fight acquired a bite.
    IF EXISTS (SELECT 1 FROM delve_tile_kinds k
               WHERE NOT k.is_beast AND k.bite > 0) THEN
        RAISE EXCEPTION 'a seam is biting people';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        JOIN player_physique pp ON pp.player_id = p.player_id
        WHERE p.deleted_at IS NULL
          AND EXISTS (SELECT 1 FROM player_techniques pt
                      WHERE pt.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.region_code = pl.region_code)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT pp.max_hp INTO v_max FROM player_physique pp
        WHERE pp.player_id = v_p;

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);
        SELECT r2.at_x, r2.at_y INTO at FROM delve_runs r2
        WHERE r2.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'deep', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;

        PERFORM delve_step(v_p, 'up');

        LOOP
            n := n + 1;
            EXIT WHEN n > 40;
            SELECT * INTO r FROM delve_strike(v_p, NULL);
            v_worst := GREATEST(v_worst, r.taken);
            EXIT WHEN r.outcome IN ('slain', 'died');
        END LOOP;

        RAISE NOTICE
            'the deep thing took % a round out of a body of % - % of it',
            v_worst, v_max,
            round(100.0 * v_worst / GREATEST(1, v_max), 1);

        -- The heart of it: a round against the deep thing has to be felt.
        IF v_worst < v_max / 100 THEN
            RAISE EXCEPTION
                'the deep thing takes % out of a body of %, which is nothing',
                v_worst, v_max;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
