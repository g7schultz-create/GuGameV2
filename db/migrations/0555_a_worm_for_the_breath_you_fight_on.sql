-- 0555_a_worm_for_the_breath_you_fight_on
--
-- Asked for: Gu across the ranks that give more qi, so a cultivator can throw
-- more attacks before they have to brace.
--
-- WHAT THE FIGHT ACTUALLY LOOKS LIKE. Qi costs a fraction of the aperture per
-- cast and a brace gives back `guard_qi_restore` (0.20), so the question is
-- how many casts the pool holds. Measured against the live world:
--
--     cultivator      standing   max_qi bonus   casts of their heaviest move
--     sylvrime            19         0.000                   2
--     m_i_y_u_k_i.        18         0.000                   2
--     pashu0              19         0.030                   3
--     clearwest           19         0.513                   3
--     real._.yoru         17         0.447                   3
--
-- Two casts and then brace. Three of the deepest cultivators in the game have
-- put NOTHING into qi, which is the shape of a stat nobody can buy enough of
-- to care about.
--
-- THE LINE ALREADY EXISTS, which is worth saying plainly: 392 Gu carry
-- `max_qi` across ranks 1 to 8, and 0514's repricing left them correctly
-- ordered - best value per point of aperture climbs 0.0419 at rank 1 to 0.0697
-- at rank 8, the same 1.66x the rest of the roster got. Two things are wrong
-- with it rather than one.
--
-- 1. RANK 9 HAS NO QI WORM AT ALL. The fifteen apex worms carry strength,
--    crits, braced, lifesteal - and nothing for the breath. A cultivator with
--    sixty points of aperture has no apex-tier way to spend any of it on qi.
--
-- 2. THE LID DOES NOT RISE. `max_qi` has `cap_per_rank = 0`, so the ceiling is
--    a flat 1.0 for a rank 1 and a Venerable alike, and the Gu lane is
--    `cap * source_share` = 0.600 for everybody for ever. 0492 fixed exactly
--    this for `crit_damage` (0.70 a rank) and `multi_hit` (0.40 a rank),
--    because "a flat cap meant Gu volume always caught Gu tier and the top of
--    the worm ladder was dead". Qi was not in that migration and has been flat
--    ever since - and the existing rank 8 worm already gives 0.5574 of the
--    0.600 lane, so ANY new worm would have been nearly unspendable.
--
-- Adding worms without (2) would have been nine new items that change nobody's
-- fight. So both.
--
-- THE LID: 0.08 a rank, the gentlest of the three. At rank 1 the lid stays
-- exactly 1.0 (GREATEST keeps it there, so nothing below rank 13 moves at
-- all); at rank 18 it is 1.44 and the Gu lane is 0.864; at Venerable 9 it is
-- 2.16. What that buys, for a rank 18 pool and a move costing 40% of aperture:
--
--     qi bonus    pool          casts
--     0.000       131,072,000       2      <- three of your top cultivators
--     0.557       204,131,533       3      <- the best worm available today
--     0.864       244,478,208       4      <- the lane, once the lid rises
--
-- Two casts to four, for a cultivator who spends nine points of aperture on
-- it. Still a real price: nine points is a rank 9 worm's whole size.
--
-- THE WORMS: one per rank, 1 to 9, on the curve the existing line already
-- follows rather than above it. At ranks 1 to 8 they TIE the current best
-- instead of beating it, so nothing anybody owns is devalued - what they add
-- is a worm that is obviously the qi worm at every rank, including the one
-- rank that had none. Magnitudes are the measured curve, 0.0419 per point of
-- aperture at rank 1 rising to 0.0750 at rank 9.
--
-- Materials and drop regions are taken from what already exists at each rank
-- rather than invented, so a recipe cannot name a material that is not there
-- and a drop cannot land in a region that does not spawn worms of that depth.
-- Rank 9 gets no region drop on purpose: `gu_max_droppable_rank` is 5 and
-- `gu_max_immortal_droppable_rank` is 8, so the apex comes from refining
-- (`gu_max_refinable_rank` is 9) and from the Vault, exactly as the other
-- fifteen apex worms do.


-- ---------------------------------------------------------------------------
-- 1. A lid that rises with the realm, as crit's has since 0492
-- ---------------------------------------------------------------------------

UPDATE gu_effects
SET cap_per_rank = 0.08,
    description = 'How much the battle qi pool is widened, as a fraction of the realm''s own capacity. The lid rises 0.08 a rank since 0555 - flat at 1.0 it meant one rank 8 worm filled the Gu lane and the apex had nothing left to sell, the same dead top 0492 fixed for critical damage and extra strikes.'
WHERE code = 'max_qi';


-- ---------------------------------------------------------------------------
-- 2. The line itself
-- ---------------------------------------------------------------------------

-- The prefixes the roster already uses to walk a worm up the ladder, and the
-- rarity band each rank actually carries. Both read off the existing data
-- rather than chosen here.
CREATE TEMP TABLE _qi_line_0555 (
    rank      SMALLINT PRIMARY KEY,
    code      TEXT NOT NULL,
    name      TEXT NOT NULL,
    rarity    TEXT NOT NULL,
    magnitude NUMERIC NOT NULL
) ON COMMIT DROP;

INSERT INTO _qi_line_0555 (rank, code, name, rarity, magnitude) VALUES
    (1, 'qi_sea_gu',           'Qi Sea Gu',           'rare',      0.0420),
    (2, 'grand_qi_sea_gu',     'Grand Qi Sea Gu',     'epic',      0.0902),
    (3, 'ancient_qi_sea_gu',   'Ancient Qi Sea Gu',   'legendary', 0.1455),
    (4, 'elder_qi_sea_gu',     'Elder Qi Sea Gu',     'legendary', 0.2084),
    (5, 'heaven_qi_sea_gu',    'Heaven Qi Sea Gu',    'mythic',    0.2800),
    (6, 'immortal_qi_sea_gu',  'Immortal Qi Sea Gu',  'divine',    0.3618),
    (7, 'venerable_qi_sea_gu', 'Venerable Qi Sea Gu', 'unique',    0.4536),
    (8, 'divine_qi_sea_gu',    'Divine Qi Sea Gu',    'unique',    0.5576),
    (9, 'dao_qi_sea_gu',       'Dao Qi Sea Gu',       'extreme',   0.6750);

INSERT INTO gu_types (code, name, path_code, rank, rarity, category, size, emoji, description)
SELECT q.code, q.name, 'qi', q.rank, q.rarity, 'support', q.rank, '🫁',
       CASE q.rank
         WHEN 1 THEN 'A shallow thing. It holds one more breath than you had, which on the day you need it is the whole of the difference.'
         WHEN 2 THEN 'The pool stops draining quite so fast. You notice it in the third exchange rather than the first.'
         WHEN 3 THEN 'Old cultivators call this the first worm worth feeding. It is not strong. It is simply always useful.'
         WHEN 4 THEN 'What it widens is not your strength but your patience - and a fight is decided by whoever runs out last.'
         WHEN 5 THEN 'A sea rather than a pool. The word is not decoration: you will feel where the floor used to be.'
         WHEN 6 THEN 'Immortals do not fight briefly. This is the worm that lets them not have to.'
         WHEN 7 THEN 'Carried by those who intend the fight to go long, and who have already decided they will win it that way.'
         WHEN 8 THEN 'Nine tenths of the lane, in one worm. What is left is barely worth a second.'
         ELSE 'The breath beneath the breath. A Venerable does not pause to gather themselves, and this is why.'
       END
FROM _qi_line_0555 q;

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT t.gu_type_id, 'max_qi', q.magnitude
FROM _qi_line_0555 q JOIN gu_types t ON t.code = q.code;

-- A recipe built from whatever already feeds a worm of that rank. Deterministic
-- (`ORDER BY ... LIMIT 1`), so the migration cannot pick a material that does
-- not exist at that depth - which is how a recipe becomes unmakeable.
INSERT INTO gu_recipes (gu_type_id, base_material, secondary_material)
SELECT t.gu_type_id, src.base_material, src.secondary_material
FROM _qi_line_0555 q
JOIN gu_types t ON t.code = q.code
CROSS JOIN LATERAL (
    SELECT r.base_material, r.secondary_material
    FROM gu_recipes r JOIN gu_types t2 ON t2.gu_type_id = r.gu_type_id
    WHERE t2.rank = q.rank
      AND r.base_material IS NOT NULL
      AND r.secondary_material IS NOT NULL
    ORDER BY r.base_material, r.secondary_material
    LIMIT 1
) src;

-- And it drops where worms of that rank already drop. Rank 9 is left out
-- deliberately: nothing rank 9 drops in the world.
INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
SELECT src.region_code, t.gu_type_id, src.weight
FROM _qi_line_0555 q
JOIN gu_types t ON t.code = q.code
CROSS JOIN LATERAL (
    SELECT d.region_code, d.weight
    FROM gu_region_drops d JOIN gu_types t2 ON t2.gu_type_id = d.gu_type_id
    WHERE t2.rank = q.rank
    ORDER BY d.region_code
    LIMIT 1
) src
WHERE q.rank <= 8;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n      INTEGER;
    v_prev   NUMERIC := 0;
    v_rk     RECORD;
    v_lo     NUMERIC;
    v_hi     NUMERIC;
    v_who    BIGINT;
    v_before NUMERIC;
    v_after  NUMERIC;
    v_casts  INTEGER;
    v_was    INTEGER;
BEGIN
    -- 1. NINE WORMS, ONE PER RANK, EACH SIZED BY ITS RANK.
    SELECT count(*) INTO v_n FROM gu_types WHERE code LIKE '%qi_sea_gu';
    IF v_n <> 9 THEN
        RAISE EXCEPTION 'the qi line has % worms, not 9', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM gu_types WHERE code LIKE '%qi_sea_gu' AND size <> rank) THEN
        RAISE EXCEPTION 'a qi worm is not sized by its own rank';
    END IF;

    -- 2. THE LADDER CLIMBS. 0514's whole subject: value per point of aperture
    --    must rise with rank, or the cheapest worm is the best worm again.
    FOR v_rk IN
        SELECT t.rank, e.magnitude / t.rank AS per_point
        FROM gu_types t JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
        WHERE t.code LIKE '%qi_sea_gu' AND e.effect_code = 'max_qi'
        ORDER BY t.rank
    LOOP
        IF v_rk.per_point <= v_prev THEN
            RAISE EXCEPTION
                'rank % gives %/point, no better than the rank below it',
                v_rk.rank, round(v_rk.per_point, 4);
        END IF;
        v_prev := v_rk.per_point;
    END LOOP;

    -- 3. AND IT DOES NOT BEAT WHAT PEOPLE ALREADY OWN. Ranks 1-8 tie the
    --    existing best rather than exceeding it, so no shelf is devalued.
    FOR v_rk IN
        SELECT t.rank, e.magnitude AS mine,
               (SELECT max(e2.magnitude) FROM gu_type_effects e2
                JOIN gu_types t2 ON t2.gu_type_id = e2.gu_type_id
                WHERE e2.effect_code = 'max_qi' AND t2.rank = t.rank
                  AND t2.code NOT LIKE '%qi_sea_gu') AS theirs
        FROM gu_types t JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
        WHERE t.code LIKE '%qi_sea_gu' AND e.effect_code = 'max_qi' AND t.rank <= 8
    LOOP
        IF v_rk.mine > v_rk.theirs * 1.01 THEN
            RAISE EXCEPTION
                'the rank % qi worm gives % against an existing best of % - '
                'that is power creep, not a line', v_rk.rank, v_rk.mine, v_rk.theirs;
        END IF;
    END LOOP;

    -- 4. EVERY ONE OF THEM CAN BE MADE, and the materials are real.
    SELECT count(*) INTO v_n
    FROM gu_types t JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
    JOIN materials b ON b.code = r.base_material
    JOIN materials s ON s.code = r.secondary_material
    WHERE t.code LIKE '%qi_sea_gu';
    IF v_n <> 9 THEN
        RAISE EXCEPTION
            'only % of 9 qi worms have a recipe whose materials exist', v_n;
    END IF;
    IF (SELECT max(rank) FROM gu_types WHERE code LIKE '%qi_sea_gu')
       > game_config_value('gu_max_refinable_rank') THEN
        RAISE EXCEPTION
            'the apex qi worm is past the refining ceiling - the same gate that '
            'left fifteen rank 9 recipes unreachable until 0494';
    END IF;

    -- 5. RANKS 1-8 DROP SOMEWHERE; RANK 9 DELIBERATELY DOES NOT.
    SELECT count(DISTINCT t.rank) INTO v_n
    FROM gu_types t JOIN gu_region_drops d ON d.gu_type_id = t.gu_type_id
    WHERE t.code LIKE '%qi_sea_gu';
    IF v_n <> 8 THEN
        RAISE EXCEPTION '% ranks of the qi line drop in the world, expected 8', v_n;
    END IF;
    IF EXISTS (SELECT 1 FROM gu_types t JOIN gu_region_drops d
               ON d.gu_type_id = t.gu_type_id
               WHERE t.code = 'dao_qi_sea_gu') THEN
        RAISE EXCEPTION 'the apex qi worm drops in the world and should not';
    END IF;

    -- 6. THE LID NOW RISES WITH THE REALM, which is what makes any of this
    --    spendable. Read through `gu_effect_cap`, the function that decides it.
    SELECT p.player_id INTO v_who
    FROM players p WHERE p.deleted_at IS NULL AND p.discord_id > 0
    ORDER BY player_standing(p.player_id) DESC LIMIT 1;

    IF v_who IS NOT NULL THEN
        v_hi := gu_effect_cap('max_qi', v_who);
        IF v_hi <= 1.0 THEN
            RAISE EXCEPTION
                'the qi lid is still flat at % for the deepest cultivator', v_hi;
        END IF;
        RAISE NOTICE
            'the qi lid for the deepest cultivator is now % (was 1.00)',
            round(v_hi, 2);
    END IF;

    -- And a rank 1 is untouched: the lid RISES with realm, it never falls.
    IF (SELECT GREATEST(e.cap, e.cap_per_rank * 1) FROM gu_effects e
        WHERE e.code = 'max_qi') <> 1.0 THEN
        RAISE EXCEPTION 'the lid moved for a rank 1, and it should not have';
    END IF;

    -- 7. AND NOBODY'S QI CHANGED TODAY. New worms sit on a shelf nobody owns;
    --    a raised lid cannot raise a stat that was below the old lid anyway.
    PERFORM 1;
    SELECT count(*) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id > 0
      AND player_stat(p.player_id, 'max_qi') > gu_effect_cap('max_qi', p.player_id);
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators read above their own qi lid', v_n;
    END IF;
END
$probe$;
