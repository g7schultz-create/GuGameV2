-- 0282_a_beast_hatches_small_and_is_raised
--
-- A beast came out of its shell at full strength, which made an egg a lottery
-- ticket rather than a thing you raise. It hatches as a baby now and is fed up
-- through four stages:
--
--     baby      quarter strength   what comes out of the shell
--     juvenile  half
--     adult     full               what a hatched beast used to be
--     elder     three fifths more  further than one could reach before
--
-- WHAT IT EATS is three of the things this game already has too many of at
-- the low end: cultivation pills, beast materials, and ore. Nourishment is the
-- square of the grade, the same curve the forge prices its metals on, so
-- depth counts for more than volume without volume counting for nothing - a
-- pile of tier 1 ore raises a baby, and only a baby.
--
--     ore            tier ^ 2
--     beast material grade ^ 2
--     cultivation pill  tier ^ 2 x pet_pill_nourishment
--
-- Pills are worth more per unit because somebody brewed them, and because a
-- Cultivation pill fed to a beast is the plainest reading of what the thing
-- is for.
--
-- WHAT IT COSTS scales with the beast's tier: a tier 9 beast is a longer
-- project than a tier 1, which is the same thing its tier says everywhere
-- else. Reaching elder on a tier 9 is 2,880 nourishment - about a hundred
-- and fifteen pieces of tier 5 ore, or rather fewer good pills.
--
-- THE FOURTEEN ALREADY HATCHED KEEP WHAT THEY HAVE. They were hatched under
-- the old rule, at what is now adult, and demoting them to quarter strength
-- would be taking something back that people already went and got. New eggs
-- hatch small; those fourteen start at adult and may still be raised to elder.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE beast_stages (
    code       TEXT PRIMARY KEY,
    name       TEXT     NOT NULL,
    sort_order SMALLINT NOT NULL UNIQUE,
    power      NUMERIC(4,2) NOT NULL CHECK (power > 0),
    -- Nourishment to REACH this stage, per tier of the beast. The first stage
    -- is what hatches, so it costs nothing.
    feed_per_tier INTEGER NOT NULL CHECK (feed_per_tier >= 0)
);

INSERT INTO beast_stages (code, name, sort_order, power, feed_per_tier) VALUES
    ('baby',     'Baby',     1, 0.25,   0),
    ('juvenile', 'Juvenile', 2, 0.50,  30),
    ('adult',    'Adult',    3, 1.00,  90),
    ('elder',    'Elder',    4, 1.60, 240);

COMMENT ON TABLE beast_stages IS
    'What a beast grows through. `power` multiplies its attack; `feed_per_tier` is what reaching the stage costs, times the beast''s own tier.';


INSERT INTO game_config (key, value, description) VALUES
    ('pet_pill_nourishment', 4,
     'How much more a cultivation pill is worth to a growing beast than a '
     'piece of ore or bone of the same grade. Somebody brewed it.');


ALTER TABLE player_beasts
    ADD COLUMN stage TEXT NOT NULL DEFAULT 'baby' REFERENCES beast_stages (code),
    ADD COLUMN fed   NUMERIC NOT NULL DEFAULT 0 CHECK (fed >= 0);

CREATE INDEX player_beasts_stage_idx ON player_beasts (stage);

COMMENT ON COLUMN player_beasts.fed IS
    'Nourishment banked toward the next stage. Reset each time one is reached, so it reads as progress rather than a lifetime total.';


-- The fourteen hatched before there were stages were hatched at full
-- strength. That is `adult`, and it is theirs.
UPDATE player_beasts SET stage = 'adult' WHERE hatched_at < now();


-- ---------------------------------------------------------------------------
-- What a mouthful is worth
-- ---------------------------------------------------------------------------

CREATE FUNCTION beast_food_value(p_material_code TEXT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Ore by its tier, anything off a beast by its grade. Squared, the way
    -- the forge prices what goes on its anvil.
    SELECT CASE
        WHEN o.material_code IS NOT NULL THEN o.tier::numeric ^ 2
        WHEN bp.material_code IS NOT NULL THEN material_grade(m.rarity)::numeric ^ 2
        ELSE 0
    END
    FROM materials m
    LEFT JOIN ores o ON o.material_code = m.code
    LEFT JOIN beast_parts bp ON bp.material_code = m.code
    WHERE m.code = p_material_code;
$$;

COMMENT ON FUNCTION beast_food_value(TEXT) IS
    'What one unit of ore or beast material is worth to a growing beast, or 0 if a beast will not eat it.';


CREATE FUNCTION beast_feed_needed(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- What the NEXT stage costs this beast, or NULL at the end of the ladder.
    SELECT next.feed_per_tier * b.tier
    FROM player_beasts b
    JOIN beast_stages here ON here.code = b.stage
    JOIN beast_stages next ON next.sort_order = here.sort_order + 1
    WHERE b.beast_id = p_beast_id;
$$;

COMMENT ON FUNCTION beast_feed_needed(BIGINT) IS
    'Nourishment still required for the next stage, or NULL for an elder - there is nothing after it.';


-- ---------------------------------------------------------------------------
-- Growing on what it is given
-- ---------------------------------------------------------------------------

CREATE FUNCTION beast_grow(p_beast_id BIGINT, p_nourishment NUMERIC)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    want  NUMERIC;
    grown TEXT := NULL;
BEGIN
    IF p_nourishment <= 0 THEN
        RETURN NULL;
    END IF;

    UPDATE player_beasts SET fed = fed + p_nourishment WHERE beast_id = p_beast_id;

    -- A generous meal may carry it through more than one stage, so this is a
    -- loop rather than one comparison.
    LOOP
        want := beast_feed_needed(p_beast_id);
        EXIT WHEN want IS NULL;                    -- an elder eats for nothing
        EXIT WHEN (SELECT fed FROM player_beasts WHERE beast_id = p_beast_id) < want;

        UPDATE player_beasts b
        SET stage = (SELECT n.code FROM beast_stages n
                     JOIN beast_stages h ON h.code = b.stage
                     WHERE n.sort_order = h.sort_order + 1),
            fed = b.fed - want
        WHERE b.beast_id = p_beast_id
        RETURNING b.stage INTO grown;
    END LOOP;

    RETURN grown;
END;
$$;

COMMENT ON FUNCTION beast_grow(BIGINT, NUMERIC) IS
    'Banks nourishment and advances the beast as far as it carries. Returns the stage it reached, or NULL if it did not reach one.';


CREATE FUNCTION feed_beast(
    p_player_id BIGINT, p_beast_id BIGINT, p_material_code TEXT, p_quantity INTEGER
)
RETURNS TABLE (fed NUMERIC, stage TEXT, grew_to TEXT, still_wants NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    worth NUMERIC;
    grown TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM player_beasts
        WHERE beast_id = p_beast_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that is not your beast' USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_quantity, 0) < 1 THEN
        RAISE EXCEPTION 'feed it something' USING ERRCODE = 'check_violation';
    END IF;
    IF beast_feed_needed(p_beast_id) IS NULL THEN
        RAISE EXCEPTION 'an elder has nothing left to grow into'
            USING ERRCODE = 'check_violation';
    END IF;

    worth := beast_food_value(p_material_code);
    IF COALESCE(worth, 0) <= 0 THEN
        RAISE EXCEPTION 'a beast will not eat that - ore and what comes off other beasts'
            USING ERRCODE = 'check_violation';
    END IF;

    -- `spend_material` refuses rather than going negative, so an unaffordable
    -- meal stops here rather than half way through.
    PERFORM spend_material(p_player_id, p_material_code, p_quantity::bigint);

    grown := beast_grow(p_beast_id, worth * p_quantity);

    RETURN QUERY
    SELECT b.fed, b.stage, grown, beast_feed_needed(p_beast_id)
    FROM player_beasts b WHERE b.beast_id = p_beast_id;
END;
$$;

COMMENT ON FUNCTION feed_beast(BIGINT, BIGINT, TEXT, INTEGER) IS
    'Feeds ore or beast material to one beast. Returns where it now stands and what it still wants.';


CREATE FUNCTION feed_beast_pill(
    p_player_id BIGINT, p_beast_id BIGINT, p_pill_id BIGINT, p_quantity INTEGER
)
RETURNS TABLE (fed NUMERIC, stage TEXT, grew_to TEXT, still_wants NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    pill  RECORD;
    worth NUMERIC;
    grown TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM player_beasts
        WHERE beast_id = p_beast_id AND owner_id = p_player_id
    ) THEN
        RAISE EXCEPTION 'that is not your beast' USING ERRCODE = 'check_violation';
    END IF;
    IF beast_feed_needed(p_beast_id) IS NULL THEN
        RAISE EXCEPTION 'an elder has nothing left to grow into'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO pill FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that pill is not yours' USING ERRCODE = 'check_violation';
    END IF;
    IF pill.kind <> 'cultivation' THEN
        RAISE EXCEPTION 'a beast grows on Cultivation pills, not %', pill.name
            USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_quantity, 0) < 1 OR p_quantity > pill.quantity THEN
        RAISE EXCEPTION 'you hold % of those', pill.quantity
            USING ERRCODE = 'check_violation';
    END IF;

    -- The same delete-if-last dance `take_pill` does: the quantity CHECK
    -- trips before a cleanup DELETE would run.
    IF pill.quantity = p_quantity THEN
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
    ELSE
        UPDATE player_pills SET quantity = quantity - p_quantity
        WHERE pill_id = p_pill_id;
    END IF;

    worth := pill.tier::numeric ^ 2 * game_config_value('pet_pill_nourishment');
    grown := beast_grow(p_beast_id, worth * p_quantity);

    RETURN QUERY
    SELECT b.fed, b.stage, grown, beast_feed_needed(p_beast_id)
    FROM player_beasts b WHERE b.beast_id = p_beast_id;
END;
$$;

COMMENT ON FUNCTION feed_beast_pill(BIGINT, BIGINT, BIGINT, INTEGER) IS
    'Feeds a Cultivation pill to one beast. Worth more per unit than ore because somebody brewed it.';


-- ---------------------------------------------------------------------------
-- A baby hits like a baby
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pet_attack(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1,
        cs.base_attack
        * power(game_config_value('creature_defense_scale_per_rank'),
                GREATEST(0, b.tier - cs.rank))
        * (1 + game_config_value('pet_rarity_step')
               * (SELECT count(*) FROM rarities r2
                  WHERE r2.sort_order < r.sort_order))
        * st.power
        * game_config_value('pet_attack_scale'))
    FROM player_beasts b
    JOIN creature_species cs ON cs.species_id = b.species_id
    JOIN rarities r ON r.code = b.rarity
    JOIN beast_stages st ON st.code = b.stage
    WHERE b.beast_id = p_beast_id;
$$;


-- Appended, not inserted: CREATE OR REPLACE VIEW may only add columns to the
-- end, and putting the stage where it reads best renames every column after it.
CREATE OR REPLACE VIEW player_beast_shelf AS
SELECT b.beast_id, b.owner_id, b.name, b.tier, b.rarity, b.at_heel,
       b.hatched_at,
       cs.name AS species, cs.rank AS species_rank, cs.kind AS species_kind,
       q.emoji, q.word AS shell,
       r.sort_order AS rarity_order,
       p.name AS path_name, p.emoji AS path_emoji,
       round(pet_attack(b.beast_id)) AS attack,
       reg.name AS found_in_name,
       b.stage, b.fed,
       st.name AS stage_name, st.sort_order AS stage_order, st.power AS stage_power,
       beast_feed_needed(b.beast_id) AS wants
FROM player_beasts b
JOIN creature_species cs ON cs.species_id = b.species_id
JOIN rarities r ON r.code = b.rarity
JOIN beast_stages st ON st.code = b.stage
LEFT JOIN egg_qualities q ON q.rarity = b.rarity
LEFT JOIN paths p ON p.code = pet_path(b.beast_id)
LEFT JOIN player_beast_eggs e ON e.egg_id = b.egg_id
LEFT JOIN regions reg ON reg.code = e.found_in;


-- ---------------------------------------------------------------------------
-- It hatches small, and it grows on what it is given
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who    BIGINT;
    egg    BIGINT;
    beast  BIGINT;
    baby   NUMERIC;
    grown  NUMERIC;
    got    RECORD;
    food   TEXT;
BEGIN
    SELECT e.owner_id, e.egg_id INTO who, egg
    FROM player_beast_eggs e
    JOIN players p ON p.player_id = e.owner_id
    WHERE e.hatched_at IS NULL AND p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY e.tier LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no eggs to hatch; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        beast := hatch_egg(who, egg);

        IF (SELECT stage FROM player_beasts WHERE beast_id = beast) <> 'baby' THEN
            RAISE EXCEPTION 'it did not hatch as a baby';
        END IF;

        baby := pet_attack(beast);

        -- The cheapest thing anybody could feed it.
        SELECT o.material_code INTO food FROM ores o ORDER BY o.tier LIMIT 1;
        PERFORM grant_material(who, food, 100000);

        SELECT * INTO got FROM feed_beast(who, beast, food, 100000);

        IF got.stage = 'baby' THEN
            RAISE EXCEPTION 'a hundred thousand mouthfuls raised nothing';
        END IF;

        grown := pet_attack(beast);
        IF grown <= baby THEN
            RAISE EXCEPTION 'growing up made it weaker: % against %', grown, baby;
        END IF;

        -- Fed to the end of the ladder, it stops rather than running off it.
        IF got.stage = 'elder' AND got.still_wants IS NOT NULL THEN
            RAISE EXCEPTION 'an elder is still hungry';
        END IF;

        -- And it will not eat a herb.
        IF beast_food_value('spirit_dew_grass') <> 0 THEN
            RAISE EXCEPTION 'a beast is eating the herb garden';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;


-- ---------------------------------------------------------------------------
-- Nobody's beast was taken back down
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    small INTEGER;
BEGIN
    SELECT count(*) INTO small
    FROM player_beasts WHERE stage <> 'adult';

    IF small > 0 THEN
        RAISE EXCEPTION
            '% beasts hatched before stages existed are no longer adult', small;
    END IF;

    RAISE NOTICE 'all % beasts hatched so far stand at adult',
        (SELECT count(*) FROM player_beasts);
END;
$$;
