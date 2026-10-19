-- 0368_the_heavens_grow_nothing_a_mortal_could_use
--
-- Black Heaven and White Heaven are gated to immortals and grow herbs of tier
-- 1 to 7 - the same band as the Central Continent, where a Qi Condensation
-- cultivator picks weeds. An immortal-only region handing out tier 1 herbs is
-- the reward curve flattening out exactly where it should be steepest.
--
-- The heavens now run tier 6 to 12: a floor no mortal region reaches and a
-- ceiling nothing else in the game has.
--
-- WHAT TIER ACTUALLY IS, because it decides whether this is safe. For a herb
-- it is not a lookup into a ladder, it is a WEIGHT. `brew` sums
-- `tier x quantity` into a potency total and then takes the best pill grade
-- that total can afford, and it already handles running off the top of
-- `pill_tiers` - the top grade borrows the ladder's own step rather than
-- breaking. So a tier 12 herb makes a better pill and more alchemy experience,
-- proportionally, and nothing needs a new row to describe it.
--
-- The same is true of every other reader: broker price, beast food value, jade
-- protection cost and the horde's spilled herbs all scale off tier rather than
-- looking it up. The two that sounded like gates are not - `breakthrough_gate`
-- reads a PILL's tier and `pseudo_immortal_shortfall` reads an ORE's, neither
-- of which is touched here.
--
-- SHIFTED, NOT REASSIGNED. Every tiered heaven herb moves up by exactly five,
-- so 1 becomes 6 and 7 becomes 12 and the ordering inside each heaven is
-- preserved. A herb that was the best thing in Black Heaven still is.
--
-- ORES ARE DELIBERATELY UNTOUCHED, and it is not a nicety. `brew` decides
-- whether something is a herb by `m.tier IS NOT NULL` - that is the whole test.
-- Every ore in the game has a NULL material tier and its own `ores.tier`
-- instead, and giving one a material tier would not raise its grade, it would
-- make it brewable. The nineteen ores and specials in Black Heaven and eight in
-- White Heaven keep their NULL.
--
-- Nothing mortal moves: `region_materials_one_region_each` is a UNIQUE index on
-- material_code, so a herb grows in exactly one region and a heaven herb cannot
-- also be a Central one.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE materials DROP CONSTRAINT materials_tier_check;
ALTER TABLE materials ADD CONSTRAINT materials_tier_check
    CHECK (tier IS NULL OR (tier >= 1 AND tier <= 12));


UPDATE materials m
SET tier = m.tier + 5
WHERE m.tier IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM region_materials rm
      JOIN regions r ON r.code = rm.region_code
      WHERE rm.material_code = m.code AND r.min_rank > 1
  );


-- ---------------------------------------------------------------------------
-- A floor of six in the heavens, and seven still the ceiling everywhere else
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    lo      SMALLINT;
    hi      SMALLINT;
    n       INTEGER;
    bad     TEXT;
    mortal_hi SMALLINT;
BEGIN
    SELECT min(m.tier), max(m.tier), count(*)
    INTO lo, hi, n
    FROM materials m
    JOIN region_materials rm ON rm.material_code = m.code
    JOIN regions r ON r.code = rm.region_code
    WHERE r.min_rank > 1 AND m.tier IS NOT NULL;

    IF n = 0 THEN
        RAISE EXCEPTION 'the heavens grow no tiered herbs at all';
    END IF;
    IF lo < 6 THEN
        RAISE EXCEPTION 'a heaven still grows a tier % herb', lo;
    END IF;
    IF hi <> 12 THEN
        RAISE EXCEPTION 'the heavens top out at tier % rather than 12', hi;
    END IF;
    RAISE NOTICE '% heaven herbs now run tier % to %', n, lo, hi;

    -- The mortal world is exactly where it was. This is the half that would
    -- have gone unnoticed: a shift applied one region too widely reads fine in
    -- the heavens and quietly makes the Central Continent unrecognisable.
    SELECT max(m.tier) INTO mortal_hi
    FROM materials m
    JOIN region_materials rm ON rm.material_code = m.code
    JOIN regions r ON r.code = rm.region_code
    WHERE COALESCE(r.min_rank, 1) = 1 AND m.tier IS NOT NULL;

    IF mortal_hi <> 7 THEN
        RAISE EXCEPTION 'the mortal regions now top out at tier %', mortal_hi;
    END IF;

    -- No ore picked up a material tier, which would not promote it - it would
    -- drop it in a cauldron.
    SELECT string_agg(o.material_code, ', ') INTO bad
    FROM ores o JOIN materials m ON m.code = o.material_code
    WHERE m.tier IS NOT NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these ores became brewable: %', bad;
    END IF;

    -- And a cauldron full of the best heaven herbs still makes a pill rather
    -- than falling off the top of the ladder. Driven, not assumed.
    IF NOT EXISTS (
        SELECT 1 FROM pill_tiers pt
        WHERE pt.potency_required <= (
            SELECT max(m.tier) * game_config_value('alchemy_max_batch')
            FROM materials m WHERE m.tier IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'the best herbs in the game can no longer reach a pill grade';
    END IF;

    RAISE NOTICE
        'mortal regions still stop at tier %, and every ore kept its NULL',
        mortal_hi;
END;
$probe$;
