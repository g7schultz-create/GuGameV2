-- 0023_manual_pages
--
-- Manual Pages: the ingredients refinement will consume.
--
-- Nothing drops them yet, and that is deliberate. This migration builds the
-- pages, the roll that mints one, and the two tables a drop entry goes in -
-- but leaves those two tables EMPTY. Adding pages to the drop tables later is
-- then an INSERT, not a schema change, and the roll can be exercised through
-- /dev in the meantime.
--
-- A PAGE IS AN INSTANCE, not a template. Two Tier 4 Fire Attack pages differ
-- by quality and by whether one of them is Resonant, and the design is
-- explicit that individual page quality is one of the anti-meta variables. So
-- there is no "page type" row to point at - `manual_pages` holds one row per
-- page that exists, the same call `manuals` makes.
--
-- POWER IS DENOMINATED IN THE SAME UNITS AS A MANUAL'S TIER BUDGET. A Tier 3
-- page averages 15 power and a Tier 3 manual distributes 15%. That is not a
-- coincidence: refinement sums the powers of its pages, and the total is what
-- decides the finished manual's tier. Keeping the two scales identical means
-- "these four pages are worth about a Tier 5 manual" is arithmetic anyone can
-- do in their head rather than a curve they have to trust.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- page_types
-- ---------------------------------------------------------------------------
-- The ten types, and - the important column - which manual bonus each one
-- feeds. Storing that mapping as data means refinement reads it rather than
-- hardcoding a ten-branch CASE that has to be edited alongside every new
-- bonus column.

CREATE TABLE page_types (
    code         TEXT PRIMARY KEY,
    name         TEXT NOT NULL UNIQUE,

    -- The column on `manuals` this type contributes to.
    manual_column TEXT NOT NULL,

    -- Whether anything consumes that column yet. Four of the ten feed bonuses
    -- with no system behind them; a page that says so is better than one that
    -- quietly makes a dead manual.
    is_live      BOOLEAN NOT NULL DEFAULT TRUE,

    description  TEXT NOT NULL DEFAULT '',
    emoji        TEXT NOT NULL DEFAULT '\N{PAGE FACING UP}',
    roll_weight  NUMERIC(6, 2) NOT NULL DEFAULT 10 CHECK (roll_weight >= 0),
    sort_order   SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO page_types (code, name, manual_column, is_live, description, emoji, roll_weight, sort_order) VALUES
    ('cultivation',  'Cultivation',  'cultivation_rate_bonus', TRUE,
     'Speeds the accumulation of cultivation itself.', '🌿', 18, 10),
    ('attack',       'Attack',       'attack_bonus',           TRUE,
     'Offensive power, applied to everything you throw.', '⚔️', 20, 20),
    ('defense',      'Defense',      'defense_bonus',          TRUE,
     'Mitigation. Worth more the more of it you have.', '🛡️', 12, 30),
    ('vitality',     'Vitality',     'hp_bonus',               TRUE,
     'Maximum HP, and so how many mistakes a fight allows.', '❤️', 10, 40),
    ('gathering',    'Gathering',    'gathering_bonus',        TRUE,
     'Yield from foraging a region.', '🌱', 8, 50),
    ('refinement',   'Refinement',   'refinement_bonus',       FALSE,
     'Refinement bonuses. No refinement skill exists yet.', '🧪', 5, 60),
    ('speed',        'Speed',        'speed_bonus',            FALSE,
     'Action speed. No turn-order system exists yet.', '💨', 10, 70),
    ('breakthrough', 'Breakthrough', 'breakthrough_bonus',     FALSE,
     'Breakthrough chance. Realms currently advance on totals, not rolls.', '🌟', 6, 80),
    ('essence',      'Essence',      'essence_bonus',          FALSE,
     'Primeval essence capacity. Nothing spends essence yet.', '💧', 6, 90),
    ('utility',      'Utility',      'strength_bonus',         TRUE,
     'Odds and ends. Expresses as raw physical force for now.', '📜', 5, 100);

COMMENT ON COLUMN page_types.manual_column IS
    'Which manuals column this page type feeds. Data rather than a CASE in the refiner, so a new bonus is a row.';


-- ---------------------------------------------------------------------------
-- page_tiers
-- ---------------------------------------------------------------------------
-- Power band per tier, and how often each turns up.
--
-- TIERS 8-10 HAVE roll_weight 0. The design is explicit that they do not drop
-- and must be refined into existence. Expressing that as a zero weight rather
-- than as a range check in the roller means the rule is visible in the data,
-- and turning it off later - an inheritance that grants a Tier 8 page, say -
-- is an UPDATE.

CREATE TABLE page_tiers (
    tier        SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 10),
    name        TEXT NOT NULL,

    power_min   SMALLINT NOT NULL CHECK (power_min > 0),
    power_max   SMALLINT NOT NULL,

    roll_weight NUMERIC(6, 2) NOT NULL DEFAULT 0 CHECK (roll_weight >= 0),

    CONSTRAINT page_tiers_power_range CHECK (power_max >= power_min)
);

-- Power midpoints track manual_tiers.bonus_budget exactly: a Tier 3 page
-- averages 15 power, a Tier 3 manual distributes 15%.
INSERT INTO page_tiers (tier, name, power_min, power_max, roll_weight) VALUES
    ( 1, 'Common mortal knowledge',       4,  8, 30),
    ( 2, 'Improved mortal technique',     7, 13, 24),
    ( 3, 'Skilled technique',            11, 19, 18),
    ( 4, 'Sect-level technique',         15, 27, 13),
    ( 5, 'High-grade mortal technique',  20, 36,  8),
    ( 6, 'Rare inheritance technique',   25, 47,  5),
    ( 7, 'Peak naturally obtainable',    32, 58,  2),
    ( 8, 'Refined beyond the drop table',40, 72,  0),
    ( 9, 'Extremely difficult refined',  50, 88,  0),
    (10, 'Pinnacle Mortal World page',   62,106,  0);

COMMENT ON COLUMN page_tiers.roll_weight IS
    'Zero for tiers 8-10: they do not drop and must be refined into existence. A weight rather than a check, so granting one later is an UPDATE.';


-- ---------------------------------------------------------------------------
-- page_traits
-- ---------------------------------------------------------------------------
-- Occasional extras that make one page more interesting loot than another.
-- `harmony_bonus` is what refinement will read; the rest shape the page itself
-- at the moment it is minted.

CREATE TABLE page_traits (
    code           TEXT PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE,
    description    TEXT NOT NULL DEFAULT '',

    -- Flat harmony the trait contributes to a refinement.
    harmony_bonus  SMALLINT NOT NULL DEFAULT 0,

    -- Applied when the page is rolled.
    power_multiplier   NUMERIC(6, 4) NOT NULL DEFAULT 1 CHECK (power_multiplier > 0),
    quality_bonus      SMALLINT NOT NULL DEFAULT 0,

    -- Resonant's effect is conditional on another Resonant page being present,
    -- which no column can express. Flagged so the refiner knows to ask.
    pairs_with_itself  BOOLEAN NOT NULL DEFAULT FALSE,

    roll_weight    NUMERIC(6, 2) NOT NULL DEFAULT 10 CHECK (roll_weight >= 0)
);

INSERT INTO page_traits (code, name, description, harmony_bonus, power_multiplier, quality_bonus, pairs_with_itself, roll_weight) VALUES
    ('ancient',        'Ancient',
     'Older than the sect that kept it. Worth more, and harder to read.',
     -4, 1.2500, 0, FALSE, 12),
    ('pure',           'Pure',
     'One idea, stated once, with nothing else in it.',
     8, 1.0000, 8, FALSE, 14),
    ('corrupted',      'Corrupted',
     'Something has been at it. Some of what it teaches is wrong.',
     -10, 0.9000, -15, FALSE, 12),
    ('bloodstained',   'Bloodstained',
     'The previous owner did not put it down voluntarily.',
     -3, 1.1000, 0, FALSE, 12),
    ('enlightened',    'Enlightened',
     'Annotated by someone who understood it better than its author.',
     10, 1.1000, 10, FALSE, 8),
    ('heaven_touched', 'Heaven-Touched',
     'The ink was not applied by a hand.',
     14, 1.3000, 12, FALSE, 3),
    ('perfect',        'Perfect',
     'No smudge, no gap, no hesitation in the stroke.',
     6, 1.1500, 20, FALSE, 4),
    ('chaotic',        'Chaotic',
     'The order of the pages is a matter of opinion.',
     -14, 1.2000, 0, FALSE, 8),
    ('resonant',       'Resonant',
     'Hums faintly beside another page like it.',
     0, 1.0000, 0, TRUE, 7),
    ('incomplete',     'Incomplete',
     'Ends mid-instruction. Whatever came next was the important part.',
     -6, 0.7500, -10, FALSE, 14);


-- ---------------------------------------------------------------------------
-- manual_pages
-- ---------------------------------------------------------------------------
-- One row per page that exists. Owned outright rather than through a join
-- table, because a page is consumed by refinement - destroyed on a bad roll,
-- absorbed on a good one - and a quantity column would make "which two of my
-- five Fire pages went into that manual" unanswerable.

CREATE TABLE manual_pages (
    page_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    owner_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    tier       SMALLINT NOT NULL REFERENCES page_tiers (tier) ON DELETE RESTRICT,
    path_code  TEXT     NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,
    page_type  TEXT     NOT NULL REFERENCES page_types (code) ON DELETE RESTRICT,
    trait      TEXT              REFERENCES page_traits (code) ON DELETE RESTRICT,

    power      SMALLINT NOT NULL CHECK (power > 0),
    quality    SMALLINT NOT NULL CHECK (quality BETWEEN 1 AND 100),

    -- Where it came from, for a "found in the Northern Plains" line later.
    found_in   TEXT REFERENCES regions (code) ON DELETE SET NULL,
    found_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Set when refinement consumes it, so a manual can list the pages that
    -- became it. Nulling the page instead would erase the history the design
    -- asks manuals to keep.
    consumed_by BIGINT REFERENCES manuals (manual_id) ON DELETE SET NULL,
    consumed_at TIMESTAMPTZ,

    CONSTRAINT manual_pages_consumption_is_whole CHECK (
        (consumed_by IS NULL AND consumed_at IS NULL)
        OR (consumed_by IS NOT NULL AND consumed_at IS NOT NULL)
    )
);

CREATE INDEX manual_pages_owner_idx ON manual_pages (owner_id)
    WHERE consumed_at IS NULL;
CREATE INDEX manual_pages_tier_idx ON manual_pages (tier);
CREATE INDEX manual_pages_path_idx ON manual_pages (path_code);
CREATE INDEX manual_pages_type_idx ON manual_pages (page_type);
CREATE INDEX manual_pages_trait_idx ON manual_pages (trait);
CREATE INDEX manual_pages_consumed_idx ON manual_pages (consumed_by);
CREATE INDEX manual_pages_region_idx ON manual_pages (found_in);

COMMENT ON TABLE manual_pages IS
    'One row per page. Instances, not templates: quality and trait differ between two pages of the same tier, path and type.';
COMMENT ON COLUMN manual_pages.consumed_by IS
    'The manual this page became. Kept rather than deleted so a manual can show what went into it.';


-- ---------------------------------------------------------------------------
-- The drop tables, deliberately empty
-- ---------------------------------------------------------------------------
-- Two tables rather than one with a source_kind column, because a polymorphic
-- parent cannot carry a real foreign key and every FK in this schema is
-- declared.
--
-- A drop entry is a SPEC, not a page: "this creature yields a Tier 2-4 page,
-- Fire Path, any type". The page itself is minted at the moment it drops, so
-- two players killing the same creature get different pages.
--
-- Both are empty on purpose. Populating them is the next change, and it is an
-- INSERT.

CREATE TABLE creature_page_drops (
    species_id BIGINT NOT NULL REFERENCES creature_species (species_id) ON DELETE CASCADE,

    -- NULL means "any", so a creature can drop a Path-locked page or a
    -- free-for-all one without two different shapes of row.
    path_code  TEXT REFERENCES paths (code) ON DELETE RESTRICT,
    page_type  TEXT REFERENCES page_types (code) ON DELETE RESTRICT,

    tier_min   SMALLINT NOT NULL DEFAULT 1 REFERENCES page_tiers (tier) ON DELETE RESTRICT,
    tier_max   SMALLINT NOT NULL DEFAULT 3 REFERENCES page_tiers (tier) ON DELETE RESTRICT,

    chance     NUMERIC(6, 4) NOT NULL CHECK (chance > 0 AND chance <= 1),

    PRIMARY KEY (species_id, path_code, page_type, tier_min, tier_max),
    CONSTRAINT creature_page_drops_tier_range CHECK (tier_max >= tier_min)
);

CREATE INDEX creature_page_drops_path_idx ON creature_page_drops (path_code);
CREATE INDEX creature_page_drops_type_idx ON creature_page_drops (page_type);
CREATE INDEX creature_page_drops_tier_min_idx ON creature_page_drops (tier_min);
CREATE INDEX creature_page_drops_tier_max_idx ON creature_page_drops (tier_max);

CREATE TABLE region_page_drops (
    region_code TEXT NOT NULL REFERENCES regions (code) ON DELETE CASCADE,

    path_code   TEXT REFERENCES paths (code) ON DELETE RESTRICT,
    page_type   TEXT REFERENCES page_types (code) ON DELETE RESTRICT,

    tier_min    SMALLINT NOT NULL DEFAULT 1 REFERENCES page_tiers (tier) ON DELETE RESTRICT,
    tier_max    SMALLINT NOT NULL DEFAULT 3 REFERENCES page_tiers (tier) ON DELETE RESTRICT,

    chance      NUMERIC(6, 4) NOT NULL CHECK (chance > 0 AND chance <= 1),

    PRIMARY KEY (region_code, path_code, page_type, tier_min, tier_max),
    CONSTRAINT region_page_drops_tier_range CHECK (tier_max >= tier_min)
);

CREATE INDEX region_page_drops_path_idx ON region_page_drops (path_code);
CREATE INDEX region_page_drops_type_idx ON region_page_drops (page_type);
CREATE INDEX region_page_drops_tier_min_idx ON region_page_drops (tier_min);
CREATE INDEX region_page_drops_tier_max_idx ON region_page_drops (tier_max);

COMMENT ON TABLE creature_page_drops IS
    'Page drop specs per species. Empty until pages are added to drop tables; a NULL path or type means "any".';
COMMENT ON TABLE region_page_drops IS
    'Page drop specs per region, for gathering and caches. Empty for now.';


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('page_trait_chance', 0.18,
     'PLACEHOLDER - chance a minted page carries a trait.'),
    ('page_quality_min', 55,
     'PLACEHOLDER - floor on a rolled page''s quality.'),
    ('page_quality_max', 99,
     'PLACEHOLDER - ceiling on a rolled page''s quality before trait bonuses.');


-- ---------------------------------------------------------------------------
-- mint_page
-- ---------------------------------------------------------------------------
-- Rolls one page and hands it to a player.
--
-- Everything the caller does not pin is drawn from the tables: the tier from
-- page_tiers.roll_weight (so 8-10 never appear), the type from
-- page_types.roll_weight, the Path uniformly from the Paths that exist, and
-- the trait from page_traits.roll_weight behind a configured chance.
--
-- Power is the tier's band scaled by quality, so a 99% Tier 3 page beats a 55%
-- Tier 3 page without ever crossing into Tier 4's band.

CREATE FUNCTION mint_page(
    p_owner_id  BIGINT,
    p_tier_min  SMALLINT DEFAULT 1,
    p_tier_max  SMALLINT DEFAULT 7,
    p_path      TEXT     DEFAULT NULL,
    p_type      TEXT     DEFAULT NULL,
    p_region    TEXT     DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    chosen_tier  SMALLINT;
    chosen_path  TEXT;
    chosen_type  TEXT;
    chosen_trait TEXT;
    lo           SMALLINT;
    hi           SMALLINT;
    q            SMALLINT;
    pow          SMALLINT;
    new_id       BIGINT;
BEGIN
    SELECT t.tier INTO chosen_tier
    FROM page_tiers t
    WHERE t.tier BETWEEN p_tier_min AND p_tier_max
      AND t.roll_weight > 0
    ORDER BY -ln(random()) / t.roll_weight
    LIMIT 1;

    IF chosen_tier IS NULL THEN
        RAISE EXCEPTION 'no droppable page tier between % and %', p_tier_min, p_tier_max
            USING ERRCODE = 'check_violation';
    END IF;

    chosen_path := COALESCE(p_path, (SELECT code FROM paths ORDER BY random() LIMIT 1));

    chosen_type := COALESCE(p_type, (
        SELECT pt.code FROM page_types pt
        WHERE pt.roll_weight > 0
        ORDER BY -ln(random()) / pt.roll_weight
        LIMIT 1
    ));

    IF random() < game_config_value('page_trait_chance') THEN
        SELECT tr.code INTO chosen_trait
        FROM page_traits tr
        WHERE tr.roll_weight > 0
        ORDER BY -ln(random()) / tr.roll_weight
        LIMIT 1;
    END IF;

    SELECT t.power_min, t.power_max INTO lo, hi
    FROM page_tiers t WHERE t.tier = chosen_tier;

    q := game_config_value('page_quality_min')
         + floor(random() * (game_config_value('page_quality_max')
                             - game_config_value('page_quality_min') + 1));
    q := GREATEST(1, LEAST(100,
         q + COALESCE((SELECT quality_bonus FROM page_traits WHERE code = chosen_trait), 0)));

    pow := GREATEST(1, round(
        (lo + (hi - lo) * (q / 100.0))
        * COALESCE((SELECT power_multiplier FROM page_traits WHERE code = chosen_trait), 1)
    ));

    INSERT INTO manual_pages
        (owner_id, tier, path_code, page_type, trait, power, quality, found_in)
    VALUES (p_owner_id, chosen_tier, chosen_path, chosen_type, chosen_trait, pow, q, p_region)
    RETURNING page_id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION mint_page(BIGINT, SMALLINT, SMALLINT, TEXT, TEXT, TEXT) IS
    'Rolls one page. Tier, type and trait are drawn from the weights in their tables; tiers 8-10 carry weight 0 and never appear.';


-- ---------------------------------------------------------------------------
-- roll_page_drops
-- ---------------------------------------------------------------------------
-- What a kill or a forage yields, read from the drop specs. Returns the pages
-- it minted, which is an empty set today because both spec tables are empty -
-- so this is safe to call from combat and gathering now, and starts producing
-- the moment the first spec row is inserted.

CREATE FUNCTION roll_page_drops(
    p_player_id  BIGINT,
    p_species_id BIGINT DEFAULT NULL,
    p_region     TEXT   DEFAULT NULL
) RETURNS SETOF BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    spec RECORD;
BEGIN
    IF p_species_id IS NOT NULL THEN
        FOR spec IN
            SELECT * FROM creature_page_drops WHERE species_id = p_species_id
        LOOP
            IF random() < spec.chance THEN
                RETURN NEXT mint_page(p_player_id, spec.tier_min, spec.tier_max,
                                      spec.path_code, spec.page_type, p_region);
            END IF;
        END LOOP;
    END IF;

    IF p_region IS NOT NULL THEN
        FOR spec IN
            SELECT * FROM region_page_drops WHERE region_code = p_region
        LOOP
            IF random() < spec.chance THEN
                RETURN NEXT mint_page(p_player_id, spec.tier_min, spec.tier_max,
                                      spec.path_code, spec.page_type, p_region);
            END IF;
        END LOOP;
    END IF;

    RETURN;
END;
$$;

COMMENT ON FUNCTION roll_page_drops(BIGINT, BIGINT, TEXT) IS
    'Pages from a kill or a forage, per the drop specs. Returns nothing while the spec tables are empty, so callers can be wired up ahead of the content.';
