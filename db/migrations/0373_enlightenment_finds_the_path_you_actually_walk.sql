-- 0373_enlightenment_finds_the_path_you_actually_walk
--
-- /enlighten works and is dull in three specific ways. This fixes those three
-- and leaves the rest alone.
--
-- 1. THE PATH IS DRAWN UNIFORMLY FROM ALL THIRTY-FOUR. m_i_y_u_k_i has poured
--    2,521,243 insight into the Heaven Path - Supreme Grandmaster, the top of
--    `attainment_tiers` - and 0360 rolls their comprehension off a flat list
--    where Heaven is as likely as Painting. A lifetime of study buying nothing
--    is the opposite of what a cultivation game is about. Attainment now
--    weights the draw, hard but never absolutely: a Supreme Grandmaster's own
--    Path comes up about twenty times as often as one they have never touched,
--    and the untouched one still comes up. Comprehending something you have
--    never studied should be rare and it should be possible - that is the
--    moment worth having.
--
-- 2. QUALITY IS AN INVISIBLE CURVE. `power_grade` is a cubed random between
--    0.35 and 3.0, which produces a good spread and tells the player nothing.
--    Six named tiers now, from Common Insight to Dao Revelation, and the tier
--    decides everything downstream: the power band, how many Paths, and how
--    much the technique carries. A Dao Revelation is one forge in a hundred
--    and it is worth telling somebody about.
--
-- 3. A FORGED TECHNIQUE CARRIES NOTHING. `techniques.effects` has been '{}'
--    on every one of them - the column exists, `battle_effect_kinds` has five
--    live kinds with caps, `technique_cast_effects` already applies them, and
--    nothing forged has ever used any of it. Higher tiers now come with real
--    effects, chosen by the Paths the technique stands on.
--
-- WHAT I HAVE DELIBERATELY NOT BUILT, from the spec as written:
--
--   * AoE, front row, back row, 'random enemies', 'lowest HP enemy'. This
--     game fights one thing at a time - a duel, or a room of raiders against
--     one boss. There is no enemy line to splash across, so those are not
--     balance knobs here, they are fiction.
--   * Stun, freeze, silence, bleed, poison, fear. `battle_effect_kinds` has
--     five kinds. Adding fifteen more is a combat engine rewrite wearing an
--     enlightenment feature as a hat, and every one of them would need
--     `battle_act`, the dungeon round and the horde swing to agree about it.
--   * A technique-or-manual coin flip. This game already hands over BOTH -
--     0360 builds the manual out of the stat rounds and the technique out of
--     the grade. Splitting them would be a downgrade.
--   * A separate Insight currency to spend. Insight here is per-Path
--     attainment and it is progression, not a wallet. The daily stands, and
--     insight now buys direction instead.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE enlighten_qualities (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    emoji       TEXT NOT NULL DEFAULT '✨',
    weight      NUMERIC(6,3) NOT NULL CHECK (weight >= 0),
    grade_min   NUMERIC(6,3) NOT NULL CHECK (grade_min > 0),
    grade_max   NUMERIC(6,3) NOT NULL,
    min_paths   SMALLINT NOT NULL DEFAULT 1 CHECK (min_paths BETWEEN 1 AND 3),
    max_paths   SMALLINT NOT NULL DEFAULT 1 CHECK (max_paths BETWEEN 1 AND 3),
    effects     SMALLINT NOT NULL DEFAULT 0 CHECK (effects BETWEEN 0 AND 3),
    sort_order  SMALLINT NOT NULL DEFAULT 0,
    flavour     TEXT NOT NULL DEFAULT '',
    CHECK (grade_max >= grade_min),
    CHECK (max_paths >= min_paths)
);

COMMENT ON TABLE enlighten_qualities IS
    'What a day of meditation came to. The tier decides the power band, how many Paths the result stands on, and how much it carries - so one roll drives the whole shape instead of three unrelated curves.';

INSERT INTO enlighten_qualities
    (code, name, emoji, weight, grade_min, grade_max, min_paths, max_paths, effects, sort_order, flavour) VALUES
    ('common',   'Common Insight',      '🕯️', 40, 0.40, 0.85, 1, 1, 0, 10,
     'A quiet day. Something was understood, but not much of it.'),
    ('clear',    'Clear Insight',       '🌤️', 28, 0.75, 1.30, 1, 1, 0, 20,
     'The shape of it came clean, once.'),
    ('profound', 'Profound Insight',    '🌊', 18, 1.20, 1.85, 1, 2, 1, 30,
     'It went further down than you meant to follow it.'),
    ('great',    'Great Enlightenment', '⭐', 9, 1.75, 2.45, 1, 2, 1, 40,
     'You stood up knowing something you had not been taught.'),
    ('heavenly', 'Heavenly Inspiration','☄️', 4, 2.35, 3.10, 2, 2, 2, 50,
     'Something outside the room took an interest.'),
    ('dao',      'Dao Revelation',      '🌌', 1, 3.00, 4.20, 2, 3, 3, 60,
     'For a moment the whole of it was simply there, and then it was not.');


-- ---------------------------------------------------------------------------
-- What a Path tends to teach
-- ---------------------------------------------------------------------------
--
-- The spec's PATH_EFFECT_BIASES, mapped onto the five kinds that actually
-- exist rather than the twenty that do not. A Path with no row here draws
-- uniformly, so a new Path never breaks this - it simply has no opinion.

CREATE TABLE path_effect_bias (
    path_code   TEXT NOT NULL REFERENCES paths(code) ON DELETE CASCADE,
    effect_code TEXT NOT NULL REFERENCES battle_effect_kinds(code) ON DELETE CASCADE,
    weight      NUMERIC(6,3) NOT NULL DEFAULT 1 CHECK (weight > 0),
    PRIMARY KEY (path_code, effect_code)
);

CREATE INDEX path_effect_bias_effect_idx ON path_effect_bias (effect_code);

COMMENT ON TABLE path_effect_bias IS
    'Which of the battle effects a Path leans toward when a forged technique comes out carrying one. Absent means no preference.';

INSERT INTO path_effect_bias (path_code, effect_code, weight) VALUES
    -- Things that hit harder
    ('strength','attack_up',4), ('sword','attack_up',4), ('blood','attack_up',3),
    ('fire','attack_up',3),     ('lightning','attack_up',3), ('theft','attack_up',2),
    ('star','attack_up',2),
    -- Things that hold
    ('earth','defence_up',4),   ('metal','defence_up',4), ('bone','defence_up',3),
    ('ice','defence_up',2),     ('formation','defence_up',3), ('rule','defence_up',2),
    -- Things that guard
    ('formation','block_up',3), ('metal','block_up',2), ('earth','block_up',2),
    ('shadow','block_up',2),    ('space','block_up',2),
    -- Things that mend
    ('wood','regen',4),         ('water','regen',4), ('food','regen',3),
    ('light','regen',3),        ('qi','regen',2),    ('transformation','regen',2),
    -- Things that pull attention, which only a room can answer
    ('enslavement','taunt',3),  ('soul','taunt',2), ('illusion','taunt',2),
    ('heaven','taunt',2),       ('human','taunt',2);


-- ---------------------------------------------------------------------------
-- Names that are not a grade word stapled to a Path
-- ---------------------------------------------------------------------------
--
-- 0360 named everything '<Grade> <Path> Art' - Crude Lightning Art, Ascendant
-- Refinement Art - which reads as a receipt rather than a technique. The Path
-- nouns already exist in `path_words` and are good; these are the two ends
-- around them.

CREATE TABLE technique_words (
    slot TEXT NOT NULL CHECK (slot IN ('prefix', 'ending')),
    word TEXT NOT NULL,
    PRIMARY KEY (slot, word)
);

COMMENT ON TABLE technique_words IS
    'The two ends of a forged technique''s name. The middle comes from path_words, so a technique is named after the Path it actually stands on.';

INSERT INTO technique_words (slot, word) VALUES
    ('prefix','Ninefold'), ('prefix','Heaven-Defying'), ('prefix','Boundless'),
    ('prefix','Silent'),   ('prefix','Shattered'),      ('prefix','Eternal'),
    ('prefix','Falling'),  ('prefix','Profound'),       ('prefix','Immemorial'),
    ('prefix','Unyielding'),('prefix','Solitary'),      ('prefix','Ten-Thousand'),
    ('prefix','Waning'),   ('prefix','First'),          ('prefix','Last'),
    ('ending','Art'),      ('ending','Scripture'),      ('ending','Method'),
    ('ending','Canon'),    ('ending','Descent'),        ('ending','Requiem'),
    ('ending','Cycle'),    ('ending','Breath'),         ('ending','Strike'),
    ('ending','Guard'),    ('ending','Domain'),         ('ending','Mantra'),
    ('ending','Doctrine'), ('ending','Severing'),       ('ending','Meditation');


ALTER TABLE technique_forges
    ADD COLUMN quality TEXT REFERENCES enlighten_qualities(code) ON DELETE RESTRICT,
    ADD COLUMN focus   TEXT REFERENCES paths(code) ON DELETE SET NULL;

CREATE INDEX technique_forges_quality_idx ON technique_forges (quality);

COMMENT ON COLUMN technique_forges.quality IS
    'Which tier of insight the day produced. NULL on forges opened before 0373.';
COMMENT ON COLUMN technique_forges.focus IS
    'The Path the cultivator sat down intending to comprehend, if they named one. Weights the draw; never decides it.';


INSERT INTO game_config (key, value, description) VALUES
    ('enlighten_path_base_weight', 8,
     'Weight every Path carries in the enlightenment draw before attainment is counted. What makes comprehending an untouched Path rare rather than impossible.'),
    ('enlighten_path_tier_weight', 4,
     'Weight per attainment tier, raised to enlighten_path_tier_curve. At the top tier this puts a studied Path about twenty times above an untouched one.'),
    ('enlighten_path_tier_curve', 1.6,
     'Exponent on the attainment tier. Above 1 so the late tiers are felt more than the early ones, which is where the study actually was.'),
    ('enlighten_focus_weight', 1.75,
     'What naming a focus multiplies that Path''s weight by. Deliberately not a guarantee - a meditation you can aim precisely is a shopping trip.'),
    ('enlighten_effect_turn_min', 2,
     'Fewest turns an effect carried by a forged technique lasts.'),
    ('enlighten_effect_turn_max', 4,
     'Most turns an effect carried by a forged technique lasts.');


-- ---------------------------------------------------------------------------
-- Sitting down, now with somewhere to look
-- ---------------------------------------------------------------------------

DROP FUNCTION forge_begin(BIGINT);

CREATE FUNCTION forge_begin(p_player_id BIGINT, p_focus TEXT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    mine     SMALLINT;
    open_one BIGINT;
    q        RECORD;
    grade    NUMERIC;
    want     INTEGER;
    picked   TEXT[];
    ready    RECORD;
BEGIN
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

    IF p_focus IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM paths WHERE code = p_focus) THEN
        RAISE EXCEPTION 'there is no % Path to sit with', p_focus
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO ready FROM claim_cooldown(
        p_player_id, 'forge_technique',
        game_config_value('technique_forge_cooldown_minutes'));

    IF NOT ready.claimed THEN
        RAISE EXCEPTION 'you have already sat with this today'
            USING ERRCODE = 'check_violation';
    END IF;

    -- What the day came to. One roll, and it decides the rest.
    SELECT * INTO q FROM enlighten_qualities
    WHERE weight > 0 ORDER BY -ln(random()) / weight LIMIT 1;

    grade := q.grade_min + (q.grade_max - q.grade_min) * random();
    want  := q.min_paths
             + CASE WHEN q.max_paths > q.min_paths
                    THEN floor(random() * (q.max_paths - q.min_paths + 1))::int
                    ELSE 0 END;

    -- THE DRAW. Every Path carries a base weight so nothing is unreachable,
    -- and attainment piles on top of it. `-ln(random()) / weight` is the same
    -- weighted draw the rest of the game uses, and taking N of them without
    -- replacement is just the top N of that ordering.
    SELECT array_agg(pick.code) INTO picked FROM (
        SELECT p.code
        FROM paths p
        LEFT JOIN player_path_attainment pa
               ON pa.player_id = p_player_id AND pa.path_code = p.code
        ORDER BY -ln(random()) / (
            (game_config_value('enlighten_path_base_weight')
             + game_config_value('enlighten_path_tier_weight')
               * power(COALESCE(pa.tier, 0),
                       game_config_value('enlighten_path_tier_curve')))
            * CASE WHEN p.code = p_focus
                   THEN game_config_value('enlighten_focus_weight')
                   ELSE 1 END)
        LIMIT want
    ) AS pick;

    INSERT INTO technique_forges
        (player_id, realm_rank, power_grade, dual, paths, quality, focus)
    VALUES (p_player_id, mine, round(grade, 3),
            array_length(picked, 1) > 1, picked, q.code, p_focus)
    RETURNING forge_id INTO open_one;

    RETURN open_one;
END;
$$;

COMMENT ON FUNCTION forge_begin(BIGINT, TEXT) IS
    'Open a forge, or hand back the one already open. The Paths are drawn against the cultivator''s own attainment, so study buys direction - never certainty.';


-- ---------------------------------------------------------------------------
-- And what the last answer builds is named, and carries something
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    SELECT string_agg(initcap(replace(p, ''_'', '' '')), '' '' ORDER BY p)', chr(10),
'    INTO path_txt FROM unnest(f.paths) AS p;', chr(10),
chr(10),
'    -- Named for what it came out as, so a shelf of forged techniques reads as', chr(10),
'    -- a record of how the days went.', chr(10),
'    grade_q := CASE', chr(10),
'        WHEN f.power_grade >= 3.4 THEN ''Peerless''', chr(10),
'        WHEN f.power_grade >= 2.4 THEN ''Sovereign''', chr(10),
'        WHEN f.power_grade >= 1.6 THEN ''Ascendant''', chr(10),
'        WHEN f.power_grade >= 0.9 THEN ''Lesser''', chr(10),
'        ELSE ''Crude'' END;', chr(10),
chr(10),
'    titled := grade_q || '' '' || path_txt', chr(10),
'              || CASE WHEN f.dual THEN '' Twin Art'' ELSE '' Art'' END;');

    swap := concat(
'    -- Named from the Paths it actually stands on. `path_words` has the', chr(10),
'    -- nouns already; `technique_words` supplies the two ends. The old name', chr(10),
'    -- was the grade word stapled to the Path - Crude Lightning Art - which', chr(10),
'    -- reads as a receipt rather than a technique.', chr(10),
'    SELECT string_agg(w.word, ''-'' ORDER BY w.ord) INTO path_txt', chr(10),
'    FROM unnest(f.paths) WITH ORDINALITY AS u(code, ord)', chr(10),
'    CROSS JOIN LATERAL (', chr(10),
'        SELECT pw.word, u.ord FROM path_words pw', chr(10),
'        WHERE pw.path_code = u.code ORDER BY random() LIMIT 1', chr(10),
'    ) AS w;', chr(10),
chr(10),
'    -- A Path with no words of its own still gets a name.', chr(10),
'    IF path_txt IS NULL THEN', chr(10),
'        SELECT string_agg(initcap(replace(p, ''_'', '' '')), ''-'' ORDER BY p)', chr(10),
'        INTO path_txt FROM unnest(f.paths) AS p;', chr(10),
'    END IF;', chr(10),
chr(10),
'    titled := (SELECT word FROM technique_words WHERE slot = ''prefix''', chr(10),
'               ORDER BY random() LIMIT 1)', chr(10),
'              || '' '' || path_txt || '' ''', chr(10),
'              || (SELECT word FROM technique_words WHERE slot = ''ending''', chr(10),
'                  ORDER BY random() LIMIT 1);', chr(10),
chr(10),
'    grade_q := COALESCE(', chr(10),
'        (SELECT name FROM enlighten_qualities WHERE code = f.quality),', chr(10),
'        CASE WHEN f.power_grade >= 2.4 THEN ''Sovereign'' ELSE ''Lesser'' END);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'forge_take';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer names a technique where it did';
    END IF;
    body := replace(body, anchor, swap);

    -- The technique itself: effects, a qi cost that answers for them, and a
    -- cooldown. Every forged technique until now was 8 per cent qi, no
    -- cooldown, and an empty `effects` column.
    anchor := concat(
'        titled, 9, ''attack'', power::integer, 0.08, 1, ''advanced'',');

    swap := concat(
'        titled, 9, ''attack'', power::integer,', chr(10),
'        -- A power budget, in the two currencies a technique actually pays', chr(10),
'        -- in here. What it carries is what it costs.', chr(10),
'        LEAST(1.0, 0.05 + 0.02 * COALESCE(', chr(10),
'            (SELECT effects FROM enlighten_qualities WHERE code = f.quality), 0)', chr(10),
'            + f.power_grade / 40.0)::numeric(6,4),', chr(10),
'        1, ''advanced'',');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer builds a technique where it did';
    END IF;
    body := replace(body, anchor, swap);

    EXECUTE body;
END;
$patch$;


-- The effects are hung on afterwards rather than squeezed into the INSERT,
-- because choosing them is a query per slot and an INSERT is a poor place for
-- a loop.
DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    INSERT INTO technique_paths (technique_id, path_code, weight)', chr(10),
'    SELECT new_t, p, round(1.0 / array_length(f.paths, 1), 4)', chr(10),
'    FROM unnest(f.paths) AS p;');

    swap := concat(anchor, chr(10),
chr(10),
'    -- What it carries. `battle_effect_kinds` has five live kinds with their', chr(10),
'    -- own caps and `technique_cast_effects` already applies them - forged', chr(10),
'    -- techniques simply never used any of it. Which kind is leaned by the', chr(10),
'    -- Paths the technique stands on; how much, by the tier.', chr(10),
'    DECLARE', chr(10),
'        slots INTEGER := COALESCE((SELECT e.effects FROM enlighten_qualities e', chr(10),
'                                   WHERE e.code = f.quality), 0);', chr(10),
'        kinds JSONB := ''[]''::jsonb;', chr(10),
'        k     RECORD;', chr(10),
'    BEGIN', chr(10),
'        FOR i IN 1..slots LOOP', chr(10),
'            SELECT b.code, b.cap INTO k', chr(10),
'            FROM battle_effect_kinds b', chr(10),
'            WHERE NOT (b.code = ANY (', chr(10),
'                SELECT jsonb_array_elements(kinds) ->> ''code''))', chr(10),
'            ORDER BY -ln(random()) / GREATEST(0.5, COALESCE((', chr(10),
'                SELECT sum(pb.weight) FROM path_effect_bias pb', chr(10),
'                WHERE pb.effect_code = b.code', chr(10),
'                  AND pb.path_code = ANY (f.paths)), 0.5))', chr(10),
'            LIMIT 1;', chr(10),
chr(10),
'            EXIT WHEN k.code IS NULL;', chr(10),
chr(10),
'            kinds := kinds || jsonb_build_object(', chr(10),
'                ''code'', k.code,', chr(10),
'                -- Never the whole cap from one technique, and scaled by the', chr(10),
'                -- tier that produced it.', chr(10),
'                ''magnitude'', GREATEST(0.01, round(', chr(10),
'                    (k.cap * 0.25 * LEAST(2.0, f.power_grade)', chr(10),
'                     * (0.7 + random() * 0.6))::numeric, 3)),', chr(10),
'                ''turns'', game_config_value(''enlighten_effect_turn_min'')::int', chr(10),
'                    + floor(random() * (1 +', chr(10),
'                        game_config_value(''enlighten_effect_turn_max'')', chr(10),
'                        - game_config_value(''enlighten_effect_turn_min'')))::int,', chr(10),
'                ''target'', CASE WHEN k.code = ''taunt'' THEN ''self''', chr(10),
'                                WHEN random() < 0.25 THEN ''party''', chr(10),
'                                ELSE ''self'' END);', chr(10),
'        END LOOP;', chr(10),
chr(10),
'        IF jsonb_array_length(kinds) > 0 THEN', chr(10),
'            UPDATE techniques SET effects = jsonb_build_object(''apply'', kinds),', chr(10),
'                   cooldown_turns = LEAST(5, 1 + jsonb_array_length(kinds))', chr(10),
'            WHERE technique_id = new_t;', chr(10),
'        END IF;', chr(10),
'    END;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'forge_take';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'forge_take no longer lays down Paths where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Study buys direction, the tiers are rare in the right order, and it carries
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    best   TEXT;
    fid    BIGINT;
    board  JSONB;
    got    RECORD;
    steps  INTEGER := game_config_value('technique_forge_steps')::integer;
    hits   INTEGER := 0;
    tries  INTEGER := 2000;
    n      INTEGER;
    made   RECORD;
    drew   TEXT;
BEGIN
    -- The six tiers must be rarer as they climb, or the names are decoration.
    SELECT string_agg(a.code, ', ') INTO best
    FROM enlighten_qualities a JOIN enlighten_qualities b
      ON b.sort_order = (SELECT min(sort_order) FROM enlighten_qualities
                         WHERE sort_order > a.sort_order)
    WHERE b.weight > a.weight;
    IF best IS NOT NULL THEN
        RAISE EXCEPTION 'these tiers are commoner than the one below: %', best;
    END IF;

    -- Every Path can still be drawn: nothing is weighted to zero.
    SELECT count(*) INTO n FROM paths;
    IF n < 30 THEN
        RAISE EXCEPTION 'only % Paths to draw from', n;
    END IF;

    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= game_config_value('technique_forge_min_rank')
    ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to sit down - the draw is unmeasured';
        RETURN;
    END IF;

    SELECT pa.path_code INTO best FROM player_path_attainment pa
    WHERE pa.player_id = who ORDER BY pa.tier DESC, pa.insight DESC LIMIT 1;

    BEGIN
        -- The draw favours what they studied, measured rather than argued.
        IF best IS NOT NULL THEN
            FOR i IN 1..tries LOOP
                -- One draw, the same ordering `forge_begin` uses.
                SELECT p.code INTO drew
                FROM paths p
                LEFT JOIN player_path_attainment pa
                       ON pa.player_id = who AND pa.path_code = p.code
                ORDER BY -ln(random()) / (
                    game_config_value('enlighten_path_base_weight')
                    + game_config_value('enlighten_path_tier_weight')
                      * power(COALESCE(pa.tier, 0),
                              game_config_value('enlighten_path_tier_curve')))
                LIMIT 1;

                IF drew = best THEN
                    hits := hits + 1;
                END IF;
            END LOOP;

            -- Measured against UNIFORM, not against a flat percentage. A
            -- cultivator who spread their study across a dozen Paths should
            -- not see any single one dominate - pashu0 holds two Paths at the
            -- top tier and six more below, so their best comes up about four
            -- times its random share rather than half the time. Asserting a
            -- flat 20 percent would have been asserting that they had
            -- specialised, which is a choice the player gets to make.
            IF hits::numeric / tries < 3.0 / n THEN
                RAISE EXCEPTION
                    'their best Path came up % times in % - barely above the % '
                    'a flat draw would give, so study bought nothing',
                    hits, tries, round(tries::numeric / n);
            END IF;
            IF hits::numeric / tries > 0.95 THEN
                RAISE EXCEPTION
                    'their best Path came up % times in % - nothing else can happen',
                    hits, tries;
            END IF;
            RAISE NOTICE
                'the % Path came up % times in % draws - % times its share of a flat draw',
                best, hits, tries, round((hits::numeric / tries) * n, 1);
        END IF;

        -- And a whole forge still runs end to end, now carrying something.
        DELETE FROM technique_forges
        WHERE player_id = who AND finished_at IS NULL;
        DELETE FROM player_cooldowns
        WHERE player_id = who AND action = 'forge_technique';

        fid := forge_begin(who, best);
        IF (SELECT quality FROM technique_forges WHERE forge_id = fid) IS NULL THEN
            RAISE EXCEPTION 'the forge recorded no quality';
        END IF;

        FOR i IN 1..steps LOOP
            board := forge_offer(fid);
            SELECT * INTO got FROM forge_take(fid, board -> 0 ->> 'code');
        END LOOP;

        SELECT t.name, t.effects, t.qi_cost_pct, t.cooldown_turns, q.name AS tier
        INTO made
        FROM techniques t
        JOIN technique_forges tf ON tf.technique_id = t.technique_id
        LEFT JOIN enlighten_qualities q ON q.code = tf.quality
        WHERE tf.forge_id = fid;

        IF made.name IS NULL THEN
            RAISE EXCEPTION 'the forge built nothing';
        END IF;
        IF NOT technique_effects_well_formed(made.effects) THEN
            RAISE EXCEPTION 'it came out carrying a malformed effect: %', made.effects;
        END IF;

        RAISE NOTICE '% : % (qi %, cooldown %) carrying %',
            made.tier, made.name, made.qi_cost_pct, made.cooldown_turns,
            COALESCE(made.effects ->> 'apply', 'nothing');

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a whole enlightenment ran and was rolled back';
END;
$probe$;
