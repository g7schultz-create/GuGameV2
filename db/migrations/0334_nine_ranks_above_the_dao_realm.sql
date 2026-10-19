-- 0334_nine_ranks_above_the_dao_realm
--
-- Five cultivators are sitting on Dao Realm - Peak with nothing above them.
-- This is the ladder they climb next: nine Gu Immortal ranks, four stages
-- each, thirty-six realms, and a fuel that is not a pill.
--
-- IMMORTAL ESSENCE IS THE FUEL. Nine kinds, one to a rank, and the four the
-- game is really built around stand a hundred apart from each other:
--
--     1 Yellow Apricot = 100 White Litchi = 10,000 Red Date
--                      = 1,000,000 Green Grape
--
-- The five beneath Green Grape step by three a rank, which is what makes the
-- whole ladder fit. More on that below - it is the one place where the shape
-- of the thing was decided by arithmetic rather than by taste.
--
-- EVERY STAGE COSTS THE SAME NUMBER OF ITS OWN ESSENCE. That is the rule the
-- whole ladder is built from: `essence_per_stage` of the essence belonging to
-- the rank you are standing in. It means a player never has to read a table
-- to know what a stage costs, and it means the requirement curve is not a
-- second set of numbers that can drift away from the first - the curve IS the
-- essence ladder, multiplied out.
--
--     cultivation_required(rank, stage)
--         = Dao Realm - Peak
--         + essence_per_stage x essence_cultivation_rate
--           x (4 x every lower immortal rank's value + stage x this one's)
--
-- WHY THE LOWER FIVE STEP BY THREE AND NOT BY A HUNDRED. `cultivation` is a
-- bigint and Dao Realm - Peak already stands at 11,732,263,997. The top four
-- essences are fixed a hundred apart by the design, which is a span of a
-- million on its own; the five below them have to fit what is left of the
-- column underneath that. Stepping them by three puts the whole essence
-- ladder at 243,000,000 to one, and the deepest realm at about 4.9 x 10^18 -
-- inside the bigint ceiling of 9.2 x 10^18 with room to spare. Stepping them
-- by five would overflow it. The probe at the foot of this migration checks
-- the ceiling rather than trusting the sum above.
--
-- WHAT THIS MIGRATION DOES NOT DO. Nothing drops essence yet - that is
-- deliberate, and blessed lands, the black and white heavens and rogue
-- immortals are where it will come from. Absorbing it, and the door closing
-- on pills, are 0335. This migration is only the shape of the thing.
--
-- TWO CEILINGS HAD TO MOVE, and the second is not obvious. `realms_rank_check`
-- is the expected one. The other is `player_destinies_rank_check`: crossing a
-- rank calls `destiny_offer(player, rank)`, which INSERTs into
-- player_destinies with that rank, and that table refuses anything above 9.
-- Left alone, the first cultivator to reach for rank 10 would have had the
-- whole breakthrough refused by a constraint on a table about fate.
--
-- The other ten rank <= 9 constraints in this schema are left exactly as they
-- are. They are about techniques, creatures, Gu, manuals, dungeons, hordes
-- and bodies, and none of them wants to know that a cultivator went past the
-- Dao Realm. `horde_open` already clamps the tide it opens with LEAST(9, ...),
-- so an immortal in the room cannot ask for a rank 18 horde.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE realms DROP CONSTRAINT realms_rank_check;
ALTER TABLE realms ADD CONSTRAINT realms_rank_check
    CHECK (rank >= 1 AND rank <= 18);

ALTER TABLE player_destinies DROP CONSTRAINT player_destinies_rank_check;
ALTER TABLE player_destinies ADD CONSTRAINT player_destinies_rank_check
    CHECK (rank >= 2 AND rank <= 18);

ALTER TABLE materials DROP CONSTRAINT materials_category_check;
ALTER TABLE materials ADD CONSTRAINT materials_category_check
    CHECK (category = ANY (ARRAY['gathering', 'beast', 'currency', 'essence']));


INSERT INTO game_config (key, value, description) VALUES
    ('essence_per_stage', 25,
     'How much of a rank own immortal essence one stage of that rank costs. '
     'The same number at every rank, so a cultivator never has to look up '
     'what a stage wants - only which essence their rank drinks.'),
    ('essence_cultivation_rate', 200000000,
     'Cultivation granted per point of essence VALUE absorbed. Dewberry is '
     'worth one, so a Dewberry is worth this; a Yellow Apricot is worth '
     '243,000,000 of them and grants that many times as much. The tiers are '
     'denominations - a rarer essence is exactly as much harder to find as it '
     'is worth, so no tier is the efficient one to farm.');


-- ---------------------------------------------------------------------------
-- The nine essences, and what each is worth against the others
-- ---------------------------------------------------------------------------

CREATE TABLE immortal_essences (
    rank          SMALLINT PRIMARY KEY,
    material_code TEXT NOT NULL UNIQUE REFERENCES materials(code) ON DELETE RESTRICT,
    unit_value    BIGINT NOT NULL,
    CONSTRAINT immortal_essences_rank_check CHECK (rank >= 10 AND rank <= 18),
    CONSTRAINT immortal_essences_value_check CHECK (unit_value > 0)
);

COMMENT ON TABLE immortal_essences IS
    'One essence to an immortal rank, and what a unit of it is worth against the rest.';
COMMENT ON COLUMN immortal_essences.unit_value IS
    'Relative worth, Dewberry = 1. The top four stand a hundred apart: 1 Yellow Apricot = 100 White Litchi = 10,000 Red Date = 1,000,000 Green Grape.';


INSERT INTO materials (code, name, category, rarity, emoji, description) VALUES
    ('dewberry_essence', 'Dewberry Essence', 'essence', 'rare', '🫐',
     'Pale blue-white, and cold in the hand. The first thing a mortal aperture cannot hold.'),
    ('jade_plum_essence', 'Jade Plum Essence', 'essence', 'rare', '🫒',
     'Light jade, and faintly sweet. Immortals speak of the smell before the taste.'),
    ('purple_mulberry_essence', 'Purple Mulberry Essence', 'essence', 'epic', '🟣',
     'Deep violet. It stains what it touches and the stain does not come out.'),
    ('golden_peach_essence', 'Golden Peach Essence', 'essence', 'epic', '🍑',
     'Golden-orange and slow-moving, like honey that has not decided to fall.'),
    ('blood_cherry_essence', 'Blood Cherry Essence', 'essence', 'legendary', '🍒',
     'Crimson, and warm. Nobody has satisfactorily explained why it is warm.'),
    ('green_grape_essence', 'Green Grape Immortal Essence', 'essence', 'legendary', '🟢',
     'The unit every immortal prices the others against. A hundred of these is one Red Date.'),
    ('red_date_essence', 'Red Date Immortal Essence', 'essence', 'mythic', '🔴',
     'A hundred Green Grapes pressed into one. The pressing is the hard part.'),
    ('white_litchi_essence', 'White Litchi Immortal Essence', 'essence', 'divine', '⚪',
     'Ten thousand Green Grapes. Whole sects have been founded on less.'),
    ('yellow_apricot_essence', 'Yellow Apricot Immortal Essence', 'essence', 'extreme', '🟡',
     'A million Green Grapes in a single bead. Venerables have gone to war over one.');


INSERT INTO immortal_essences (rank, material_code, unit_value) VALUES
    (10, 'dewberry_essence',              1),
    (11, 'jade_plum_essence',             3),
    (12, 'purple_mulberry_essence',       9),
    (13, 'golden_peach_essence',         27),
    (14, 'blood_cherry_essence',         81),
    (15, 'green_grape_essence',         243),
    (16, 'red_date_essence',           24300),
    (17, 'white_litchi_essence',     2430000),
    (18, 'yellow_apricot_essence', 243000000);


-- ---------------------------------------------------------------------------
-- Thirty-six realms, priced in the essence each of them drinks
-- ---------------------------------------------------------------------------

INSERT INTO realms
    (realm_id, code, name, rank, stage,
     cultivation_required, essence_capacity, qi_capacity, gu_capacity)
SELECT
    35 + (e.rank - 10) * 4 + s.n,
    replace(replace(m.code, '_essence', ''), ' ', '_') || '_' || s.stage,
    replace(m.name, ' Immortal Essence', '')
        || CASE WHEN m.name LIKE '%Immortal Essence' THEN '' ELSE '' END,
    e.rank,
    s.stage,
    -- Dao Realm - Peak, then every stage of every rank up to this one, each
    -- costing `essence_per_stage` of its own rank's essence.
    (SELECT r.cultivation_required FROM realms r WHERE r.realm_id = 35)
    + game_config_value('essence_per_stage')::bigint
      * game_config_value('essence_cultivation_rate')::bigint
      * (4 * COALESCE((SELECT sum(lower.unit_value) FROM immortal_essences lower
                       WHERE lower.rank < e.rank), 0)
         + s.n * e.unit_value),
    256000::bigint * power(2, e.rank - 9)::bigint,
    128000::bigint * power(2, e.rank - 9)::bigint,
    (e.rank + CASE WHEN s.stage = 'peak' THEN 3 ELSE 2 END)::smallint
FROM immortal_essences e
JOIN materials m ON m.code = e.material_code
CROSS JOIN (VALUES (1, 'early'), (2, 'middle'), (3, 'late'), (4, 'peak'))
    AS s (n, stage);

-- The name wants the essence in it and not the word 'Essence'. Done as an
-- update rather than wrestled into the SELECT above, where it was unreadable.
UPDATE realms r
SET name = replace(replace(m.name, ' Immortal Essence', ''), ' Essence', '')
           || ' Immortal — '
           || CASE r.stage WHEN 'early' THEN 'Early' WHEN 'middle' THEN 'Mid'
                           WHEN 'late' THEN 'Late' ELSE 'Peak' END
FROM immortal_essences e
JOIN materials m ON m.code = e.material_code
WHERE r.rank = e.rank AND r.rank >= 10;


-- ---------------------------------------------------------------------------
-- The ladder is whole, climbs, and fits in the column that holds it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    gaps    INTEGER;
    n       INTEGER;
    deepest BIGINT;
    bad     TEXT;
BEGIN
    -- Contiguous realm_ids, or `breakthrough` (which walks realm_id + 1)
    -- would strand somebody on a rung with nothing above it.
    SELECT count(*) INTO gaps
    FROM realms a
    WHERE a.realm_id < (SELECT max(realm_id) FROM realms)
      AND NOT EXISTS (SELECT 1 FROM realms b WHERE b.realm_id = a.realm_id + 1);
    IF gaps > 0 THEN
        RAISE EXCEPTION 'the ladder has % gap(s) in it', gaps;
    END IF;

    SELECT count(*) INTO n FROM realms WHERE rank >= 10;
    IF n <> 36 THEN
        RAISE EXCEPTION 'expected 36 immortal realms, built %', n;
    END IF;

    -- Every rung strictly harder than the one below it.
    SELECT string_agg(a.name, ', ') INTO bad
    FROM realms a JOIN realms b ON b.realm_id = a.realm_id - 1
    WHERE a.cultivation_required <= b.cultivation_required;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rungs do not climb: %', bad;
    END IF;

    -- And the deepest one is inside a bigint with room left. This is the
    -- check the lower five essences were stepped by three to satisfy.
    SELECT max(cultivation_required) INTO deepest FROM realms;
    IF deepest > 9000000000000000000 THEN
        RAISE EXCEPTION 'the deepest realm asks % and a bigint holds 9.2e18',
            deepest;
    END IF;

    -- The essence ladder says what the design says it says.
    IF (SELECT unit_value FROM immortal_essences WHERE rank = 18)
       <> 1000000 * (SELECT unit_value FROM immortal_essences WHERE rank = 15) THEN
        RAISE EXCEPTION 'a Yellow Apricot is not a million Green Grapes';
    END IF;
    IF (SELECT unit_value FROM immortal_essences WHERE rank = 17)
       <> 100 * (SELECT unit_value FROM immortal_essences WHERE rank = 16) THEN
        RAISE EXCEPTION 'a White Litchi is not a hundred Red Dates';
    END IF;

    RAISE NOTICE
        'thirty-six immortal realms; the deepest asks % and holds inside a bigint',
        deepest;
END;
$probe$;
