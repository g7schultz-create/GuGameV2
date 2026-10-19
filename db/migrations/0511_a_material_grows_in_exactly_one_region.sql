-- 0511_a_material_grows_in_exactly_one_region
--
-- 0510 tried to give the Heavenly Court the heavens' tier 6 to 12 growth by
-- copying Black Heaven's rows. It inserted nothing, reported success, and
-- my own probe passed it. Three failures in one:
--
--     region_materials_one_region_each   UNIQUE (material_code)
--
-- A material grows in exactly ONE region - a deliberate rule, and a good
-- one: a herb that grows everywhere is not a reason to go anywhere. My
-- `ON CONFLICT DO NOTHING` swallowed all twenty-two violations silently,
-- and the probe I wrote to catch exactly this compared a count against
-- itself and could not fail. A probe that cannot fail is worse than no
-- probe, because it reads like cover.
--
-- SO THE COURT GROWS ITS OWN LADDER. Twenty-one materials across tiers 6 to
-- 12, in the Court's own register - petitions, rosters, summonses, dockets -
-- so the place is read through what grows in it rather than through borrowed
-- flora. Tier 6 carries a COMMON star-Path herb, which is how 0177's rule
-- that every region grow a common cultivation herb is answered here instead
-- of by inheriting Black Heaven's.
--
-- AND THREE CURVES THAT HAD TO BE READ OFF THE WORLD RATHER THAN CHOSEN:
--
--   Herb weight falls with tier, per region. The Court's band falls 6.00 to
--   0.40 across tiers 6 to 12, and the tier 13 band is pushed BELOW 0.40 -
--   it shipped at 0.40-0.90, which would have made the apex commoner than
--   the band under it.
--
--   Vein weight falls with tier GLOBALLY, not per region. The world's
--   maximum runs 8.0 at tier 1 down to 0.200 at tier 8, and the ninth band
--   shipped at 3.00 - commoner than tier 2. It is now 0.180 down to 0.060.
--
--   A gated region is twelve hours from anywhere. The travel test reads the
--   gated set from the schema so a third one would not break it, and then
--   asserts twelve exactly - "what is being crossed is the gap and not the
--   ground". The Court shipped at eighteen on my reasoning that it is
--   further; the gap is the gap, so it is twelve.
--
-- Plus an emoji that was a Python escape. 0175 is a whole migration about
-- that and I hand-wrote `'\U0001F451'` into SQL anyway.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The Court's own band
-- ---------------------------------------------------------------------------

INSERT INTO materials (code, name, category, rarity, description, path_code, emoji, tier) VALUES
    ('court_step_moss', 'Court Step Moss', 'gathering', 'common', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'star', '🌿', 6),
    ('antechamber_lichen', 'Antechamber Lichen', 'gathering', 'common', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'earth', '🪴', 6),
    ('waiting_hall_reed', 'Waiting Hall Reed', 'gathering', 'uncommon', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'water', '🌾', 6),
    ('petition_grass', 'Petition Grass', 'gathering', 'uncommon', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'rule', '🌽', 7),
    ('clerks_nightshade', 'Clerk''s Nightshade', 'gathering', 'uncommon', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'shadow', '🌑', 7),
    ('sealing_resin', 'Sealing Resin', 'gathering', 'rare', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'formation', '🟠', 7),
    ('roster_moth_dust', 'Roster Moth Dust', 'gathering', 'rare', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'painting', '💫', 8),
    ('hour_ledger_sap', 'Hour Ledger Sap', 'gathering', 'rare', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'time', '🪵', 8),
    ('gate_iron_bloom', 'Gate Iron Bloom', 'gathering', 'rare', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'metal', '🌹', 8),
    ('summons_bell_fungus', 'Summons Bell Fungus', 'gathering', 'epic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'light', '🍄', 9),
    ('arbiters_tea_leaf', 'Arbiter''s Tea Leaf', 'gathering', 'epic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'wisdom', '🍃', 9),
    ('void_docket_spore', 'Void Docket Spore', 'gathering', 'epic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'space', '🌌', 9),
    ('censer_smoke_flower', 'Censer Smoke Flower', 'gathering', 'epic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'fire', '🌸', 10),
    ('edict_vine', 'Edict Vine', 'gathering', 'legendary', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'rule', '🌿', 10),
    ('fortune_tally_bean', 'Fortune Tally Bean', 'gathering', 'legendary', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'luck', '🫘', 10),
    ('aeon_court_root', 'Aeon Court Root', 'gathering', 'legendary', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'time', '🫒', 11),
    ('star_charter_dew', 'Star Charter Dew', 'gathering', 'legendary', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'star', '💦', 11),
    ('pillar_moss_essence', 'Pillar Moss Essence', 'gathering', 'mythic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'earth', '🧪', 11),
    ('longevity_pollen', 'Longevity Pollen', 'gathering', 'mythic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'heaven', '🐝', 12),
    ('unwritten_margin', 'Unwritten Margin', 'gathering', 'mythic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'luck', '📄', 12),
    ('sovereign_breath_ice', 'Sovereign Breath Ice', 'gathering', 'mythic', 'Grows in the halls of the Heavenly Court, and nowhere else - a material belongs to one region.', 'ice', '❄', 12);

INSERT INTO region_materials (region_code, material_code, weight) VALUES
    ('heavenly_court', 'court_step_moss', 6.00),
    ('heavenly_court', 'antechamber_lichen', 5.00),
    ('heavenly_court', 'waiting_hall_reed', 4.50),
    ('heavenly_court', 'petition_grass', 4.00),
    ('heavenly_court', 'clerks_nightshade', 3.50),
    ('heavenly_court', 'sealing_resin', 3.00),
    ('heavenly_court', 'roster_moth_dust', 2.60),
    ('heavenly_court', 'hour_ledger_sap', 2.20),
    ('heavenly_court', 'gate_iron_bloom', 2.00),
    ('heavenly_court', 'summons_bell_fungus', 1.80),
    ('heavenly_court', 'arbiters_tea_leaf', 1.50),
    ('heavenly_court', 'void_docket_spore', 1.30),
    ('heavenly_court', 'censer_smoke_flower', 1.20),
    ('heavenly_court', 'edict_vine', 1.00),
    ('heavenly_court', 'fortune_tally_bean', 0.90),
    ('heavenly_court', 'aeon_court_root', 0.80),
    ('heavenly_court', 'star_charter_dew', 0.70),
    ('heavenly_court', 'pillar_moss_essence', 0.60),
    ('heavenly_court', 'longevity_pollen', 0.50),
    ('heavenly_court', 'unwritten_margin', 0.45),
    ('heavenly_court', 'sovereign_breath_ice', 0.40);


-- ---------------------------------------------------------------------------
-- The three curves
-- ---------------------------------------------------------------------------

-- The apex band goes under the band below it. It shipped commoner.
UPDATE region_materials rm SET weight = CASE m.rarity
        WHEN 'extreme' THEN 0.20 ELSE 0.30 END
FROM materials m
WHERE m.code = rm.material_code AND rm.region_code = 'heavenly_court'
  AND m.tier = 13;

-- The ninth ore band goes under the eighth, which is 0.200 world-wide.
UPDATE region_veins rv SET weight = v.w
FROM (VALUES
    ('court_foundation_stone', 0.180::numeric),
    ('edict_iron', 0.150::numeric),
    ('sovereign_vein_gold', 0.120::numeric),
    ('tribunal_crystal', 0.090::numeric),
    ('unmoving_pillar_jade', 0.060::numeric)
) AS v(code, w)
WHERE rv.material_code = v.code AND rv.region_code = 'heavenly_court';

-- The gap is the gap.
UPDATE region_routes SET travel_hours = 12.00
WHERE origin = 'heavenly_court' OR destination = 'heavenly_court';

-- And an emoji that is an emoji.
UPDATE materials SET emoji = '👑' WHERE code = 'longevity_crown_fragment';


-- ---------------------------------------------------------------------------
-- Probes that can fail
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad  TEXT;
    v_n    INTEGER;
    one    RECORD;
BEGIN
    -- The rule 0510 walked into. Asserted directly, because the thing that
    -- went wrong was an ON CONFLICT hiding twenty-two of these.
    SELECT string_agg(material_code, ', ') INTO v_bad FROM (
        SELECT material_code FROM region_materials
        GROUP BY material_code HAVING count(*) > 1) t;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these materials grow in more than one region: %', v_bad;
    END IF;

    -- An unbroken ladder, per region, written so a hole is the thing that
    -- fails rather than a count compared against itself.
    FOR one IN
        SELECT rm.region_code AS code, min(m.tier) AS lo, max(m.tier) AS hi,
               count(DISTINCT m.tier) AS n
        FROM region_materials rm JOIN materials m ON m.code = rm.material_code
        WHERE m.tier IS NOT NULL
        GROUP BY rm.region_code
    LOOP
        IF one.hi - one.lo + 1 <> one.n THEN
            v_bad := COALESCE(v_bad, '') || one.code || ' (' || one.lo || '-'
                     || one.hi || ', ' || one.n || ' tiers) ';
        END IF;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a hole in a herb ladder: %', v_bad;
    END IF;

    -- The Court specifically reaches 6 to 13 now, which is what it was for.
    IF (SELECT min(m.tier) FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        WHERE rm.region_code = 'heavenly_court') <> 6 THEN
        RAISE EXCEPTION 'the Court''s ladder does not start at 6';
    END IF;

    -- Weight falls with tier, in every region. NON-increasing, not
    -- strictly decreasing: the standing test uses sorted(reverse=True)
    -- which permits ties, and the Central Continent has them. My first
    -- version of this probe banned ties and failed on data that was
    -- already correct.
    FOR one IN SELECT DISTINCT region_code AS code FROM region_materials LOOP
        SELECT string_agg(x.tier::text, ',' ORDER BY x.tier) INTO v_bad
        FROM (
            SELECT m.tier, max(rm.weight) AS w
            FROM region_materials rm JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = one.code AND m.tier IS NOT NULL
            GROUP BY m.tier) x
        JOIN (
            SELECT m.tier, max(rm.weight) AS w
            FROM region_materials rm JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = one.code AND m.tier IS NOT NULL
            GROUP BY m.tier) y ON y.tier > x.tier AND y.w > x.w;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION
                'in % a deeper herb is not rarer, around tiers %', one.code, v_bad;
        END IF;
    END LOOP;

    -- And vein weight falls with tier world-wide, which is how the test
    -- reads it.
    SELECT string_agg(a.tier || '->' || b.tier, ', ') INTO v_bad
    FROM (SELECT o.tier, max(rv.weight) w FROM region_veins rv
          JOIN ores o ON o.material_code = rv.material_code GROUP BY o.tier) a
    JOIN (SELECT o.tier, max(rv.weight) w FROM region_veins rv
          JOIN ores o ON o.material_code = rv.material_code GROUP BY o.tier) b
      ON b.tier > a.tier AND b.w > a.w;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a deeper vein is not rarer: %', v_bad;
    END IF;

    -- A common cultivation herb, in the Court, of its own.
    IF NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        WHERE rm.region_code = 'heavenly_court' AND ppk.kind = 'cultivation'
          AND m.rarity = 'common') THEN
        RAISE EXCEPTION 'the Court still grows no common cultivation herb';
    END IF;

    -- Twelve hours, like every other gated region.
    SELECT string_agg(origin || '-' || destination || ' ' || travel_hours, ', ')
    INTO v_bad FROM region_routes
    WHERE (origin = 'heavenly_court' OR destination = 'heavenly_court')
      AND travel_hours <> 12;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the Court is not twelve hours from somewhere: %', v_bad;
    END IF;

    -- No material anywhere carries a Python escape as its emoji.
    SELECT string_agg(code, ', ') INTO v_bad FROM materials
    WHERE emoji ~ '\\[uU]' OR emoji LIKE '%\\U000%';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these emoji are escapes rather than emoji: %', v_bad;
    END IF;

    RAISE NOTICE
        'the Court grows % of its own across tiers %-%, veins %-%, twelve hours out',
        (SELECT count(*) FROM region_materials WHERE region_code='heavenly_court'),
        (SELECT min(m.tier) FROM region_materials rm JOIN materials m ON m.code=rm.material_code WHERE rm.region_code='heavenly_court'),
        (SELECT max(m.tier) FROM region_materials rm JOIN materials m ON m.code=rm.material_code WHERE rm.region_code='heavenly_court'),
        (SELECT min(o.tier) FROM region_veins rv JOIN ores o ON o.material_code=rv.material_code WHERE rv.region_code='heavenly_court'),
        (SELECT max(o.tier) FROM region_veins rv JOIN ores o ON o.material_code=rv.material_code WHERE rv.region_code='heavenly_court');
END;
$probe$;
