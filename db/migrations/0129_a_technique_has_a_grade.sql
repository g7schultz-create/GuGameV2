-- 0129_a_technique_has_a_grade
--
-- 0126 made every technique buyable. That is one shape of progression - money
-- and attainment - and it is the wrong one for the whole roster, because it
-- means the most fearsome move in the game is a purchase. Nothing is ever
-- FOUND.
--
-- So techniques split in two.
--
--   BASIC     what /learn sells. The 52 techniques that exist today, all of
--             them, unchanged. Every rank has a shelf of them, and a
--             cultivator who never gets lucky is never weaponless.
--
--   ADVANCED  what a manual carries. Not for sale at any price. It arrives off
--             something that was hard to kill, or out of a refinement that
--             went unusually well, and it works only while the manual teaching
--             it is one of your two equipped. You do not own it. You carry it.
--
-- That last clause is the point. A learned technique is settled; an advanced
-- one competes for a manual slot against every cultivation bonus in your bag,
-- for as long as you want to keep throwing it.
--
-- POWER. An advanced technique of rank N sits BETWEEN rank N basic and rank
-- N+1 basic - about 1.8x the rank's basic ceiling. Carrying one is fighting
-- half a rank above yourself, which is worth a manual slot and is not worth
-- breaking the game over. The ladder check 0125 wrote still passes unchanged,
-- which is the arithmetic saying the same thing.
--
--     rank 4   basic 1,500-1,750    advanced 2,900-3,100    rank 5 basic 3,800
--
-- Every one is dual-Path. A killer move is a compound of two understandings,
-- and mechanically it means an advanced technique always has a second half
-- that lands when something resists the first.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE techniques ADD COLUMN grade TEXT NOT NULL DEFAULT 'basic'
    CHECK (grade IN ('basic', 'advanced'));

CREATE INDEX techniques_grade_idx ON techniques (grade, rank);

COMMENT ON COLUMN techniques.grade IS
    'basic = sold by /learn and owned for good. advanced = carried by a manual, never for sale, and gone the moment the manual is unequipped.';


INSERT INTO techniques
    (code, name, rank, grade, category, base_power,
     qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    -- ---- rank 1, against a basic ceiling of 135 -------------------------
    ('blood_drinking_awl', 'Blood-Drinking Awl', 1, 'advanced', 'attack', 245,
     0.1000, 0.9500, 2,
     'A thin iron spike with a channel cut down its length. What goes in is the awl. What comes back out is not.'),

    ('hoarfrost_execution_form', 'Hoarfrost Execution Form', 1, 'advanced', 'attack', 230,
     0.0900, 1.0000, 2,
     'Not a duel. A form practised for one purpose, on someone already still, and it has no second movement because it has never needed one.'),

    -- ---- rank 2, against 330 --------------------------------------------
    ('wolf_tide_charge', 'Wolf Tide Charge', 2, 'advanced', 'attack', 580,
     0.1600, 0.9000, 2,
     'One wolf is a fight. The tide is not a larger fight; it is a different kind of event.'),

    ('creeping_rot_sigil', 'Creeping Rot Sigil', 2, 'advanced', 'attack', 550,
     0.1500, 0.9500, 2,
     'Drawn on the ground rather than on the target, and the ground is patient about carrying it the rest of the way.'),

    -- ---- rank 3, against 690 --------------------------------------------
    ('thunder_gale_dismemberment', 'Thunder Gale Dismemberment', 3, 'advanced', 'attack', 1250,
     0.2200, 0.9000, 3,
     'The wind decides which pieces, the lightning decides how fast, and neither consults the other or the subject.'),

    ('hungry_shade_grasp', 'Hungry Shade Grasp', 3, 'advanced', 'attack', 1150,
     0.2000, 0.9500, 3,
     'Something that has been dead a long time is still hungry, and it has been waiting under your feet for someone to point.'),

    -- ---- rank 4, against 1,750 ------------------------------------------
    ('iron_river_severance', 'Iron River Severance', 4, 'advanced', 'attack', 3100,
     0.2800, 0.9000, 4,
     'Metal poured into moving water and kept moving. It has a current, an edge, and no bank to stop at.'),

    ('pyre_of_borrowed_years', 'Pyre of Borrowed Years', 4, 'advanced', 'attack', 2900,
     0.3000, 0.9500, 4,
     'The fire is fed with time rather than fuel. The cultivator settles up afterwards, and the rate is not favourable.'),

    -- ---- rank 5, against 4,200 ------------------------------------------
    ('mountain_swallowing_maw', 'Mountain-Swallowing Maw', 5, 'advanced', 'attack', 7800,
     0.3200, 0.9000, 4,
     'A hole in the world with an appetite and an opinion about where things belong. Mountains have gone into it. They have not come back out.'),

    ('crimson_moth_requiem', 'Crimson Moth Requiem', 5, 'advanced', 'attack', 7200,
     0.3000, 0.9500, 4,
     'Every drop of blood the cultivator has ever spilled comes back as a moth, and they all remember whose it was.'),

    -- ---- rank 6, against 10,500 -----------------------------------------
    ('heaven_defying_edge', 'Heaven-Defying Edge', 6, 'advanced', 'attack', 19000,
     0.3500, 0.9500, 5,
     'A sword raised at the sky in full knowledge of what the sky can do. The edge is the argument; heaven has not yet answered it.'),

    ('bone_tide_annihilation', 'Bone Tide Annihilation', 6, 'advanced', 'attack', 17500,
     0.3400, 0.9000, 5,
     'Everything the sea has ever taken, returned all at once and in poor condition.'),

    -- ---- rank 7, against 26,000 -----------------------------------------
    ('star_severing_palm', 'Star-Severing Palm', 7, 'advanced', 'attack', 48000,
     0.3800, 0.9000, 5,
     'The distance is the only thing that ever protected a star, and distance is a thing a palm at this level simply declines to acknowledge.'),

    ('dream_thief_verdict', 'Dream Thief''s Verdict', 7, 'advanced', 'attack', 44000,
     0.3600, 0.9500, 5,
     'Sentence passed in a dream, on a charge never read out, and carried out on the body that was doing the sleeping.'),

    -- ---- rank 8, against 64,000 -----------------------------------------
    ('light_devouring_formation', 'Light-Devouring Formation', 8, 'advanced', 'attack', 125000,
     0.4200, 0.9000, 6,
     'Nine hundred years of arrangement, and the only thing it does is make sure that whatever is standing inside it never was.'),

    ('ten_thousand_shapes_undone', 'Ten Thousand Shapes Undone', 8, 'advanced', 'attack', 115000,
     0.4000, 0.9500, 6,
     'Everything the target could have been is shown to it, at once, and then all of them are declined on its behalf.'),

    -- ---- rank 9, against 160,000 ----------------------------------------
    ('sovereign_immortal_killer_move', 'Sovereign Immortal Killer Move', 9, 'advanced', 'attack', 300000,
     0.5000, 0.9500, 7,
     'The move an immortal is remembered by. It is not aimed and it is not dodged; it is simply the thing that happened next.'),

    ('eternal_hunger_of_the_nine', 'Eternal Hunger of the Nine', 9, 'advanced', 'attack', 280000,
     0.4800, 0.9000, 7,
     'Nine worlds of appetite, given one direction and no instruction about when to stop.');


INSERT INTO technique_paths (technique_id, path_code, weight)
SELECT t.technique_id, v.path_code, v.weight
FROM (VALUES
    ('blood_drinking_awl',             'blood',          0.6000),
    ('blood_drinking_awl',             'metal',          0.4000),
    ('hoarfrost_execution_form',       'ice',            0.7000),
    ('hoarfrost_execution_form',       'sword',          0.3000),

    ('wolf_tide_charge',               'strength',       0.6000),
    ('wolf_tide_charge',               'wind',           0.4000),
    ('creeping_rot_sigil',             'poison',         0.6000),
    ('creeping_rot_sigil',             'wood',           0.4000),

    ('thunder_gale_dismemberment',     'lightning',      0.6000),
    ('thunder_gale_dismemberment',     'wind',           0.4000),
    ('hungry_shade_grasp',             'shadow',         0.6000),
    ('hungry_shade_grasp',             'soul',           0.4000),

    ('iron_river_severance',           'metal',          0.5000),
    ('iron_river_severance',           'water',          0.5000),
    ('pyre_of_borrowed_years',         'fire',           0.6000),
    ('pyre_of_borrowed_years',         'time',           0.4000),

    ('mountain_swallowing_maw',        'earth',          0.6000),
    ('mountain_swallowing_maw',        'space',          0.4000),
    ('crimson_moth_requiem',           'blood',          0.5000),
    ('crimson_moth_requiem',           'soul',           0.5000),

    ('heaven_defying_edge',            'sword',          0.6000),
    ('heaven_defying_edge',            'heaven',         0.4000),
    ('bone_tide_annihilation',         'bone',           0.6000),
    ('bone_tide_annihilation',         'water',          0.4000),

    ('star_severing_palm',             'star',           0.5000),
    ('star_severing_palm',             'strength',       0.5000),
    ('dream_thief_verdict',            'dream',          0.5000),
    ('dream_thief_verdict',            'theft',          0.5000),

    ('light_devouring_formation',      'light',          0.5000),
    ('light_devouring_formation',      'formation',      0.5000),
    ('ten_thousand_shapes_undone',     'transformation', 0.6000),
    ('ten_thousand_shapes_undone',     'illusion',       0.4000),

    ('sovereign_immortal_killer_move', 'rule',           0.5000),
    ('sovereign_immortal_killer_move', 'heaven',         0.5000),
    ('eternal_hunger_of_the_nine',     'enslavement',    0.5000),
    ('eternal_hunger_of_the_nine',     'qi',             0.5000)
) AS v (technique_code, path_code, weight)
JOIN techniques t ON t.code = v.technique_code;


-- ---------------------------------------------------------------------------
-- Where advanced sits
-- ---------------------------------------------------------------------------
-- Two rungs, both of which are invisible if they break. An advanced technique
-- weaker than its own rank's basics is a reward that is not one; an advanced
-- technique stronger than the NEXT rank's basics makes crossing a realm pay
-- less than a lucky drop, which unravels the whole progression.

DO $$
DECLARE
    wrong INTEGER;
BEGIN
    IF (SELECT count(*) FROM techniques
        WHERE created_by IS NULL AND grade = 'advanced') <> 18 THEN
        RAISE EXCEPTION 'expected 18 advanced techniques, found %',
            (SELECT count(*) FROM techniques
             WHERE created_by IS NULL AND grade = 'advanced');
    END IF;

    -- Every rank must offer both grades, or one of the two routes is shut at
    -- that rank and nobody finds out until they arrive there.
    SELECT count(*) INTO wrong
    FROM generate_series(1, 9) AS r (rank)
    WHERE NOT EXISTS (SELECT 1 FROM techniques t WHERE t.created_by IS NULL
                      AND t.rank = r.rank AND t.grade = 'basic')
       OR NOT EXISTS (SELECT 1 FROM techniques t WHERE t.created_by IS NULL
                      AND t.rank = r.rank AND t.grade = 'advanced');
    IF wrong > 0 THEN
        RAISE EXCEPTION '% rank(s) are missing one of the two grades', wrong;
    END IF;

    -- Advanced beats its own rank's basics outright...
    SELECT count(*) INTO wrong
    FROM (SELECT t.rank, max(t.base_power) AS hi FROM techniques t
          WHERE t.created_by IS NULL AND t.grade = 'basic' GROUP BY t.rank) b
    JOIN (SELECT t.rank, min(t.base_power) AS lo FROM techniques t
          WHERE t.created_by IS NULL AND t.grade = 'advanced' GROUP BY t.rank) a
      ON a.rank = b.rank
    WHERE a.lo <= b.hi;
    IF wrong > 0 THEN
        RAISE EXCEPTION 'advanced does not beat basic at % rank(s)', wrong;
    END IF;

    -- ...and loses to the next rank's, so a realm is still worth crossing.
    SELECT count(*) INTO wrong
    FROM (SELECT t.rank, max(t.base_power) AS hi FROM techniques t
          WHERE t.created_by IS NULL AND t.grade = 'advanced' GROUP BY t.rank) a
    JOIN (SELECT t.rank, min(t.base_power) AS lo FROM techniques t
          WHERE t.created_by IS NULL AND t.grade = 'basic' GROUP BY t.rank) b
      ON b.rank = a.rank + 1
    WHERE a.hi >= b.lo;
    IF wrong > 0 THEN
        RAISE EXCEPTION
            'an advanced technique outreaches the next rank at % boundary(s)', wrong;
    END IF;
END;
$$;
