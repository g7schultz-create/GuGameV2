-- 0311_six_techniques_that_needed_a_book
--
-- 0310 created six advanced techniques and no manuals to carry them, which
-- `test_every_advanced_technique_has_a_book_and_every_book_has_a_move` caught
-- immediately and correctly. An advanced technique cannot be learned at any
-- price - that is the whole point of the grade - so one with no book is not
-- rare, it is unreachable. Six techniques written, described, balanced, and
-- impossible to obtain by any route in the game.
--
-- Worth noting what did NOT catch it: 0310's own probe ran the exact query
-- `refine` runs and confirmed all six resolve. They do. `refine` builds its
-- manual on the spot, so that path was genuinely fine - and it is the only
-- path I thought about. The canonical books, which is how every other
-- advanced technique in the game is reachable, I simply did not write. The
-- probe was right about the question it asked and the question was too small.
--
-- The tier and required rank follow the eighteen that already exist: a
-- manual's tier is its technique's rank plus one, and the realm it asks for
-- is (rank + 1) / 2. Quality common, harmony null, the same as the rest -
-- these are canonical books, not refined ones.
--
-- Forward-only. Do not edit once applied.


WITH spec (tcode, mcode, mname, descr) AS (VALUES
  ('ten_thousand_hearts_as_one','ten_thousand_hearts_as_one_manual',
   'Muster of Ten Thousand Hearts',
   'Not a technique so much as a roll-call. The names are all of them dead, and the reading is what matters.'),

  ('the_plan_held_in_common','the_plan_held_in_common_manual',
   'The Shared Stratagem',
   'Written in nine hands. None of them signed it, and none of them disagreed with any of the others.'),

  ('the_table_that_seats_the_line','the_table_that_seats_the_line_manual',
   'Rites of the Long Table',
   'Recipes at the front, seating at the back. The seating is the technique.'),

  ('fortune_shared_among_us','fortune_shared_among_us_manual',
   'Ledger of Divided Fortune',
   'Every entry is somebody giving away luck. Every entry is in the same hand, and it is not the hand of somebody who ran out.'),

  ('the_line_that_holds','the_line_that_holds_manual',
   'Scroll of the Unbroken Line',
   'One brushstroke, unlifted, across four hundred pages. Where it wavers, the notes explain who died.'),

  ('tempering_of_the_whole_company','tempering_of_the_whole_company_manual',
   'Furnace Record of the Whole Company',
   'A smelting record with names where the ores should be. It is not clear the author saw a difference.')
), made AS (
    INSERT INTO manuals
        (code, name, tier, required_rank, archetype, quality, description)
    SELECT s.mcode, s.mname,
           (t.rank + 1)::smallint,
           ((t.rank + 1) / 2)::smallint,
           'technique', 'common', s.descr
    FROM spec s JOIN techniques t ON t.code = s.tcode
    RETURNING manual_id, code
)
INSERT INTO manual_techniques (manual_id, technique_id)
SELECT m.manual_id, t.technique_id
FROM made m
JOIN spec s ON s.mcode = m.code
JOIN techniques t ON t.code = s.tcode;


-- ---------------------------------------------------------------------------
-- Both directions, the way the rule asks
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    stranded TEXT;
    empty    TEXT;
BEGIN
    SELECT string_agg(t.name, ', ') INTO stranded
    FROM techniques t
    WHERE t.created_by IS NULL AND t.grade = 'advanced'
      AND NOT EXISTS (
          SELECT 1 FROM manual_techniques mt
          JOIN manuals m ON m.manual_id = mt.manual_id
          WHERE mt.technique_id = t.technique_id AND m.archetype = 'technique');

    IF stranded IS NOT NULL THEN
        RAISE EXCEPTION 'these cannot be reached by any route: %', stranded;
    END IF;

    SELECT string_agg(m.name, ', ') INTO empty
    FROM manuals m
    WHERE m.archetype = 'technique' AND m.code IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM manual_techniques mt
          JOIN techniques t ON t.technique_id = mt.technique_id
          WHERE mt.manual_id = m.manual_id AND t.grade = 'advanced');

    IF empty IS NOT NULL THEN
        RAISE EXCEPTION 'these books teach nothing: %', empty;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- And the new books sit where the eighteen already there sit
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    odd TEXT;
BEGIN
    SELECT string_agg(m.name || ' (tier ' || m.tier || ' for a rank '
                      || t.rank || ' technique)', ', ') INTO odd
    FROM manuals m
    JOIN manual_techniques mt ON mt.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    WHERE m.archetype = 'technique' AND m.code IS NOT NULL
      AND (m.tier <> t.rank + 1 OR m.required_rank <> (t.rank + 1) / 2);

    IF odd IS NOT NULL THEN
        RAISE EXCEPTION 'these books are shelved off the pattern: %', odd;
    END IF;

    RAISE NOTICE '% technique manuals, all on the pattern',
        (SELECT count(*) FROM manuals
         WHERE archetype = 'technique' AND code IS NOT NULL);
END;
$$;
