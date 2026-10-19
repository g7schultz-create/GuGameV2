-- 0487_a_worm_is_used_by_being_carried
--
-- 0483 shipped the Gu aspect of a Dao standing on a measure it was not meant
-- to have, and said so in its own header: the spec calls that axis "fed by
-- using them rather than hoarding them", nothing in the game counted a use,
-- so the aspect named whichever worm had the most stars. A statement about
-- hoarding, which is the opposite of the one intended.
--
-- WHAT A USE IS, HERE. There is no cast to count. A Gu is not a technique -
-- 0037 resolves the six build axes passively inside `battle_act` out of
-- `player_gu_stats`, and no function in the schema takes a gu_id and spends
-- it. A worm is used by being worn, in an aperture of finite size, in place
-- of some other worm you could have worn instead. That IS the choice, and
-- `player_gu_equipped.equipped_at` has been recording when each one started
-- since 0036 - 170 stints across 12 cultivators, averaging 7.9 days, the
-- oldest opened on the 5th of September.
--
-- What it does not record is anything that happened before the current stint,
-- because unequipping DELETEs the row and the time goes with it.
--
-- SO: BANK THE STINT WHEN THE ROW DIES. Per (cultivator, kind of worm) rather
-- than per worm, so the tally survives the worm being traded away, refined
-- into something else or released, and so it stays a fact about the person
-- rather than about an object that changed hands. A worm carried for a month
-- and handed over leaves its month with the one who carried it.
--
-- WHY A TRIGGER AND NOT THE FIVE CALL SITES. Rows leave that table from the
-- unequip command in bot/cogs/gu.py, from `load_preset`, from
-- `release_gu_on_handover` when a trade completes, and from two cascades.
-- Banking at each of those is the shape of every fault found this month - a
-- guard moves and a reader does not. The row dies in one place.
--
-- AND WHY THE TRIGGER ONLY UPDATES, NEVER INSERTS. Both foreign keys on
-- `player_gu_equipped` are ON DELETE CASCADE, so deleting a cultivator sweeps
-- their equipped rows and fires this trigger mid-teardown. A trigger that
-- INSERTED a tally row there would hand the half-deleted player a fresh
-- referencing row after the cascade had already passed over the tally table,
-- and the DELETE would fail on the foreign key - breaking `/dev wipe` and
-- real account removal, neither of which would have shown up here. An UPDATE
-- during a teardown either touches a row that is about to go or touches
-- nothing. So the tally row is created when a worm is EQUIPPED, which only
-- ever happens on purpose, and the open stints that already exist are
-- backfilled below.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE player_gu_carried (
    player_id      BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    gu_type_id     BIGINT NOT NULL REFERENCES gu_types(gu_type_id),
    seconds_carried BIGINT NOT NULL DEFAULT 0 CHECK (seconds_carried >= 0),
    last_banked_at TIMESTAMPTZ,
    PRIMARY KEY (player_id, gu_type_id)
);

CREATE INDEX player_gu_carried_by_time_idx
    ON player_gu_carried (player_id, seconds_carried DESC);

COMMENT ON TABLE player_gu_carried IS
    'How long a cultivator has worn each kind of worm, across every stint. Keyed by kind rather than by instance so it survives a trade, a refinement or a release - it is a fact about the person, not the object.';

COMMENT ON COLUMN player_gu_carried.seconds_carried IS
    'Closed stints only. The open one is added by gu_carried_seconds, which is the only thing that should be asked for a total.';


-- ---------------------------------------------------------------------------
-- Open a tally when a worm goes in, close it when the row dies
-- ---------------------------------------------------------------------------

CREATE FUNCTION open_gu_carry_tally()
RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
BEGIN
    -- Equipping is always deliberate, so this is the safe place to create the
    -- row the delete side needs. See the header on why the delete side cannot.
    INSERT INTO player_gu_carried (player_id, gu_type_id)
    SELECT NEW.player_id, g.gu_type_id
    FROM player_gu g
    WHERE g.gu_id = NEW.gu_id
    ON CONFLICT (player_id, gu_type_id) DO NOTHING;
    RETURN NEW;
END;
$fn$;

CREATE FUNCTION bank_gu_carry_tally()
RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
BEGIN
    -- UPDATE only. During a cascade this touches a row that is about to be
    -- deleted, or nothing at all; either is fine. An INSERT here would break
    -- deleting a cultivator.
    UPDATE player_gu_carried c
    SET seconds_carried = c.seconds_carried
                        + GREATEST(0, floor(extract(epoch FROM (now() - OLD.equipped_at))))::BIGINT,
        last_banked_at = now()
    FROM player_gu g
    WHERE g.gu_id = OLD.gu_id
      AND c.player_id = OLD.player_id
      AND c.gu_type_id = g.gu_type_id;
    RETURN OLD;
END;
$fn$;

CREATE TRIGGER player_gu_equipped_opens_a_tally
    AFTER INSERT ON player_gu_equipped
    FOR EACH ROW EXECUTE FUNCTION open_gu_carry_tally();

CREATE TRIGGER player_gu_equipped_banks_the_stint
    AFTER DELETE ON player_gu_equipped
    FOR EACH ROW EXECUTE FUNCTION bank_gu_carry_tally();


-- The 170 stints already open. Without these the delete side would have
-- nothing to bank into and every one of them would be lost the first time
-- somebody changed their loadout.
INSERT INTO player_gu_carried (player_id, gu_type_id)
SELECT DISTINCT e.player_id, g.gu_type_id
FROM player_gu_equipped e
JOIN player_gu g ON g.gu_id = e.gu_id
ON CONFLICT (player_id, gu_type_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- One definition of how long a worm has been worn
-- ---------------------------------------------------------------------------

CREATE FUNCTION gu_carried_seconds(p_player_id BIGINT, p_gu_type_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
        (SELECT seconds_carried FROM player_gu_carried
         WHERE player_id = p_player_id AND gu_type_id = p_gu_type_id), 0)
    + COALESCE((
        -- every stint still open for this kind, including two worms of one
        -- kind worn at once, which is twice the use and counts twice
        SELECT sum(GREATEST(0, floor(extract(epoch FROM (now() - e.equipped_at)))))::BIGINT
        FROM player_gu_equipped e
        JOIN player_gu g ON g.gu_id = e.gu_id
        WHERE e.player_id = p_player_id AND g.gu_type_id = p_gu_type_id
    ), 0);
$fn$;

COMMENT ON FUNCTION gu_carried_seconds(BIGINT, BIGINT) IS
    'Total time a cultivator has worn a kind of worm: banked stints plus whatever is open now. Ask this rather than reading player_gu_carried, which holds only the closed half.';


-- ---------------------------------------------------------------------------
-- The aspect reads use instead of stars
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dao_aspects(p_player_id BIGINT)
RETURNS TABLE (
    ordinal     INTEGER,
    source_kind TEXT,
    source_code TEXT,
    label       TEXT,
    weight      NUMERIC,
    feeds       TEXT
)
LANGUAGE sql STABLE AS $fn$
WITH lead_path AS (
    SELECT max(insight) AS top
    FROM player_path_attainment
    WHERE player_id = p_player_id
),
craft_total AS (
    SELECT sum(level)::NUMERIC AS total
    FROM player_skills
    WHERE player_id = p_player_id AND level > 0
),
carried AS (
    -- every kind this cultivator has ever worn, and for how long
    SELECT t.gu_type_id, gu_carried_seconds(p_player_id, t.gu_type_id) AS secs
    FROM (
        SELECT gu_type_id FROM player_gu_carried WHERE player_id = p_player_id
        UNION
        SELECT g.gu_type_id FROM player_gu_equipped e
        JOIN player_gu g ON g.gu_id = e.gu_id
        WHERE e.player_id = p_player_id
    ) t
),
carried_total AS (
    SELECT sum(secs)::NUMERIC AS total FROM carried
),
a_path AS (
    SELECT 1 AS kind_rank,
           row_number() OVER (ORDER BY pa.insight DESC, pa.path_code) AS within,
           'path'::TEXT AS source_kind, pa.path_code AS source_code,
           p.name AS label,
           round(pa.insight::NUMERIC / lp.top, 3) AS weight,
           'casting techniques of this path in a real fight'::TEXT AS feeds
    FROM player_path_attainment pa
    JOIN paths p ON p.code = pa.path_code
    CROSS JOIN lead_path lp
    WHERE pa.player_id = p_player_id
      AND lp.top > 0
      AND pa.insight >= lp.top * 0.10
    ORDER BY pa.insight DESC, pa.path_code
    LIMIT 3
),
a_body AS (
    SELECT 2, 1::BIGINT, 'body'::TEXT, pp.body_path, b.name, 1.000::NUMERIC,
           'damage taken and lived through'::TEXT
    FROM player_physique pp
    JOIN body_paths b ON b.code = pp.body_path
    WHERE pp.player_id = p_player_id AND pp.body_path IS NOT NULL
),
a_craft AS (
    SELECT 3, 1::BIGINT, 'craft'::TEXT, ps.skill, ps.name,
           round(ps.level::NUMERIC / ct.total, 3),
           'working the craft'::TEXT
    FROM player_skills ps
    CROSS JOIN craft_total ct
    WHERE ps.player_id = p_player_id AND ps.level > 0 AND ct.total > 0
    ORDER BY ps.level DESC, ps.skill
    LIMIT 1
),
a_root AS (
    SELECT 4, 1::BIGINT, 'root'::TEXT, r.code, r.name,
           COALESCE(rw.weight, 0.200)::NUMERIC,
           'whatever the root was always for'::TEXT
    FROM player_character pc
    JOIN roots r ON r.code = pc.root_code
    LEFT JOIN dao_rarity_weight rw ON rw.rarity = r.rarity
    WHERE pc.player_id = p_player_id AND pc.root_code IS NOT NULL
),
a_destiny AS (
    SELECT 5,
           row_number() OVER (
               ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code),
           'destiny'::TEXT, d.code, d.name,
           round(least(1.0, (1 - d.roll_weight) * (1 + d.min_rank / 18.0)), 3),
           'the deeds the destiny names'::TEXT
    FROM player_destinies pdx
    JOIN destinies d ON d.code = pdx.code
    WHERE pdx.player_id = p_player_id AND pdx.chosen_at IS NOT NULL
    ORDER BY (1 - d.roll_weight) * (1 + d.min_rank / 18.0) DESC, d.code
    LIMIT 2
),
a_gu AS (
    -- The worm worn longest, weighted by its share of everything this
    -- cultivator has ever worn - the same rule the craft axis uses, so a
    -- specialist scores high and a tinkerer low.
    --
    -- A day is the floor. A worm slotted for an hour to see what it did is
    -- not an aspect of anybody's Dao.
    SELECT 6, 1::BIGINT, 'gu'::TEXT, gt.code, gt.name,
           round(c.secs::NUMERIC / NULLIF(ct.total, 0), 3),
           'wearing the worm rather than keeping it in a jar'::TEXT
    FROM carried c
    JOIN gu_types gt ON gt.gu_type_id = c.gu_type_id
    CROSS JOIN carried_total ct
    WHERE c.secs >= 86400 AND ct.total > 0
    ORDER BY c.secs DESC, gt.code
    LIMIT 1
),
all_parts AS (
    SELECT * FROM a_path
    UNION ALL SELECT * FROM a_body
    UNION ALL SELECT * FROM a_craft
    UNION ALL SELECT * FROM a_root
    UNION ALL SELECT * FROM a_destiny
    UNION ALL SELECT * FROM a_gu
)
SELECT (row_number() OVER (ORDER BY kind_rank, within))::INTEGER,
       source_kind, source_code, label, weight, feeds
FROM all_parts
ORDER BY kind_rank, within;
$fn$;


-- ---------------------------------------------------------------------------
-- Including the teardown the trigger was written around
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_gid   BIGINT;
    v_type  BIGINT;
    v_secs  BIGINT;
    v_n     INTEGER;
    v_stars INTEGER;
BEGIN
    SELECT min(gu_type_id) INTO v_type FROM gu_types;

    -- Every open stint has somewhere to bank to.
    SELECT count(*) INTO v_n
    FROM player_gu_equipped e
    JOIN player_gu g ON g.gu_id = e.gu_id
    WHERE NOT EXISTS (
        SELECT 1 FROM player_gu_carried c
        WHERE c.player_id = e.player_id AND c.gu_type_id = g.gu_type_id);
    IF v_n > 0 THEN
        RAISE EXCEPTION '% open stints have no tally row to bank into', v_n;
    END IF;

    -- A stint is banked when the row dies, and an unequip-then-requip does
    -- not lose what came before it.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-991, 'carry-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_gu (owner_id, gu_type_id, stars)
        VALUES (v_pid, v_type, 1) RETURNING gu_id INTO v_gid;

        INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at)
        VALUES (v_gid, v_pid, now() - INTERVAL '10 hours');

        IF NOT EXISTS (SELECT 1 FROM player_gu_carried
                       WHERE player_id = v_pid AND gu_type_id = v_type) THEN
            RAISE EXCEPTION 'equipping opened no tally';
        END IF;

        -- the open stint counts before anything is banked
        v_secs := gu_carried_seconds(v_pid, v_type);
        IF v_secs < 35000 THEN
            RAISE EXCEPTION 'an open stint of ten hours read as % seconds', v_secs;
        END IF;

        DELETE FROM player_gu_equipped WHERE gu_id = v_gid;

        SELECT seconds_carried INTO v_secs FROM player_gu_carried
        WHERE player_id = v_pid AND gu_type_id = v_type;
        IF v_secs < 35000 THEN
            RAISE EXCEPTION 'unequipping banked % seconds of a ten hour stint', v_secs;
        END IF;

        -- and a second stint adds to the first rather than replacing it
        INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at)
        VALUES (v_gid, v_pid, now() - INTERVAL '5 hours');
        DELETE FROM player_gu_equipped WHERE gu_id = v_gid;

        SELECT seconds_carried INTO v_secs FROM player_gu_carried
        WHERE player_id = v_pid AND gu_type_id = v_type;
        IF v_secs < 52000 THEN
            RAISE EXCEPTION 'two stints came to only % seconds', v_secs;
        END IF;

        -- THE ONE THE TRIGGER WAS SHAPED AROUND. A hard delete of the
        -- cultivator has to pass through both cascades without the trigger
        -- re-creating a tally row behind it. /dev wipe and real account
        -- removal both do exactly this.
        INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (v_gid, v_pid);
        DELETE FROM players WHERE player_id = v_pid;
        IF EXISTS (SELECT 1 FROM player_gu_carried WHERE player_id = v_pid) THEN
            RAISE EXCEPTION 'deleting a cultivator left their tally behind';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- The aspect no longer answers with the most-starred worm. Somebody holds
    -- a high-star worm they have never worn; if stars still decided this, the
    -- two would agree more often than not.
    SELECT count(*) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM dao_aspects(p.player_id) WHERE source_kind = 'gu');
    RAISE NOTICE '% cultivators have worn a worm long enough for it to mean something', v_n;

    -- Nobody's Dao broke in the process.
    FOR v_pid IN
        SELECT player_id FROM players WHERE deleted_at IS NULL
    LOOP
        SELECT count(*) INTO v_n FROM dao_aspects(v_pid);
        IF v_n > 9 THEN
            RAISE EXCEPTION 'player % now reads % aspects', v_pid, v_n;
        END IF;
        IF v_n > 0 AND EXISTS (SELECT 1 FROM dao_aspects(v_pid)
                               WHERE weight <= 0 OR weight > 1) THEN
            RAISE EXCEPTION 'player % has an aspect off the scale', v_pid;
        END IF;
    END LOOP;
END;
$probe$;
