-- 0514_the_cheapest_worm_stops_being_the_best_one
--
-- THE GU LADDER IS INVERTED EVERYWHERE. Value per point of APERTURE, which is
-- the only fair way to compare worms whose size equals their rank:
--
--     effect        rank 1    rank 8    rank 8 as a share of rank 1
--     lifesteal     0.0847    0.0300    0.35
--     dodge         0.0705    0.0297    0.42
--     armor_pen     0.1200    0.0563    0.47
--     crit_rate     0.0800    0.0389    0.49
--     braced        0.0560    0.0375    0.67
--     base_hp       7.3560    5.2500    0.71
--
-- All twenty-seven effects, 36 inversions in lifesteal alone. Filling an
-- aperture with the cheapest worms in the game beat filling it with the best,
-- everywhere, for every build. And it was not a quirk anybody got away with -
-- it is what the roster rewarded, which is visible in who wears what:
--
--     m_i_y_u_k_i.   41 worms, average rank 1.2, 54 of 54 aperture
--     shinonn._.     31 worms, average rank 1.4, 54 of 54
--     pashu0         37 worms, average rank 1.5, 57 of 57
--
-- Three cultivators built the optimal thing the numbers described. 102 rank 1
-- worms are worn across eight people.
--
-- WHY THIS CANNOT BE FIXED BY RAISING THE TOP. 0209 set every effect's biggest
-- worm at exactly three fifths of its cap - headroom is 1.00 to two decimal
-- places for twenty-five of the twenty-seven. Making a rank 8 lifesteal worm
-- merely EQUAL per slot needs magnitude 0.678 against a cap of 0.400; it would
-- have to exceed the cap on the whole build to be worth its own slot.
--
-- SO THE LOW RANKS COME DOWN. The user chose this over raising the caps,
-- knowing it costs live cultivators value - which it does, and the cost is
-- reported per person by the probe rather than summarised. The top of each
-- ladder does not move at all: the apex is the reference.
--
-- THE RULE. Walking each effect from its top rank downwards, every rank must
-- be worth less per aperture point than the rank above it by a factor of
-- `gu_rank_growth`. A rank that already sits below that line is left exactly
-- where it is - nothing is raised, because there is no room to raise it.
-- Within a rank every worm is scaled by the same factor, so a strong fire
-- worm stays strong relative to its neighbours and only the ladder moves.
--
-- 1.0753 a rank, which is 1.66x from rank 1 to rank 8. Deliberately the
-- mildest curve that still climbs: the cut is already 65% at the bottom for
-- the worst effects and a steeper ladder would only deepen it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value) VALUES ('gu_rank_growth', 1.0753)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ---------------------------------------------------------------------------
-- What the ladder is before it moves, kept so the probe can price the change
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE gu_before AS
SELECT e.effect_code, g.gu_type_id, e.magnitude
FROM gu_type_effects e JOIN gu_types g USING (gu_type_id);

CREATE TEMP TABLE worn_before AS
SELECT q.player_id, s.effect_code, s.total
FROM player_gu_stats s
JOIN (SELECT DISTINCT player_id FROM player_gu_equipped) q USING (player_id);


-- ---------------------------------------------------------------------------
-- Walk every ladder down from its apex
-- ---------------------------------------------------------------------------

DO $rebalance$
DECLARE
    v_growth NUMERIC := game_config_value('gu_rank_growth');
    v_allow  NUMERIC;
    v_cur    NUMERIC;
    v_factor NUMERIC;
    v_moved  INTEGER := 0;
    eff      RECORD;
    rk       RECORD;
BEGIN
    FOR eff IN
        SELECT e.effect_code, max(g.rank) AS top_rank
        FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
        GROUP BY e.effect_code
    LOOP
        -- The apex sets the reference and does not move.
        SELECT max(e.magnitude / g.size) INTO v_allow
        FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
        WHERE e.effect_code = eff.effect_code AND g.rank = eff.top_rank;

        FOR rk IN
            SELECT DISTINCT g.rank
            FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
            WHERE e.effect_code = eff.effect_code AND g.rank < eff.top_rank
            ORDER BY g.rank DESC
        LOOP
            -- Each rank down is allowed less per point than the one above it.
            v_allow := v_allow / v_growth;

            SELECT max(e.magnitude / g.size) INTO v_cur
            FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
            WHERE e.effect_code = eff.effect_code AND g.rank = rk.rank;

            IF v_cur IS NULL OR v_cur <= v_allow THEN
                -- Already under the line. Left alone, and the line comes down
                -- to meet it so the ranks below are measured against what is
                -- actually here rather than against a ceiling nobody reaches.
                v_allow := COALESCE(v_cur, v_allow);
                CONTINUE;
            END IF;

            v_factor := v_allow / v_cur;

            UPDATE gu_type_effects e
            SET magnitude = GREATEST(0.0010, round(e.magnitude * v_factor, 4))
            FROM gu_types g
            WHERE g.gu_type_id = e.gu_type_id
              AND e.effect_code = eff.effect_code
              AND g.rank = rk.rank;

            v_moved := v_moved + 1;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'scaled % effect-rank bands down', v_moved;
END;
$rebalance$;


-- ---------------------------------------------------------------------------
-- The ladder climbs, nothing rose, and the cost is named
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_n     INTEGER;
    v_worst NUMERIC;
    one     RECORD;
BEGIN
    -- 1. THE POINT OF ALL OF IT: no effect is inverted any more. A rank R
    -- worm is worth more per aperture point than any rank below it.
    SELECT string_agg(x.effect_code || ' r' || x.hi_rank || ' under r' || x.lo_rank, ', ')
    INTO v_bad
    FROM (
        SELECT a.effect_code, a.rank AS lo_rank, b.rank AS hi_rank
        FROM (SELECT e.effect_code, g.rank, max(e.magnitude / g.size) pp
              FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
              GROUP BY 1, 2) a
        JOIN (SELECT e.effect_code, g.rank, max(e.magnitude / g.size) pp
              FROM gu_type_effects e JOIN gu_types g USING (gu_type_id)
              GROUP BY 1, 2) b
          ON b.effect_code = a.effect_code AND b.rank > a.rank AND b.pp <= a.pp
        LIMIT 8
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the ladder is still inverted: %', v_bad;
    END IF;

    -- 2. Nothing was raised. This is a cut, and a cut that quietly buffed
    -- something would be a different change than the one agreed.
    SELECT count(*) INTO v_n
    FROM gu_type_effects e
    JOIN gu_before b ON b.gu_type_id = e.gu_type_id AND b.effect_code = e.effect_code
    WHERE e.magnitude > b.magnitude + 0.00005;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% magnitudes went UP in a rebalance that only cuts', v_n;
    END IF;

    -- 3. The apex of every ladder is untouched. The top is the reference.
    SELECT string_agg(e.effect_code, ', ') INTO v_bad
    FROM gu_type_effects e
    JOIN gu_types g USING (gu_type_id)
    JOIN gu_before b ON b.gu_type_id = e.gu_type_id AND b.effect_code = e.effect_code
    WHERE e.magnitude <> b.magnitude
      AND g.rank = (SELECT max(g2.rank) FROM gu_type_effects e2
                    JOIN gu_types g2 USING (gu_type_id)
                    WHERE e2.effect_code = e.effect_code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the apex moved for: %', v_bad;
    END IF;

    -- 4. And 0209's rule still holds - no single worm finishes an effect by
    -- itself. Cutting cannot break it, which is worth proving rather than
    -- assuming, because the rank 9 band sits above the flat cap by design.
    SELECT count(*) INTO v_n
    FROM gu_type_effects e
    JOIN gu_types g USING (gu_type_id)
    JOIN gu_effects f ON f.code = e.effect_code
    WHERE g.rank <= 8 AND e.magnitude > 0.6 * f.cap;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% worms below rank 9 now eat a whole ceiling', v_n;
    END IF;

    -- 5. Nothing fell to nothing. A worm whose number rounds to zero is a
    -- worm that stopped existing.
    SELECT count(*) INTO v_n FROM gu_type_effects WHERE magnitude <= 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% worms were cut out of existence', v_n;
    END IF;

    -- 6. THE COST, per cultivator, named rather than summarised. This is a
    -- deliberate nerf and the people who pay for it are the people who built
    -- what the old numbers rewarded.
    FOR one IN
        SELECT p.discord_name,
               round(avg(100.0 * (1 - s.total / NULLIF(w.total, 0))), 1) AS lost_pct,
               count(*) AS effects
        FROM worn_before w
        JOIN player_gu_stats s
          ON s.player_id = w.player_id AND s.effect_code = w.effect_code
        JOIN players p ON p.player_id = w.player_id
        WHERE w.total > 0
        GROUP BY p.discord_name
        ORDER BY 2 DESC NULLS LAST
        LIMIT 6
    LOOP
        RAISE NOTICE '% loses about %%% across % effects',
            one.discord_name, one.lost_pct, one.effects;
    END LOOP;

    SELECT round(max(100.0 * (1 - s.total / NULLIF(w.total, 0))), 1) INTO v_worst
    FROM worn_before w
    JOIN player_gu_stats s
      ON s.player_id = w.player_id AND s.effect_code = w.effect_code
    WHERE w.total > 0;

    RAISE NOTICE
        'the worst single stat loss is %%%; the ladder now climbs on all % effects',
        v_worst, (SELECT count(DISTINCT effect_code) FROM gu_type_effects);
END;
$probe$;
