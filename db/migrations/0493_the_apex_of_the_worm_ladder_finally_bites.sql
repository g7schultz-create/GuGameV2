-- 0493_the_apex_of_the_worm_ladder_finally_bites
--
-- 0492 lifted the lid. This is the half that puts something under it.
--
-- WHAT THE TWO LADDERS LOOKED LIKE, per point of aperture, which is the only
-- fair way to compare worms whose size equals their rank:
--
--     crit_damage   r1 0.0813   r5 0.0610   r8 0.1274   r9  -
--     multi_hit     r1 0.1250   r4 0.0548   r5 0.0522   r6+ -
--
-- Neither ladder climbs. crit_damage sags in the middle and stops at rank 8.
-- multi_hit is at its BEST on a rank 1 worm and gets worse from there, then
-- stops at rank 5 - so for the single effect that most decides a damage
-- build, the correct play was to fill the aperture with the cheapest worms in
-- the game. The apex of the ladder carried neither effect at all.
--
-- THE TEST THIS IS BUILT AGAINST, in the user's words: a tier 9 Gu must
-- outweigh many tier 1 Gu at max star. Made exact by using aperture, since a
-- rank 9 worm occupies 9 and a rank 1 worm occupies 1:
--
--     ONE rank 9 Gu at one star must beat NINE rank 1 Gu at five stars.
--
-- and measured against the BEST rank 1 worm rather than the average one,
-- because the strongest version of the thing is what has to be beaten:
--
--     nine rank 1 at five stars   crit_damage  9 x 0.1155 x 2.0 = 2.079
--                                 multi_hit    9 x 0.1500 x 2.0 = 2.700
--
-- My first pass used the averages, set rank 9 at 2.00 and 2.60, and the probe
-- below refused it. The bands are above the strict numbers instead: rank 9
-- crit_damage 2.30 to 2.90, multi_hit 2.85 to 3.40. Per point that is 0.256
-- to 0.322 and 0.317 to 0.378, against rank 8's best of 0.128 - so the apex
-- is two and a half times the rank below it per slot, not a rounding error
-- above it.
--
-- The multi_hit lid moves with them. 0492 set it to 0.28 per rank, which is
-- 5.04 at rank 18 - enough for ONE rank 9 strike worm and nothing else,
-- which is not a build. 0.40 per rank gives 7.20, which fits two. Changing a
-- seeded number in a later migration rather than editing 0492, which is
-- applied.
--
-- NOTHING EXISTING IS TOUCHED. Every magnitude already in the table stays
-- exactly as it is, because live cultivators are wearing them. This only adds
-- rows where there were none: crit_damage at rank 9, multi_hit at ranks 6
-- through 9. The sag at ranks 4 and 5 is left alone and noted - fixing it
-- would move eleven live builds, and it is a separate decision.
--
-- WHO CARRIES THE MULTI-HIT LADDER AT 6, 7 AND 8. The worms that already
-- carry armour penetration, which is not an arbitrary pick - 0037's own note
-- says it: "Defence is subtracted from EVERY strike, so a three-strike build
-- loses three lots of it and wants penetration badly". The two effects were
-- designed to want each other and were never put on the same worm above rank
-- 5. 11 worms at rank 6, 10 at rank 7, 2 at rank 8.
--
-- AND AT RANK 9, BY HAND, because there are fifteen and they have identities
-- worth keeping. The three cultivation worms, the pure formation worms and
-- Dao Wisdom stay what they are. Only the combat worms bite.
--
-- WHAT THIS COSTS AT THE TOP. One rank 9 multi-hit worm is +2.6 strikes at
-- 0.55 power each, which is 2.43x the damage of a single strike from one
-- slot. Six rank 9 crit worms reach 12.0 against the rank 18 lid of 12.6.
-- Both are large and both are the apex of a ladder that needs fifteen rare
-- worms and a repriced recipe to reach. Said plainly rather than buried.
--
-- Forward-only. Do not edit once applied.


-- Room for two rank 9 strike worms rather than one. See the header.
UPDATE gu_effects SET cap_per_rank = 0.4000 WHERE code = 'multi_hit';


-- ---------------------------------------------------------------------------
-- The multi-hit ladder, ranks 6 to 8
-- ---------------------------------------------------------------------------

-- Per-rank targets chosen so value per point of aperture rises monotonically
-- from rank 5 upward, which the probe below proves rather than assumes.
--
--     rank 6  0.42 / 6 = 0.070      rank 8  1.10 / 8 = 0.1375
--     rank 7  0.70 / 7 = 0.100      rank 9  2.60 / 9 = 0.2889
INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT gt.gu_type_id, 'multi_hit',
       CASE gt.rank WHEN 6 THEN 0.42 WHEN 7 THEN 0.70 WHEN 8 THEN 1.10 END
FROM gu_types gt
WHERE gt.rank BETWEEN 6 AND 8
  AND EXISTS (SELECT 1 FROM gu_type_effects e
              WHERE e.gu_type_id = gt.gu_type_id AND e.effect_code = 'armor_pen')
  AND NOT EXISTS (SELECT 1 FROM gu_type_effects e
                  WHERE e.gu_type_id = gt.gu_type_id AND e.effect_code = 'multi_hit');


-- ---------------------------------------------------------------------------
-- The fifteen
-- ---------------------------------------------------------------------------

-- Critical damage to the worms that are already about striking: the two
-- Heaven-Defying worms, the Heavenly Blade formation, and Love Gu, whose
-- wounded_power makes it a worm for a fight that has gone badly.
INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT gt.gu_type_id, 'crit_damage', m.mag
FROM (VALUES
    ('heaven_defying_chaos_gu',                        2.90),
    ('heaven_defying_venom_gu',                        2.70),
    ('venerable_immortal_heavenly_blade_formation_gu', 2.45),
    ('love_gu_r9',                                     2.30)
) AS m(code, mag)
JOIN gu_types gt ON gt.code = m.code AND gt.rank = 9
WHERE NOT EXISTS (SELECT 1 FROM gu_type_effects e
                  WHERE e.gu_type_id = gt.gu_type_id AND e.effect_code = 'crit_damage');

-- Extra strikes to the worms that are about reach and force: the Web that
-- catches everything, Venerable Strength, and Derivation.
INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT gt.gu_type_id, 'multi_hit', m.mag
FROM (VALUES
    ('heavenly_web_gu',      3.40),
    ('venerable_strength_gu',3.10),
    ('derivation_gu',        2.85)
) AS m(code, mag)
JOIN gu_types gt ON gt.code = m.code AND gt.rank = 9
WHERE NOT EXISTS (SELECT 1 FROM gu_type_effects e
                  WHERE e.gu_type_id = gt.gu_type_id AND e.effect_code = 'multi_hit');


-- ---------------------------------------------------------------------------
-- The ladder climbs now, and the user's test passes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_r1c   NUMERIC;
    v_r1m   NUMERIC;
    v_r9c   NUMERIC;
    v_r9m   NUMERIC;
    v_step  NUMERIC;
    v_n     INTEGER;
    r       RECORD;
BEGIN
    v_step := game_config_value('gu_star_step');

    -- 1. THE USER'S TEST, exactly. One rank 9 worm at one star against nine
    -- rank 1 worms at five stars, in the same nine points of aperture.
    SELECT max(e.magnitude) INTO v_r1c FROM gu_type_effects e
    JOIN gu_types t USING (gu_type_id)
    WHERE t.rank = 1 AND e.effect_code = 'crit_damage';
    SELECT max(e.magnitude) INTO v_r1m FROM gu_type_effects e
    JOIN gu_types t USING (gu_type_id)
    WHERE t.rank = 1 AND e.effect_code = 'multi_hit';

    SELECT min(e.magnitude) INTO v_r9c FROM gu_type_effects e
    JOIN gu_types t USING (gu_type_id)
    WHERE t.rank = 9 AND e.effect_code = 'crit_damage';
    SELECT min(e.magnitude) INTO v_r9m FROM gu_type_effects e
    JOIN gu_types t USING (gu_type_id)
    WHERE t.rank = 9 AND e.effect_code = 'multi_hit';

    IF v_r9c IS NULL OR v_r9m IS NULL THEN
        RAISE EXCEPTION 'rank 9 still carries no crit_damage or no multi_hit';
    END IF;

    -- the BEST rank 1 worm, nine of them, all at five stars - the strongest
    -- version of the thing rank 9 has to beat
    IF v_r9c <= 9 * v_r1c * (1 + v_step * 4) THEN
        RAISE EXCEPTION
            'the weakest rank 9 crit worm (%) does not beat nine max-star rank 1 (%)',
            v_r9c, 9 * v_r1c * (1 + v_step * 4);
    END IF;
    IF v_r9m <= 9 * v_r1m * (1 + v_step * 4) THEN
        RAISE EXCEPTION
            'the weakest rank 9 strike worm (%) does not beat nine max-star rank 1 (%)',
            v_r9m, 9 * v_r1m * (1 + v_step * 4);
    END IF;

    -- 2. And value per point of aperture rises from rank 5 up, on both
    -- ladders, which is the thing that was inverted.
    FOR r IN
        SELECT e.effect_code, t.rank, max(e.magnitude / t.size) AS per_point
        FROM gu_type_effects e JOIN gu_types t USING (gu_type_id)
        WHERE e.effect_code IN ('crit_damage', 'multi_hit') AND t.rank >= 5
        GROUP BY 1, 2 ORDER BY 1, 2
    LOOP
        v_bad := COALESCE(v_bad, '') || r.effect_code || ' r' || r.rank
                 || '=' || round(r.per_point, 4) || ' ';
    END LOOP;

    SELECT string_agg(x.effect_code || ' r' || x.rank || ' is worse than r' || x.prev, ', ')
    INTO v_bad
    FROM (
        SELECT cur.effect_code, cur.rank, prv.rank AS prev
        FROM (SELECT e.effect_code, t.rank, max(e.magnitude / t.size) AS pp
              FROM gu_type_effects e JOIN gu_types t USING (gu_type_id)
              WHERE e.effect_code IN ('crit_damage','multi_hit') AND t.rank >= 5
              GROUP BY 1,2) cur
        JOIN (SELECT e.effect_code, t.rank, max(e.magnitude / t.size) AS pp
              FROM gu_type_effects e JOIN gu_types t USING (gu_type_id)
              WHERE e.effect_code IN ('crit_damage','multi_hit') AND t.rank >= 5
              GROUP BY 1,2) prv
          ON prv.effect_code = cur.effect_code AND prv.rank < cur.rank
        WHERE cur.pp <= prv.pp
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the ladder still sags above rank 5: %', v_bad;
    END IF;

    -- 3. The multi-hit ladder is continuous from 6 to 9 rather than a gap.
    SELECT count(DISTINCT t.rank) INTO v_n
    FROM gu_type_effects e JOIN gu_types t USING (gu_type_id)
    WHERE e.effect_code = 'multi_hit' AND t.rank BETWEEN 6 AND 9;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'multi_hit covers only % of ranks 6 to 9', v_n;
    END IF;

    -- 4. Nothing that was already on a worm moved, because somebody is
    -- wearing it. Checked against the two magnitudes 0492 measured.
    IF (SELECT round(max(e.magnitude), 4) FROM gu_type_effects e
        JOIN gu_types t USING (gu_type_id)
        WHERE t.rank = 8 AND e.effect_code = 'crit_damage') <> 1.0237 THEN
        RAISE EXCEPTION 'an existing rank 8 crit magnitude changed';
    END IF;
    IF (SELECT round(max(e.magnitude), 4) FROM gu_type_effects e
        JOIN gu_types t USING (gu_type_id)
        WHERE t.rank = 5 AND e.effect_code = 'multi_hit') <> 0.3173 THEN
        RAISE EXCEPTION 'an existing rank 5 multi_hit magnitude changed';
    END IF;

    -- 5. The worms that are not about fighting were left alone.
    IF EXISTS (
        SELECT 1 FROM gu_types t JOIN gu_type_effects e USING (gu_type_id)
        WHERE t.rank = 9 AND e.effect_code IN ('crit_damage', 'multi_hit')
          AND t.code IN ('dao_heavenly_birth_gu', 'destiny_gu', 'fate_gu',
                         'dao_wisdom_gu', 'venerable_immortal_formation_gu',
                         'venerable_brocade_immortal_formation_gu')
    ) THEN
        RAISE EXCEPTION 'a cultivation or formation worm was given teeth';
    END IF;

    -- 6. Nobody living is wearing one of these yet, so nobody moved today.
    SELECT count(*) INTO v_n
    FROM player_gu_equipped eq
    JOIN gu_types t ON t.gu_type_id = eq.gu_type_id
    WHERE t.rank = 9;

    RAISE NOTICE
        'rank 9 now bites: crit from % up, strikes from % up; % already equipped',
        v_r9c, v_r9m, v_n;
END;
$probe$;
