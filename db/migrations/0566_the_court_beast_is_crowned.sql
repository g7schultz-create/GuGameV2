-- 0566_the_court_beast_is_crowned
--
-- The Vault's beast egg was the one prize that did not sit above its own
-- ceiling. Everything else the room pays is a rung past what the world gives:
--
--     equipment   forge stops at tier 9     the Vault pays tier 10
--     pages       drops stop at tier 7      the Vault pays tier 13
--     Gu          the world stops at 5      the Vault pays rank 9
--     essence     --                        Yellow Apricot, the deepest
--     beast egg   eggs stop at tier 9       the Vault paid tier 9
--
-- So it read as an ordinary apex egg with a lucky rarity roll, which is what
-- it was. Four things, all asked for.
--
-- 1. TIER 10, and the dead variable that was meant to say so. The function
--    worked out the deepest ore tier, clamped it, put it in `deep` - and then
--    passed a literal:
--
--        SELECT GREATEST(1, LEAST(9, max(o.tier))) INTO deep FROM ores o;
--        RETURN grant_beast_egg(p_player_id, who, 9::smallint, band, ...);
--                                                 ^^^ `deep` discarded
--
--    Harmless while `max(ores.tier)` is exactly 9 - the literal and the
--    variable agreed - and wrong for the reason this migration exists: the
--    ceiling it should have been reading is the EGG ladder's, not the ore
--    ladder's, and neither is 10. It now reads the egg ceiling and goes one
--    past it, so the next time a ceiling moves this follows.
--
-- 2. AND IT IS ALREADY STRONGER FOR IT, with no new arithmetic. Tier enters a
--    pet's power as an EXPONENT:
--
--        base_attack * creature_defense_scale_per_rank ^ (tier - species rank)
--
--    A Court beast is rank 9, so at tier 9 that exponent is zero and the tier
--    bought nothing at all. At tier 10 it is one, and the knob is 4 - so the
--    crowned beast hits FOUR TIMES as hard and carries four times the health
--    of the same beast at tier 9, at every stage of its growth.
--
-- 3. A NAME THAT SAYS WHAT IT IS. `hatched_beast_name` put a quality word in
--    front by rarity - Goldshell, Starshell, Primordial. A beast out of the
--    Heavenly Court is not a rarity, it is a provenance, so it takes a royal
--    title ahead of the quality word: 'Sovereign Goldshell Cloud Qilin'. The
--    title is picked from the species so the same beast always reads the same
--    way rather than being re-rolled on every screen.
--
-- 4. AND IT EATS LIKE ONE. Feed cost was `feed_per_tier * tier`, so tier 10
--    cost 11% more than tier 9 - which is not what being a rung past the
--    world should mean. A beast above the ordinary ceiling now pays
--    `beast_royal_feed_multiple` on top, which is EIGHT. At the Yellow Apricot
--    stage that is 65.6 billion of a material becoming 583 billion.
--
--    Deliberately steep, and deliberately only on the last tier: nothing any
--    existing beast eats changes by a single unit, because every beast alive
--    is tier 9 or below and the surcharge is written to bite only above that.


-- ---------------------------------------------------------------------------
-- 1. The ladder admits a tenth rung
-- ---------------------------------------------------------------------------

ALTER TABLE player_beast_eggs DROP CONSTRAINT player_beast_eggs_tier_check;
ALTER TABLE player_beast_eggs ADD CONSTRAINT player_beast_eggs_tier_check
    CHECK (tier >= 1 AND tier <= 10);

ALTER TABLE player_beasts DROP CONSTRAINT player_beasts_tier_check;
ALTER TABLE player_beasts ADD CONSTRAINT player_beasts_tier_check
    CHECK (tier >= 1 AND tier <= 10);

INSERT INTO game_config (key, value, description) VALUES
    ('beast_egg_tier_ceiling', 9,
     'The deepest tier the WORLD puts in an egg. The Vault of Unclaimed Dao pays one past it, the way it pays a tier past the forge and six past the page table - so this is the number that decides what "past it" means rather than a literal in a function.'),
    ('beast_royal_feed_multiple', 8,
     'What a beast above `beast_egg_tier_ceiling` pays on top of the ordinary feed cost. Tier alone multiplies the cost by a ninth, which is not what a rung past the world should mean. Bites only above the ceiling, so nothing already hatched changes.');


-- ---------------------------------------------------------------------------
-- 2. A title for a beast that came out of the Court
-- ---------------------------------------------------------------------------

CREATE TABLE beast_royal_titles (
    sort_order SMALLINT PRIMARY KEY,
    word       TEXT NOT NULL UNIQUE
);

COMMENT ON TABLE beast_royal_titles IS
    'Titles for a beast above the ordinary egg ceiling. Picked by species rather than rolled, so one beast always reads the same way on every screen.';

INSERT INTO beast_royal_titles (sort_order, word) VALUES
    (1, 'Sovereign'), (2, 'Imperial'),  (3, 'Crowned'),
    (4, 'Throned'),   (5, 'Anointed'),  (6, 'Diademed'),
    (7, 'Regnal'),    (8, 'Scepterborn');


-- `hatched_beast_name` has one caller - `hatch_egg` - so widening it is a
-- DROP and CREATE rather than a defaulted argument, which would have left two
-- signatures and an ambiguous call.
DROP FUNCTION IF EXISTS hatched_beast_name(BIGINT, TEXT);

CREATE FUNCTION hatched_beast_name(
    p_species_id BIGINT, p_rarity TEXT, p_tier SMALLINT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    -- Royal title, then the quality word, then the beast. The title only
    -- appears above the ordinary ceiling, so every beast that exists today
    -- reads exactly as it did.
    SELECT COALESCE(
               (SELECT t.word || ' '
                FROM beast_royal_titles t
                WHERE p_tier > game_config_value('beast_egg_tier_ceiling')
                  -- By species, not at random: a name that changed every time
                  -- it was drawn would not be a name.
                  AND t.sort_order = 1 + (cs.species_id %
                      (SELECT count(*) FROM beast_royal_titles))),
               '')
           || COALESCE(q.word || ' ', '')
           || cs.name
    FROM creature_species cs
    LEFT JOIN egg_qualities q ON q.rarity = p_rarity
    WHERE cs.species_id = p_species_id;
$fn$;


DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'hatch_egg' AND pronamespace = 'public'::regnamespace;

    IF position('hatched_beast_name(egg.species_id, egg.rarity)' IN src) = 0 THEN
        RAISE EXCEPTION 'hatch_egg does not name the beast where it did';
    END IF;
    patched := replace(src,
        'hatched_beast_name(egg.species_id, egg.rarity)',
        'hatched_beast_name(egg.species_id, egg.rarity, egg.tier)');
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- 3. And it eats like one
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION beast_feed_needed(p_beast_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- What the NEXT stage costs this beast, or NULL at the end of the ladder.
    --
    -- The surcharge bites only ABOVE `beast_egg_tier_ceiling`, so every beast
    -- that exists pays exactly what it paid before - tier 9 and below reach
    -- the CASE's ELSE and multiply by one.
    SELECT next.feed_per_tier * b.tier
           * CASE WHEN b.tier > game_config_value('beast_egg_tier_ceiling')
                  THEN game_config_value('beast_royal_feed_multiple')
                  ELSE 1 END
    FROM player_beasts b
    JOIN beast_stages here ON here.code = b.stage
    JOIN beast_stages next ON next.sort_order = here.sort_order + 1
    WHERE b.beast_id = p_beast_id;
$fn$;


-- ---------------------------------------------------------------------------
-- 4. The clamp that was the real ceiling
--
-- `grant_beast_egg` ends in `GREATEST(1, LEAST(9, p_tier))`, so the tier the
-- Vault asked for never mattered - a literal nine written when nine was the
-- top of the ladder. The same stale-ceiling shape as the dungeon's rank 18,
-- the forge's tier 8 and the page table's tier 7.
--
-- Widened to what the TABLE allows rather than to what the world ordinarily
-- lays, because that is this function's job: it is the generic granter, and
-- the world ceiling is already enforced one level up - `roll_beast_egg`
-- clamps its own grade to `LEAST(9, p_tier)` before it ever calls here. So an
-- ordinary egg is still capped at 9 by the function that rolls it.
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'grant_beast_egg' AND pronamespace = 'public'::regnamespace;

    IF position('GREATEST(1, LEAST(9, p_tier))::smallint' IN src) = 0 THEN
        RAISE EXCEPTION 'grant_beast_egg does not clamp the tier where it did';
    END IF;

    patched := replace(src,
        'GREATEST(1, LEAST(9, p_tier))::smallint',
        'GREATEST(1, LEAST((game_config_value(''beast_egg_tier_ceiling'') + 1)::int,
                               p_tier))::smallint');

    IF patched = src THEN
        RAISE EXCEPTION 'the grant_beast_egg patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- 5. The egg itself, reading the ceiling instead of a literal
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src     TEXT;
    patched TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'roll_venerable_egg' AND pronamespace = 'public'::regnamespace;

    IF position('SELECT GREATEST(1, LEAST(9, max(o.tier)))::smallint INTO deep FROM ores o;'
                IN src) = 0 THEN
        RAISE EXCEPTION 'roll_venerable_egg does not compute the tier it ignores';
    END IF;

    patched := replace(src,
'    SELECT GREATEST(1, LEAST(9, max(o.tier)))::smallint INTO deep FROM ores o;

    RETURN grant_beast_egg(p_player_id, who, 9::smallint, band,
                           ''heavenly_court'');',
'    -- ONE PAST WHAT THE WORLD LAYS. This read the deepest ORE tier into
    -- `deep` and then passed a literal 9, so the variable was dead and the
    -- ladder it consulted was the wrong one - ore has nothing to do with what
    -- is inside an egg. The egg ceiling is the number that matters, and the
    -- Vault pays a rung past it exactly as it does for gear and pages.
    deep := (game_config_value(''beast_egg_tier_ceiling'') + 1)::smallint;

    RETURN grant_beast_egg(p_player_id, who, deep, band, ''heavenly_court'');');

    IF patched = src THEN
        RAISE EXCEPTION 'the roll_venerable_egg patch changed nothing';
    END IF;
    EXECUTE patched;
END
$patch$;


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_egg   BIGINT;
    v_tier  SMALLINT;
    v_name  TEXT;
    v_sp    BIGINT;
    v_beast BIGINT;
    v_cost  NUMERIC;
    v_was   NUMERIC;
    v_atk   NUMERIC;
    v_atk9  NUMERIC;
BEGIN
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-2201, 'crown-probe') RETURNING player_id INTO v_who;

        -- 1. THE VAULT LAYS A TENTH-TIER EGG, and the dead variable is gone.
        v_egg := roll_venerable_egg(v_who);
        IF v_egg IS NULL THEN
            RAISE NOTICE 'the Court holds no egg-laying beast, nothing asserted';
        ELSE
            SELECT tier, species_id INTO v_tier, v_sp
            FROM player_beast_eggs WHERE egg_id = v_egg;

            IF v_tier <> 10 THEN
                RAISE EXCEPTION 'the Court egg came out at tier %', v_tier;
            END IF;

            -- 2. AND IT IS NAMED LIKE ONE.
            v_name := hatched_beast_name(v_sp, 'legendary', v_tier);
            IF NOT EXISTS (SELECT 1 FROM beast_royal_titles t
                           WHERE v_name LIKE t.word || ' %') THEN
                RAISE EXCEPTION 'a tier 10 beast hatched as "%"', v_name;
            END IF;
            RAISE NOTICE 'the Court egg hatches as "%"', v_name;

            -- 3. AND AN ORDINARY BEAST IS NAMED EXACTLY AS BEFORE.
            IF EXISTS (SELECT 1 FROM beast_royal_titles t
                       WHERE hatched_beast_name(v_sp, 'legendary', 9::smallint)
                             LIKE t.word || ' %') THEN
                RAISE EXCEPTION 'a tier 9 beast was crowned as well';
            END IF;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 4. NOTHING ALREADY HATCHED PAYS A PENNY MORE. The surcharge is written
    --    to bite above the ceiling only, and every beast alive is below it.
    IF EXISTS (
        SELECT 1 FROM player_beasts b
        JOIN beast_stages here ON here.code = b.stage
        JOIN beast_stages next ON next.sort_order = here.sort_order + 1
        WHERE b.tier <= game_config_value('beast_egg_tier_ceiling')
          AND beast_feed_needed(b.beast_id)
              IS DISTINCT FROM next.feed_per_tier * b.tier
    ) THEN
        RAISE EXCEPTION 'an existing beast''s feed cost moved';
    END IF;
    RAISE NOTICE
        '% beast(s) already hatched, none of them pay more',
        (SELECT count(*) FROM player_beasts);
END
$probe$;
