-- 0177_something_worth_gathering_on_every_cultivation_path
--
-- A brew's kind comes from its lead herb's Path, and the five Paths mapped to
-- 'cultivation' - Space, Time, Luck, Rule, Star - had almost nothing growing
-- on them. Gatherable weight by what a Path's herbs would brew into:
--
--   physique          186.1   14 common entries
--   healing           182.8   16
--   qi                113.4    9
--   cultivation_rate   34.8    3
--   insight            21.3    0
--   attainment_rate    19.0    1
--   cultivation        10.1    0   <- the whole supply, in four regions
--
-- Not one common herb on any of the five, and 5% of physique's weight. The
-- roster holds 8,548 herbs that brew physique and 1,555 that brew cultivation,
-- and cultivation is the bar every cultivator is actually trying to move.
--
-- That is not a design decision anywhere - the kind map gives cultivation five
-- Paths against healing's four. It is that the Paths carrying it happen to be
-- the ones nothing grows on.
--
-- `region_materials_one_region_each` means a herb grows in exactly one place,
-- which is how every other Path does it: healing has 27 kinds spread over the
-- five regions rather than 5 kinds growing everywhere. So this follows the
-- same shape - ten new herbs, two to a region, each of the five Paths twice.
-- Every region gets a common cultivation herb; no region gets all five Paths.
--
-- Weight 8.0 is mid-band for a common (6 to 10). That takes cultivation from
-- 10.1 to about 90 - fourth of seven rather than last. A cultivation pill is
-- the most valuable there is, 60 a magnitude point against Qi's 8, and a tier
-- 5 one is still only nine hours of passive cultivation, so it does not need
-- protecting from being available.
--
-- Forward-only. Do not edit once applied.


INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
VALUES
    ('void_dew', 'Void Dew', 'gathering', 'common', 'space', '🌀',
     'Collects on nothing, in the morning, in the shape of what is not there.'),
    ('hollow_pearl', 'Hollow Pearl', 'gathering', 'common', 'space', '🫧',
     'Weighs less than the air it displaces, which is the wrong way round.'),

    ('slowsand_moss', 'Slowsand Moss', 'gathering', 'common', 'time', '⌛',
     'Grows a hand''s width a century, and the century is the useful part.'),
    ('hourbloom', 'Hourbloom', 'gathering', 'common', 'time', '🕛',
     'Opens once and closes once, and nobody has watched it do either.'),

    ('copper_clover', 'Copper Clover', 'gathering', 'common', 'luck', '🍃',
     'Four leaves, every one of them, which is either very lucky or not luck at all.'),
    ('fortune_bell_fungus', 'Fortune Bell Fungus', 'gathering', 'common', 'luck', '🔔',
     'Rings when picked. Nobody agrees on whether that is the good sign.'),

    ('precept_reed', 'Precept Reed', 'gathering', 'common', 'rule', '📏',
     'Straight because it will not be otherwise, not because nothing bent it.'),
    ('tally_vine', 'Tally Vine', 'gathering', 'common', 'rule', '📜',
     'Puts out one notch a season and has never miscounted.'),

    ('starfall_seed', 'Starfall Seed', 'gathering', 'common', 'star', '✴️',
     'Landed rather than grew. It has not decided yet whether to be a plant.'),
    ('starcap', 'Starcap', 'gathering', 'common', 'star', '🍄',
     'Comes up only under a clear sky, and only where one was looked at.');


-- Two to a region, so gathering where you happen to be turns up something
-- that brews cultivation wherever that is.
INSERT INTO region_materials (region_code, material_code, weight) VALUES
    ('western',  'void_dew',            8.0000),
    ('western',  'precept_reed',        8.0000),
    ('eastern',  'slowsand_moss',       8.0000),
    ('eastern',  'starfall_seed',       8.0000),
    ('northern', 'copper_clover',       8.0000),
    ('northern', 'hollow_pearl',        8.0000),
    ('southern', 'hourbloom',           8.0000),
    ('southern', 'tally_vine',          8.0000),
    ('central',  'fortune_bell_fungus', 8.0000),
    ('central',  'starcap',             8.0000);


DO $$
DECLARE
    thin  TEXT;
    least_kind TEXT;
BEGIN
    -- Every REGION, not every Path in every region: a herb grows in one
    -- place, so five Paths everywhere would be twentyfive herbs. What has to
    -- be true is that gathering wherever you are turns up something that
    -- brews cultivation.
    SELECT string_agg(r.code, ', ' ORDER BY r.code) INTO thin
    FROM regions r
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = r.code
          AND ppk.kind = 'cultivation'
          AND m.rarity = 'common'
    );

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION
            'no common cultivation herb grows in: %', thin;
    END IF;

    -- And each of the five Paths grows somewhere, or a Path is still barren.
    SELECT string_agg(p.name, ', ' ORDER BY p.sort_order) INTO thin
    FROM path_pill_kinds ppk
    JOIN paths p ON p.code = ppk.path_code
    WHERE ppk.kind = 'cultivation'
      AND NOT EXISTS (
          SELECT 1 FROM region_materials rm
          JOIN materials m ON m.code = rm.material_code
          WHERE m.path_code = p.code AND m.rarity = 'common'
      );

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'still nothing common growing on: %', thin;
    END IF;

    -- And it is no longer the least gatherable thing in the game, which is
    -- what it was before this and what nothing intended.
    SELECT ppk.kind INTO least_kind
    FROM region_materials rm
    JOIN materials m ON m.code = rm.material_code
    JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
    GROUP BY ppk.kind
    ORDER BY sum(rm.weight)
    LIMIT 1;

    IF least_kind = 'cultivation' THEN
        RAISE EXCEPTION 'cultivation is still the rarest thing to gather';
    END IF;
END;
$$;
