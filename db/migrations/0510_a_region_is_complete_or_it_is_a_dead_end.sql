-- 0510_a_region_is_complete_or_it_is_a_dead_end
--
-- 0509 seeded the Heavenly Court and twelve standing tests refused it. Every
-- one was right, and between them they are the definition of what a region
-- IS in this game - which is worth writing down, because I had been treating
-- "a region" as a row plus some content rather than as a contract:
--
--     an unbroken herb ladder          no tier missing between its own
--                                      floor and its own ceiling
--     ore at every tier                a miner who hits a dead end can only
--                                      leave, "which is not a decision, it
--                                      is a tax"
--     a common cultivation herb        0177: cultivation was the rarest
--                                      thing to gather in the game
--     every ingredient leans           a Path-less material is "bulk and no
--                                      opinion"
--     beast parts that can be forged   or the drop is a dead row
--     a road, both ways                0122
--     a page worth reading             region_index must return gather,
--                                      mine, beast, gu AND road
--     a world beast holding something  no hunt can yield
--
-- The Court had the top of each ladder and none of the rest. An apex region
-- that hands out tier 13 growth and no tier 6 is not a harder version of the
-- heavens, it is a place where a gatherer climbing from below falls through
-- a hole the width of seven bands.
--
-- SO IT INHERITS THE HEAVENS' LADDERS AND KEEPS ITS OWN APEX. Black Heaven's
-- tier 6 to 12 growth and all eight of its ore tiers are seeded into the
-- Court beside the tier 13 band and the ninth ore band, which gives it 6-13
-- and 1-9 - the deepest of both ladders anywhere, with no holes. It also
-- means the Court inherits `starless_moss`, the common star-Path herb that
-- is how Black Heaven satisfies the cultivation rule; inventing a second
-- common cultivation herb for one region would have been a second answer to
-- a question already answered.
--
-- THE ROAD IS 18 HOURS where the heavens are 12. It is a rank above them.
--
-- AND THE ORE TEST ITSELF IS WRONG NOW, so it changes with this. It asserts
-- `(low, high, distinct) == (1, 8, 8)` for every region - a literal band,
-- which was true while 8 was the top of the world. The herb test next to it
-- already went through exactly this and says so in its own docstring: it
-- asserted `count == 7`, then tiers 1-7 everywhere, and ended up at a
-- per-region no-holes rule with the bands pinned separately, because "the
-- same thing only while every region shared one band". The ore test is at
-- stage two of that history and this moves it to stage three.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The ladders it was missing
-- ---------------------------------------------------------------------------

-- Tiers 6 to 12, from Black Heaven, at Black Heaven's own weights. The Court
-- grows them more thinly - it is not a gentler place - but an unbroken ladder
-- matters more than a steeper one.
INSERT INTO region_materials (region_code, material_code, weight)
SELECT 'heavenly_court', rm.material_code, GREATEST(0.20, rm.weight * 0.6)
FROM region_materials rm
JOIN materials m ON m.code = rm.material_code
WHERE rm.region_code = 'black_heaven' AND m.tier BETWEEN 6 AND 12
ON CONFLICT DO NOTHING;

-- Ore at tiers 1 to 8, likewise. A miner climbing in the Court climbs the
-- whole way rather than arriving already at the top.
INSERT INTO region_veins (region_code, material_code, weight)
SELECT 'heavenly_court', rv.material_code, GREATEST(0.20, rv.weight * 0.6)
FROM region_veins rv
JOIN ores o ON o.material_code = rv.material_code
WHERE rv.region_code = 'black_heaven' AND o.tier BETWEEN 1 AND 8
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- Every ingredient leans somewhere
-- ---------------------------------------------------------------------------

-- The five Court ores shipped with no Path. Each leans where its signature
-- does: the stone that lends defence is earth, the iron that lends strength
-- is metal, the gold that lends cultivation is rule, the crystal that lends
-- critical damage is sword, the jade that lends a body is strength.
UPDATE materials SET path_code = 'earth'    WHERE code = 'court_foundation_stone';
UPDATE materials SET path_code = 'metal'    WHERE code = 'edict_iron';
UPDATE materials SET path_code = 'rule'     WHERE code = 'sovereign_vein_gold';
UPDATE materials SET path_code = 'sword'    WHERE code = 'tribunal_crystal';
UPDATE materials SET path_code = 'strength' WHERE code = 'unmoving_pillar_jade';

-- And Court Marrow, which shipped Path-less because "a part off anything"
-- felt generic. It is bone; bone is the body, and the body is strength.
UPDATE materials SET path_code = 'bone' WHERE code = 'court_marrow';


-- ---------------------------------------------------------------------------
-- Parts a smith can use
-- ---------------------------------------------------------------------------

INSERT INTO beast_parts (material_code, part) VALUES
    ('edict_sinew',      'core'),
    ('warden_scale',     'scale'),
    ('censer_ash_gland', 'venom'),
    ('summons_plume',    'feather'),
    ('ledger_fang',      'fang'),
    ('court_marrow',     'bone')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- A road, both ways
-- ---------------------------------------------------------------------------

-- One row per pair, in the canonical order the table's CHECK demands.
-- 0122's "a road runs both ways" is about the READER, not about two rows -
-- inserting both directions is refused by `region_routes_canonical_pair`,
-- which is how I found out.
INSERT INTO region_routes (origin, destination, travel_hours)
SELECT LEAST('heavenly_court', r.code), GREATEST('heavenly_court', r.code), 18.00
FROM regions r WHERE r.code <> 'heavenly_court'
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- Something the Warden holds that no hunt yields
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, description, path_code, emoji, tier)
VALUES ('longevity_crown_fragment', 'Longevity Crown Fragment', 'beast', 'extreme',
        'Off the Warden of Longevity Heaven, and off nothing else. No hunt in any region yields one.',
        'heaven', '\U0001F451', NULL)
ON CONFLICT (code) DO NOTHING;

INSERT INTO beast_parts (material_code, part) VALUES
    ('longevity_crown_fragment', 'heart')
ON CONFLICT DO NOTHING;

INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, 'longevity_crown_fragment', 1.00, 1, 2
FROM creature_species cs WHERE cs.code = 'longevity_heaven_warden'
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- The contract, checked against every region rather than the new one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
    one   RECORD;  -- not `r`: it shadows `regions r` below
BEGIN
    -- 1. No holes in any region's herb ladder, which is the rule the herb
    -- test settled on. Checked everywhere, because the Court's seeding
    -- borrowed from Black Heaven and could have broken that instead.
    FOR one IN SELECT code FROM regions LOOP
        SELECT count(*) INTO v_n FROM (
            SELECT DISTINCT m.tier FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = one.code AND m.tier IS NOT NULL
        ) t;
        IF v_n > 0 THEN
            SELECT max(m.tier) - min(m.tier) + 1 INTO v_n
            FROM region_materials rm JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = one.code AND m.tier IS NOT NULL;
            IF v_n <> (SELECT count(DISTINCT m.tier) FROM region_materials rm
                       JOIN materials m ON m.code = rm.material_code
                       WHERE rm.region_code = one.code AND m.tier IS NOT NULL) THEN
                v_bad := COALESCE(v_bad, '') || one.code || ' ';
            END IF;
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these regions have a hole in their herb ladder: %', v_bad;
    END IF;

    -- 2. And none in any ore ladder, by the same rule.
    v_bad := NULL;
    FOR one IN
        SELECT rv.region_code AS code, min(o.tier) AS lo, max(o.tier) AS hi,
               count(DISTINCT o.tier) AS n
        FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
        GROUP BY rv.region_code
    LOOP
        IF one.hi - one.lo + 1 <> one.n OR one.lo <> 1 THEN
            v_bad := COALESCE(v_bad, '') || one.code
                     || ' (' || one.lo || '-' || one.hi || ', ' || one.n || ') ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these regions have a hole in their ore ladder: %', v_bad;
    END IF;

    -- Every region has veins at all, which the GROUP BY above would skip.
    SELECT count(*) INTO v_n FROM regions r
    WHERE NOT EXISTS (SELECT 1 FROM region_veins rv WHERE rv.region_code = one.code);
    IF v_n > 0 THEN RAISE EXCEPTION '% regions have no veins', v_n; END IF;

    -- 3. The Court reaches deeper than anywhere else on both ladders, which
    -- is the whole point of it being a rank above.
    IF (SELECT max(m.tier) FROM region_materials rm JOIN materials m ON m.code = rm.material_code
        WHERE rm.region_code = 'heavenly_court')
       <= (SELECT max(m.tier) FROM region_materials rm JOIN materials m ON m.code = rm.material_code
           WHERE rm.region_code <> 'heavenly_court') THEN
        RAISE EXCEPTION 'the Court does not grow deeper than anywhere else';
    END IF;
    IF (SELECT max(o.tier) FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
        WHERE rv.region_code = 'heavenly_court')
       <= (SELECT max(o.tier) FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
           WHERE rv.region_code <> 'heavenly_court') THEN
        RAISE EXCEPTION 'the Court does not hold deeper ore than anywhere else';
    END IF;

    -- 4. A common cultivation herb, everywhere.
    SELECT string_agg(one.code, ', ') INTO v_bad FROM regions r
    WHERE NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = one.code AND ppk.kind = 'cultivation'
          AND m.rarity = 'common');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'no common cultivation herb grows in: %', v_bad;
    END IF;

    -- 5. Nothing is bulk and no opinion.
    SELECT string_agg(code, ', ') INTO v_bad FROM materials
    WHERE path_code IS NULL AND category NOT IN ('currency', 'essence');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these ingredients lean nowhere: %', v_bad;
    END IF;

    -- 6. Every beast material a smith could be handed can be used.
    SELECT string_agg(m.code, ', ') INTO v_bad FROM materials m
    WHERE m.category = 'beast'
      AND NOT EXISTS (SELECT 1 FROM beast_parts bp WHERE bp.material_code = m.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these beast materials cannot be forged: %', v_bad;
    END IF;

    -- 7. A page worth reading: every kind the index reports, in every region.
    FOR one IN SELECT code, name FROM regions LOOP
        SELECT string_agg(k.kind, ', ') INTO v_bad
        FROM (VALUES ('gather'), ('mine'), ('beast'), ('gu'), ('road')) AS k(kind)
        WHERE NOT EXISTS (
            SELECT 1 FROM region_index(one.code) ix WHERE ix.kind = k.kind);
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION '% has no %', one.name, v_bad;
        END IF;
    END LOOP;

    -- 8. And the Warden holds something no hunt can yield.
    SELECT count(*) INTO v_n
    FROM creature_drops cd
    JOIN creature_species cs ON cs.species_id = cd.species_id
    WHERE cs.code = 'longevity_heaven_warden'
      AND NOT EXISTS (
          SELECT 1 FROM creature_drops other
          JOIN creature_species oc ON oc.species_id = other.species_id
          WHERE other.material_code = cd.material_code
            AND oc.code <> 'longevity_heaven_warden');
    IF v_n = 0 THEN
        RAISE EXCEPTION 'the Warden holds nothing a hunt could not also yield';
    END IF;

    RAISE NOTICE
        'the Court: growth %-%, ore %-%, % creatures, roads both ways',
        (SELECT min(m.tier) FROM region_materials rm JOIN materials m ON m.code = rm.material_code WHERE rm.region_code='heavenly_court'),
        (SELECT max(m.tier) FROM region_materials rm JOIN materials m ON m.code = rm.material_code WHERE rm.region_code='heavenly_court'),
        (SELECT min(o.tier) FROM region_veins rv JOIN ores o ON o.material_code=rv.material_code WHERE rv.region_code='heavenly_court'),
        (SELECT max(o.tier) FROM region_veins rv JOIN ores o ON o.material_code=rv.material_code WHERE rv.region_code='heavenly_court'),
        (SELECT count(*) FROM creature_regions WHERE region_code='heavenly_court');
END;
$probe$;
