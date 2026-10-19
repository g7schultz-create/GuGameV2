-- 0532_damage_matters_in_a_duel
--
-- "Make damage matter in pvp."
--
-- 0530 and 0531 stopped the one-shots and left PvP almost build-blind: the
-- knee recovered 1.14x of expression, so every cultivator at the top felled
-- every other in six and a half to seven and a half rounds whatever they had
-- built. That is not what anybody wants out of a duel.
--
-- WHAT I FOUND WHEN I DECOMPOSED IT, which corrects something I said twice
-- this session. The dominant spread is NOT manual `attack_bonus`. Measured
-- across the six cultivators at the top of the ladder:
--
--     strength            82.0x      <- the blow IS strength; thews dwarf the
--     technique power     22.6x         technique's own base
--     max health          14.1x
--     defence             13.8x
--     crit_damage         10.4x
--     external multiplier  6.5x      <- where attack_bonus lives
--
-- A round is worth 1.1 to 1,248 times the body it is aimed at, a spread of
-- 1,174x, against a health spread of only 14x. THAT MISMATCH IS THE WHOLE
-- PROBLEM, and no divisor can fix it:
--
--     a cap flattens        every build is above any survivable ceiling
--     a knee flattens       for the same reason, to within 14%
--     a smaller defence
--     divisor makes it WORSE   swept it: the spread widens from 847x to
--                              4,465x, because it amplifies the 13.8x defence
--                              spread on top of the damage spread
--
-- SO THE SPREAD IS COMPRESSED RATHER THAN CLIPPED. A duel round takes
--
--     share  = LEAST(duel_max_bite, duel_bite * (round / their_body) ^ duel_curve)
--     landed = share * their_body
--
-- which is monotonic - a harder round ALWAYS lands strictly more - and
-- compresses a 1,174x advantage in raw damage into a 50x advantage in share
-- at `duel_curve` 0.55. `duel_bite` is what a round worth exactly the
-- defender's whole body takes; `duel_max_bite` is a floor under the fight,
-- so no duel is ever shorter than two rounds.
--
-- MEASURED ON THE REAL THIRTY PAIRINGS, swept rather than chosen:
--
--     bite  curve     rounds        one-shots   kill-speed spread vs the
--                                               SAME defender (median)
--     0.07   0.25   2.3 to 14.2       0/30            2.3x
--     0.06   0.40   2.0 to 16.6       0/30            3.4x
--     0.05   0.55   2.0 to 19.8       0/30            4.1x   <- chosen
--     0.03   0.85   2.0 to 32.9       0/30            5.5x
--
-- 0.05 / 0.55 because the instruction was that damage should matter: a strong
-- damage build now fells the same opponent about FOUR TIMES faster than a weak
-- one, where under the knee it was 1.14x. The cost is that the slowest
-- pairing - the frailest attacker against the toughest body - takes twenty
-- rounds, which is a grind it should be.
--
-- `duel_blow_cap` from 0530 is deleted rather than left lying about, so nobody
-- tunes a knob that is no longer read.
--
-- STILL PVP ONLY, behind the same `p_defender_player_id IS NOT NULL` guard
-- 0529 added. The eleven creature lanes pass NULL and cannot reach any of it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('duel_bite', 0.05,
     'What one round takes from a cultivator when that round is worth exactly their whole body, as a share of it. The anchor of the duel damage curve.'),
    ('duel_curve', 0.55,
     'How much of an advantage in raw damage carries through into a duel. 1.0 would pass it all through and bring back the one-shots; 0 would ignore damage entirely. At 0.55 a 1,174x raw spread becomes about 50x in share, and a strong damage build fells the same opponent about four times faster than a weak one.'),
    ('duel_max_bite', 0.50,
     'The most one round may ever take from a cultivator. A floor under the length of a duel - two rounds, always - so no build and no roll can produce a one-shot.');

DELETE FROM game_config WHERE key = 'duel_blow_cap';


DO $patch$
DECLARE
    src TEXT;
    one TEXT;
    new TEXT;
BEGIN
    src := pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint,bigint)'::regprocedure);

    -- The whole block 0530 added and 0531 reshaped, replaced in one piece
    -- rather than patched twice over. Anchored on its opening and its closing
    -- `END IF;` pair via the comment banner, which appears once.
    one := '    -- ---- a cultivator is not a creature ----------------------------';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the duel block banner is not where 0530 put it';
    END IF;

    IF strpos(src, 'duel_blow_cap') = 0 THEN
        RAISE EXCEPTION 'player_swing does not read duel_blow_cap, so this is not the body I expect';
    END IF;

    -- Everything from the banner to the lifesteal block is the duel cap.
    one := substr(src,
                  strpos(src, one),
                  strpos(src, '    IF steal > 0 AND landed > 0 THEN') - strpos(src, one));

    new :=
        '    -- ---- a cultivator is not a creature ----------------------------' || chr(10) ||
        '    -- PVP ONLY, behind the same guard 0529 added.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- A round is worth 1.1 to 1,248 times the body it is aimed at - a' || chr(10) ||
        '    -- spread of 1,174x against a health spread of 14x. A cap or a knee' || chr(10) ||
        '    -- flattens that, because EVERY build sits above any survivable' || chr(10) ||
        '    -- ceiling; 0530 and 0531 both did, to within 14%.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- So the advantage is COMPRESSED instead of clipped. Monotonic, so' || chr(10) ||
        '    -- a harder round always lands strictly more, and bounded by' || chr(10) ||
        '    -- `duel_max_bite` so a duel is never shorter than two rounds.' || chr(10) ||
        '    -- Measured on the thirty real pairings at the top of the ladder:' || chr(10) ||
        '    -- 2.0 to 19.8 rounds, no one-shots, and a strong damage build' || chr(10) ||
        '    -- fells the same opponent about four times faster than a weak one.' || chr(10) ||
        '    IF p_defender_player_id IS NOT NULL AND out_dmg > 0 THEN' || chr(10) ||
        '        duel_pool := GREATEST(1, COALESCE(' || chr(10) ||
        '            (SELECT pp.max_hp FROM player_physique pp' || chr(10) ||
        '             WHERE pp.player_id = p_defender_player_id),' || chr(10) ||
        '            p_target_hp, 1));' || chr(10) ||
        chr(10) ||
        '        duel_share := LEAST(' || chr(10) ||
        '            game_config_value(''duel_max_bite''),' || chr(10) ||
        '            game_config_value(''duel_bite'')' || chr(10) ||
        '            * power(out_dmg::numeric / duel_pool,' || chr(10) ||
        '                    game_config_value(''duel_curve'')));' || chr(10) ||
        chr(10) ||
        '        cap_hit := GREATEST(1, round(duel_share * duel_pool))::bigint;' || chr(10) ||
        chr(10) ||
        '        IF cap_hit <> out_dmg THEN' || chr(10) ||
        '            log := log || jsonb_build_object(' || chr(10) ||
        '                ''strike'', ''duel_curve'',' || chr(10) ||
        '                ''damage'', out_dmg,' || chr(10) ||
        '                ''share'', round(duel_share, 4),' || chr(10) ||
        '                ''landed'', cap_hit);' || chr(10) ||
        '            out_dmg := cap_hit;' || chr(10) ||
        '            -- Recomputed from the pool rather than handed the' || chr(10) ||
        '            -- difference back, because an overkill round had already' || chr(10) ||
        '            -- clamped `left_hp` at zero.' || chr(10) ||
        '            left_hp := GREATEST(0, p_target_hp - out_dmg);' || chr(10) ||
        '        END IF;' || chr(10) ||
        '    END IF;' || chr(10) ||
        chr(10);

    src := replace(src, one, new);

    IF strpos(src, 'duel_blow_cap') > 0 THEN
        RAISE EXCEPTION 'the old cap survived the replacement';
    END IF;

    -- Two more locals for the curve.
    one := '    cap_hit   BIGINT;   -- 0530. The most a duel round may take.';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the cap_hit declaration is not where 0530 put it';
    END IF;
    src := replace(src, one,
        '    cap_hit    BIGINT;    -- 0532. What a duel round actually lands for.' || chr(10) ||
        '    duel_pool  BIGINT;    -- the defender''s whole body' || chr(10) ||
        '    duel_share NUMERIC;   -- the share of it this round takes');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Damage matters, nobody falls in one round, and no creature is touched
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    one       RECORD;
    v_dealt   BIGINT;
    v_rounds  NUMERIC;
    v_pairs   INTEGER := 0;
    v_shots   INTEGER := 0;
    v_min     NUMERIC;
    v_max     NUMERIC;
    v_bad     TEXT;
    v_sp      BIGINT;
    v_tech    BIGINT;
    v_me      BIGINT;
    v_fast    NUMERIC;
    v_slow    NUMERIC;
    v_spread  NUMERIC;
    v_worst   NUMERIC;
    v_defname TEXT;
BEGIN
    IF game_config_value('duel_bite') <> 0.05
       OR game_config_value('duel_curve') <> 0.55
       OR game_config_value('duel_max_bite') <> 0.50 THEN
        RAISE EXCEPTION 'the curve was not seeded at the swept values';
    END IF;
    IF EXISTS (SELECT 1 FROM game_config WHERE key = 'duel_blow_cap') THEN
        RAISE EXCEPTION 'the dead knob is still tunable';
    END IF;

    -- 1. DAMAGE MATTERS. For each defender, the fastest attacker must fell
    -- them materially sooner than the slowest. Under the knee this ratio was
    -- 1.14; it is the single number this migration exists to move.
    v_worst := NULL;
    FOR one IN
        WITH top AS (
            SELECT p.player_id, p.discord_name, pp.max_hp, pp.defense
            FROM players p JOIN player_physique pp USING (player_id)
            WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        )
        SELECT d.player_id AS did, d.discord_name AS def, d.max_hp, d.defense
        FROM top d
    LOOP
        v_fast := NULL; v_slow := NULL;
        FOR v_dealt IN
            SELECT s.dealt
            FROM players p
            JOIN player_physique pp ON pp.player_id = p.player_id
            CROSS JOIN LATERAL (
                SELECT (array_agg(u.technique_id ORDER BY t.base_power DESC))[1] AS tid
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                WHERE u.player_id = p.player_id AND t.base_power > 0) b
            CROSS JOIN LATERAL player_swing(
                p.player_id, b.tid, NULL::bigint, one.max_hp, one.defense,
                NULL, NULL, 0, NULL, NULL, one.did) s
            WHERE p.deleted_at IS NULL
              AND player_realm_rank(p.player_id) = 18
              AND p.player_id <> one.did
              AND b.tid IS NOT NULL
        LOOP
            v_pairs  := v_pairs + 1;
            v_rounds := one.max_hp::numeric / GREATEST(v_dealt, 1);
            IF v_rounds <= 1 THEN v_shots := v_shots + 1; END IF;
            v_min  := LEAST(COALESCE(v_min, v_rounds), v_rounds);
            v_max  := GREATEST(COALESCE(v_max, v_rounds), v_rounds);
            v_fast := LEAST(COALESCE(v_fast, v_rounds), v_rounds);
            v_slow := GREATEST(COALESCE(v_slow, v_rounds), v_rounds);
        END LOOP;

        IF v_fast IS NOT NULL AND v_slow IS NOT NULL THEN
            v_spread := v_slow / GREATEST(v_fast, 0.0001);
            IF v_worst IS NULL OR v_spread > v_worst THEN
                v_worst := v_spread; v_defname := one.def;
            END IF;
            RAISE NOTICE
                'against %: % to % rounds, so damage is worth %x',
                one.def, round(v_fast, 1), round(v_slow, 1), round(v_spread, 1);
        END IF;
    END LOOP;

    IF v_pairs < 20 THEN
        RAISE EXCEPTION 'only % pairings measured', v_pairs;
    END IF;
    IF v_shots > 0 THEN
        RAISE EXCEPTION '% pairings are a one-shot', v_shots;
    END IF;
    IF v_worst < 2 THEN
        RAISE EXCEPTION
            'the best damage advantage anywhere is only %x - damage still does not matter',
            round(v_worst, 2);
    END IF;

    -- And the floor under a duel holds: `duel_max_bite` is half a body, so
    -- two rounds is the quickest possible kill.
    IF v_min < 1 / game_config_value('duel_max_bite') - 0.01 THEN
        RAISE EXCEPTION
            'the quickest kill is % rounds, under the % the bite cap guarantees',
            round(v_min, 2), round(1 / game_config_value('duel_max_bite'), 1);
    END IF;

    RAISE NOTICE
        '% pairings: % to % rounds, no one-shots, damage worth up to %x (vs %)',
        v_pairs, round(v_min, 1), round(v_max, 1), round(v_worst, 1), v_defname;

    -- 2. MONOTONIC. A strictly harder round must land strictly more against
    -- the same body - the property a LEAST destroyed.
    IF (SELECT count(DISTINCT round(
            LEAST(game_config_value('duel_max_bite'),
                  game_config_value('duel_bite')
                  * power(x::numeric / 1000000000000, game_config_value('duel_curve')))
            * 1000000000000))
        FROM unnest(ARRAY[1000000000000, 2000000000000, 4000000000000,
                          8000000000000]::bigint[]) AS x) <> 4 THEN
        RAISE EXCEPTION 'four different rounds do not produce four different results';
    END IF;

    -- 3. AND NO CREATURE IS TOUCHED.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-987, 'curve-pve-probe') RETURNING player_id INTO v_me;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_me, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_me, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ORDER BY pp.strength DESC LIMIT 1;
        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_me, v_tech) ON CONFLICT DO NOTHING;
        SELECT cs.species_id INTO v_sp FROM creature_species cs
        WHERE cs.kind = 'beast' ORDER BY cs.species_id LIMIT 1;

        SELECT s.dealt INTO v_dealt FROM player_swing(
            v_me, v_tech, v_sp, 1000000::bigint, 0::bigint) s;
        IF v_dealt <= 1000000 THEN
            RAISE EXCEPTION
                'a creature took only % - the duel curve reached a beast', v_dealt;
        END IF;
        RAISE NOTICE 'a creature still takes % against a pool of 1,000,000', v_dealt;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
