-- 0454_the_trial_rehearses_the_party_instead_of_guessing
--
-- 0453 sized a Trial off the party's sinew at a measured ratio of twenty
-- damage per point. The first full-length run says that ratio is not a
-- constant at all:
--
--     party sinew 10.95T  x 20          =  219T predicted per round
--     what the party actually put out    =  389T per round, over five rounds
--
-- Nearly double, so a fight meant to last eight rounds ended in five, and
-- nobody was ever in danger of losing it.
--
-- WHY THE RATIO CANNOT HOLD. One swing each, against the realm 18 creature:
--
--     clearwest      forecast 301G   dealt   1.25T   3 strikes  0 crits
--     m_i_y_u_k_i.   forecast 8.76T  dealt 222.60T   3 strikes  2 crits
--     shinonn._.     forecast 4.28T  dealt 314.70T   4 strikes  3 crits
--
-- A strike that does not critical lands near its forecast. A strike that does
-- is worth fifteen to twenty-five of them. `crit_damage` is still a percent
-- bonus - one of the three the balance pass has not converted - and it has run
-- away from everything else. So a party's damage is governed by how much crit
-- it carries, not by how much sinew, and any single number fitted to one party
-- is fitted to that party's crit and to nothing else.
--
-- THAT IS A SEPARATE REPAIR and it is a large one. This migration does not
-- attempt it. It stops the Trial depending on it.
--
-- SO THE TRIAL REHEARSES. Instead of predicting the party from a ratio, it
-- runs the party - really, through `player_swing`, the same function the round
-- itself uses - inside a subtransaction that is then rolled back. The pool is
-- what the party actually turned out to do, times the rounds a Trial lasts.
--
--     pool = (mean of N rehearsed rounds) x trial_rounds_wanted
--
-- This is "one definition, not two" applied to balance: there is no second
-- model of what a party can do that can drift from the first. If the damage
-- pipeline changes tomorrow - if crit_damage is converted, if a new technique
-- lands - the Trial resizes itself with no constant left to go stale.
--
-- IT REHEARSES MORE THAN ONCE because criticals are a coin. Across the five
-- rounds measured, the party's output ranged from 200T to 548T: a factor of
-- nearly three, same party, same creature. One sample would size half the
-- fights wrong. The mean of several is steady enough.
--
-- NOTHING LEAKS. The rehearsal writes taunts and regens into `battle_effects`
-- exactly as a real round does, and the subtransaction rolls every one of them
-- back. The probe at the bottom checks that by counting.
--
-- THE CREATURE IS STILL THE FLOOR, as in 0453.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_rehearsal_rounds', 3,
     'How many times a Trial runs the party through a practice round before deciding what the creature carries. More than one because criticals are a coin: the same party against the same creature ranged from 200T to 548T across five real rounds.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;

UPDATE game_config
SET description = 'Kept only as the floor under a party that cannot be rehearsed - no techniques, no body. Live sizing rehearses the party through player_swing instead, because this ratio is governed by crit_damage rather than by sinew and is not a constant. See 0454.'
WHERE key = 'trial_damage_per_strength';


-- ---------------------------------------------------------------------------
-- What this party really does in a round
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_rehearse(p_party_id bigint, p_species_id bigint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_def  BIGINT;
    v_sum  BIGINT := 0;
    v_n    INTEGER;
    v_move BIGINT;
    one    RECORD;
    swung  RECORD;
    i      INTEGER;
BEGIN
    v_n := GREATEST(1, game_config_value('trial_rehearsal_rounds')::int);
    SELECT s.base_defense INTO v_def FROM creature_species s
    WHERE s.species_id = p_species_id;
    IF v_def IS NULL THEN
        RETURN 0;
    END IF;

    BEGIN
        FOR i IN 1..v_n LOOP
            FOR one IN
                SELECT m.player_id, COALESCE(pp.max_hp, 1) AS max_hp
                FROM trial_party_members m
                LEFT JOIN player_physique pp ON pp.player_id = m.player_id
                WHERE m.party_id = p_party_id
                ORDER BY m.player_id
            LOOP
                v_move := dungeon_default_move(one.player_id);
                CONTINUE WHEN v_move IS NULL;

                -- The real swing, against an unkillable target so that no
                -- rehearsal ends early and biases the mean downward.
                SELECT * INTO swung FROM player_swing(
                    one.player_id, v_move, p_species_id,
                    9223372036854775807::bigint, v_def,
                    GREATEST(1, one.max_hp), GREATEST(1, one.max_hp),
                    i, 'rehearsal', -p_party_id);

                v_sum := v_sum + GREATEST(0, swung.dealt);
            END LOOP;
        END LOOP;

        -- Everything above is undone here, including every battle_effect the
        -- rehearsed techniques wrote. The sum survives because it is a local
        -- variable rather than a row.
        RAISE EXCEPTION 'rehearsal-done';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rehearsal-done' THEN RAISE; END IF;
    END;

    RETURN GREATEST(0, v_sum / v_n);
END;
$fn$;

COMMENT ON FUNCTION trial_rehearse(bigint, bigint) IS
    'What a party really puts out in one round, found by running it rather than by predicting it. The swings happen inside a subtransaction that is rolled back, so a rehearsal costs nothing and leaves nothing. Averaged over several rounds because criticals swing the answer by a factor of three.';


DROP FUNCTION IF EXISTS trial_boss_hp(bigint, bigint);

CREATE FUNCTION trial_boss_hp(p_party_id bigint, p_species_id bigint,
                              p_scale numeric DEFAULT 1.0)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_round BIGINT;
    v_pool  BIGINT;
    v_floor BIGINT;
BEGIN
    v_round := trial_rehearse(p_party_id, p_species_id);

    IF v_round <= 0 THEN
        -- A party that cannot be rehearsed - not one technique between them -
        -- falls back on the old ratio rather than meeting an empty body.
        v_round := GREATEST(1, round(
            COALESCE((SELECT sum(GREATEST(0, pp.strength))
                      FROM trial_party_members m
                      JOIN player_physique pp ON pp.player_id = m.player_id
                      WHERE m.party_id = p_party_id), 0)
            * game_config_value('trial_damage_per_strength')))::bigint;
    END IF;

    v_pool := GREATEST(1, round(
        v_round::numeric
        * game_config_value('trial_rounds_wanted')
        * GREATEST(0.01, p_scale)))::bigint;

    SELECT GREATEST(1, round(
        s.base_hp
        * game_config_value('trial_boss_hp_scale')
        * (1 + game_config_value('trial_party_hp_step')
               * GREATEST(0, (SELECT count(*) FROM trial_party_members m
                              WHERE m.party_id = p_party_id) - 1))
        * GREATEST(0.01, p_scale)
    ))::bigint INTO v_floor
    FROM creature_species s WHERE s.species_id = p_species_id;

    RETURN GREATEST(v_pool, COALESCE(v_floor, 1));
END;
$fn$;

COMMENT ON FUNCTION trial_boss_hp(bigint, bigint, numeric) IS
    'What a Peer Trial''s creature carries. Rehearsed from the party since 0454: a ratio off sinew was wrong by nearly double, because crit_damage rather than sinew governs what a party puts out. p_scale sizes a lesser or a greater creature off the same rehearsal.';


-- ---------------------------------------------------------------------------
-- A rehearsal predicts the fight, and leaves nothing behind
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_spec  BIGINT;
    v_round BIGINT;
    v_pool  BIGINT;
    v_eff   BIGINT;
    v_after BIGINT;
    v_run   BIGINT;
    v_n     INTEGER := 0;
    r       RECORD;
    got     RECORD;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;

        IF v_lead IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT count(*) INTO v_eff FROM battle_effects;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
              AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;

        SELECT dg.species_id INTO v_spec FROM dungeons dg
        WHERE dg.realm_rank = (SELECT tp.realm_rank FROM trial_parties tp
                               WHERE tp.party_id = v_party) LIMIT 1;

        v_round := trial_rehearse(v_party, v_spec);
        IF v_round <= 0 THEN
            RAISE EXCEPTION 'the rehearsal says this party does nothing at all';
        END IF;

        -- Not one effect survived the rehearsal. This is the whole safety of
        -- the design: it runs the real swing, so it writes what the real swing
        -- writes, and all of it must be gone.
        SELECT count(*) INTO v_after FROM battle_effects;
        IF v_after <> v_eff THEN
            RAISE EXCEPTION
                'the rehearsal left % effects behind', v_after - v_eff;
        END IF;

        v_pool := trial_boss_hp(v_party, v_spec);
        IF v_pool < v_round * 3 THEN
            RAISE EXCEPTION
                'the creature carries % against a party that does % a round',
                v_pool, v_round;
        END IF;

        -- And the scale really sizes a lesser creature.
        IF trial_boss_hp(v_party, v_spec, 0.35) >= v_pool THEN
            RAISE EXCEPTION 'a scaled-down creature is not smaller';
        END IF;

        -- Then the fight itself, start to finish, to see how long it ran.
        PERFORM trial_party_seal(v_lead);
        SELECT t.run_id INTO v_run FROM trial_begin(v_lead) t;
        LOOP
            v_n := v_n + 1;
            SELECT * INTO got FROM trial_resolve_round(v_run);
            EXIT WHEN got IS NULL OR got.status = 'done' OR v_n > 40;
        END LOOP;

        RAISE NOTICE
            'rehearsed % a round, set % health, the fight ran % rounds and was %',
            v_round, v_pool, v_n,
            (SELECT tr.outcome FROM trial_runs tr WHERE tr.run_id = v_run);

        -- The point of the whole migration: a Trial is a fight, not an
        -- execution. Half the rounds it was asked for is the floor.
        IF v_n < game_config_value('trial_rounds_wanted') / 2 THEN
            RAISE EXCEPTION
                'the Trial still ends in % rounds when it was sized for %',
                v_n, game_config_value('trial_rounds_wanted');
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- And the old two-argument form is gone rather than shadowing the new one.
    IF (SELECT count(*) FROM pg_proc
        WHERE proname = 'trial_boss_hp'
          AND pronamespace = 'public'::regnamespace) <> 1 THEN
        RAISE EXCEPTION 'there is more than one trial_boss_hp to call';
    END IF;
END;
$probe$;
