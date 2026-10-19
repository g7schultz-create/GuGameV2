-- 0550_a_duel_the_shallow_end_can_win
--
-- 0532 made damage matter in a duel, which was asked for in those words, and
-- it works:
--
--     duel_share = LEAST(duel_max_bite,
--                        duel_bite * (raw / pool) ^ duel_curve)
--
-- The spread it was measured on - 2.0 to 19.8 rounds, 8.1x between the fastest
-- and slowest kill, no one-shots - was measured AT THE TOP OF THE LADDER,
-- because that is where the Venerable raid was being built. Below there it was
-- never looked at, and `raw / pool` is exactly the thing that changes with
-- depth. Strength per point of health, measured off the live world:
--
--     standing  1    0.20        standing 12    1.11
--     standing  3    0.24        standing 17    3.91
--     standing  5    0.42        standing 18    2.26
--     standing  6    1.04
--
-- A rank 1 cultivator hits for a fifth of their own health; a Venerable hits
-- for twice theirs. Through `(raw/pool)^0.55` that is a 2.9x difference in the
-- share of a blow that lands, and with `duel_bite` at 0.05 the shallow end
-- falls under the floor the turn cap puts on a fight:
--
--     standing  1    DREW AT THE CAP        standing 12    28 rounds
--     standing  3    DREW AT THE CAP        standing 17    10 rounds
--     standing  5    16 rounds              standing 18    21 rounds
--     standing  6    DREW AT THE CAP
--
-- THREE OF SEVEN LIVE STANDINGS COULD NOT WIN A DUEL. Not "found it slow" -
-- could not win one, at all, ever: fifty rounds of landing real blows and then
-- `battle_turn_cap` calls it a draw. And /duel is open to everybody, so that
-- is most of the people who would use it.
--
-- `duel_bite` is a LINEAR scale on the share, so raising it moves every duel
-- by the same factor and changes nothing about the spread between two builds -
-- the 8.1x that was tuned and approved is untouched. 0.12 is the smallest
-- value with real headroom. Measured, same bodies, same moves:
--
--     bite    shallowest       deepest     draws
--     0.05    50 (drew)        21          3
--     0.09    46               10          0   <- 4 rounds of margin
--     0.12    34                8          0   <- 16 rounds of margin
--     0.16    24                6          0
--
-- 0.09 clears the draws on paper and one braced round puts it back over, so it
-- is not a fix. 0.12 is, and keeps the band inside the 2-to-20 the top of the
-- ladder was signed off at - those figures are MIRROR duels, two identical
-- bodies, which is the longest a fight at that depth can run. A real duel
-- between unequal builds ends sooner, for the better one.
--
-- What this does NOT touch: `duel_max_bite` (0.50), `duel_curve` (0.55), and
-- every chance effect. The raid's betrayal goes through the same
-- `compute_duel_damage`, so a knife in the Vault lands 2.4x harder too - which
-- is the same correction, in the one place PvP was already live.


UPDATE game_config
SET value = 0.12,
    description = 'The share of a defender''s health one duel blow may take at parity, before `duel_curve` shapes it and `duel_max_bite` caps it. Raised from 0.05 in 0550: at 0.05 the three shallowest live standings could not win a duel at all - fifty rounds of real blows and then the turn cap called it a draw. A linear scale, so the spread between two builds is exactly what 0532 tuned.'
WHERE key = 'duel_bite';


-- ---------------------------------------------------------------------------
-- The probe
--
-- A mirror duel at every standing anybody actually stands at, played out to
-- the cap. This is the probe that was missing: the rule it checks cannot be
-- read off a formula, because what it depends on - strength per point of
-- health - is a property of the world and not of the arithmetic.
--
-- On a database with no cultivators in it the loop finds nobody and asserts
-- nothing, which is correct: there is no world to measure. tests/test_duel.py
-- pins the same rule against figures it builds itself.
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    src     RECORD;
    v_a     BIGINT;
    v_b     BIGINT;
    v_tech  BIGINT;
    v_duel  BIGINT;
    v_i     INTEGER;
    v_round INTEGER;
    v_stat  TEXT;
    v_cap   INTEGER := game_config_value('battle_turn_cap');
    v_seq   INTEGER := 0;
    v_drew  TEXT := '';
    v_worst INTEGER := 0;
BEGIN
    BEGIN
        FOR src IN
            SELECT player_standing(p.player_id) AS standing,
                   pp.player_id, pp.max_hp, pp.defense, pp.strength
            FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
            WHERE p.deleted_at IS NULL AND p.discord_id > 0
            ORDER BY player_standing(p.player_id), pp.max_hp DESC
        LOOP
            -- One representative per standing: the deepest body standing at it.
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM player_physique pp2
                JOIN players p2 ON p2.player_id = pp2.player_id
                WHERE p2.deleted_at IS NULL AND p2.discord_id > 0
                  AND player_standing(p2.player_id) = src.standing
                  AND pp2.max_hp > src.max_hp
            );

            -- THEIR OWN best move. A rank 1 swinging the apex technique is not
            -- a rank 1 duel, and the whole question here is what the shallow
            -- end can do with what it has.
            SELECT u.technique_id INTO v_tech
            FROM player_usable_techniques u
            JOIN techniques t ON t.technique_id = u.technique_id
            WHERE u.player_id = src.player_id AND t.category = 'attack'
            ORDER BY technique_power_for(src.player_id, u.technique_id) DESC
            LIMIT 1;

            CONTINUE WHEN v_tech IS NULL;

            v_seq := v_seq + 1;
            INSERT INTO players (discord_id, discord_name)
            VALUES (-7000 - v_seq * 2, 'mirror-a-' || v_seq)
            RETURNING player_id INTO v_a;
            INSERT INTO players (discord_id, discord_name)
            VALUES (-7001 - v_seq * 2, 'mirror-b-' || v_seq)
            RETURNING player_id INTO v_b;

            INSERT INTO player_cultivation (player_id, realm_id, cultivation)
            SELECT x.who, c.realm_id, c.cultivation
            FROM (VALUES (v_a), (v_b)) AS x(who)
            CROSS JOIN LATERAL (
                SELECT realm_id, cultivation FROM player_cultivation
                WHERE player_id = src.player_id) c;

            INSERT INTO player_physique
                (player_id, physique_id, max_hp, current_hp, defense, strength)
            SELECT x.who, (SELECT physique_id FROM player_physique
                           WHERE player_id = src.player_id),
                   src.max_hp, src.max_hp, src.defense, src.strength
            FROM (VALUES (v_a), (v_b)) AS x(who);

            INSERT INTO player_techniques (player_id, technique_id)
            VALUES (v_a, v_tech), (v_b, v_tech);

            v_duel := duel_open(v_a, v_b);
            v_round := 0;

            FOR v_i IN 1..(v_cap + 5) LOOP
                -- Swing if it can be paid for, brace if it cannot. Bracing is
                -- what restores the qi to swing again, so a harness that only
                -- attacks is not measuring the fight.
                BEGIN
                    PERFORM duel_choose(v_duel, v_a, 'attack', v_tech);
                EXCEPTION WHEN check_violation THEN
                    PERFORM duel_choose(v_duel, v_a, 'guard');
                END;
                BEGIN
                    PERFORM duel_choose(v_duel, v_b, 'attack', v_tech);
                EXCEPTION WHEN check_violation THEN
                    PERFORM duel_choose(v_duel, v_b, 'guard');
                END;
                v_round := v_round + 1;
                SELECT b.status INTO v_stat FROM battles b
                WHERE b.battle_id = v_duel;
                EXIT WHEN v_stat <> 'active';
            END LOOP;

            v_worst := GREATEST(v_worst, v_round);
            IF v_stat = 'expired' THEN
                v_drew := v_drew || ' ' || src.standing::text;
            END IF;

            RAISE NOTICE 'standing %: % rounds (%)',
                src.standing, v_round, v_stat;
        END LOOP;

        IF v_drew <> '' THEN
            RAISE EXCEPTION
                'these standings still cannot win a duel:% - fifty rounds of '
                'real blows and the turn cap calls it a draw', v_drew;
        END IF;

        IF v_seq = 0 THEN
            RAISE NOTICE
                'no cultivators to measure, so nothing was asserted';
        ELSE
            RAISE NOTICE
                '% standings measured, longest mirror duel % rounds against a '
                'cap of %', v_seq, v_worst, v_cap;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN
            RAISE;
        END IF;
    END;
END
$probe$;
