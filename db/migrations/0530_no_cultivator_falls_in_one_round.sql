-- 0530_no_cultivator_falls_in_one_round
--
-- 0529 gave the pipeline a way to aim at a cultivator, and the first thing it
-- showed was that an interactive duel between the six people at the top of
-- the ladder would not be a fight. Measured across all thirty pairings of
-- their best techniques against each other's real bodies:
--
--     TWENTY-ONE OF THIRTY ARE A ONE-SHOT
--     rounds to fell:  0.02  to  20.4     median 0.34
--
-- 0.02 rounds means the blow is fifty times the defender's entire pool. A
-- duel decided before either player chooses anything is not a duel, and it
-- takes the backstab - which is supposed to be a DECISION with the boss
-- getting a free round for it - and makes it a question of who clicked first.
--
-- A FLAT DAMAGE DAMPER CANNOT FIX THIS, because the problem is the SPREAD and
-- not the magnitude. The range is a thousandfold: any share that makes
-- sylvrime versus clearwest survivable makes clearwest versus m_i_y_u_k_i
-- take five hundred rounds.
--
-- CAPPING A ROUND AT A SHARE OF WHAT THE DEFENDER CAN HOLD does fix it,
-- because it bounds the thing that actually matters - rounds to fell -
-- regardless of how hard the attacker hits. Measured, again across the real
-- thirty:
--
--     cap    rounds to fell        median    one-shots
--     none    0.02 to  20.4         0.34       21/30
--     0.25    4.0  to  20.4         4.0         0/30
--     0.15    6.7  to  20.4         6.7         0/30     <- chosen
--     0.10   10.0  to  20.4        10.0         0/30
--
-- 0.15 was the user's call: "a backstab should be survivable enough that the
-- victim gets real turns to respond". It also keeps a build meaningful - an
-- attacker strong enough to reach the cap does, a weaker one does not and
-- still needs twenty rounds, so the ordering of builds survives.
--
-- PVP ONLY, and the guard is the one 0529 already added. The cap sits behind
-- `p_defender_player_id IS NOT NULL`, which is NULL for every one of the
-- eleven creature lanes, so nothing that fights a beast can reach it.
--
-- WHY IT IS IN `player_swing` AND NOT IN THE DUEL. Because it has to apply to
-- the ROUND'S TOTAL, after the extra strikes and after the crit - a rank 18
-- crit lid is 12.6, so a per-strike cap would still let one critical take
-- nearly twice a defender's body. `player_swing` is the only thing that knows
-- the whole round, and putting it there means every PvP lane built after this
-- one inherits it instead of having to remember it. There is precedent beside
-- it: the pet's blow has been capped at a share of its owner's round since the
-- beast arrived.
--
-- And it is a share of MAX hp, not of what is left. A cap on the remainder
-- would take fifteen percent of fifteen percent of fifteen percent and the
-- duel would never end.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('duel_blow_cap', 0.15,
     'The most one round may take from a cultivator, as a share of their maximum, in a fight against another cultivator. Without it 21 of the 30 pairings at the top of the ladder were a one-shot. Creatures are not capped - this is read only when the defender is a player.');


DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef(
        'player_swing(bigint,bigint,bigint,bigint,bigint,bigint,bigint,integer,text,bigint,bigint)'::regprocedure);

    one := '    got_back  BIGINT := 0;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the player_swing declarations are not where I read them';
    END IF;
    src := replace(src, one,
        one || chr(10) ||
        '    cap_hit   BIGINT;   -- 0530. The most a duel round may take.');

    -- After the pet, so the cap covers the whole round including the beast,
    -- and before the lifesteal, which is priced off strikes landed rather
    -- than off damage and so is untouched either way.
    one := '    IF steal > 0 AND landed > 0 THEN';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the lifesteal block is not where I read it';
    END IF;

    src := replace(src, one,
        '    -- ---- a cultivator is not a creature ----------------------------' || chr(10) ||
        '    -- PVP ONLY, behind the same guard 0529 added. No round may take' || chr(10) ||
        '    -- more than `duel_blow_cap` of what the defender can hold.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- Without it, twenty-one of the thirty pairings among the six' || chr(10) ||
        '    -- cultivators at the top of the ladder were a ONE-SHOT - the worst' || chr(10) ||
        '    -- of them fifty times the defender''s whole body. Applied to the' || chr(10) ||
        '    -- round rather than the strike because a rank 18 crit lid is 12.6,' || chr(10) ||
        '    -- so one critical would clear the cap on its own.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- A share of their MAXIMUM, not of what is left: a cap on the' || chr(10) ||
        '    -- remainder takes a share of a share of a share and never kills.' || chr(10) ||
        '    IF p_defender_player_id IS NOT NULL AND out_dmg > 0 THEN' || chr(10) ||
        '        cap_hit := GREATEST(1, round(' || chr(10) ||
        '            game_config_value(''duel_blow_cap'')' || chr(10) ||
        '            * COALESCE(' || chr(10) ||
        '                (SELECT pp.max_hp FROM player_physique pp' || chr(10) ||
        '                 WHERE pp.player_id = p_defender_player_id),' || chr(10) ||
        '                p_target_hp, 1)))::bigint;' || chr(10) ||
        chr(10) ||
        '        IF out_dmg > cap_hit THEN' || chr(10) ||
        '            log := log || jsonb_build_object(' || chr(10) ||
        '                ''strike'', ''duel_cap'',' || chr(10) ||
        '                ''damage'', out_dmg,' || chr(10) ||
        '                ''capped_to'', cap_hit);' || chr(10) ||
        '            out_dmg := cap_hit;' || chr(10) ||
        '            -- Recomputed from the pool rather than handed back the' || chr(10) ||
        '            -- difference, because an overkill round had already' || chr(10) ||
        '            -- clamped `left_hp` at zero and the difference would' || chr(10) ||
        '            -- restore more than was ever there.' || chr(10) ||
        '            left_hp := GREATEST(0, p_target_hp - cap_hit);' || chr(10) ||
        '        END IF;' || chr(10) ||
        '    END IF;' || chr(10) ||
        chr(10) ||
        one);

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nobody at the top falls in one round, and no creature is spared
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_cap   NUMERIC := game_config_value('duel_blow_cap');
    v_one   INTEGER := 0;
    v_pairs INTEGER := 0;
    v_min   NUMERIC;
    v_max   NUMERIC;
    v_dealt BIGINT;
    v_sp    BIGINT;
    v_tech  BIGINT;
    v_me    BIGINT;
    one     RECORD;
    v_r     NUMERIC;
BEGIN
    IF v_cap <> 0.15 THEN
        RAISE EXCEPTION 'the cap is % and the decision was 0.15', v_cap;
    END IF;

    -- 1. EVERY REAL PAIRING AT THE TOP, driven through `player_swing` itself
    -- rather than through the arithmetic - the cap lives in the round, and a
    -- probe that priced one strike would not see it.
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
            WHERE tq.base_power > 0
            GROUP BY t.player_id
        )
        SELECT a.discord_name AS atk, d.discord_name AS def,
               d.max_hp, b.tid, a.player_id AS aid, d.player_id AS did,
               d.defense
        FROM top a JOIN best b ON b.player_id = a.player_id
        CROSS JOIN top d
        WHERE a.player_id <> d.player_id
    LOOP
        SELECT s.dealt INTO v_dealt FROM player_swing(
            one.aid, one.tid, NULL::bigint, one.max_hp, one.defense,
            NULL, NULL, 0, NULL, NULL, one.did) s;

        v_pairs := v_pairs + 1;
        v_r := one.max_hp::numeric / GREATEST(v_dealt, 1);
        v_min := LEAST(COALESCE(v_min, v_r), v_r);
        v_max := GREATEST(COALESCE(v_max, v_r), v_r);

        IF v_r <= 1 THEN
            v_one := v_one + 1;
            RAISE NOTICE
                'ONE-SHOT: % fells % in % rounds (% against %)',
                one.atk, one.def, round(v_r, 2), v_dealt, one.max_hp;
        END IF;
    END LOOP;

    IF v_pairs < 20 THEN
        RAISE EXCEPTION
            'only % pairings were measured, so this proves little', v_pairs;
    END IF;
    IF v_one > 0 THEN
        RAISE EXCEPTION
            '% of % pairings are still a one-shot', v_one, v_pairs;
    END IF;

    -- A crit must not clear it either, which is the reason the cap is on the
    -- round. Checked against the ceiling the cap allows rather than trusted.
    IF v_min < 1 / v_cap - 0.5 THEN
        RAISE EXCEPTION
            'the quickest kill is % rounds, under the % the cap should guarantee',
            round(v_min, 2), round(1 / v_cap, 1);
    END IF;

    RAISE NOTICE
        '% pairings, % to % rounds to fell, no one-shots',
        v_pairs, round(v_min, 1), round(v_max, 1);

    -- 2. AND NO CREATURE IS CAPPED. The same call with no defending player
    -- must overkill a small creature freely, or the cap has leaked into the
    -- eleven lanes that fight beasts.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-989, 'pve-cap-probe') RETURNING player_id INTO v_me;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_me, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        SELECT v_me, (SELECT min(physique_id) FROM physiques),
               pp.max_hp, pp.max_hp, pp.defense, pp.strength
        FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL AND player_realm_rank(p.player_id) = 18
        ORDER BY pp.strength DESC LIMIT 1;

        SELECT t.technique_id INTO v_tech FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        INSERT INTO player_techniques (player_id, technique_id)
        VALUES (v_me, v_tech) ON CONFLICT DO NOTHING;

        SELECT cs.species_id INTO v_sp FROM creature_species cs
        WHERE cs.kind = 'beast' ORDER BY cs.species_id LIMIT 1;

        -- A creature holding a millionth of what this blow is worth. An
        -- uncapped lane overkills it by orders of magnitude; a capped one
        -- would stop at 15% of 1,000,000.
        SELECT s.dealt INTO v_dealt FROM player_swing(
            v_me, v_tech, v_sp, 1000000::bigint, 0::bigint) s;

        IF v_dealt <= 1000000 * v_cap THEN
            RAISE EXCEPTION
                'a creature took only % from a blow worth far more - the duel cap reached a beast',
                v_dealt;
        END IF;
        RAISE NOTICE
            'a creature still takes % against a pool of 1,000,000', v_dealt;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
