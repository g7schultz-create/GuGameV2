-- 0312_a_book_you_wear_pays_while_you_wear_it
--
-- The six books 0311 wrote grant no stats at all, and three rules caught it:
-- a technique manual must spend its tier's whole bonus budget, because 0187
-- settled that argument. Before 0187 they were written at half budget so that
-- a book carrying a killer move could not also beat a stat manual - and the
-- result was that the rarest drop in the game was the weakest thing of its
-- tier. They are rare enough to be strictly better; the move's own realm gate
-- is what keeps them honest, not a thinner book.
--
-- Mine were written at NO budget, which is worse than the thing 0187 fixed.
-- A cultivator who wins one and cannot yet meet the realm gate would have
-- equipped it and received precisely nothing.
--
-- WHERE THE BUDGET GOES. The existing eighteen put all of it into attack,
-- which is right for eighteen books that all teach a killing move. These six
-- teach wards, mendings and rallies, so each spends its budget on what the
-- book is actually about - the Furnace Record on defence, the Rites on the
-- body, the Stratagem split between the two the way the technique is. The
-- rule is about the total, and the total is exact either way.
--
-- Read from `manual_tiers` rather than typed in, so a book cannot drift off
-- its budget later if the budget moves.
--
-- Forward-only. Do not edit once applied.


UPDATE manuals m SET hp_bonus = mt.bonus_budget
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'the_table_that_seats_the_line_manual';

UPDATE manuals m SET defense_bonus = mt.bonus_budget
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'the_line_that_holds_manual';

UPDATE manuals m SET defense_bonus = mt.bonus_budget
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'tempering_of_the_whole_company_manual';

UPDATE manuals m SET attack_bonus = mt.bonus_budget
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'ten_thousand_hearts_as_one_manual';

UPDATE manuals m SET attack_bonus = mt.bonus_budget
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'fortune_shared_among_us_manual';

-- The Plan Held in Common rallies AND sets, so its book is split the way the
-- technique is. Halved off the budget itself so the two still total exactly.
UPDATE manuals m
SET attack_bonus  = mt.bonus_budget / 2,
    defense_bonus = mt.bonus_budget - (mt.bonus_budget / 2)
FROM manual_tiers mt WHERE mt.tier = m.tier
  AND m.code = 'the_plan_held_in_common_manual';


-- ---------------------------------------------------------------------------
-- Every technique manual spends exactly its tier, to the last hundredth
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    short TEXT;
BEGIN
    SELECT string_agg(m.name || ' (' || manual_total_bonus(m.manual_id)
                      || ' of ' || mt.bonus_budget || ')', ', ') INTO short
    FROM manuals m
    JOIN manual_tiers mt ON mt.tier = m.tier
    WHERE m.archetype = 'technique' AND m.code IS NOT NULL
      AND manual_total_bonus(m.manual_id) <> mt.bonus_budget;

    IF short IS NOT NULL THEN
        RAISE EXCEPTION 'these books are off their tier budget: %', short;
    END IF;

    -- And none of the six pays nothing, which was the whole failure.
    IF EXISTS (
        SELECT 1 FROM manuals
        WHERE archetype = 'technique' AND code IS NOT NULL
          AND manual_total_bonus(manual_id) = 0
    ) THEN
        RAISE EXCEPTION 'a technique manual still pays nothing to wear';
    END IF;

    RAISE NOTICE 'all % technique manuals spend their tier in full',
        (SELECT count(*) FROM manuals
         WHERE archetype = 'technique' AND code IS NOT NULL);
END;
$$;
