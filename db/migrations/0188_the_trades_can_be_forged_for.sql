-- 0188_the_trades_can_be_forged_for
--
-- An audit of all 32 effects against everything that grants one. The four a
-- craftsman would actually chase are the four almost nothing hands out:
--
--   effect                        gu  gear  body  root  dwell
--   brew_potency  Cauldron Sense   0     0     2     2     1
--   gu_potency    Worm Sense       0     0     2     2     1
--   forge_power   Smith's Hand     0     0     2     3     1
--   gathering_yield                3     0     2     0     1
--
-- Nothing on any of them from equipment, and Cauldron Sense caps at +60%
-- while the best-off cultivator here has 8.4% - from the root they happened
-- to roll at character creation. A profession stat you cannot pursue is a
-- profession stat that is decoration.
--
-- The reason is one table wide. `forge` writes `equipment_effects` from four
-- places - the ore's signature, the slot, the beast parts, the reaction - and
-- between them they produce exactly ten effects, every one of them combat or
-- cultivation. There is no ore whose signature is a trade.
--
-- Four, then, one per trade, at tier 4. That is where the ore caps the piece
-- and where a signature pays 0.0481 - a fifth of Cauldron Sense's ceiling
-- from one forging, which is worth going after and does not end the question.
-- They are the same shape as 0174's Nightsilver: the metal is known for
-- something, and what it is known for is a craft rather than a wound.
--
-- Forward-only. Do not edit once applied.


INSERT INTO materials (code, name, category, rarity, path_code, emoji, description)
VALUES
    ('cinnabar_vein', 'Cinnabar Vein', 'gathering', 'uncommon', 'refinement', '⚗️',
     'Alchemists have paid for this by weight since before anybody forged it. '
     'It turns out to know what it is doing in a crucible too.'),

    ('forgeheart_iron', 'Forgeheart Iron', 'gathering', 'uncommon', 'fire', '🔨',
     'Comes out of the ground already tempered, as though something had got '
     'to it first and left the knack behind.'),

    ('wormsilver', 'Wormsilver', 'gathering', 'uncommon', 'poison', '🐛',
     'Gu will not eat it and will not leave it alone. Nobody has settled '
     'which of those is the useful half.'),

    ('prospector_quartz', 'Prospector''s Quartz', 'gathering', 'uncommon', 'earth', '💎',
     'Sits on top of whatever else is worth having, which is the entire '
     'reason anybody digs for it.');


-- Tier 4: the ore caps the piece, so this is mid-grade gear rather than the
-- best a smith can make. A trade is worth pursuing, not worth everything.
INSERT INTO ores (material_code, tier, signature, word) VALUES
    ('cinnabar_vein',     4, 'brew_potency',    'Cinnabar'),
    ('forgeheart_iron',   4, 'forge_power',     'Forgeheart'),
    ('wormsilver',        4, 'gu_potency',      'Wormsilver'),
    ('prospector_quartz', 4, 'gathering_yield', 'Prospector');


INSERT INTO region_veins (region_code, material_code, weight) VALUES
    ('central',  'cinnabar_vein',     1.2000),
    ('western',  'forgeheart_iron',   1.2000),
    ('southern', 'wormsilver',        1.2000),
    ('northern', 'prospector_quartz', 1.2000);


DO $$
DECLARE
    thin TEXT;
BEGIN
    -- The four trades are forgeable now. Stated as the rule rather than as
    -- four names, so a fifth trade effect added later has to answer it too.
    SELECT string_agg(e.name, ', ' ORDER BY e.code) INTO thin
    FROM gu_effects e
    WHERE e.code IN ('brew_potency', 'gu_potency', 'forge_power',
                     'gathering_yield')
      AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.signature = e.code)
      AND NOT EXISTS (SELECT 1 FROM part_effects pe WHERE pe.effect_code = e.code)
      AND NOT EXISTS (SELECT 1 FROM slot_effects se WHERE se.effect_code = e.code)
      AND NOT EXISTS (SELECT 1 FROM forge_reactions r WHERE r.effect_code = e.code);

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'no forging can grant: %', thin;
    END IF;

    -- And every new ore is diggable, or this is 0174's fault repeated in a
    -- different table.
    SELECT string_agg(m.name, ', ') INTO thin
    FROM materials m
    WHERE m.code IN ('cinnabar_vein', 'forgeheart_iron', 'wormsilver',
                     'prospector_quartz')
      AND NOT EXISTS (SELECT 1 FROM region_veins v WHERE v.material_code = m.code);

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'nothing yields: %', thin;
    END IF;

    -- An ore signature has to be an effect that exists; the FK says so, but
    -- the FK cannot say it must be one a player can ever hold.
    SELECT string_agg(o.material_code, ', ') INTO thin
    FROM ores o
    JOIN gu_effects e ON e.code = o.signature
    WHERE e.cap <= 0;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these ores are known for a capped-out effect: %', thin;
    END IF;

    -- 0175's guard, because this writes four more emoji.
    SELECT string_agg(m.code, ', ') INTO thin
    FROM materials m
    WHERE m.emoji LIKE '%\%' OR m.emoji LIKE '%{%' OR m.emoji = '';

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these are not emoji: %', thin;
    END IF;
END;
$$;
