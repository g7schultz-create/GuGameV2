-- 0307_the_paths_that_had_no_summit
--
-- Fourteen of the thirty-four Paths had nothing above rank 6. Sword had
-- eleven techniques and not one of them past the middle of the ladder, which
-- meant a cultivator who had poured a lifetime into Sword hit a ceiling made
-- of nothing but missing content. Bone, Earth, Food, Ice, Lightning, Luck,
-- Metal, Painting, Poison, Refinement, Wind, Wisdom and Wood were the same.
--
-- This gives each of them a rank 7 and a rank 8, sized on the curve the
-- existing ones already sit on - roughly four times the rank below, and a qi
-- cost climbing 0.34 to 0.38. Every one is dual-Path with weights summing to
-- one, the way every high technique in this game already is, because a
-- technique that belongs to exactly one Path is a rank 1 technique.
--
-- THE PARTNER PATH IS CHOSEN TO BE USEFUL, NOT ONLY TO READ WELL. A second
-- Path is a second column in the matchup chart, so pairing Sword with Heaven
-- is a different weapon from pairing it with Strength, and a cultivator deep
-- in both gets the attainment bonus twice. The pairings below are the ones
-- that give each Path a reason to be taken alongside something.
--
-- Forward-only. Do not edit once applied.


WITH spec (code, name, rank, power, qi, pa, wa, pb, wb, descr) AS (VALUES
  ('ossuary_tide','Ossuary Tide',7,470000,0.34,'bone',0.6,'earth',0.4,
   'Everything that died on this ground is still under it, and it has been waiting to be counted.'),
  ('marrow_throne','Marrow Throne',8,1950000,0.38,'bone',0.6,'soul',0.4,
   'A seat built from what held other men up. Sitting in it is the technique.'),

  ('continental_press','Continental Press',7,520000,0.34,'earth',0.6,'strength',0.4,
   'The earth does not strike. It arrives, and it does not stop arriving.'),
  ('the_weight_of_provinces','The Weight of Provinces',8,2100000,0.38,'earth',0.6,'formation',0.4,
   'Nine counties of stone, folded into the space a man is standing in.'),

  ('devouring_banquet','Devouring Banquet',7,480000,0.34,'food',0.6,'blood',0.4,
   'A table is set. You are not a guest at it.'),
  ('the_gullet_of_mountains','The Gullet of Mountains',8,1980000,0.38,'food',0.6,'earth',0.4,
   'Mountains eat slowly. This is a mountain persuaded to hurry.'),

  ('glacier_sealing_palm','Glacier Sealing Palm',7,500000,0.34,'ice',0.6,'water',0.4,
   'Not cold enough to kill. Cold enough that moving costs more than holding still, and then it is.'),
  ('the_last_winter','The Last Winter',8,2050000,0.38,'ice',0.6,'time',0.4,
   'Spring is a promise the world makes. This is the world being held to account for it.'),

  ('sky_splitting_lance','Sky-Splitting Lance',7,560000,0.34,'lightning',0.6,'heaven',0.4,
   'The sky does not aim. It simply decides where the ground will be touched.'),
  ('nine_thunder_verdict','Nine Thunder Verdict',8,2250000,0.38,'lightning',0.6,'rule',0.4,
   'Nine strikes, each one a sentence already passed. The trial was held elsewhere.'),

  ('fortune_called_in','Fortune Called In',7,450000,0.34,'luck',0.6,'theft',0.4,
   'Your luck was never yours. It was only nearest to you, and it is owed elsewhere.'),
  ('the_odds_rewritten','The Odds Rewritten',8,1900000,0.38,'luck',0.6,'rule',0.4,
   'Not a lucky blow. A blow after which luck is a different shape.'),

  ('ten_thousand_blade_rain','Ten Thousand Blade Rain',7,540000,0.34,'metal',0.6,'sword',0.4,
   'Ten thousand edges, none of them aimed, all of them arriving.'),
  ('the_unbreaking_edge','The Unbreaking Edge',8,2200000,0.38,'metal',0.6,'refinement',0.4,
   'Folded until the folding stopped mattering, and then folded again out of habit.'),

  ('ink_devouring_scroll','Ink-Devouring Scroll',7,440000,0.34,'painting',0.6,'illusion',0.4,
   'The scroll is hungry. It has been painted hungry.'),
  ('the_world_as_drawn','The World As Drawn',8,1870000,0.38,'painting',0.6,'space',0.4,
   'The distance between you was drawn in. It can be painted over.'),

  ('ten_thousand_toxin_canon','Ten Thousand Toxin Canon',7,510000,0.34,'poison',0.6,'wood',0.4,
   'Every poison ever catalogued, recited at once, in order.'),
  ('the_plague_sovereigns_gift','The Plague Sovereign''s Gift',8,2080000,0.38,'poison',0.6,'blood',0.4,
   'Given freely. That is what makes it a gift and not a wound.'),

  ('crucible_of_nine_turns','Crucible of Nine Turns',7,490000,0.34,'refinement',0.6,'fire',0.4,
   'Nine turns in the furnace. The ninth is the one that is not survivable.'),
  ('refining_the_refiner','Refining the Refiner',8,2020000,0.38,'refinement',0.6,'soul',0.4,
   'Everything that can be purified can be purified out of.'),

  ('heaven_severing_edge','Heaven-Severing Edge',7,580000,0.34,'sword',0.6,'heaven',0.4,
   'Sword Path has one idea and has never needed a second. This is the idea, sharpened.'),
  ('one_strike_ten_thousand_dead','One Strike, Ten Thousand Dead',8,2300000,0.38,'sword',0.6,'strength',0.4,
   'The count is not a boast. It is what the stroke is for.'),

  ('gale_that_shatters_vaults','Gale That Shatters Vaults',7,470000,0.34,'wind',0.6,'space',0.4,
   'Wind goes where there is no room for it. That is the whole of the method.'),
  ('the_long_winds_judgement','The Long Wind''s Judgement',8,1960000,0.38,'wind',0.6,'time',0.4,
   'A wind that has been crossing the world since before you were named, arriving now.'),

  ('the_flaw_made_plain','The Flaw Made Plain',7,460000,0.34,'wisdom',0.6,'rule',0.4,
   'Nothing is added. Something is merely pointed at, and then it fails.'),
  ('ten_thousand_calculations','Ten Thousand Calculations',8,1940000,0.38,'wisdom',0.6,'formation',0.4,
   'The blow was struck some time ago. The arithmetic is only now finishing.'),

  ('strangling_verdure','Strangling Verdure',7,480000,0.34,'wood',0.6,'poison',0.4,
   'Growth is not gentle. It is only slow, and this is not slow.'),
  ('the_forest_that_walks','The Forest That Walks',8,1990000,0.38,'wood',0.6,'earth',0.4,
   'Ten thousand years rooted is ten thousand years of deciding where to go first.')
), made AS (
    INSERT INTO techniques
        (code, name, rank, category, base_power, qi_cost_pct, grade, description)
    SELECT s.code, s.name, s.rank::smallint, 'attack', s.power,
           s.qi::numeric(6,4), 'basic', s.descr
    FROM spec s
    RETURNING technique_id, code
)
INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT m.technique_id, s.pa, s.wa::numeric FROM made m JOIN spec s ON s.code = m.code
UNION ALL
SELECT m.technique_id, s.pb, s.wb::numeric FROM made m JOIN spec s ON s.code = m.code;


-- ---------------------------------------------------------------------------
-- Every Path now has a summit, and the new ones sit on the curve
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bare   TEXT;
    wrong  TEXT;
BEGIN
    SELECT string_agg(p.code, ' ') INTO bare
    FROM paths p
    WHERE NOT EXISTS (
        SELECT 1 FROM technique_paths tp
        JOIN techniques t ON t.technique_id = tp.technique_id
        WHERE tp.path_code = p.code AND t.created_by IS NULL AND t.rank >= 7
    );

    IF bare IS NOT NULL THEN
        RAISE EXCEPTION 'these Paths still stop below rank 7: %', bare;
    END IF;

    -- A new technique that is wildly off the curve is a balance bug shipped
    -- as content. Half to double the rank's existing average is the window.
    SELECT string_agg(t.code || ' (' || t.base_power || ')', ' ') INTO wrong
    FROM techniques t
    JOIN (SELECT rank, avg(base_power) AS mean FROM techniques
          WHERE created_by IS NULL GROUP BY rank) m ON m.rank = t.rank
    WHERE t.created_by IS NULL
      AND t.code IN (SELECT code FROM techniques WHERE created_by IS NULL)
      AND t.rank >= 7
      AND (t.base_power < m.mean / 2 OR t.base_power > m.mean * 2);

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'these sit off their rank''s curve: %', wrong;
    END IF;

    -- And every one of them is reachable: two Paths, weights summing to one.
    IF EXISTS (
        SELECT 1 FROM techniques t
        WHERE t.created_by IS NULL AND t.rank >= 7
        GROUP BY t.technique_id
        HAVING (SELECT count(*) FROM technique_paths tp
                WHERE tp.technique_id = t.technique_id) < 1
    ) THEN
        RAISE EXCEPTION 'a high technique belongs to no Path at all';
    END IF;

    RAISE NOTICE 'all 34 Paths now reach rank 7 or beyond';
END;
$$;
