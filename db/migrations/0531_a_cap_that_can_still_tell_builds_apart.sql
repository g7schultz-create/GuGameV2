-- 0531_a_cap_that_can_still_tell_builds_apart
--
-- 0530's cap does what was asked - no cultivator falls in one round, and all
-- thirty pairings at the top now take about seven. Measuring it afterwards
-- showed what it costs:
--
--     EVERY ONE OF THE THIRTY PAIRINGS LANDS EXACTLY THE SAME NUMBER.
--
-- `clearwest`, whose round is worth 4.7e12, and `sylvrime`, whose round is
-- worth 7.0e14, deal identical damage to the same defender. A hard LEAST
-- clips everything above the ceiling to the ceiling, and at rank 18 EVERY
-- build is above the ceiling - the raw rounds run 4.6e12 to 7.0e14 against
-- pools of 5e11 to 7e12, so a round is already between ten and fourteen
-- hundred times the body it is aimed at. Two completely different builds
-- becoming the same number is the sort of thing a player reports as a bug.
--
-- I SIZED THAT CAP WRONG BEFORE APPLYING IT. The table I measured came from
-- `compute_duel_damage`, which prices ONE STRIKE. `player_swing` then applies
-- the extra strikes and a crit against a rank 18 lid of 12.6, which multiplies
-- a round by ten to fifty. So the projection said "6.7 to 20.4 rounds, builds
-- still ordered" and the truth was "6.7 for everybody".
--
-- SO THE CEILING BECOMES A KNEE:
--
--     landed = cap * raw / (raw + cap)
--
-- which is the shape this game already uses everywhere a number has to be
-- bounded without being clipped - `raw * scale / (scale + defence)` is the
-- defence divisor in `compute_technique_damage`, `compute_duel_damage` and
-- `pet_blow`. It is monotonic, so a stronger round always lands strictly more;
-- it approaches the cap without reaching it, so the one-shot stays dead; and
-- it leaves a weak round nearly untouched, which a clip cannot do.
--
-- WHAT IT BUYS TODAY IS SMALL AND I AM NOT GOING TO OVERSELL IT. Measured
-- across the same thirty pairings:
--
--     hard clip   6.7 to 6.7 rounds    spread 1.00x    0 one-shots
--     soft knee   6.7 to 7.7 rounds    spread 1.15x    0 one-shots
--
-- Fifteen percent of build expression where there was none. The reason to
-- take it anyway is that the knee RESPONDS to the raw figure and the clip
-- never will: if damage and health are ever brought back into proportion -
-- the uncapped manual `attack_bonus` at up to 8.31x is most of a sixfold
-- attack spread, and the crit lid rises 0.70 a rank - PvP becomes expressive
-- again on its own, with no second migration. Under a clip it would stay flat
-- for ever no matter what else is fixed.
--
-- Forward-only. Do not edit once applied.

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint,bigint)'::regprocedure);

    one := '        IF out_dmg > cap_hit THEN' || chr(10) ||
           '            log := log || jsonb_build_object(' || chr(10) ||
           '                ''strike'', ''duel_cap'',' || chr(10) ||
           '                ''damage'', out_dmg,' || chr(10) ||
           '                ''capped_to'', cap_hit);' || chr(10) ||
           '            out_dmg := cap_hit;';

    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the duel cap 0530 added is not where I left it';
    END IF;

    src := replace(src, one,
        '        -- A KNEE, NOT A CEILING. `cap * raw / (raw + cap)` is the same' || chr(10) ||
        '        -- shape as the defence divisor three functions above: it' || chr(10) ||
        '        -- approaches the cap without reaching it, so a harder round' || chr(10) ||
        '        -- always lands strictly more than a softer one. A LEAST here' || chr(10) ||
        '        -- made every build at rank 18 deal the identical number,' || chr(10) ||
        '        -- because every build''s round is already far above the cap.' || chr(10) ||
        '        IF out_dmg > 0 THEN' || chr(10) ||
        '            IF out_dmg > cap_hit THEN' || chr(10) ||
        '                log := log || jsonb_build_object(' || chr(10) ||
        '                    ''strike'', ''duel_cap'',' || chr(10) ||
        '                    ''damage'', out_dmg,' || chr(10) ||
        '                    ''capped_to'', GREATEST(1, round(' || chr(10) ||
        '                        cap_hit::numeric * out_dmg / (out_dmg + cap_hit))));' || chr(10) ||
        '            END IF;' || chr(10) ||
        '            out_dmg := GREATEST(1, round(' || chr(10) ||
        '                cap_hit::numeric * out_dmg / (out_dmg + cap_hit)))::bigint;');

    -- The reconciliation below used `cap_hit`; it has to use what was actually
    -- dealt now that the two differ.
    one := '            left_hp := GREATEST(0, p_target_hp - cap_hit);';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the left_hp reconciliation is not where I left it';
    END IF;
    src := replace(src, one,
        '            left_hp := GREATEST(0, p_target_hp - out_dmg);');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Still no one-shot, and no longer the same number for everybody
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    one      RECORD;
    v_dealt  BIGINT;
    v_cap    NUMERIC := game_config_value('duel_blow_cap');
    v_seen   BIGINT[] := ARRAY[]::BIGINT[];
    v_rounds NUMERIC[] := ARRAY[]::NUMERIC[];
    v_r      NUMERIC;
    v_pairs  INTEGER := 0;
    v_one    INTEGER := 0;
    v_min    NUMERIC;
    v_max    NUMERIC;
    v_sp     BIGINT;
    v_tech   BIGINT;
    v_me     BIGINT;
BEGIN
    FOR one IN
        WITH top AS (
            SELECT p.player_id, p.discord_name, pp.max_hp, pp.defense
            FROM players p JOIN player_physique pp USING (player_id)
            WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ), best AS (
            SELECT t.player_id,
                   (array_agg(u.technique_id ORDER BY tq.base_power DESC))[1] AS tid
            FROM top t
            JOIN player_usable_techniques u ON u.player_id = t.player_id
            JOIN techniques tq ON tq.technique_id = u.technique_id
            WHERE tq.base_power > 0 GROUP BY t.player_id
        )
        SELECT a.player_id AS aid, d.player_id AS did, b.tid,
               d.max_hp, d.defense, a.discord_name AS atk, d.discord_name AS def
        FROM top a JOIN best b ON b.player_id = a.player_id
        CROSS JOIN top d WHERE a.player_id <> d.player_id
    LOOP
        SELECT s.dealt INTO v_dealt FROM player_swing(
            one.aid, one.tid, NULL::bigint, one.max_hp, one.defense,
            NULL, NULL, 0, NULL, NULL, one.did) s;

        v_pairs  := v_pairs + 1;
        v_r      := one.max_hp::numeric / GREATEST(v_dealt, 1);
        v_rounds := v_rounds || v_r;
        v_min    := LEAST(COALESCE(v_min, v_r), v_r);
        v_max    := GREATEST(COALESCE(v_max, v_r), v_r);
        IF v_r <= 1 THEN v_one := v_one + 1; END IF;

        -- A round must never reach the cap outright, which is what makes the
        -- knee a knee.
        IF v_dealt >= GREATEST(1, round(v_cap * one.max_hp)) THEN
            RAISE EXCEPTION
                '% reached the cap exactly against % (% of %), so it is still a ceiling',
                one.atk, one.def, v_dealt, round(v_cap * one.max_hp);
        END IF;

        v_seen := v_seen || v_dealt;
    END LOOP;

    IF v_pairs < 20 THEN
        RAISE EXCEPTION 'only % pairings measured', v_pairs;
    END IF;
    IF v_one > 0 THEN
        RAISE EXCEPTION '% pairings are a one-shot again', v_one;
    END IF;

    -- THE THING 0530 BROKE. Thirty pairings must not share six numbers.
    IF (SELECT count(DISTINCT x) FROM unnest(v_seen) AS x) <= 6 THEN
        RAISE EXCEPTION
            'the thirty pairings produce only % distinct figures - still flattened',
            (SELECT count(DISTINCT x) FROM unnest(v_seen) AS x);
    END IF;

    -- And a harder round still lands harder: the spread must be above one.
    IF v_max / v_min <= 1.02 THEN
        RAISE EXCEPTION
            'rounds-to-fell spread is only %x, so builds are indistinguishable',
            round(v_max / v_min, 3);
    END IF;

    RAISE NOTICE
        '% pairings: % to % rounds (spread %x), % distinct figures, no one-shots',
        v_pairs, round(v_min, 1), round(v_max, 1), round(v_max / v_min, 2),
        (SELECT count(DISTINCT x) FROM unnest(v_seen) AS x);

    -- And still nothing reaches a creature.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-988, 'knee-pve-probe') RETURNING player_id INTO v_me;
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
                'a creature took only % from a blow worth far more', v_dealt;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
