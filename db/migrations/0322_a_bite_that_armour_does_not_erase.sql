-- 0322_a_bite_that_armour_does_not_erase
--
-- 0320 sized the gauntlet's bite at a share of the walker's own body and took
-- its reference blow at zero defence, reasoning that armour should still do
-- its job on the real one. Driving an actual run showed what that is worth:
--
--     clearwest, wave one, dealt 273,061,235, TAKEN 0
--
-- The bite computed to 799,307 - three percent of a 26,643,567 body, as
-- intended - and arrived as 21.
--
-- DEFENCE IS A RATIO, NOT A SUBTRACTION. `compute_creature_damage` ends on
--
--     after_defense := raw * dscale / (dscale + def) * (1 - resist)
--
-- where dscale is `defense_scale` times a per-rank step - about 60 against a
-- rank 1 beast. clearwest wears 2,271,932 of defence. Every point of creature
-- damage in the game is therefore divided by roughly thirty-eight thousand
-- before it lands. Taking the reference at zero defence measured a blow that
-- never happens and then let the real one be erased.
--
-- This is not a horde problem - it is every lane a creature swings in, and
-- the curve is not being rewritten here. What IS fixed is the one lane that
-- claims to size itself to the person walking it: the reference blow now
-- includes their armour, so `horde_gauntlet_bite_share` means what it says.
--
-- THAT MAKES THE LANE SELF-NORMALISING ON BOTH SIDES, which is deliberate
-- and worth stating plainly. A wave's HEALTH is already measured against the
-- walker's own burst, so hitting harder does not make waves fall faster; now
-- its BITE is measured against the walker's own body, so wearing more armour
-- does not make waves hurt less. What is left is depth - the 1.18 step - and
-- depth is what this lane has always said it was about. Gear still decides
-- everything in every other lane; here it decides how far you get before the
-- compounding catches you, which is the same for everybody by design.
--
-- THE PROBE MULTIPLIER IS NOT DECORATION. `compute_creature_damage` clamps
-- its result to GREATEST(1, ...), and a reference blow taken at real defence
-- lands well below one - clearwest's is 0.00037. Asking for the blow at
-- multiplier 1 and dividing would divide by that clamped 1 and be wrong by
-- four orders of magnitude. Damage is linear in the multiplier, so the
-- reference is taken at a millionfold multiple, far above where the clamp
-- can bind, and scaled back down.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'                    -- A share of the body actually standing there, turned', chr(10),
'                    -- into the multiple this species needs to land it. The', chr(10),
'                    -- reference blow is taken at zero defence so that the', chr(10),
'                    -- armour still does its job on the real one.', chr(10),
'                    game_config_value(''horde_gauntlet_bite_share'') * run.max_hp', chr(10),
'                    / GREATEST(1, (SELECT b.final_damage', chr(10),
'                                   FROM compute_creature_damage(', chr(10),
'                                       run.species_id, run.player_id, 1, 0) b))');

    swap := concat(
'                    -- A share of the body actually standing there, turned', chr(10),
'                    -- into the multiple this species needs to land it. The', chr(10),
'                    -- reference blow carries the walker''''s own armour, because', chr(10),
'                    -- defence here divides rather than subtracts: measured', chr(10),
'                    -- without it, a three percent bite arrived as 21.', chr(10),
'                    --', chr(10),
'                    -- Taken at a millionfold multiple and scaled back down.', chr(10),
'                    -- Damage is linear in the multiple, and the reference at', chr(10),
'                    -- multiple 1 lands under the GREATEST(1, ...) clamp inside', chr(10),
'                    -- compute_creature_damage - dividing by that clamp is the', chr(10),
'                    -- whole bug being fixed.', chr(10),
'                    game_config_value(''horde_gauntlet_bite_share'')', chr(10),
'                    * run.max_hp * 1000000', chr(10),
'                    / GREATEST(1, (SELECT b.final_damage', chr(10),
'                                   FROM compute_creature_damage(', chr(10),
'                                       run.species_id, run.player_id, 1000000) b))');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_gauntlet_swing';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the gauntlet no longer takes its reference blow where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A wave now takes a real share of whoever is standing in front of it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who   BIGINT;
    nm    TEXT;
    body  BIGINT;
    def   BIGINT;
    sp    BIGINT;
    share NUMERIC := game_config_value('horde_gauntlet_bite_share');
    mult  NUMERIC;
    lands BIGINT;
    old   BIGINT;
BEGIN
    -- Read-only on purpose. There is a live tide on this server as this is
    -- being applied, with somebody mid-run on it; a probe that opened a
    -- gauntlet to measure one would be writing gameplay state into a running
    -- event to check its own arithmetic.
    SELECT p.player_id, p.discord_name, pp.max_hp, pp.defense
    INTO who, nm, body, def
    FROM players p
    JOIN player_physique pp ON pp.player_id = p.player_id
    WHERE p.deleted_at IS NULL
    ORDER BY pp.defense DESC NULLS LAST
    LIMIT 1;

    SELECT species_id INTO sp FROM creature_species WHERE code = 'crescent_horn_deer';

    IF who IS NULL OR sp IS NULL OR COALESCE(def, 0) = 0 THEN
        RAISE NOTICE 'no armoured body to measure against';
        RETURN;
    END IF;

    -- Exactly what the patched function now computes at wave one.
    mult := GREATEST(
        game_config_value('horde_gauntlet_bite'),
        share * body * 1000000
        / GREATEST(1, (SELECT b.final_damage
                       FROM compute_creature_damage(sp, who, 1000000) b)));

    lands := (SELECT b.final_damage
              FROM compute_creature_damage(sp, who, mult, def) b);

    -- And what it computed before, which is the thing that came back as 21.
    old := (SELECT b.final_damage
            FROM compute_creature_damage(sp, who,
                GREATEST(game_config_value('horde_gauntlet_bite'),
                         share * body
                         / GREATEST(1, (SELECT b2.final_damage
                                        FROM compute_creature_damage(sp, who, 1, 0) b2))),
                def) b);

    IF lands < share * body / 2 THEN
        RAISE EXCEPTION
            'wave one still lands % on a body of % - wanted about %',
            lands, body, round(share * body);
    END IF;

    -- Non-vacuous: the old arithmetic must actually fail this bar, or the
    -- probe is agreeing with a bug rather than catching one.
    IF old >= share * body / 2 THEN
        RAISE EXCEPTION
            'the old reference blow was fine after all (% on %) - this probe proves nothing',
            old, body;
    END IF;

    RAISE NOTICE 'wave one against %: % was %, now % of a % body',
        nm, old, round(old * 100.0 / body, 4), lands, body;
END;
$probe$;
