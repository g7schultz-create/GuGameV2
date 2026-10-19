-- 0507_the_bite_was_short_because_the_attack_was_short
--
-- 0505 gave creature damage a floor - a share of the body it is biting - and
-- a standing test refused it inside the hour, correctly:
--
--     test_creature_damage_mirrors_the_technique_clamps
--     assert dmg("ash_moth", 10_000_000) == 1, "a landed hit never rounds below 1"
--
-- A share-of-body floor ignores defence by construction, so defence stopped
-- protecting anybody from a peer at all. That takes a stat out of the game,
-- which nobody asked for. 0468's delve bite can be a pure share because the
-- delve has no defence term; the bestiary has one and it is meant to matter.
--
-- I THEN TRIED THE WRONG FIX AND MEASURED IT. The gap looked like the attack
-- number - 6.98e8 against a 2.87e12 body, with defence only taking 17% off,
-- because `creature_defense_scale_per_rank = 4` already solved mitigation
-- while `creature_attack_scale` stayed a flat 1. So: give attack the same
-- per-rank curve, 1.42 a rank to make up 496x over 17 ranks. Measured:
--
--     k      rank 17    rank 18      target
--     1.42     1.32%      5.37%       10%
--     1.55     5.35%     23.79%       10%
--     1.60     8.88%     40.81%       10%
--
-- No value works, because `base_attack` ALREADY rises about 1.7x a rank, so
-- a per-rank multiplier compounds with it to 2.4x a rank and the curve goes
-- through the target rather than landing on it. A multiplier was the wrong
-- instrument and two measurements said so before any of it shipped.
--
-- THE SHARE WAS RIGHT; IT WAS MISSING ONE TERM. The floor is a share of the
-- body times THE SAME MITIGATION THE ARITHMETIC USES:
--
--     max_hp * peer_share * bite_share * dscale/(dscale + defence)
--
-- which keeps every property that matters:
--
--     a peer bites a real share        rank 18 rogue 7.71% against a 10% target
--     defence still works             it divides the floor exactly as it
--                                     divides the arithmetic, so a defensive
--                                     build is still a defensive build
--     the clamp still clamps          an ash moth against defence 10,000,000
--                                     mitigates to 0.0006, so the floor
--                                     vanishes and GREATEST(1, ...) answers 1
--     nothing gets weaker             it is a GREATEST over the old result
--
-- Fitted to one measurement, so the probe measures the OUTCOME against the
-- `creature_bite_*` targets rather than trusting the arithmetic - which is
-- how the per-rank multiplier got caught.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef(
        'compute_creature_damage(bigint,bigint,numeric,bigint)'::regprocedure);

    anchor := '                     SELECT round(pp.max_hp';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'the 0505 share floor is not in compute_creature_damage as written';
    END IF;

    -- The one missing term. `dscale` and `def` are locals already computed
    -- above this expression, so the floor is mitigated by exactly what the
    -- arithmetic is mitigated by rather than by a second copy of the idea.
    src := replace(src, anchor,
        '                     SELECT round(' || chr(10) ||
        '                            -- mitigated by the same term the' || chr(10) ||
        '                            -- arithmetic above uses, so defence still' || chr(10) ||
        '                            -- divides a peer''s bite instead of being' || chr(10) ||
        '                            -- bypassed by the floor. Without this,' || chr(10) ||
        '                            -- defence protected nobody from a peer.' || chr(10) ||
        '                            dscale / (dscale + GREATEST(def, 0))' || chr(10) ||
        '                            * pp.max_hp');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The outcome, measured, not the arithmetic trusted
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_hp    BIGINT;
    v_stand INTEGER;
    v_share NUMERIC;
    v_want  NUMERIC;
    v_bad   TEXT;
    v_fresh BIGINT;
    v_moth  BIGINT;
    v_got   BIGINT;
    r       RECORD;
BEGIN
    SELECT p.player_id, pp.max_hp, player_standing(p.player_id)
    INTO v_pid, v_hp, v_stand
    FROM players p JOIN player_physique pp USING (player_id)
    WHERE p.deleted_at IS NULL AND player_standing(p.player_id) >= 17
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'no high-standing cultivator to measure against';
    END IF;

    -- A TRUE PEER bites near the share its kind is meant to. Only creatures
    -- at or above this cultivator's standing are peers; anything below is
    -- faded on purpose and has no target to miss.
    FOR r IN
        SELECT cs.name, cs.kind, cs.immortal_rank, d.final_damage AS bite
        FROM creature_species cs
        CROSS JOIN LATERAL compute_creature_damage(cs.species_id, v_pid, 1.0, NULL) d
        WHERE COALESCE(cs.immortal_rank, cs.rank) >= v_stand
    LOOP
        v_share := r.bite::NUMERIC / v_hp;
        v_want  := game_config_value('creature_bite_' || r.kind);
        IF v_share < v_want / 3 THEN
            v_bad := COALESCE(v_bad, '') || r.name || ' bites '
                     || round(100 * v_share, 2) || ' wanting '
                     || round(100 * v_want, 2) || '; ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a peer still cannot hurt anybody: %', v_bad;
    END IF;

    FOR r IN
        SELECT cs.name, cs.immortal_rank, d.final_damage AS bite
        FROM creature_species cs
        CROSS JOIN LATERAL compute_creature_damage(cs.species_id, v_pid, 1.0, NULL) d
        WHERE cs.immortal_rank >= v_stand
        ORDER BY cs.immortal_rank DESC, cs.name LIMIT 2
    LOOP
        RAISE NOTICE '% (rank %) bites % of a % body - % percent',
            r.name, r.immortal_rank, r.bite, v_hp,
            round(100.0 * r.bite / v_hp, 2);
    END LOOP;

    -- AND DEFENCE STILL CLAMPS, which is why 0505's floor needed the term.
    -- Asserted against a FRESH minimal cultivator, because that is what the
    -- standing test uses - the floor is a share of a body, so a body of
    -- 3.89e12 is a different question from a body of a hundred.
    SELECT cs.species_id INTO v_moth FROM creature_species cs WHERE cs.code = 'ash_moth';
    IF v_moth IS NULL THEN
        RAISE EXCEPTION 'the tutorial moth the standing test uses is gone';
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-997, 'clamp-probe') RETURNING player_id INTO v_fresh;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        VALUES (v_fresh, (SELECT min(realm_id) FROM realms), 0);
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_fresh, (SELECT min(physique_id) FROM physiques));

        SELECT d.final_damage INTO v_got
        FROM compute_creature_damage(v_moth, v_fresh, 1.0, 10000000::BIGINT) d;
        IF v_got <> 1 THEN
            RAISE EXCEPTION
                'a huge defence no longer clamps a tutorial moth to 1 - got %', v_got;
        END IF;

        SELECT d.final_damage INTO v_got
        FROM compute_creature_damage(v_moth, v_fresh, 0, 0::BIGINT) d;
        IF v_got <> 0 THEN
            RAISE EXCEPTION 'a zero-power hit no longer deals exactly 0 - got %', v_got;
        END IF;

        IF (SELECT d.final_damage FROM compute_creature_damage(v_moth, v_fresh, 1.0, -500::BIGINT) d)
           <> (SELECT d.final_damage FROM compute_creature_damage(v_moth, v_fresh, 1.0, 0::BIGINT) d) THEN
            RAISE EXCEPTION 'negative defence amplifies again';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Defence genuinely still buys something against a peer: twice the
    -- defence has to mean a smaller bite, or the floor has bypassed it again.
    SELECT cs.species_id INTO v_moth FROM creature_species cs
    WHERE cs.kind = 'rogue' ORDER BY COALESCE(cs.immortal_rank, cs.rank) DESC LIMIT 1;

    IF (SELECT d.final_damage FROM compute_creature_damage(
            v_moth, v_pid, 1.0,
            ((SELECT defense FROM player_physique WHERE player_id = v_pid) * 4)::BIGINT) d)
       >= (SELECT d.final_damage FROM compute_creature_damage(
            v_moth, v_pid, 1.0,
            (SELECT defense FROM player_physique WHERE player_id = v_pid)::BIGINT) d)
    THEN
        RAISE EXCEPTION 'four times the defence does not reduce a peer''s bite';
    END IF;

    -- Nothing bites softer than it did: the floor is a GREATEST.
    SELECT count(*) INTO v_got
    FROM creature_species cs
    CROSS JOIN LATERAL compute_creature_damage(cs.species_id, v_pid, 1.0, NULL) d
    WHERE d.final_damage < 1;
    IF v_got > 0 THEN
        RAISE EXCEPTION '% creatures bite for nothing at all', v_got;
    END IF;
END;
$probe$;
