-- 0182_a_herb_without_a_tier_cannot_be_brewed
--
-- 0177 added ten cultivation herbs and left `materials.tier` NULL on every
-- one. Alchemy potency is `tier x quantity`, and `/alchemy` only offers
-- materials with `m.tier IS NOT NULL` - so those ten can be gathered and can
-- never go in a cauldron. Three players have picked up 23 of them already.
--
-- Gatherable and unusable is the worst state an item can be in: it costs a
-- gathering roll, sits in the satchel, and does nothing. The whole point of
-- 0177 was to make cultivation pills easier to brew, and it shipped herbs
-- that cannot be brewed at all.
--
-- Tier 2, which is what a common cultivation herb should be worth, and which
-- leaves the weight ladder alone - tier 2's heaviest entry is already 8.0.
--
-- AND THE LADDER RULE CHANGES, DELIBERATELY. `region_materials` used to hold
-- exactly seven tiered herbs a region, one per tier, and 0177 and 0181 both
-- broke that by appending. The rule that was being enforced is not quite the
-- rule that matters: what a region owes a gatherer is a COMPLETE ladder, one
-- herb at every tier from 1 to 7. Growing something extra beside it is not a
-- gap. So the invariant becomes coverage rather than a count, and the extra
-- herbs stay - which is what was asked for.
--
-- Forward-only. Do not edit once applied.


UPDATE materials SET tier = 2
WHERE code IN ('void_dew', 'hollow_pearl', 'slowsand_moss', 'hourbloom',
               'copper_clover', 'fortune_bell_fungus', 'precept_reed',
               'tally_vine', 'starfall_seed', 'starcap');


DO $$
DECLARE
    thin TEXT;
BEGIN
    -- A tier is what MAKES a material a herb: 76 gatherable things have
    -- none - ore, stones, general spoils - and `/alchemy` filters on exactly
    -- that. So this is not a rule about everything gatherable. It is that
    -- the ten 0177 introduced as cultivation herbs are now herbs.
    SELECT string_agg(m.name, ', ' ORDER BY m.name) INTO thin
    FROM materials m
    WHERE m.code IN ('void_dew', 'hollow_pearl', 'slowsand_moss', 'hourbloom',
                     'copper_clover', 'fortune_bell_fungus', 'precept_reed',
                     'tally_vine', 'starfall_seed', 'starcap')
      AND m.tier IS NULL;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION
            'still gatherable and unbrewable: %', thin;
    END IF;

    -- A complete ladder in every region, which is what the old count was
    -- reaching for.
    SELECT string_agg(r.code || ' missing tier ' || t.tier, ', ')
    INTO thin
    FROM regions r
    CROSS JOIN generate_series(1, 7) AS t (tier)
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        WHERE rm.region_code = r.code AND m.tier = t.tier
    );

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'incomplete ladder: %', thin;
    END IF;

    -- The weight ladder still falls with tier, which is where rarity lives.
    IF EXISTS (
        SELECT 1 FROM (
            SELECT m.tier, max(rm.weight) AS w,
                   LEAD(max(rm.weight)) OVER (ORDER BY m.tier) AS next_w
            FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            WHERE m.tier IS NOT NULL
            GROUP BY m.tier
        ) x WHERE x.next_w > x.w
    ) THEN
        RAISE EXCEPTION 'a higher tier became easier to find than a lower one';
    END IF;

    -- And nobody is left holding one of the ten in its unbrewable state.
    IF EXISTS (
        SELECT 1 FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE m.tier IS NULL AND pm.quantity > 0
          AND m.code IN ('void_dew', 'hollow_pearl', 'slowsand_moss',
                         'hourbloom', 'copper_clover', 'fortune_bell_fungus',
                         'precept_reed', 'tally_vine', 'starfall_seed',
                         'starcap')
    ) THEN
        RAISE EXCEPTION 'somebody is holding a herb that cannot be brewed';
    END IF;
END;
$$;
