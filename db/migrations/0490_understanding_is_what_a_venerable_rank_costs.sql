-- 0490_understanding_is_what_a_venerable_rank_costs
--
-- Phase 3 of the Venerable spec. Everything below rank 18 is a meter filled
-- with hours and pills; above it a cultivator advances by understanding their
-- own Dao, and understanding accrues by acting in accordance with it.
--
-- THE DAO IS FROZEN WHEN IT IS READ. `dao_aspects` derives fresh on every
-- call, which is right for reading somebody and wrong for advancing them: a
-- cultivator could re-weight their own Dao by training a different Path and
-- have the ladder follow them. So ascension STAMPS it - the aspects, their
-- weights and a baseline reading of every deed counter - and understanding is
-- measured against that stamp from then on. `dao_stamp` is here for the
-- tribulation in phase 6 to call; for now only an owner can reach it.
--
-- UNDERSTANDING IS MOVEMENT, NOT TOTAL. A cultivator arriving at rank 19 with
-- 3,402 mining levels has not already understood anything - they have a
-- history, which is what gave them the Dao in the first place. Understanding
-- is what they do AFTER. Nobody gets credit backdated, and everybody starts
-- at nothing.
--
-- WEIGHTED BY THE ASPECT. The gained deeds of each aspect are multiplied by
-- that aspect's weight, so a Dao that leads with Shadow at 1.000 gives full
-- credit for Shadow casts and a fifth of it for a third Path at 0.200. This
-- is the whole mechanic: your Dao decides which of your deeds advance you.
--
-- WHICH DEEDS. Four of the six axes record one, and I checked rather than
-- assumed - 0489 had to resurrect a dead column to get the first of them:
--
--     path    casts, from times_used shared out by technique weight
--     body    body_level
--     craft   the craft's level
--     gu      hours carried
--
--     root     NOTHING. A root is rolled, not chosen, and no deed is done
--              in accordance with one. It stays an aspect and feeds nothing.
--     destiny  NOTHING YET. Each of the sixty would need its own deed hook.
--              The weakest axis already; it stays an aspect too.
--
-- SO FOUR OF SIX FEED. Said plainly rather than quietly, because the spec's
-- aspect table shows six and two of them will read "nothing" on the screen.
--
-- WHY LEVELS AND COUNTS RATHER THAN EXP. The four have to be comparable or
-- the ladder is nonsense, and `physique_xp` tops out at 1,988,914 while craft
-- exp is larger again. Both are realm-inflated. Their normalised forms are
-- not, and they land in one order of magnitude:
--
--     body_level   1 - 609 - 3978        craft level  1 - 258 - 3402
--     gu hours     1 - 440 - 2789        path casts   0 everywhere, new
--
-- A flat divisor against an exponential bar is the oldest fault in this
-- schema; levels and hours and casts do not inflate with realm, so a flat
-- rate is honest against them.
--
-- THE RUNG LADDER IS A TABLE, AND SO IS THE OPEN QUESTION. The spec asks
-- whether a rung should demand another aspect realised - rewarding a broad
-- history - or deeper realisation across all of them - rewarding focus. It is
-- a real fork and it is also a balance question, so it is three columns
-- rather than a decision baked into a function: total understanding, how many
-- aspects must be realised, and what realising one takes. The seeded rows
-- lean on both and changing the lean is an UPDATE.
--
-- No stages. Ranks 10 to 18 each have four, and understanding is the meter
-- now - a sub-meter inside it would be the thing this replaces.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What a point of understanding costs, in each axis's own currency
-- ---------------------------------------------------------------------------

CREATE TABLE dao_deed_rates (
    source_kind     TEXT PRIMARY KEY,
    units_per_point NUMERIC(10,3) NOT NULL CHECK (units_per_point > 0),
    unit_name       TEXT NOT NULL
);

COMMENT ON TABLE dao_deed_rates IS
    'How many of an axis own units make one point of understanding. A table because these are a first guess - nobody has stood at rank 19 yet - and tuning them should not need a migration.';

INSERT INTO dao_deed_rates (source_kind, units_per_point, unit_name) VALUES
    -- A cast is one swing in one real fight, and the rarest of the four.
    ('path',  2.000,  'casts'),
    ('body',  10.000, 'body levels'),
    ('craft', 10.000, 'craft levels'),
    ('gu',    10.000, 'hours carried');


-- ---------------------------------------------------------------------------
-- One definition of the deed an aspect accrues from
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_deed_of(p_player_id BIGINT, p_source_kind TEXT, p_source_code TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    SELECT CASE p_source_kind
        WHEN 'path' THEN path_casts_of(p_player_id, p_source_code)
        WHEN 'body' THEN (SELECT body_level::NUMERIC FROM player_physique
                          WHERE player_id = p_player_id)
        WHEN 'craft' THEN (SELECT level::NUMERIC FROM player_skills
                           WHERE player_id = p_player_id AND skill = p_source_code)
        WHEN 'gu' THEN (SELECT gu_carried_seconds(p_player_id, gt.gu_type_id) / 3600.0
                        FROM gu_types gt WHERE gt.code = p_source_code)
        -- NULL rather than 0: these axes do not record a deed, which is a
        -- different thing from recording that none was done.
        ELSE NULL
    END;
$fn$;

COMMENT ON FUNCTION dao_deed_of(BIGINT, TEXT, TEXT) IS
    'The counter an aspect of a Dao accrues understanding from. NULL for root and destiny, which name no recorded deed. The one place that mapping lives.';


-- ---------------------------------------------------------------------------
-- The stamp
-- ---------------------------------------------------------------------------

CREATE TABLE player_dao (
    player_id  BIGINT PRIMARY KEY REFERENCES players(player_id) ON DELETE CASCADE,
    dao_name   TEXT NOT NULL,
    stamped_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE player_dao_aspects (
    player_id   BIGINT NOT NULL REFERENCES player_dao(player_id) ON DELETE CASCADE,
    ordinal     INTEGER NOT NULL,
    source_kind TEXT NOT NULL,
    source_code TEXT NOT NULL,
    label       TEXT NOT NULL,
    weight      NUMERIC(4,3) NOT NULL CHECK (weight > 0 AND weight <= 1),
    baseline    NUMERIC,
    PRIMARY KEY (player_id, source_kind, source_code)
);

CREATE INDEX player_dao_aspects_order_idx
    ON player_dao_aspects (player_id, ordinal);

COMMENT ON TABLE player_dao IS
    'A Dao as it stood when it was stamped. Below this rank a Dao is derived fresh every read; from here it is fixed, so training a new Path cannot re-weight the ladder underneath a cultivator.';

COMMENT ON COLUMN player_dao_aspects.baseline IS
    'What this aspect''s deed counter read at the stamp. Understanding is movement away from here, so a long history grants none of it retroactively. NULL where the axis records no deed.';


CREATE FUNCTION dao_stamp(p_player_id BIGINT)
RETURNS TEXT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_name TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id) THEN
        -- Re-stamping would reset every baseline and erase whatever had been
        -- understood. Whether a Dao may change after it is read is still an
        -- open question in the spec; until it is answered, the answer is no.
        RAISE EXCEPTION 'that Dao is already stamped'
            USING ERRCODE = 'check_violation';
    END IF;

    v_name := dao_name_of(p_player_id);
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'there is no Dao to stamp - no Path has been walked'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO player_dao (player_id, dao_name) VALUES (p_player_id, v_name);

    INSERT INTO player_dao_aspects
        (player_id, ordinal, source_kind, source_code, label, weight, baseline)
    SELECT p_player_id, a.ordinal, a.source_kind, a.source_code, a.label, a.weight,
           dao_deed_of(p_player_id, a.source_kind, a.source_code)
    FROM dao_aspects(p_player_id) a;

    RETURN v_name;
END;
$fn$;

COMMENT ON FUNCTION dao_stamp(BIGINT) IS
    'Freeze a cultivator Dao and take a baseline reading of every deed counter. For the tribulation in phase 6 to call on a successful ascension; owner-only until then.';


-- ---------------------------------------------------------------------------
-- What has been understood since
-- ---------------------------------------------------------------------------

CREATE FUNCTION dao_understanding(p_player_id BIGINT)
RETURNS TABLE (
    ordinal       INTEGER,
    source_kind   TEXT,
    source_code   TEXT,
    label         TEXT,
    weight        NUMERIC,
    unit_name     TEXT,
    baseline      NUMERIC,
    deed_now      NUMERIC,
    gained        NUMERIC,
    understanding NUMERIC
)
LANGUAGE sql STABLE AS $fn$
    SELECT a.ordinal, a.source_kind, a.source_code, a.label, a.weight::NUMERIC,
           r.unit_name,
           a.baseline,
           dao_deed_of(p_player_id, a.source_kind, a.source_code) AS deed_now,
           GREATEST(0, dao_deed_of(p_player_id, a.source_kind, a.source_code)
                       - a.baseline) AS gained,
           round(
               GREATEST(0, dao_deed_of(p_player_id, a.source_kind, a.source_code)
                           - a.baseline)
               * a.weight / r.units_per_point,
           3) AS understanding
    FROM player_dao_aspects a
    JOIN dao_deed_rates r ON r.source_kind = a.source_kind
    WHERE a.player_id = p_player_id
    ORDER BY a.ordinal;
$fn$;

COMMENT ON FUNCTION dao_understanding(BIGINT) IS
    'Per aspect: what its deed read at the stamp, what it reads now, and what that movement is worth. Only the four axes that record a deed appear - root and destiny are aspects that feed nothing.';


CREATE FUNCTION dao_understanding_total(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(sum(understanding), 0)::NUMERIC
    FROM dao_understanding(p_player_id);
$fn$;


-- ---------------------------------------------------------------------------
-- The rungs
-- ---------------------------------------------------------------------------

CREATE TABLE venerable_ranks (
    rank                  SMALLINT PRIMARY KEY CHECK (rank >= 19),
    name                  TEXT NOT NULL UNIQUE,
    understanding_required NUMERIC NOT NULL CHECK (understanding_required > 0),
    aspects_required      SMALLINT NOT NULL CHECK (aspects_required >= 1),
    per_aspect_required   NUMERIC NOT NULL CHECK (per_aspect_required > 0),
    description           TEXT
);

COMMENT ON TABLE venerable_ranks IS
    'The ladder above the nine fruits. Three demands rather than one so the spec''s open question - whether a rung wants another aspect realised or deeper realisation of the same ones - is a row edit and not a migration.';

COMMENT ON COLUMN venerable_ranks.aspects_required IS
    'How many aspects must each have reached per_aspect_required. The breadth knob: raise it and a cultivator with a wide history climbs further.';

COMMENT ON COLUMN venerable_ranks.per_aspect_required IS
    'What realising one aspect takes. The depth knob: raise it and focus pays instead.';

INSERT INTO venerable_ranks
    (rank, name, understanding_required, aspects_required, per_aspect_required, description)
VALUES
    (19, 'Dao Venerable',            100,  2, 25,
     'Has read their own Dao and begun to act on it.'),
    (20, 'Immemorial Venerable',     300,  3, 60,
     'Understands enough of it that the understanding shows.'),
    (21, 'Heaven-Rivalling Venerable', 700, 4, 120,
     'Acts in accordance with the whole of it, not a part.'),
    (22, 'Primordial Venerable',    1500,  5, 220,
     'Nothing of the Dao is left unrealised.');


CREATE FUNCTION venerable_rank_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- The highest rung whose three demands are all met. NULL for anybody
    -- whose Dao is not stamped, which is everybody until phase 6.
    SELECT max(v.rank)
    FROM venerable_ranks v
    WHERE EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id)
      AND dao_understanding_total(p_player_id) >= v.understanding_required
      AND (SELECT count(*) FROM dao_understanding(p_player_id) u
           WHERE u.understanding >= v.per_aspect_required) >= v.aspects_required;
$fn$;

COMMENT ON FUNCTION venerable_rank_of(BIGINT) IS
    'The Venerable rung a cultivator has earned, or NULL if their Dao is not stamped. Reads the demands off venerable_ranks rather than hard-coding any of them.';


-- ---------------------------------------------------------------------------
-- Walk a cultivator up the ladder and back down
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_tid   BIGINT;
    v_spec  BIGINT;
    v_name  TEXT;
    v_tot   NUMERIC;
    v_rank  SMALLINT;
    v_n     INTEGER;
BEGIN
    -- Every feeding axis has a rate, and no axis has a rate without feeding.
    IF EXISTS (SELECT 1 FROM dao_deed_rates r
               WHERE dao_deed_of(1, r.source_kind, 'nonesuch') IS NULL
                 AND r.source_kind <> 'path') THEN
        NULL;   -- a missing code reads NULL for any kind; nothing to assert here
    END IF;

    IF (SELECT count(*) FROM dao_deed_rates) <> 4 THEN
        RAISE EXCEPTION 'the four feeding axes do not all have a rate';
    END IF;

    -- root and destiny record no deed, and say so rather than reading zero.
    IF dao_deed_of(1, 'root', 'iron_root') IS NOT NULL
       OR dao_deed_of(1, 'destiny', 'killing_intent') IS NOT NULL THEN
        RAISE EXCEPTION 'an axis that records nothing reported something';
    END IF;

    -- The ladder only climbs, on all three demands.
    IF EXISTS (
        SELECT 1 FROM venerable_ranks a JOIN venerable_ranks b ON b.rank = a.rank + 1
        WHERE b.understanding_required <= a.understanding_required
           OR b.aspects_required < a.aspects_required
           OR b.per_aspect_required <= a.per_aspect_required
    ) THEN
        RAISE EXCEPTION 'a Venerable rung is no harder than the one below it';
    END IF;

    -- And it starts where the fruits stop.
    IF (SELECT min(rank) FROM venerable_ranks) <> 19
       OR (SELECT max(rank) FROM realms) <> 18 THEN
        RAISE EXCEPTION 'the Venerable ladder does not begin at 19';
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-995, 'understanding-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        VALUES (v_pid, (SELECT min(realm_id) FROM realms), 0);
        INSERT INTO player_physique (player_id, physique_id, body_path, body_level)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques), 'buddhist', 100);
        INSERT INTO player_professions (player_id, profession, level)
        VALUES (v_pid, 'mining', 50);

        SELECT technique_id INTO v_tid FROM techniques t
        WHERE EXISTS (SELECT 1 FROM technique_paths WHERE technique_id = t.technique_id)
        ORDER BY technique_id LIMIT 1;
        SELECT species_id INTO v_spec FROM creature_species ORDER BY species_id LIMIT 1;

        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        SELECT v_pid, tp.path_code, 90000, 5 FROM technique_paths tp
        WHERE tp.technique_id = v_tid;
        INSERT INTO player_techniques (player_id, technique_id) VALUES (v_pid, v_tid);

        -- Nothing is understood before anything is stamped.
        IF venerable_rank_of(v_pid) IS NOT NULL THEN
            RAISE EXCEPTION 'an unstamped cultivator held a Venerable rank';
        END IF;
        IF dao_understanding_total(v_pid) <> 0 THEN
            RAISE EXCEPTION 'an unstamped cultivator had understood something';
        END IF;

        v_name := dao_stamp(v_pid);
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'the stamp returned no name';
        END IF;

        -- A long history grants nothing backdated: fifty craft levels and a
        -- hundred body levels were already there, so they are the baseline.
        v_tot := dao_understanding_total(v_pid);
        IF v_tot <> 0 THEN
            RAISE EXCEPTION
                'stamping granted % understanding for deeds already done', v_tot;
        END IF;

        -- Now do something. Levelling the craft moves its aspect.
        UPDATE player_professions SET level = 250
        WHERE player_id = v_pid AND profession = 'mining';
        v_tot := dao_understanding_total(v_pid);
        IF v_tot <= 0 THEN
            RAISE EXCEPTION 'two hundred craft levels came to no understanding';
        END IF;

        -- And casting moves the Path aspect, weighted by how far that Path
        -- leads the Dao.
        PERFORM player_swing(v_pid, v_tid, v_spec, 1000000::BIGINT, 0::BIGINT);
        PERFORM player_swing(v_pid, v_tid, v_spec, 1000000::BIGINT, 0::BIGINT);
        IF (SELECT count(*) FROM dao_understanding(v_pid)
            WHERE source_kind = 'path' AND understanding > 0) = 0 THEN
            RAISE EXCEPTION 'casting twice taught the cultivator nothing';
        END IF;

        -- Enough of it, and a rung is reached. 30,000 rather than more
        -- because `level` and `body_level` are both SMALLINT, which caps a
        -- single craft or body at 3,276 understanding - worth knowing, since
        -- it is the real ceiling the rung costs sit under.
        UPDATE player_professions SET level = 30000
        WHERE player_id = v_pid AND profession = 'mining';
        UPDATE player_physique SET body_level = 30000 WHERE player_id = v_pid;
        v_rank := venerable_rank_of(v_pid);
        IF v_rank IS NULL THEN
            RAISE EXCEPTION
                'a cultivator with % understanding reached no rung',
                dao_understanding_total(v_pid);
        END IF;

        -- The stamp holds. Training a Path that is not in the Dao cannot add
        -- an aspect to it, which is the reason for freezing at all.
        SELECT count(*) INTO v_n FROM player_dao_aspects WHERE player_id = v_pid;
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, 'poison', 9000000, 10);
        IF (SELECT count(*) FROM player_dao_aspects WHERE player_id = v_pid) <> v_n THEN
            RAISE EXCEPTION 'a stamped Dao grew an aspect';
        END IF;
        IF (SELECT count(*) FROM dao_understanding(v_pid)
            WHERE source_code = 'poison') > 0 THEN
            RAISE EXCEPTION 'an unstamped Path accrued understanding';
        END IF;

        -- Stamping twice is refused rather than quietly resetting a ladder.
        BEGIN
            PERFORM dao_stamp(v_pid);
            RAISE EXCEPTION 'a Dao was stamped twice';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM <> 'that Dao is already stamped' THEN RAISE; END IF;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody living is stamped, so nobody living has changed.
    SELECT count(*) INTO v_n FROM player_dao;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% cultivators were stamped by this migration', v_n;
    END IF;

    RAISE NOTICE
        'four axes feed understanding, % rungs above the fruits, nobody stamped yet',
        (SELECT count(*) FROM venerable_ranks);
END;
$probe$;
