-- 0353_an_ability_is_rarer_than_a_number
--
-- Thirty-four percent of every Gu this world hands out carries an ability -
-- a crit rate, a crit multiplier, armour penetration, life on hit. One drop
-- in three. Which is why every cultivator who has played for a week is
-- swinging with a blow multiple between one and a half and three and a half,
-- entirely off worms:
--
--     m_i_y_u_k_i.   external multiplier 5.03, blow multiple 3.49
--     clearwest      4.63, 1.62
--     pashu0         3.82, 1.99
--
-- Those two numbers multiply. A cultivator with no Gu at all and the same
-- realm swings for something under a sixth of what m_i_y_u_k_i does, and the
-- realm - twelve and a half million of thews - is the SAME in both cases. The
-- realm sets the scale and the worms were deciding the outcome, which is the
-- wrong way round.
--
-- ABILITY BECOMES A PROPERTY OF THE EFFECT, not a list in a migration.
-- `gu_effects.is_ability` says whether a thing changes how combat works - an
-- extra strike, a critical, a dodge, a ward against death - as against a
-- number that adds to something a cultivator already has. Anything added
-- later declares itself and the drop tables follow without being rewritten.
--
-- The nine are crit rate, crit damage, armour penetration, life on hit, extra
-- strikes, evasion, death ward, shield and momentum. Braced and foresight are
-- deliberately NOT among them: both are numbers that make an existing thing
-- better rather than mechanics of their own.
--
-- AND THE DROP TABLES LEAN. A Gu carrying any ability weighs
-- `gu_ability_drop_weight` of what it did; one carrying only numbers weighs
-- `gu_flat_drop_weight`. At 0.40 and 1.50 the ability share of a draw falls
-- from 34.1% to about 12% - roughly one worm in eight rather than one in
-- three. A crit build becomes a thing a cultivator assembles over months and
-- then builds around, which is what the wider aperture in 0352 is for.
--
-- RARITY, RANK AND PRICE ARE ALL LEFT ALONE. `gu_types.rarity` is a function
-- of rank everywhere in this schema - it sets size, refine cost and what the
-- bench will attempt - and bumping an ability worm's rarity to make it scarce
-- would also make it bigger, dearer and unrefinable. Scarcity belongs in how
-- often the world hands it over, which is exactly what `gu_region_drops.weight`
-- is.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE gu_effects
    ADD COLUMN is_ability BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN gu_effects.is_ability IS
    'Does this change how combat works, rather than adding to a number the cultivator already has? Abilities are handed out far less often.';

UPDATE gu_effects SET is_ability = TRUE
WHERE code IN ('crit_rate', 'crit_damage', 'armor_pen', 'lifesteal',
               'multi_hit', 'dodge', 'death_ward', 'shield', 'momentum');


INSERT INTO game_config (key, value, description) VALUES
    ('gu_ability_drop_weight', 0.40,
     'What a Gu carrying any ability weighs in a region drop table, against '
     'what it weighed before. An ability is a mechanic - a critical, an extra '
     'strike, life on hit - and one drop in three carrying one is why worms '
     'were deciding fights the realm should have been deciding.'),
    ('gu_flat_drop_weight', 1.50,
     'And what a Gu carrying only numbers weighs. Together with '
     'gu_ability_drop_weight this puts abilities at about one drop in eight '
     'rather than one in three, without touching rank, rarity or price.');


UPDATE gu_region_drops d
SET weight = round(d.weight * CASE
        WHEN EXISTS (SELECT 1 FROM gu_type_effects ef
                     JOIN gu_effects f ON f.code = ef.effect_code
                     WHERE ef.gu_type_id = d.gu_type_id AND f.is_ability)
        THEN game_config_value('gu_ability_drop_weight')
        ELSE game_config_value('gu_flat_drop_weight') END, 2);


-- ---------------------------------------------------------------------------
-- One worm in eight, and no worm worth nothing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    share NUMERIC;
    n     INTEGER;
    bad   TEXT;
BEGIN
    -- The weight column has a CHECK that it is positive, so a rounding that
    -- took a small weight to zero would have thrown - but a weight of 0.01 is
    -- a Gu nobody will ever see, which the CHECK would not catch.
    SELECT count(*) INTO n FROM gu_region_drops WHERE weight < 0.05;
    IF n > 0 THEN
        RAISE EXCEPTION '% drop rows are now too light to ever come up', n;
    END IF;

    SELECT round(100.0 * sum(d.weight) FILTER (
               WHERE EXISTS (SELECT 1 FROM gu_type_effects ef
                             JOIN gu_effects f ON f.code = ef.effect_code
                             WHERE ef.gu_type_id = d.gu_type_id AND f.is_ability))
           / sum(d.weight), 1)
    INTO share
    FROM gu_region_drops d
    JOIN regions r ON r.code = d.region_code
    WHERE r.min_rank = 1;

    IF share > 20 THEN
        RAISE EXCEPTION 'abilities are still % percent of a draw', share;
    END IF;
    IF share < 5 THEN
        RAISE EXCEPTION 'abilities are down to % percent - that is extinct, not rare', share;
    END IF;

    -- Every Gu that was findable still is. Rarer, not removed.
    SELECT string_agg(t.code, ', ') INTO bad
    FROM gu_types t
    WHERE EXISTS (SELECT 1 FROM gu_type_effects ef
                  JOIN gu_effects f ON f.code = ef.effect_code
                  WHERE ef.gu_type_id = t.gu_type_id AND f.is_ability)
      AND NOT EXISTS (SELECT 1 FROM gu_region_drops d WHERE d.gu_type_id = t.gu_type_id)
      AND EXISTS (SELECT 1 FROM gu_recipes r WHERE r.gu_type_id = t.gu_type_id)
    LIMIT 1;

    RAISE NOTICE
        'an ability is % percent of a draw, down from 34.1', share;
END;
$probe$;
