-- 0556_the_qi_line_pays_its_own_depth
--
-- 0555 gave the new qi worms recipes by copying whatever an existing worm of
-- the same rank was made from, picked `ORDER BY base_material LIMIT 1`. That
-- is deterministic, which was the point, and alphabetical, which was not:
--
--     rank   base material          tier    that rank's average
--     1-4    abyssal_soul_lotus       6         3.6 - 4.1
--     5-7    abyssal_bone_powder      9         4.4 - 5.3
--     8      abyssal_soul_lotus       6         9.9      <-- below its peers
--     9      abyssal_soul_lotus       6         3.9
--
-- Two things wrong with it. The Divine Qi Sea Gu asks for a tier 6 material
-- where every other rank 8 worm asks for about tier 10 - the apex of the
-- obtainable ladder, bought with something a Core Formation cultivator can
-- farm. And six of the nine ranks name the same two materials, so the line
-- reads as one recipe copied down a column rather than a worm that gets harder
-- to make.
--
-- Worth being clear about what is NOT wrong: the QUANTITY is right. Cost comes
-- from `gu_refine_costs` keyed on rank and `gu_refine_rarity_costs` keyed on
-- rarity - the material's identity never enters it - so the apex still asks
-- for 4,800 base at the `extreme` multiplier of 14, which is 67,200. Nothing
-- here is cheaper or dearer than 0555 made it. This is about which shelf you
-- empty, not how much of it.
--
-- Nor is a shallow material wrong in itself at rank 9: the fifteen existing
-- apex worms average tier 3.9 and that is deliberate, since the apex is gated
-- by volume rather than by depth. Rank 8 is the one that stands out from its
-- own neighbours, and the repetition is the one that reads badly.
--
-- So each rank is repointed at a material drawn from its OWN rank's recipes,
-- nearest to that rank's median tier, and distinct from the ranks around it.
-- Derived rather than chosen, so it cannot name a material that does not exist
-- or one that no worm of that depth is built from.


WITH target AS (
    -- What a worm of each rank is actually made from, in depth terms.
    SELECT t.rank,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY m.tier) AS median_tier
    FROM gu_recipes r
    JOIN gu_types t ON t.gu_type_id = r.gu_type_id
    JOIN materials m ON m.code = r.base_material
    WHERE t.code NOT LIKE '%qi_sea_gu'
    GROUP BY t.rank
),
ranked AS (
    -- Every material that rank is built from, nearest its median first, and
    -- numbered so each rank can take a different one.
    SELECT t.rank, m.code, m.tier,
           row_number() OVER (
               PARTITION BY t.rank
               ORDER BY abs(m.tier - g.median_tier), m.code
           ) AS nth
    FROM gu_recipes r
    JOIN gu_types t ON t.gu_type_id = r.gu_type_id
    JOIN materials m ON m.code = r.base_material
    JOIN target g ON g.rank = t.rank
    WHERE t.code NOT LIKE '%qi_sea_gu'
    GROUP BY t.rank, m.code, m.tier, g.median_tier
),
pick AS (
    -- NEAREST THE MEDIAN, full stop. The first version walked `nth` forward
    -- with rank to keep neighbouring ranks off the same shelf, and that pulled
    -- in the opposite direction to the thing being fixed: at rank 8 the offset
    -- reached the eighth-nearest material and landed on tier 2 against a band
    -- of 12. The probe caught it. Depth is the point; variety is whatever
    -- falls out of nine ranks having nine different material pools.
    SELECT q.gu_type_id, q.rank,
           (SELECT rk.code FROM ranked rk
            WHERE rk.rank = q.rank AND rk.nth = 1) AS base_material
    FROM (SELECT t.gu_type_id, t.rank FROM gu_types t
          WHERE t.code LIKE '%qi_sea_gu') q
)
UPDATE gu_recipes r
SET base_material = pick.base_material
FROM pick
WHERE r.gu_type_id = pick.gu_type_id
  AND pick.base_material IS NOT NULL;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_rk   RECORD;
    v_q    INTEGER;
BEGIN
    -- 1. STILL MAKEABLE: nine recipes, every material real.
    SELECT count(*) INTO v_n
    FROM gu_types t
    JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
    JOIN materials b ON b.code = r.base_material
    JOIN materials s ON s.code = r.secondary_material
    WHERE t.code LIKE '%qi_sea_gu';
    IF v_n <> 9 THEN
        RAISE EXCEPTION '% of 9 qi worms have a makeable recipe', v_n;
    END IF;

    -- 2. EACH SITS IN ITS OWN RANK'S BAND. Not a fixed tier - the roster is
    --    loose about this on purpose, and rank 9 is genuinely shallow - but
    --    within reach of what that rank is actually built from, which is what
    --    rank 8 at tier 6 against a band of 9.9 was not.
    FOR v_rk IN
        SELECT t.rank, m.tier AS mine,
               (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY m2.tier)
                FROM gu_recipes r2 JOIN gu_types t2 ON t2.gu_type_id = r2.gu_type_id
                JOIN materials m2 ON m2.code = r2.base_material
                WHERE t2.rank = t.rank
                  AND t2.code NOT LIKE '%qi_sea_gu')::numeric AS band
        FROM gu_types t
        JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
        JOIN materials m ON m.code = r.base_material
        WHERE t.code LIKE '%qi_sea_gu'
        ORDER BY t.rank
    LOOP
        IF abs(v_rk.mine - v_rk.band) > 3 THEN
            RAISE EXCEPTION
                'the rank % qi worm is built from tier % against a band of % '
                'for that rank', v_rk.rank, v_rk.mine, round(v_rk.band::numeric, 1);
        END IF;
        RAISE NOTICE 'rank %: tier % (rank''s median %)',
            v_rk.rank, v_rk.mine, round(v_rk.band::numeric, 1);
    END LOOP;

    -- 3. AND IT IS NOT ONE RECIPE COPIED DOWN A COLUMN. Reported rather than
    --    demanded: nine ranks draw from nine different material pools, so some
    --    spread is expected, but forcing it is what broke rank 8 above.
    SELECT count(DISTINCT r.base_material) INTO v_n
    FROM gu_types t JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
    WHERE t.code LIKE '%qi_sea_gu';
    RAISE NOTICE 'nine worms, % distinct base materials', v_n;
    IF v_n < 3 THEN
        RAISE EXCEPTION
            'the whole line is built from % material(s) - that is one recipe '
            'with nine names', v_n;
    END IF;

    -- 4. THE PRICE DID NOT MOVE. Cost is rank x rarity and never the material,
    --    so the apex must still ask what 0494 priced it at.
    SELECT base_quantity INTO v_q
    FROM gu_recipe_costs WHERE gu_code = 'dao_qi_sea_gu';
    IF v_q <> ceil(4800 * (SELECT multiplier FROM gu_refine_rarity_costs
                           WHERE rarity = 'extreme')) THEN
        RAISE EXCEPTION
            'the apex qi worm now costs % base, which is not what rank 9 at '
            'extreme is priced at', v_q;
    END IF;
    RAISE NOTICE 'the apex still asks for % of its base material', v_q;
END
$probe$;
