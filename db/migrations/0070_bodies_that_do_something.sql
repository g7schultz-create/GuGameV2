-- 0070_bodies_that_do_something
--
-- Thirty-six bodies stop lying.
--
-- Since 0012 a physique has been worth three multipliers and a Path affinity,
-- and everything ELSE it claimed lived in `unmodelled` - a jsonb column whose
-- whole job is to admit, in writing, that the engine does not pay this. Two
-- migrations ago that was still the honest place for it. It is not any more:
-- 0066 folded `physique_stat` into `player_stat`, so a body speaking the
-- shared vocabulary reaches a fight with no engine change, and 0069 built the
-- two things the vocabulary could not say.
--
-- BODIES ARE MEANT TO BE BIG. A physique is ROLLED, and a rolled trait
-- carrying a mechanic is only fair if the roll can be retaken - which is the
-- plan, with a rarer currency, and which is why these numbers are set to be
-- felt rather than to be safe. A Void Sovereign body is +23% evasion on a cap
-- of 40%; a Heaven and Earth body is +38% damage reduction on a cap of 50%.
--
-- THAT SHARED CAP IS THE POINT, not a side effect. Because `player_stat` caps
-- the SUM, a body that already spends most of an effect's ceiling makes gear
-- granting the same effect nearly worthless - so the roll you did not choose
-- decides what the forge you did choose should make. That is a build
-- decision, and this game did not have one before.
--
-- STEPS, NOT SHARES OF THE CAP. Effects are not commensurable: crit damage
-- caps at 200% and evasion at 40%, so "half the cap" means two wildly
-- different things. This is the same problem `pill_kinds.per_point` solved in
-- 0057 - "cultivation is counted in hundreds and health in tens, so the scale
-- cannot live in the pill" - and it gets the same answer. Each effect declares
-- how big one step of it is; each tier declares how many steps a body of that
-- rank is worth; a body's rows say only how it splits them.
--
-- Retuning the whole ladder is therefore one UPDATE to `physique_power`, and
-- retuning one effect everywhere is one UPDATE to `gu_effects.step`.
--
-- WHAT IS STILL NOT PAID stays in `unmodelled`, clause by clause. Ink Skin's
-- redrawn wound, Puppet Array's bound creature, Heaven Defying's breakthrough
-- backlash and eleven others need systems that do not exist. Every body now
-- grants something real; several still promise a second thing they do not.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- How big one step of an effect is
-- ---------------------------------------------------------------------------
-- A source-agnostic unit. Nothing about bodies is baked in here - this is the
-- natural granularity of the effect itself, and the next system handing out a
-- budget spends it in the same steps.

ALTER TABLE gu_effects ADD COLUMN step NUMERIC(6, 4) NOT NULL DEFAULT 0.0200
    CHECK (step > 0);

COMMENT ON COLUMN gu_effects.step IS
    'One step of this effect. Effects are not commensurable - a point of crit damage and a point of evasion are different sizes - so anything spending a budget across effects spends it in these.';

UPDATE gu_effects SET step = v.step FROM (VALUES
    ('attack_power',     0.0300),
    ('multi_hit',        0.0300),
    ('crit_rate',        0.0200),
    ('crit_damage',      0.0400),
    ('armor_pen',        0.0250),
    ('lifesteal',        0.0150),
    ('dodge',            0.0120),
    ('damage_reduction', 0.0150),
    ('max_hp',           0.0300),
    ('max_qi',           0.0300),
    ('cultivation_rate', 0.0300),
    ('gathering_yield',  0.0300),
    ('refine_conflict_relief', 0.0300)
) AS v (code, step) WHERE gu_effects.code = v.code;


-- ---------------------------------------------------------------------------
-- How many steps a body is worth
-- ---------------------------------------------------------------------------
-- Keyed on the rarity ladder, so a new band brings its own power without this
-- table being edited - the same reason `equipment_qualities` is keyed there.

CREATE TABLE physique_power (
    tier  TEXT PRIMARY KEY REFERENCES rarities (code) ON DELETE RESTRICT,
    ranks SMALLINT NOT NULL CHECK (ranks > 0)
);

INSERT INTO physique_power (tier, ranks) VALUES
    ('common',     3),
    ('uncommon',   5),
    ('rare',       7),
    ('epic',      10),
    ('legendary', 14),
    ('mythic',    19),
    ('divine',    25),
    ('extreme',   30);

COMMENT ON TABLE physique_power IS
    'What a body of each tier is worth, in steps. One UPDATE here retunes every physique in the game.';


-- ---------------------------------------------------------------------------
-- What each body spends its steps on
-- ---------------------------------------------------------------------------
-- Weights per body, not magnitudes. A body that names one effect puts
-- everything into it; a body that names two splits.

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT p.physique_id, v.effect, round(e.step * pw.ranks * v.weight, 4)
FROM (VALUES
    -- Common. Small, but no longer nothing.
    ('flexible_meridian_body',  'dodge',            0.50),
    ('flexible_meridian_body',  'cultivation_rate', 0.50),
    ('lightfoot_body',          'dodge',            1.00),
    ('mirage_lantern_body',     'dodge',            1.00),
    ('orchard_body',            'max_hp',           1.00),

    -- Uncommon.
    ('cutpurse_body',           'gathering_yield',  1.00),
    ('iron_kiln_body',          'refine_conflict_relief', 1.00),

    -- Rare.
    ('blood_tyrant_body',       'lifesteal',        1.00),
    ('night_wandering_body',    'cultivation_rate', 1.00),
    ('thunderbone_physique',    'dodge',            1.00),

    -- Epic.
    ('endless_ocean_body',      'max_qi',           1.00),
    ('heavenly_battle_body',    'multi_hit',        0.60),
    ('heavenly_battle_body',    'attack_power',     0.40),
    ('long_odds_body',          'crit_rate',        1.00),
    ('mountain_king_body',      'damage_reduction', 0.60),
    ('mountain_king_body',      'gathering_yield',  0.40),
    ('phoenix_rebirth_body',    'attack_power',     1.00),
    ('puppet_array_body',       'max_qi',           1.00),

    -- Legendary.
    ('celestial_emperor_body',  'cultivation_rate', 0.50),
    ('celestial_emperor_body',  'max_hp',           0.50),
    ('heaven_defying_body',     'cultivation_rate', 1.00),
    ('heavenly_giant_body',     'armor_pen',        1.00),
    ('ink_skin_body',           'damage_reduction', 1.00),
    ('primordial_chaos_body',   'max_qi',           1.00),

    -- Mythic.
    ('celestial_sovereign_body','crit_rate',        1.00),
    ('chaos_immortal_body',     'attack_power',     1.00),
    ('eternal_dragon_body',     'attack_power',     0.50),
    ('eternal_dragon_body',     'damage_reduction', 0.50),
    ('void_sovereign_body',     'dodge',            1.00),

    -- Divine.
    ('heaven_and_earth_physique','damage_reduction', 1.00),
    ('infinite_immortal_body',  'dodge',            1.00),
    ('primordial_origin_body',  'cultivation_rate', 0.34),
    ('primordial_origin_body',  'max_hp',           0.33),
    ('primordial_origin_body',  'attack_power',     0.33),

    -- Extreme. The Ten, and they are meant to read as unfair.
    ('blazing_glory_lightning_brilliance', 'attack_power', 0.60),
    ('blazing_glory_lightning_brilliance', 'crit_damage',  0.40),
    ('carefree_wisdom_heart',   'cultivation_rate', 1.00)
) AS v (code, effect, weight)
JOIN physiques p       ON p.code = v.code
JOIN physique_power pw ON pw.tier = p.tier
JOIN gu_effects e      ON e.code = v.effect;


-- ---------------------------------------------------------------------------
-- The bodies that resist a Path
-- ---------------------------------------------------------------------------
-- Eight of them, and the promises were already written as percentages. Two
-- steps of resistance per rank puts Flameblood at the +10% it claimed and
-- Northern Dark Ice at +60%, which is more than the +50% it claimed - the
-- point of this migration being that a rolled body should be worth rolling.
--
-- A row may already exist here: a body with a Path affinity has one. So the
-- resistance is merged in rather than inserted over the top.

INSERT INTO physique_path_bonuses (physique_id, path_code, resistance)
SELECT p.physique_id, v.path, round(0.02 * pw.ranks, 4)
FROM (VALUES
    ('flameblood_physique',     'fire'),
    ('frostblood_physique',     'ice'),
    ('iron_bone_physique',      'strength'),
    ('jade_skin_physique',      'poison'),
    ('charnel_body',            'poison'),
    ('sword_bone_physique',     'sword'),
    ('thunderbone_physique',    'lightning'),
    ('northern_dark_ice_soul',  'ice')
) AS v (code, path)
JOIN physiques p       ON p.code = v.code
JOIN physique_power pw ON pw.tier = p.tier
ON CONFLICT (physique_id, path_code) DO UPDATE
    SET resistance = EXCLUDED.resistance;


-- ---------------------------------------------------------------------------
-- Saying so
-- ---------------------------------------------------------------------------
-- Eleven of these bodies never had a special_name at all - they were a line of
-- jsonb and three multipliers. A body that does something has to say what.

UPDATE physiques SET special_name = v.nm, special_text = v.txt
FROM (VALUES
    ('flexible_meridian_body', 'Loose in the Joints',
     'Nothing about this body is quite where a blow expects it, and the qi moves as freely as the rest of it.'),
    ('lightfoot_body', 'Light On It',
     'Weight is a thing this body puts down only when it has to.'),
    ('mirage_lantern_body', 'Hard to Fix',
     'Clearly there, at a distance, and less clearly the longer anybody looks.'),
    ('orchard_body', 'Well Fed',
     'Grown rather than tempered, and there is simply more of it than there was.'),
    ('flameblood_physique', 'Blood Runs Hot',
     'Fire has been through this body already and found nothing left to take.'),
    ('frostblood_physique', 'Blood Runs Cold',
     'Cold is a condition this body is in, not one it can be put into.'),
    ('iron_bone_physique', 'Iron in the Frame',
     'Raw force arrives and finds the frame has been expecting it.'),
    ('jade_skin_physique', 'Jade Does Not Take a Stain',
     'Venom sits on the surface of this body and stays there.'),
    ('blood_tyrant_body', 'Takes It Back',
     'Every wound this body opens in something else is a wound it closes in itself.'),
    ('sword_bone_physique', 'Edge Against Edge',
     'Built around a blade, and unimpressed by other people''s.'),
    ('thunderbone_physique', 'Faster Than the Strike',
     'Lightning is quick. This body has been told so and disagrees.')
) AS v (code, nm, txt)
WHERE physiques.code = v.code;

-- Three that had a name and a promise the engine now keeps in a different
-- currency than the one it was written in. 0053 rewrote Supreme Dao's line
-- when it modelled it; the same rule applies here.
UPDATE physiques SET special_text = v.txt
FROM (VALUES
    ('iron_kiln_body',
     'A body fired rather than forged. What will not sit together in anybody else''s crucible sits together in this one.'),
    ('cutpurse_body',
     'Quick in the way that matters, which is the last six inches. It comes back from everywhere with more than it went out with.'),
    ('charnel_body',
     'There is not much left in here for a venom to ruin, and what there is has been ruined already.')
) AS v (code, txt)
WHERE physiques.code = v.code;


-- ---------------------------------------------------------------------------
-- What is still owed
-- ---------------------------------------------------------------------------
-- Cleared where the promise is now kept in full; trimmed to the remaining
-- clauses where a body still claims something the engine cannot pay. Nothing
-- is deleted merely because it has become inconvenient to admit.

UPDATE physiques SET unmodelled = '{}'::jsonb
WHERE code IN (
    'flexible_meridian_body', 'lightfoot_body', 'mirage_lantern_body',
    'cutpurse_body', 'flameblood_physique', 'frostblood_physique',
    'iron_bone_physique', 'iron_kiln_body', 'jade_skin_physique',
    'blood_tyrant_body', 'charnel_body', 'night_wandering_body',
    'sword_bone_physique', 'thunderbone_physique',
    'long_odds_body', 'heavenly_giant_body', 'void_sovereign_body',
    'primordial_chaos_body', 'northern_dark_ice_soul'
);

UPDATE physiques SET unmodelled = v.left_owing::jsonb
FROM (VALUES
    ('orchard_body',
     '{"Food and herb consumables": "restore a little more"}'),
    ('endless_ocean_body',
     '{"Guarding": "restores 6% of battle Qi, once an encounter"}'),
    ('heavenly_battle_body',
     '{"Damage to beasts": "+4%"}'),
    ('mountain_king_body',
     '{"Damage taken above 60% HP": "a further reduction while mostly whole"}'),
    ('phoenix_rebirth_body',
     '{"Guard": "5 points weaker", "On a kill": "5% battle Qi returned", "Below 50% HP": "a further +11% strength"}'),
    ('puppet_array_body',
     '{"A bound creature and a formation": "may be held together"}'),
    ('celestial_emperor_body',
     '{"At encounter start": "the lowest foundation stat gains 7%"}'),
    ('heaven_defying_body',
     '{"Breakthrough backlash": "reduced, never removed"}'),
    ('ink_skin_body',
     '{"A wound": "may be redrawn rather than healed"}'),
    ('celestial_sovereign_body',
     '{"At encounter start": "the creature''s weakness is already known, without spending Observe"}'),
    ('chaos_immortal_body',
     '{"Path resistances against this body": "bite less"}'),
    ('eternal_dragon_body',
     '{"Dragon Might": "builds in stacks over a fight rather than being carried into it", "At full stacks": "Transformation techniques gain an effect"}'),
    ('heaven_and_earth_physique',
     '{"Healing below 30% HP": "-3%", "Armour penetration against this body": "cannot take defence below half"}'),
    ('infinite_immortal_body',
     '{"Once a battle": "a lethal blow leaves 1 HP and breaks the engagement instead", "Space techniques": "a chance to cost no Qi"}'),
    ('primordial_origin_body',
     '{"Every realm crossed": "two foundation stats rise permanently"}'),
    ('blazing_glory_lightning_brilliance',
     '{"Fire + Lightning dual-Path damage": "a further +25%"}'),
    ('carefree_wisdom_heart',
     '{"Technique comprehension": "+30%", "Attainment breakthrough chance": "+15%"}')
) AS v (code, left_owing)
WHERE physiques.code = v.code;
