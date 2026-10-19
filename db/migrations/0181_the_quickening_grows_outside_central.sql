-- 0181_the_quickening_grows_outside_central
--
-- Quickened Cultivation is the only thing in the game that raises cultivation
-- speed past the +100% stat cap: it enters `settle_passive_cultivation` as
-- extra HOURS - `(paid + cult_boost * cult_hours)` - rather than as a stat
-- inside the capped multiplier. Two cultivators sit within 6% of that cap, so
-- it is the one accelerant still worth anything to them.
--
-- It is brewed from Heaven or Qi herbs at tier 5 or better. The complete list
-- of Heaven and Qi herbs that can go in a cauldron at all:
--
--   Heavenly Essence Ginseng   rare   tier 6   central, weight 0.8
--   Spirit Dew Grass           common tier 1   central, weight 8.0
--
-- Two herbs. Both in central. And `brew` wants two distinct kinds, so that
-- pair is not merely the best recipe, it is the ONLY one - and only somebody
-- who gathers in central can assemble it. Exactly one player can, and only
-- because he has gathered 257 of them.
--
-- 0177 did this for the `cultivation` Paths and stopped short of the two that
-- brew `cultivation_rate`, which are the more valuable half. Same shape and
-- the same one-region-per-herb rule: eight herbs, a Qi and a Heaven in each
-- region that had neither.
--
-- Tiers matter more here than rarity does - alchemy potency is `tier x
-- quantity`, not the rarity grade - so the Qi commons are tier 2 and the
-- Heaven uncommons tier 4. Tier 5 wants 70 potency, which is reachable by
-- gathering rather than by luck.
--
-- Forward-only. Do not edit once applied.


INSERT INTO materials (code, name, category, rarity, path_code, emoji, tier, description)
VALUES
    ('ninth_breath_fern', 'Ninth Breath Fern', 'gathering', 'common', 'qi', '🌿', 2,
     'Unrolls one frond at a time, and the ninth is the one worth having.'),
    ('mandate_lotus', 'Mandate Lotus', 'gathering', 'uncommon', 'heaven', '🪷', 4,
     'Opens facing whichever way the sky is heaviest that morning.'),

    ('tidebreath_kelp', 'Tidebreath Kelp', 'gathering', 'common', 'qi', '🌊', 2,
     'Breathes in and out with the water, and does not stop when landed.'),
    ('oracle_bloom', 'Oracle Bloom', 'gathering', 'uncommon', 'heaven', '🔮', 4,
     'Flowers on the day something happens. Never the day before.'),

    ('frostbreath_lichen', 'Frostbreath Lichen', 'gathering', 'common', 'qi', '❄️', 2,
     'The fog above it is its own, and it makes more in the cold.'),
    ('cold_mandate_root', 'Cold Mandate Root', 'gathering', 'uncommon', 'heaven', '🥶', 4,
     'Grows downward through frozen ground as though told to.'),

    ('humid_breath_vine', 'Humid Breath Vine', 'gathering', 'common', 'qi', '🍀', 2,
     'Sweats in still air. The drops go up as often as down.'),
    ('fateweave_orchid', 'Fateweave Orchid', 'gathering', 'uncommon', 'heaven', '🌸', 4,
     'Two of them never grow the same, and neither does anything near them.');


INSERT INTO region_materials (region_code, material_code, weight) VALUES
    ('western',  'ninth_breath_fern',  8.0000),
    ('western',  'mandate_lotus',      3.0000),
    ('eastern',  'tidebreath_kelp',    8.0000),
    ('eastern',  'oracle_bloom',       3.0000),
    ('northern', 'frostbreath_lichen', 8.0000),
    ('northern', 'cold_mandate_root',  3.0000),
    ('southern', 'humid_breath_vine',  8.0000),
    ('southern', 'fateweave_orchid',   3.0000);


DO $$
DECLARE
    thin TEXT;
BEGIN
    -- `brew` wants two distinct kinds, so one herb in a region is no recipe
    -- at all. Every region needs a pair that brews the quickened kind.
    SELECT string_agg(r.code || ' (' || got.kinds || ')', ', ' ORDER BY r.code)
    INTO thin
    FROM regions r
    CROSS JOIN LATERAL (
        SELECT count(*) AS kinds
        FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = r.code
          AND ppk.kind = 'cultivation_rate'
          AND m.tier IS NOT NULL
    ) got
    WHERE got.kinds < 2;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION
            'these regions cannot assemble a quickened brew at all: %', thin;
    END IF;

    -- And the herbs have to be worth enough to climb. Potency is tier x
    -- quantity, so a region of nothing but tier 1 would need seventy of them.
    SELECT string_agg(r.code, ', ' ORDER BY r.code) INTO thin
    FROM regions r
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = r.code AND ppk.kind = 'cultivation_rate'
          AND m.tier >= 4
    );

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'no heavy quickening herb grows in: %', thin;
    END IF;

    -- The escape-sequence guard 0175 added, re-run because this migration
    -- writes eight more emoji.
    SELECT string_agg(m.code, ', ') INTO thin
    FROM materials m
    WHERE m.emoji LIKE '%\%' OR m.emoji LIKE '%{%' OR m.emoji = '';

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these are not emoji: %', thin;
    END IF;
END;
$$;
