-- 0310_the_strongest_rallies_are_carried_not_bought
--
-- 0308 put the party effects on the open shelf, and the biggest of them,
-- Mandate of the Nine, rallied a whole room by 45% for four turns for the
-- price of Spirit Stones. That is the strongest thing in the game available
-- to anybody who can afford it, which is the wrong shape twice: it makes the
-- ceiling a purchase, and it leaves nothing above it to want.
--
-- So the open shelf keeps the party effects and loses the top of them, and
-- the top of them moves to where this game already puts things that cannot be
-- bought at any price: an advanced technique, carried by a refined manual and
-- worth nothing the moment the manual comes off.
--
-- WHAT THE NERF IS. Roughly a third off every party magnitude. A rally is
-- multiplied by however many people are standing in the room, so 45% across
-- five cultivators was never 45% of anything - it was more than doubling the
-- room's output for one turn's work, from a shop.
--
-- AND IT FILLS A HOLE WHILE IT IS HERE. Six Paths - Food, Human, Luck,
-- Painting, Refinement and Wisdom - had no advanced technique at all, which
-- meant a refiner whose pages came out dominant in any of them could never
-- produce a technique manual however high the harmony went. `refine` looks
-- for an advanced technique on the dominant Path and finds nothing, so the
-- refinement silently becomes a stat manual instead. Those six Paths get the
-- new carried techniques, so the fix and the gap close together.
--
-- WHY THESE ARE REACHABLE AND THE OBVIOUS PLACEMENT WOULD NOT BE. `refine`
-- picks `ORDER BY rank DESC, base_power DESC` among advanced techniques on
-- the dominant Path. A support technique has base_power 0, so on a Path that
-- already carries an advanced attack of the same rank it would lose the pick
-- every time and never once appear. On these six Paths there is nothing to
-- lose to.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The open shelf comes down
-- ---------------------------------------------------------------------------

UPDATE techniques SET effects =
    '{"apply":[{"code":"attack_up","magnitude":0.10,"turns":3,"target":"party"}]}'
WHERE code = 'rally_the_line';

UPDATE techniques SET effects =
    '{"apply":[{"code":"attack_up","magnitude":0.15,"turns":3,"target":"party"}]}'
WHERE code = 'edict_of_the_vanguard';

UPDATE techniques SET effects =
    '{"apply":[{"code":"attack_up","magnitude":0.18,"turns":4,"target":"party"}]}'
WHERE code = 'constellation_muster';

UPDATE techniques SET effects =
    '{"apply":[{"code":"attack_up","magnitude":0.20,"turns":3,"target":"party"}]}'
WHERE code = 'heavens_favour';

UPDATE techniques SET effects =
    '{"apply":[{"code":"attack_up","magnitude":0.25,"turns":4,"target":"party"}]}'
WHERE code = 'mandate_of_the_nine';

UPDATE techniques SET effects =
    '{"apply":[{"code":"defence_up","magnitude":0.15,"turns":4,"target":"party"}]}'
WHERE code = 'bulwark_formation';

UPDATE techniques SET effects =
    '{"apply":[{"code":"defence_up","magnitude":0.25,"turns":4,"target":"party"}]}'
WHERE code = 'vault_of_ten_thousand_walls';

UPDATE techniques SET effects =
    '{"apply":[{"code":"regen","magnitude":0.08,"turns":4,"target":"party"}]}'
WHERE code = 'shepherd_of_the_dying';

UPDATE techniques SET effects =
    '{"apply":[{"code":"defence_up","magnitude":0.22,"turns":4,"target":"party"},
               {"code":"block_up","magnitude":0.15,"turns":4,"target":"party"}]}'
WHERE code = 'the_unmoving_edict';


-- ---------------------------------------------------------------------------
-- And the top of it moves into the manuals
-- ---------------------------------------------------------------------------

WITH spec (code, name, rank, qi, cat, pa, wa, pb, wb, effects, descr) AS (VALUES
  ('ten_thousand_hearts_as_one','Ten Thousand Hearts As One',9,0.48,'support',
   'human',0.6,'rule',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.45,"turns":4,"target":"party"}]}',
   'Not ten thousand men agreeing. Ten thousand men stopping, briefly, being separate things.'),

  ('the_plan_held_in_common','The Plan Held in Common',8,0.40,'support',
   'wisdom',0.6,'formation',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.30,"turns":4,"target":"party"},{"code":"block_up","magnitude":0.20,"turns":4,"target":"party"}]}',
   'Everyone already knows what happens next. That is the entire advantage and it is enormous.'),

  ('the_table_that_seats_the_line','The Table That Seats the Line',7,0.34,'support',
   'food',0.6,'blood',0.4,
   '{"apply":[{"code":"regen","magnitude":0.14,"turns":4,"target":"party"}]}',
   'Set for however many are standing. Food Path has never once fed one person.'),

  ('fortune_shared_among_us','Fortune Shared Among Us',8,0.40,'support',
   'luck',0.6,'human',0.4,
   '{"apply":[{"code":"attack_up","magnitude":0.28,"turns":4,"target":"party"}]}',
   'Luck divided is not luck reduced. That is the part nobody believes until it is done to them.'),

  ('the_line_that_holds','The Line That Holds',7,0.34,'defense',
   'painting',0.6,'formation',0.4,
   '{"apply":[{"code":"defence_up","magnitude":0.28,"turns":4,"target":"party"}]}',
   'Drawn once, around all of you. What is inside a line is a different thing from what is outside it.'),

  ('tempering_of_the_whole_company','Tempering of the Whole Company',9,0.48,'defense',
   'refinement',0.6,'metal',0.4,
   '{"apply":[{"code":"defence_up","magnitude":0.38,"turns":4,"target":"party"},{"code":"block_up","magnitude":0.22,"turns":4,"target":"party"}]}',
   'A company put through the furnace together comes out as one alloy, which is the point.')
), made AS (
    INSERT INTO techniques
        (code, name, rank, category, base_power, qi_cost_pct, grade,
         effects, description)
    SELECT s.code, s.name, s.rank::smallint, s.cat, 0, s.qi::numeric(6,4),
           'advanced', s.effects::jsonb, s.descr
    FROM spec s
    RETURNING technique_id, code
)
INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT m.technique_id, s.pa, s.wa::numeric FROM made m JOIN spec s ON s.code = m.code
UNION ALL
SELECT m.technique_id, s.pb, s.wb::numeric FROM made m JOIN spec s ON s.code = m.code;


-- ---------------------------------------------------------------------------
-- Nothing on the open shelf outdoes what must be carried
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bought NUMERIC;
    borne  NUMERIC;
    bad    TEXT;
BEGIN
    -- The strongest party rally you can buy, against the strongest you must
    -- carry. The shop must not hold the ceiling.
    SELECT max((e ->> 'magnitude')::numeric) INTO bought
    FROM techniques t
    CROSS JOIN LATERAL jsonb_array_elements(t.effects -> 'apply') e
    WHERE t.grade <> 'advanced' AND e ->> 'target' = 'party'
      AND e ->> 'code' = 'attack_up';

    SELECT max((e ->> 'magnitude')::numeric) INTO borne
    FROM techniques t
    CROSS JOIN LATERAL jsonb_array_elements(t.effects -> 'apply') e
    WHERE t.grade = 'advanced' AND e ->> 'target' = 'party'
      AND e ->> 'code' = 'attack_up';

    IF bought >= borne THEN
        RAISE EXCEPTION
            'a rally worth % can be bought, against % that must be carried',
            bought, borne;
    END IF;

    RAISE NOTICE 'the shop tops out at %, the manuals at %', bought, borne;

    -- Every Path can now yield a technique manual.
    SELECT string_agg(p.code, ' ') INTO bad
    FROM paths p WHERE NOT EXISTS (
        SELECT 1 FROM technique_paths tp
        JOIN techniques t ON t.technique_id = tp.technique_id
        WHERE tp.path_code = p.code AND t.grade = 'advanced');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these Paths still cannot produce a technique manual: %', bad;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- And a refiner on one of those six Paths actually reaches it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    picked TEXT;
    dom    TEXT;
BEGIN
    -- The exact pick `refine` makes, for each newly-served Path at a tier
    -- high enough to carry it. Anything that resolves to NULL is a Path this
    -- migration claims to have served and has not.
    FOREACH dom IN ARRAY ARRAY['food','human','luck','painting','refinement','wisdom']
    LOOP
        SELECT t.name INTO picked
        FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL
          AND t.grade = 'advanced'
          AND tp.path_code = dom
          AND t.rank <= 9
        ORDER BY t.rank DESC, t.base_power DESC
        LIMIT 1;

        IF picked IS NULL THEN
            RAISE EXCEPTION
                'a refinement dominant in % still finds no technique', dom;
        END IF;

        RAISE NOTICE '% now yields: %', dom, picked;
    END LOOP;
END;
$$;
