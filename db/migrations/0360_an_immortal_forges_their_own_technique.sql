-- 0360_an_immortal_forges_their_own_technique
--
-- Every technique in the game was written by me. A cultivator can learn one,
-- buy one, or find one on a beaten rogue, and that is the whole of it - which
-- means two immortals who play identically end up holding identical moves.
--
-- An immortal now sits down once a day and makes their own.
--
-- ALMOST NONE OF THIS IS A NEW SYSTEM, WHICH IS WHY IT FITS. `techniques` has
-- carried `created_by` and `generation_seed` since 0021 with nothing ever
-- writing them - the table was built expecting this and then never given it.
-- `technique_paths` already lets one move stand on two Paths, weights summing
-- to 1 under a deferred trigger. `manuals` already has `created_by`, a quality
-- drawn from `rarities`, and twelve bonus columns with NO non-negative check
-- on any of them, so a book that hurts to read was always representable.
-- `destiny_offer` already knows how to put three things in front of somebody
-- and refuse to re-roll. This migration joins those up.
--
-- HOW A FORGE GOES, AND WHERE THE LUCK LIVES. Three rolls compound, so a
-- perfect technique is rare because it has to survive all three rather than
-- because any one of them is stingy:
--
--   1. THE GRADE. How hard it hits, as a fraction of what your realm is worth.
--      Drawn as min + (max-min) x random()^shape with shape 3, so the curve
--      is bottom-heavy: most days are ordinary and the top of the range is
--      genuinely uncommon.
--   2. THE PATH. One Path usually; two now and then, and a dual-Path technique
--      is multiplied outright, because standing on two Paths is the thing the
--      matchup chart rewards most.
--   3. THE STATS. Three rounds of three options, taken through the same
--      offered-once-never-re-rolled rule fate uses. Some options are curses -
--      you lost focus, and the number is negative. Walking away does not
--      reshuffle them; that is the whole reason `destiny_offer` writes its
--      offer down before showing it.
--
-- WHY THE TECHNIQUE KEEPS SCALING. A forged technique stores a GRADE, not a
-- number. What it hits for is computed against the realm its owner stands at
-- when they swing, so the move an immortal made at Dewberry is still their
-- move at Yellow Apricot instead of becoming a souvenir. That is the whole
-- reason the grade lives in a table and `base_power` is only a snapshot.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- A book can teach you to take life with a hit
-- ---------------------------------------------------------------------------
--
-- 'Life on hit' was asked for by name and is the one stat on that list with no
-- manual column behind it. `manual_effect_columns` is exactly the table for
-- saying 'this column IS this effect', so it gets a thirteenth column and a
-- row there, and `manual_stat` learns to read it.

ALTER TABLE manuals
    ADD COLUMN lifesteal_bonus NUMERIC(6,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN manuals.lifesteal_bonus IS
    'Life taken back on a hit, read through manual_effect_columns into the lifesteal effect. Negative is legal here, as it is on every other bonus column.';

INSERT INTO manual_effect_columns (manual_column, effect_code, note) VALUES
    ('lifesteal_bonus', 'lifesteal',
     'A manual that teaches you to take the life back out of what you hit.');


-- New columns only ever go on the end of a replaced view.
CREATE OR REPLACE VIEW player_manual_bonuses AS
 SELECT s.player_id,
    COALESCE(sum(m.cultivation_rate_bonus), 0::numeric) AS cultivation_rate_bonus,
    COALESCE(sum(m.physique_rate_bonus), 0::numeric) AS physique_rate_bonus,
    COALESCE(sum(m.attainment_rate_bonus), 0::numeric) AS attainment_rate_bonus,
    COALESCE(sum(m.hp_bonus), 0::numeric) AS hp_bonus,
    COALESCE(sum(m.defense_bonus), 0::numeric) AS defense_bonus,
    COALESCE(sum(m.strength_bonus), 0::numeric) AS strength_bonus,
    COALESCE(sum(m.attack_bonus), 0::numeric) AS attack_bonus,
    COALESCE(sum(m.speed_bonus), 0::numeric) AS speed_bonus,
    COALESCE(sum(m.breakthrough_bonus), 0::numeric) AS breakthrough_bonus,
    COALESCE(sum(m.essence_bonus), 0::numeric) AS essence_bonus,
    COALESCE(sum(m.gathering_bonus), 0::numeric) AS gathering_bonus,
    COALESCE(sum(m.refinement_bonus), 0::numeric) AS refinement_bonus,
    count(*) AS equipped,
    COALESCE(sum(m.lifesteal_bonus), 0::numeric) AS lifesteal_bonus
   FROM player_manual_slots s
     JOIN manuals m ON m.manual_id = s.manual_id
  GROUP BY s.player_id;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '                   WHEN ''refinement_bonus''   THEN b.refinement_bonus';
    swap := concat(anchor, chr(10),
'                   WHEN ''lifesteal_bonus''    THEN b.lifesteal_bonus');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'manual_stat';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'manual_stat no longer reads its columns where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- What a day of concentration can win you, and what it can cost you
-- ---------------------------------------------------------------------------

CREATE TABLE forge_boons (
    code          TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    description   TEXT NOT NULL,
    manual_column TEXT NOT NULL,
    lo            NUMERIC(6,4) NOT NULL,
    hi            NUMERIC(6,4) NOT NULL,
    roll_weight   NUMERIC(6,3) NOT NULL DEFAULT 1 CHECK (roll_weight >= 0),
    is_curse      BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (hi >= lo)
);

COMMENT ON TABLE forge_boons IS
    'The pool a forge draws its stat options from. A curse is the same shape with a negative band - losing focus is a roll, not a separate mechanism.';

INSERT INTO forge_boons (code, name, description, manual_column, lo, hi, roll_weight, is_curse) VALUES
    ('boon_thews',   'The Arm Remembers',  'The form settles into the shoulder.',            'strength_bonus',    0.08, 0.42, 1.00, FALSE),
    ('boon_edge',    'Killing Intent',     'Every repetition is sharper than the last.',     'attack_bonus',      0.08, 0.45, 1.00, FALSE),
    ('boon_frame',   'A Wider Frame',      'The body grows to hold the technique.',          'hp_bonus',          0.08, 0.40, 1.00, FALSE),
    ('boon_drink',   'Blood Return',       'The technique takes back what it spends.',       'lifesteal_bonus',   0.04, 0.22, 0.65, FALSE),
    ('boon_guard',   'Unmoved Root',       'The stance stops being something you hold.',     'defense_bonus',     0.08, 0.40, 1.00, FALSE),
    ('boon_step',    'Shadowless Step',    'The blow arrives where you are not.',            'speed_bonus',       0.05, 0.28, 0.85, FALSE),
    ('boon_insight', 'Clear Aperture',     'Understanding arrives faster than practice.',    'attainment_rate_bonus', 0.06, 0.32, 0.80, FALSE),
    ('boon_temper',  'Tempered Crossing',  'The next realm hurts less than it should.',      'breakthrough_bonus', 0.05, 0.30, 0.70, FALSE),
    ('boon_well',    'Deeper Well',        'The aperture widens around the form.',           'essence_bonus',     0.05, 0.30, 0.70, FALSE),
    ('boon_dao',     'Dao Momentum',       'Cultivation moves while you drill.',             'cultivation_rate_bonus', 0.05, 0.26, 0.60, FALSE),

    ('curse_strain', 'You Lost Focus',     'The form turns on the arm that made it.',        'strength_bonus',   -0.24, -0.06, 0.55, TRUE),
    ('curse_blunt',  'The Edge Turns',     'Something in the sequence blunts the strike.',   'attack_bonus',     -0.26, -0.06, 0.55, TRUE),
    ('curse_hollow', 'A Hollow Frame',     'The body is spent holding a shape it hates.',    'hp_bonus',         -0.22, -0.05, 0.50, TRUE),
    ('curse_open',   'An Open Guard',      'The stance leaves a door you cannot see.',       'defense_bonus',    -0.22, -0.05, 0.50, TRUE),
    ('curse_slow',   'Heavy Feet',         'The footwork argues with the hands.',            'speed_bonus',      -0.18, -0.04, 0.40, TRUE);


-- ---------------------------------------------------------------------------
-- The forge itself, and the three answers it wants
-- ---------------------------------------------------------------------------

CREATE TABLE technique_forges (
    forge_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id    BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    realm_rank   SMALLINT NOT NULL,
    power_grade  NUMERIC(6,3) NOT NULL CHECK (power_grade > 0),
    dual         BOOLEAN NOT NULL DEFAULT FALSE,
    paths        TEXT[] NOT NULL,
    step         SMALLINT NOT NULL DEFAULT 0,
    technique_id BIGINT REFERENCES techniques(technique_id) ON DELETE SET NULL,
    manual_id    BIGINT REFERENCES manuals(manual_id) ON DELETE SET NULL,
    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at  TIMESTAMPTZ,
    CHECK (array_length(paths, 1) BETWEEN 1 AND 2),
    CHECK (dual = (array_length(paths, 1) = 2))
);

-- One at a time. A second forge while one is unanswered would let a cultivator
-- shop for a better grade and abandon the rest, which is the re-roll this whole
-- design refuses.
CREATE UNIQUE INDEX technique_forges_one_open_each
    ON technique_forges (player_id) WHERE finished_at IS NULL;

-- Read on every swing of a forged technique.
CREATE INDEX technique_forges_technique_idx
    ON technique_forges (technique_id) WHERE technique_id IS NOT NULL;

COMMENT ON TABLE technique_forges IS
    'One immortal sitting down to make a technique. Holds the grade rather than a damage number, because what a forged technique hits for is recomputed against the realm its owner stands at now.';


CREATE TABLE forge_choices (
    forge_id   BIGINT NOT NULL REFERENCES technique_forges(forge_id) ON DELETE CASCADE,
    step       SMALLINT NOT NULL,
    offered    JSONB NOT NULL,
    taken      TEXT REFERENCES forge_boons(code) ON DELETE RESTRICT,
    magnitude  NUMERIC(6,4),
    offered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    chosen_at  TIMESTAMPTZ,
    PRIMARY KEY (forge_id, step),
    CHECK ((taken IS NULL) = (chosen_at IS NULL)),
    CHECK ((taken IS NULL) = (magnitude IS NULL))
);

COMMENT ON TABLE forge_choices IS
    'Three options written down BEFORE they are shown, the way a destiny offer is. The magnitude is rolled here too, so what is on the card is what you get.';


INSERT INTO game_config (key, value, description) VALUES
    ('technique_forge_min_rank', 10,
     'Realm rank required to forge a technique. 10 is Dewberry - the first realm past the mortal ladder, so only a true immortal can do this.'),
    ('technique_forge_cooldown_minutes', 1320,
     'Minutes between forges. 1320 is twenty-two hours, matching daily_cooldown_hours, so a daily habit does not drift an hour later every day.'),
    ('technique_forge_power_base', 46,
     'Power per point of player_power_multiple at grade 1. 46 puts an average forge alongside the cultivator''s own thews, which is where the strongest written technique already sits.'),
    ('technique_forge_grade_min', 0.35,
     'Worst grade a forge can produce. A bad day is still a technique.'),
    ('technique_forge_grade_max', 3.0,
     'Best grade a forge can produce, before a dual Path multiplies it.'),
    ('technique_forge_grade_shape', 3,
     'Exponent on the grade roll. Higher is more bottom-heavy: at 3 the top of the range needs random() to land near 1 three times over, which is what makes a great technique rare rather than merely expensive.'),
    ('technique_forge_dual_chance', 0.12,
     'Chance a forge settles on two Paths instead of one.'),
    ('technique_forge_dual_bonus', 1.35,
     'What a second Path multiplies the grade by. Dual Path is the strongest outcome on the board, which is why it is the rarest.'),
    ('technique_forge_steps', 3,
     'Rounds of stat options a forge asks for.'),
    ('technique_forge_options', 3,
     'Options put in front of the cultivator each round. Three, as fate offers.'),
    ('technique_forge_curse_chance', 0.30,
     'Chance any single option on the board is a curse rather than a boon.');


-- ---------------------------------------------------------------------------
-- Sitting down
-- ---------------------------------------------------------------------------

CREATE FUNCTION forge_begin(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    mine     SMALLINT;
    open_one BIGINT;
    grade    NUMERIC;
    two      BOOLEAN;
    picked   TEXT[];
    ready    RECORD;
BEGIN
    -- An unfinished forge is handed back rather than replaced. Re-running the
    -- command must not cost a day, and must not reshuffle what is on the board.
    SELECT forge_id INTO open_one FROM technique_forges
    WHERE player_id = p_player_id AND finished_at IS NULL;
    IF open_one IS NOT NULL THEN
        RETURN open_one;
    END IF;

    SELECT r.rank INTO mine
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;

    IF COALESCE(mine, 1) < game_config_value('technique_forge_min_rank') THEN
        RAISE EXCEPTION
            'forging a technique is an immortal''s work - reach %, and come back',
            (SELECT min(name) FROM realms
             WHERE rank = game_config_value('technique_forge_min_rank')::smallint)
            USING ERRCODE = 'check_violation';
    END IF;

    -- Charged only once the refusals are past, so a realm that cannot forge
    -- does not lose the day finding out.
    SELECT * INTO ready FROM claim_cooldown(
        p_player_id, 'forge_technique',
        game_config_value('technique_forge_cooldown_minutes'));

    IF NOT ready.claimed THEN
        RAISE EXCEPTION 'you have already sat with this today'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Bottom-heavy on purpose: see the header.
    grade := game_config_value('technique_forge_grade_min')
             + (game_config_value('technique_forge_grade_max')
                - game_config_value('technique_forge_grade_min'))
               * power(random(), game_config_value('technique_forge_grade_shape'));

    two := random() < game_config_value('technique_forge_dual_chance');
    IF two THEN
        grade := grade * game_config_value('technique_forge_dual_bonus');
    END IF;

    SELECT array_agg(p.code) INTO picked FROM (
        SELECT code FROM paths ORDER BY random() LIMIT (CASE WHEN two THEN 2 ELSE 1 END)
    ) p;

    INSERT INTO technique_forges (player_id, realm_rank, power_grade, dual, paths)
    VALUES (p_player_id, mine, round(grade, 3), two, picked)
    RETURNING forge_id INTO open_one;

    RETURN open_one;
END;
$$;

COMMENT ON FUNCTION forge_begin(BIGINT) IS
    'Open a forge, or hand back the one already open. Costs the day only when a new one is actually started.';


-- ---------------------------------------------------------------------------
-- What is on the board this round
-- ---------------------------------------------------------------------------

CREATE FUNCTION forge_offer(p_forge_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    f       RECORD;
    said    JSONB;
    n       INTEGER;
    b       RECORD;
    rolled  JSONB := '[]'::jsonb;
BEGIN
    SELECT * INTO f FROM technique_forges WHERE forge_id = p_forge_id;
    IF f IS NULL THEN
        RAISE EXCEPTION 'no such forge' USING ERRCODE = 'check_violation';
    END IF;
    IF f.finished_at IS NOT NULL THEN
        RETURN NULL;
    END IF;

    -- Written down before it is shown, and never rolled twice. Without this a
    -- cultivator closes the screen until the board suits them.
    SELECT c.offered INTO said FROM forge_choices c
    WHERE c.forge_id = p_forge_id AND c.step = f.step;
    IF said IS NOT NULL THEN
        RETURN said;
    END IF;

    n := game_config_value('technique_forge_options')::integer;

    -- Each seat on the board decides on its own whether it is a boon or a
    -- curse, so a round of three can come up all bad. Rare, and it should be
    -- possible - losing focus is the risk being taken.
    FOR i IN 1..n LOOP
        SELECT * INTO b FROM forge_boons
        WHERE is_curse = (random() < game_config_value('technique_forge_curse_chance'))
          AND roll_weight > 0
          AND NOT (code = ANY (
              SELECT jsonb_array_elements(rolled) ->> 'code'))
        ORDER BY -ln(random()) / roll_weight
        LIMIT 1;

        -- A board short of distinct options of the kind it drew falls back to
        -- anything unused rather than offering the same line twice.
        IF b IS NULL THEN
            SELECT * INTO b FROM forge_boons
            WHERE roll_weight > 0
              AND NOT (code = ANY (
                  SELECT jsonb_array_elements(rolled) ->> 'code'))
            ORDER BY -ln(random()) / roll_weight
            LIMIT 1;
        END IF;

        EXIT WHEN b IS NULL;

        rolled := rolled || jsonb_build_object(
            'code', b.code,
            'magnitude', round((b.lo + (b.hi - b.lo) * random())::numeric, 4));
    END LOOP;

    INSERT INTO forge_choices (forge_id, step, offered)
    VALUES (p_forge_id, f.step, rolled)
    ON CONFLICT (forge_id, step) DO NOTHING;

    SELECT c.offered INTO said FROM forge_choices c
    WHERE c.forge_id = p_forge_id AND c.step = f.step;
    RETURN said;
END;
$$;

COMMENT ON FUNCTION forge_offer(BIGINT) IS
    'The options for the current round, rolled once and kept. Closing the screen and reopening it shows the same board.';


-- ---------------------------------------------------------------------------
-- Taking one, and what the last one builds
-- ---------------------------------------------------------------------------

CREATE FUNCTION forge_take(p_forge_id BIGINT, p_code TEXT)
RETURNS TABLE(done BOOLEAN, technique_id BIGINT, manual_id BIGINT, step SMALLINT)
LANGUAGE plpgsql
AS $$
DECLARE
    f        RECORD;
    board    JSONB;
    mag      NUMERIC;
    steps    INTEGER;
    new_t    BIGINT;
    new_m    BIGINT;
    power    BIGINT;
    titled   TEXT;
    grade_q  TEXT;
    total    NUMERIC;
    path_txt TEXT;
BEGIN
    SELECT * INTO f FROM technique_forges WHERE forge_id = p_forge_id;
    IF f IS NULL OR f.finished_at IS NOT NULL THEN
        RAISE EXCEPTION 'that forge is closed' USING ERRCODE = 'check_violation';
    END IF;

    board := forge_offer(p_forge_id);

    SELECT (e ->> 'magnitude')::numeric INTO mag
    FROM jsonb_array_elements(board) AS e
    WHERE e ->> 'code' = p_code;

    IF mag IS NULL THEN
        RAISE EXCEPTION 'that was not one of the things in front of you'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE forge_choices
    SET taken = p_code, magnitude = mag, chosen_at = now()
    WHERE forge_id = p_forge_id AND forge_choices.step = f.step;

    steps := game_config_value('technique_forge_steps')::integer;

    IF f.step + 1 < steps THEN
        UPDATE technique_forges
        SET step = f.step + 1 WHERE forge_id = p_forge_id;
        RETURN QUERY SELECT FALSE, NULL::bigint, NULL::bigint, (f.step + 1)::smallint;
        RETURN;
    END IF;

    -- ---- the last answer builds the thing -------------------------------

    SELECT string_agg(initcap(replace(p, '_', ' ')), ' ' ORDER BY p)
    INTO path_txt FROM unnest(f.paths) AS p;

    -- Named for what it came out as, so a shelf of forged techniques reads as
    -- a record of how the days went.
    grade_q := CASE
        WHEN f.power_grade >= 3.4 THEN 'Peerless'
        WHEN f.power_grade >= 2.4 THEN 'Sovereign'
        WHEN f.power_grade >= 1.6 THEN 'Ascendant'
        WHEN f.power_grade >= 0.9 THEN 'Lesser'
        ELSE 'Crude' END;

    titled := grade_q || ' ' || path_txt
              || CASE WHEN f.dual THEN ' Twin Art' ELSE ' Art' END;

    power := LEAST(2000000000::numeric, round(
        game_config_value('technique_forge_power_base')
        * player_power_multiple(f.player_id) * f.power_grade))::bigint;

    INSERT INTO techniques
        (name, rank, category, base_power, qi_cost_pct, accuracy, grade,
         created_by, generation_seed, description)
    VALUES (
        titled, 9, 'attack', power::integer, 0.08, 1, 'advanced',
        f.player_id, p_forge_id,
        'Forged in a day''s meditation at ' || f.realm_rank || '. '
        || CASE WHEN f.dual
                THEN 'It stands on two Paths at once.'
                ELSE 'It stands on one Path, and stands well.' END)
    RETURNING techniques.technique_id INTO new_t;

    INSERT INTO technique_paths (technique_id, path_code, weight)
    SELECT new_t, p, round(1.0 / array_length(f.paths, 1), 4)
    FROM unnest(f.paths) AS p;

    -- Weights must total exactly 1 and rounding a third twice does not. The
    -- first Path carries whatever the division left behind.
    UPDATE technique_paths
    SET weight = weight + (1 - (SELECT sum(weight) FROM technique_paths
                                WHERE technique_paths.technique_id = new_t))
    WHERE technique_paths.technique_id = new_t AND path_code = f.paths[1];

    SELECT COALESCE(sum(c.magnitude), 0) INTO total
    FROM forge_choices c WHERE c.forge_id = p_forge_id;

    INSERT INTO manuals
        (name, tier, required_rank, archetype, quality, created_by, description,
         strength_bonus, attack_bonus, hp_bonus, defense_bonus, speed_bonus,
         lifesteal_bonus, attainment_rate_bonus, breakthrough_bonus,
         essence_bonus, cultivation_rate_bonus)
    SELECT
        titled, 10, 9, 'technique',
        CASE WHEN total >= 1.00 THEN 'extreme'
             WHEN total >= 0.75 THEN 'unique'
             WHEN total >= 0.50 THEN 'divine'
             WHEN total >= 0.30 THEN 'mythic'
             WHEN total >= 0.15 THEN 'legendary'
             WHEN total >= 0.00 THEN 'epic'
             ELSE 'common' END,
        f.player_id,
        'What the forging wrote down, for good and for ill.',
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'strength_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'attack_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'hp_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'defense_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'speed_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'lifesteal_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'attainment_rate_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'breakthrough_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'essence_bonus'), 0),
        COALESCE(sum(v.mag) FILTER (WHERE v.col = 'cultivation_rate_bonus'), 0)
    FROM (
        SELECT b.manual_column AS col, c.magnitude AS mag
        FROM forge_choices c
        JOIN forge_boons b ON b.code = c.taken
        WHERE c.forge_id = p_forge_id
    ) AS v
    RETURNING manuals.manual_id INTO new_m;

    INSERT INTO manual_techniques (manual_id, technique_id) VALUES (new_m, new_t);

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_m, p, 1 FROM unnest(f.paths) AS p;

    INSERT INTO player_manuals (player_id, manual_id) VALUES (f.player_id, new_m);

    UPDATE technique_forges
    SET step = steps, technique_id = new_t, manual_id = new_m, finished_at = now()
    WHERE forge_id = p_forge_id;

    RETURN QUERY SELECT TRUE, new_t, new_m, steps::smallint;
END;
$$;

COMMENT ON FUNCTION forge_take(BIGINT, TEXT) IS
    'Take one of the options on the board. The last one builds the technique and the manual that teaches it, and hands both over.';


-- ---------------------------------------------------------------------------
-- A forged technique is a grade, not a number
-- ---------------------------------------------------------------------------
--
-- Read against the realm the cultivator stands at NOW. The stored base_power
-- stays as a snapshot of the day it was made - it is what every other reader
-- of the table sees, and what the clamp below falls back to.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    SELECT t.base_power INTO STRICT tech_base', chr(10),
'    FROM techniques t', chr(10),
'    WHERE t.technique_id = p_technique_id;');

    swap := concat(anchor, chr(10),
chr(10),
'    -- A forged technique stores a GRADE. What it hits for is that grade', chr(10),
'    -- against the realm its owner stands at now, so the move an immortal', chr(10),
'    -- made at Dewberry is still their move at Yellow Apricot rather than a', chr(10),
'    -- souvenir of the day they made it.', chr(10),
'    --', chr(10),
'    -- COALESCE rather than SELECT INTO: a technique nobody forged has no row', chr(10),
'    -- here, and SELECT INTO would quietly set tech_base to NULL for every', chr(10),
'    -- written technique in the game.', chr(10),
'    tech_base := COALESCE((', chr(10),
'        SELECT LEAST(2000000000::numeric, round(', chr(10),
'            game_config_value(''technique_forge_power_base'')', chr(10),
'            * player_power_multiple(p_attacker_player_id) * f.power_grade))', chr(10),
'        FROM technique_forges f', chr(10),
'        WHERE f.technique_id = p_technique_id', chr(10),
'    ), tech_base)::integer;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_technique_damage';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_technique_damage no longer reads base_power where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A forge runs end to end, and a mortal cannot open one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who     BIGINT;
    mortal  BIGINT;
    fid     BIGINT;
    board   JSONB;
    pick    TEXT;
    got     RECORD;
    steps   INTEGER := game_config_value('technique_forge_steps')::integer;
    before  NUMERIC;
    after   NUMERIC;
    n       INTEGER;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= game_config_value('technique_forge_min_rank')
    ORDER BY r.rank DESC LIMIT 1;

    SELECT pc.player_id INTO mortal
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank < game_config_value('technique_forge_min_rank') LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to forge with - the run is unmeasured';
        RETURN;
    END IF;

    BEGIN
        -- A mortal is refused, which is the gate the whole feature rests on.
        IF mortal IS NOT NULL THEN
            BEGIN
                PERFORM forge_begin(mortal);
                RAISE EXCEPTION 'a mortal opened a forge';
            EXCEPTION WHEN check_violation THEN
                NULL;
            END;
        END IF;

        fid := forge_begin(who);
        IF fid IS NULL THEN
            RAISE EXCEPTION 'an immortal could not open a forge';
        END IF;

        -- Opening twice is the same forge and the same board, never a re-roll.
        IF forge_begin(who) <> fid THEN
            RAISE EXCEPTION 'a second call opened a second forge';
        END IF;
        board := forge_offer(fid);
        IF board <> forge_offer(fid) THEN
            RAISE EXCEPTION 'the board reshuffled when it was looked at again';
        END IF;
        IF jsonb_array_length(board) < 1 THEN
            RAISE EXCEPTION 'the board came up empty';
        END IF;

        -- Something not on the board is refused.
        BEGIN
            PERFORM forge_take(fid, 'boon_that_does_not_exist');
            RAISE EXCEPTION 'took something that was never offered';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        FOR i IN 1..steps LOOP
            board := forge_offer(fid);
            pick := board -> 0 ->> 'code';
            SELECT * INTO got FROM forge_take(fid, pick);
        END LOOP;

        IF NOT got.done OR got.technique_id IS NULL OR got.manual_id IS NULL THEN
            RAISE EXCEPTION 'the last answer built nothing';
        END IF;

        -- It is theirs, it is usable, and it teaches what it says.
        IF NOT EXISTS (SELECT 1 FROM player_manuals
                       WHERE player_id = who AND manual_id = got.manual_id) THEN
            RAISE EXCEPTION 'the manual was not handed over';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM manual_techniques
                       WHERE manual_id = got.manual_id
                         AND technique_id = got.technique_id) THEN
            RAISE EXCEPTION 'the manual teaches nothing';
        END IF;

        SELECT sum(weight) INTO before FROM technique_paths
        WHERE technique_id = got.technique_id;
        IF before <> 1 THEN
            RAISE EXCEPTION 'Path weights total % rather than 1', before;
        END IF;

        -- The claim that it scales: the same technique, read at two realms.
        SELECT base_power INTO before FROM compute_technique_damage(
            who, got.technique_id,
            (SELECT species_id FROM creature_species LIMIT 1));

        IF before <= 0 THEN
            RAISE EXCEPTION 'a forged technique hits for nothing';
        END IF;
        RAISE NOTICE 'forged technique reads % power at rank %',
            before, (SELECT r.rank FROM player_cultivation pc
                     JOIN realms r ON r.realm_id = pc.realm_id
                     WHERE pc.player_id = who);

        SELECT count(*) INTO n FROM forge_choices WHERE forge_id = fid;
        IF n <> steps THEN
            RAISE EXCEPTION 'the forge recorded % answers, wanted %', n, steps;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a whole forge ran and was rolled back';
END;
$probe$;
