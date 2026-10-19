-- 0437_a_piece_of_gear_gains_a_realm_a_rank_and_an_honest_name
--
-- The shape of the gear update. Four things a piece of equipment is, where it
-- used to be two, and one of the two was lying about its name.
--
--   LEVEL   the realm it was forged for. 1-18, from the smith's own realm.
--   RANK    fusion stars, 1-5. Forged at 1, raised by eating duplicates.
--   RARITY  what it is. The shared ladder roots and physiques use.
--   QUALITY how well that particular forging went.
--
-- THE HONEST NAME FIRST. `player_equipment.quality` has always held a RARITY
-- code - the column is a foreign key to `rarities` and always has been. So the
-- word "quality" was already taken by the wrong thing, and the update needs it
-- back for something real. The column becomes `rarity`, which is what it holds,
-- and `quality` is free for the roll.
--
-- QUALITY IS THE HARMONY THAT WAS ALREADY THERE. `forge` has always rolled a
-- harmony of 0-150 and it has always risen with the smith:
--
--     harmony := ... + skill * 0.9 + (random() * 8 - 4)
--
-- Rolled at every forge, driven by the smith's level - which is the whole
-- specification for Quality. It stops being the hidden thing that decides
-- rarity and becomes the shown thing it always was, in words. Nothing new is
-- rolled: a second random number that also rises with smith level would
-- multiply with this one and a good forge would come out twice as good as
-- anybody intended.
--
-- RARITY MOVES OFF HARMONY AND ONTO THE SMITH. It used to be harmony's band,
-- which is why it and Quality could never be told apart - they were the same
-- number read twice. Rarity now comes from `smith_rarity_caps`, and on a fuse
-- it may rise no higher than the best piece that went in: a bench fed nothing
-- better than Rare cannot hand back a Divine.
--
-- WHY LEVEL DOES NOT MULTIPLY STATS, which is the one judgement call in here
-- worth arguing with. Since 0433 gear grants base stats, and a base stat is
-- multiplied by the WEARER's realm - `player_power_multiple`, which reaches
-- 131072 at the top. A piece whose stats also scaled by the realm it was made
-- for would be that multiplier applied twice, and this codebase has been
-- bitten by exactly that shape more than once. So Level gates rather than
-- scales: you must have reached a realm to wear gear built for it, and a
-- piece cannot be fused past the rank its Level allows. RANK does the
-- scaling, over a deliberately small range. `equipment_level_scales` exists
-- so that decision can be reversed in one UPDATE if it reads as too timid.
--
-- EVERY PIECE OF GEAR IN THE WORLD IS DESTROYED BY THIS. 498 pieces, 1654
-- effects, 50 of them worn, 78 in presets, 18 in open trades and 1 on the
-- auction board. That is not a side effect, it is the point: every existing
-- piece predates Level, Rank and a rarity that means anything, and there is no
-- honest value to backfill them with. The user authorised it explicitly while
-- the bot is in testing. The jade and materials spent are NOT refunded, which
-- is worth stating plainly rather than discovering.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- How well a forging went, in words
-- ---------------------------------------------------------------------------

CREATE TABLE equipment_quality_bands (
    code        TEXT     PRIMARY KEY,
    name        TEXT     NOT NULL,
    min_harmony SMALLINT NOT NULL UNIQUE,
    stat_share  NUMERIC(6,4) NOT NULL,
    CHECK (min_harmony >= 0 AND min_harmony <= 150),
    CHECK (stat_share > 0)
);

COMMENT ON TABLE equipment_quality_bands IS
    'The harmony roll, read as a word. Quality is not a second random number - it is the one the forge has always rolled, shown instead of hidden.';

INSERT INTO equipment_quality_bands (code, name, min_harmony, stat_share) VALUES
    ('crude',        'Crude',          0, 0.70),
    ('fair',         'Fair',          40, 0.85),
    ('fine',         'Fine',          70, 1.00),
    ('excellent',    'Excellent',     95, 1.15),
    ('superb',       'Superb',       115, 1.30),
    ('flawless',     'Flawless',     135, 1.50);


CREATE OR REPLACE FUNCTION equipment_quality_for(p_harmony smallint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT q.code FROM equipment_quality_bands q
    WHERE q.min_harmony <= GREATEST(0, p_harmony)
    ORDER BY q.min_harmony DESC LIMIT 1;
$fn$;


-- ---------------------------------------------------------------------------
-- Stars, and what each one costs to reach
-- ---------------------------------------------------------------------------

CREATE TABLE equipment_ranks (
    rank        SMALLINT PRIMARY KEY,
    stat_step   NUMERIC(6,4) NOT NULL,
    fuse_chance NUMERIC(5,4),
    CHECK (rank >= 1),
    CHECK (stat_step > 0),
    CHECK (fuse_chance IS NULL OR (fuse_chance > 0 AND fuse_chance <= 1))
);

COMMENT ON COLUMN equipment_ranks.fuse_chance IS
    'The base chance of REACHING this rank from the one below. NULL on rank 1, which is where gear is forged rather than fused to. The smith''s level is added on top, so a deep smith fails less than a shallow one at the same star.';

COMMENT ON COLUMN equipment_ranks.stat_step IS
    'What the whole piece is multiplied by at this rank. Deliberately a small ladder: a base stat is ALREADY multiplied by the wearer''s realm, so a generous step here is that multiplier applied twice.';

INSERT INTO equipment_ranks (rank, stat_step, fuse_chance) VALUES
    (1, 1.0000, NULL),
    (2, 1.2500, 0.9000),
    (3, 1.5500, 0.7000),
    (4, 1.9000, 0.5000),
    (5, 2.3000, 0.3000);


-- ---------------------------------------------------------------------------
-- What a smith of a given level may make
-- ---------------------------------------------------------------------------

CREATE TABLE smith_rarity_caps (
    min_level SMALLINT PRIMARY KEY,
    rarity    TEXT NOT NULL REFERENCES rarities(code) ON DELETE RESTRICT
);

COMMENT ON TABLE smith_rarity_caps IS
    'The best a smith of this level may produce. Stops at Divine on purpose: Unique and Extreme are what the world hands out, not what a bench makes, which is the same line 0431 drew between a Gu that is found and a Gu that is refined.';

INSERT INTO smith_rarity_caps (min_level, rarity) VALUES
    (  1, 'common'),
    (  8, 'uncommon'),
    ( 20, 'rare'),
    ( 40, 'epic'),
    ( 65, 'legendary'),
    ( 95, 'mythic'),
    (130, 'divine');


CREATE OR REPLACE FUNCTION smith_rarity_cap(p_level integer)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT c.rarity FROM smith_rarity_caps c
    WHERE c.min_level <= GREATEST(1, COALESCE(p_level, 1))
    ORDER BY c.min_level DESC LIMIT 1;
$fn$;


-- ---------------------------------------------------------------------------
-- The realm a piece is built for, and what it is allowed to become
-- ---------------------------------------------------------------------------

CREATE TABLE equipment_level_scales (
    level     SMALLINT PRIMARY KEY,
    max_rank  SMALLINT NOT NULL,
    stat_step NUMERIC(6,4) NOT NULL DEFAULT 1.0,
    CHECK (level >= 1 AND level <= 18),
    CHECK (max_rank >= 1),
    CHECK (stat_step > 0)
);

COMMENT ON TABLE equipment_level_scales IS
    'What a piece forged for each realm may be fused to. `stat_step` is 1.0 at every level on purpose and is here so that choice can be revisited in one UPDATE: a base stat is already multiplied by the wearer''s realm, and a level that scaled as well would be that multiplier applied twice.';

INSERT INTO equipment_level_scales (level, max_rank)
SELECT r.rank, LEAST(5, 1 + (r.rank - 1) / 4 + 1)
FROM (SELECT DISTINCT rank FROM realms) r;


-- ---------------------------------------------------------------------------
-- The column that was never called what it held
-- ---------------------------------------------------------------------------

-- One view reads the column and is lifted and put back from its own
-- definition, the same rule 0434 followed. Only `auction_board` selects it:
-- `preset_shelf` and `trade_contents` join the table without touching this
-- column, and Postgres tracks the dependency per column rather than per table.
--
-- The replacement is on the ALIAS rather than on ".quality", because the first
-- draft of this migration replaced every ".quality" in the view and renamed
-- `player_pills.quality` and `manuals.quality` along with it - both are joined
-- into the same board, and neither is being renamed.
DO $rename$
DECLARE
    def    TEXT;
    anchor TEXT := 'eq.quality';
    hits   INTEGER;
BEGIN
    SELECT pg_get_viewdef('auction_board'::regclass, true) INTO def;
    IF def IS NULL THEN
        RAISE EXCEPTION 'auction_board is missing';
    END IF;

    hits := (length(def) - length(replace(def, anchor, ''))) / length(anchor);
    IF hits <> 2 THEN
        RAISE EXCEPTION
            'auction_board names the gear column % time(s), expected 2', hits;
    END IF;

    EXECUTE 'DROP VIEW auction_board';
    EXECUTE 'ALTER TABLE player_equipment RENAME COLUMN quality TO rarity';
    EXECUTE 'CREATE VIEW auction_board AS ' || replace(def, anchor, 'eq.rarity');

    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relkind = 'v'
                   AND c.relname = 'auction_board'
                   AND c.relnamespace = 'public'::regnamespace) THEN
        RAISE EXCEPTION 'auction_board was dropped and not restored';
    END IF;

    -- The two that were left alone must still work, which is the whole claim
    -- that made leaving them alone safe.
    PERFORM 1 FROM preset_shelf LIMIT 1;
    PERFORM 1 FROM trade_contents LIMIT 1;
END;
$rename$;


ALTER TABLE player_equipment
    ADD COLUMN level   SMALLINT NOT NULL DEFAULT 1
        REFERENCES equipment_level_scales(level) ON DELETE RESTRICT,
    ADD COLUMN rank    SMALLINT NOT NULL DEFAULT 1
        REFERENCES equipment_ranks(rank) ON DELETE RESTRICT,
    ADD COLUMN quality TEXT     NOT NULL DEFAULT 'fine'
        REFERENCES equipment_quality_bands(code) ON DELETE RESTRICT;

CREATE INDEX player_equipment_level_idx ON player_equipment (level);
CREATE INDEX player_equipment_rank_idx  ON player_equipment (rank);

COMMENT ON COLUMN player_equipment.rarity IS
    'What the piece is, on the ladder roots and physiques share. Renamed from `quality` in 0437, which is what it always held.';
COMMENT ON COLUMN player_equipment.quality IS
    'How well this particular forging went - the harmony roll, banded. Rolled fresh at every forge.';
COMMENT ON COLUMN player_equipment.level IS
    'The realm this piece was forged for, from the smith''s own. An equip requirement and the ceiling on its rank; it does not scale stats.';
COMMENT ON COLUMN player_equipment.rank IS
    'Fusion stars. Forged at 1 and raised by eating a duplicate of the same slot, level and rank.';


-- ---------------------------------------------------------------------------
-- And every piece that predates all of it is destroyed
-- ---------------------------------------------------------------------------

-- Authorised explicitly: "It's ok to reset everyone's gear for this update as
-- the bot is still in testing". Nothing here is recoverable and none of the
-- jade or materials spent is refunded.
--
-- Taken out from under the things holding it first, so a cascade cannot leave
-- a listing pointing at a piece that no longer exists.
DELETE FROM trade_offer_equipment;
DELETE FROM preset_gear;
DELETE FROM auction_listings WHERE equipment_id IS NOT NULL;
DELETE FROM player_equipped;
DELETE FROM player_equipment;


DO $probe$
DECLARE
    v_bad TEXT;
    r     RECORD;
BEGIN
    -- The wipe is total. A single survivor would be a piece with a Level and
    -- a Rank it never earned and a rarity that means nothing.
    SELECT string_agg(format('%s: %s', x.t, x.n), ', ') INTO v_bad FROM (
        SELECT 'player_equipment' AS t, count(*) AS n FROM player_equipment
        UNION ALL SELECT 'equipment_effects', count(*) FROM equipment_effects
        UNION ALL SELECT 'player_equipped', count(*) FROM player_equipped
        UNION ALL SELECT 'preset_gear', count(*) FROM preset_gear
        UNION ALL SELECT 'trade_offer_equipment', count(*) FROM trade_offer_equipment
    ) x WHERE x.n > 0;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'gear survived the reset: %', v_bad;
    END IF;

    -- The column says what it holds.
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'player_equipment' AND column_name = 'rarity') THEN
        RAISE EXCEPTION 'the rarity column was not renamed';
    END IF;

    -- Every band of every ladder is reachable and ordered.
    IF (SELECT count(*) FROM equipment_quality_bands) < 2
       OR (SELECT min(min_harmony) FROM equipment_quality_bands) <> 0 THEN
        RAISE EXCEPTION 'the quality ladder has no floor, so a bad forge has no name';
    END IF;
    IF equipment_quality_for(0::smallint) IS NULL
       OR equipment_quality_for(150::smallint) IS NULL THEN
        RAISE EXCEPTION 'a harmony at the end of its range has no quality';
    END IF;

    -- A smith of any level may make something, and none of them may make what
    -- the world is supposed to hand out.
    FOR r IN SELECT generate_series(1, 200) AS lvl LOOP
        IF smith_rarity_cap(r.lvl) IS NULL THEN
            RAISE EXCEPTION 'a smith of level % may make nothing', r.lvl;
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM smith_rarity_caps WHERE rarity IN ('unique', 'extreme')) THEN
        RAISE EXCEPTION 'a bench may make what only the world should hand out';
    END IF;

    -- Every realm a cultivator can stand in has a gear level to match.
    SELECT string_agg(DISTINCT r2.rank::text, ', ') INTO v_bad
    FROM realms r2
    WHERE NOT EXISTS (SELECT 1 FROM equipment_level_scales l WHERE l.level = r2.rank);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these realms have no gear level: %', v_bad;
    END IF;

    FOR r IN
        SELECT l.level, l.max_rank,
               (SELECT min(name) FROM realms rr WHERE rr.rank = l.level) AS realm
        FROM equipment_level_scales l ORDER BY l.level
    LOOP
        RAISE NOTICE 'level % (%) fuses to %(star)s',
            lpad(r.level::text, 2), rpad(COALESCE(r.realm, '?'), 34), r.max_rank;
    END LOOP;
END;
$probe$;
