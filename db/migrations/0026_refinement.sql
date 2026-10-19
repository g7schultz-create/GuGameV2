-- 0026_refinement
--
-- Pages become manuals.
--
-- THE ONE IDEA. Tier is what you put in; harmony is how much of it survived.
-- The pages' total power decides the finished manual's tier, and harmony
-- multiplies the budget that tier grants - so a Tier 5 manual refined badly is
-- worth less than its tier says, and one refined at 90+ harmony is worth more.
-- That is why `manual_total_bonus` was written as a function and not a CHECK
-- back in 0022: exceeding the budget is the reward, not a bug.
--
-- PATH HARMONY IS DERIVED FROM THE MATCHUP CHART, with an override table for
-- the cases where combat and refinement genuinely disagree. Two Paths the
-- chart has rows about are Paths that push against each other, which is what
-- makes them hard to write as one technique - and every conflicting pair the
-- design names falls out of that for free. But Sword and Metal fight each
-- other precisely BECAUSE they are the same kind of thing, which is what makes
-- them refine well. `path_affinities` is where those exceptions live, beating
-- the derived value the same way creature_path_modifiers beats the chart.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- path_affinities
-- ---------------------------------------------------------------------------
-- Refinement harmony between two Paths, where it differs from what the combat
-- chart implies. Canonical ordered pair, as region_routes does, because
-- affinity is symmetric and two rows that must agree eventually will not.

CREATE TABLE path_affinities (
    path_a   TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,
    path_b   TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,

    -- Flat harmony this pairing contributes, replacing the derived value.
    harmony  SMALLINT NOT NULL,

    note     TEXT NOT NULL DEFAULT '',

    PRIMARY KEY (path_a, path_b),
    CONSTRAINT path_affinities_canonical_pair CHECK (path_a < path_b),
    CONSTRAINT path_affinities_not_reflexive  CHECK (path_a <> path_b)
);

CREATE INDEX path_affinities_b_idx ON path_affinities (path_b);

-- The pairs the design calls compatible that the chart calls hostile. Each is
-- the same shape of exception: they conflict in a fight because they are
-- alike, and being alike is what makes them refine.
INSERT INTO path_affinities (path_a, path_b, harmony, note) VALUES
    ('soul', 'wisdom', 12, 'The mind and the spirit argue in a fight and agree on paper.'),
    ('metal', 'sword', 12, 'Sword resists Metal because a blade IS metal. One book, two chapters.'),
    ('earth', 'strength', 10, 'Weight and the will to move it.'),
    ('ice', 'water', 10, 'The same substance, at two temperatures.'),
    ('food', 'poison', 8, 'Dose is the only distinction, and both books say so.'),
    ('shadow', 'soul', 10, 'One is cast by a body, the other is what casts it.'),
    ('fire', 'light', 8, 'Every flame is a small argument for the sun.'),
    ('water', 'wood', 8, 'Nothing green disagrees with rain.'),
    ('fire', 'wind', 6, 'Wind does not oppose a fire. It feeds it and then loses control of it.'),
    ('bone', 'strength', 6, 'The frame and the force it carries.');


-- ---------------------------------------------------------------------------
-- pair_harmony
-- ---------------------------------------------------------------------------
-- Two Paths' contribution to a refinement. The override wins; otherwise the
-- chart decides, with a stored row in both directions being the worst case.

CREATE FUNCTION pair_harmony(p_a TEXT, p_b TEXT)
RETURNS SMALLINT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    override SMALLINT;
    forward  BOOLEAN;
    backward BOOLEAN;
BEGIN
    IF p_a = p_b THEN
        RETURN 0;   -- the same Path twice is neither help nor hindrance here;
                    -- repetition is rewarded separately, by dominance.
    END IF;

    SELECT a.harmony INTO override
    FROM path_affinities a
    WHERE a.path_a = LEAST(p_a, p_b) AND a.path_b = GREATEST(p_a, p_b);

    IF override IS NOT NULL THEN
        RETURN override;
    END IF;

    SELECT EXISTS (SELECT 1 FROM path_matchups WHERE attacker_path = p_a AND defender_path = p_b),
           EXISTS (SELECT 1 FROM path_matchups WHERE attacker_path = p_b AND defender_path = p_a)
    INTO forward, backward;

    IF forward AND backward THEN
        RETURN -22;   -- they fight both ways
    ELSIF forward OR backward THEN
        RETURN -11;   -- one-sided
    END IF;
    RETURN 4;         -- the chart is silent, so they have no quarrel
END;
$$;

COMMENT ON FUNCTION pair_harmony(TEXT, TEXT) IS
    'Refinement harmony between two Paths. path_affinities beats the matchup chart, which is otherwise the source.';


-- ---------------------------------------------------------------------------
-- Refinement skill
-- ---------------------------------------------------------------------------

CREATE TABLE player_refinement (
    player_id  BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    exp        BIGINT   NOT NULL DEFAULT 0 CHECK (exp >= 0),
    -- Derived from exp, stored because it is read on every refinement and on
    -- the profile. Kept in step on write, never edited alone - the same
    -- discipline player_path_attainment.tier follows.
    level      SMALLINT NOT NULL DEFAULT 1 CHECK (level >= 1),

    refined    INTEGER  NOT NULL DEFAULT 0 CHECK (refined >= 0),
    failures   INTEGER  NOT NULL DEFAULT 0 CHECK (failures >= 0),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER player_refinement_set_updated_at
    BEFORE UPDATE ON player_refinement
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO game_config (key, value, description) VALUES
    ('refinement_exp_per_level', 120,
     'PLACEHOLDER - refinement EXP per level. Linear; the design gives no curve.'),
    ('refinement_base_pages', 3,
     'Pages a novice may combine at once.'),
    ('refinement_pages_per_levels', 10,
     'Levels of Refinement per additional page allowed.'),
    ('refinement_max_pages', 8,
     'Hard ceiling on pages in one refinement.'),
    ('refinement_potential_divisor', 4,
     'PLACEHOLDER - total page power divided by this maps onto the manual tier budget scale.'),
    ('refinement_failure_threshold', 20,
     'Harmony below this destroys the attempt.');

CREATE FUNCTION refinement_level_for_exp(p_exp BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1, 1 + floor(p_exp / game_config_value('refinement_exp_per_level')))::smallint;
$$;

CREATE FUNCTION refinement_max_pages(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('refinement_max_pages'),
        game_config_value('refinement_base_pages')
        + floor(p_level / game_config_value('refinement_pages_per_levels'))
    )::smallint;
$$;

CREATE FUNCTION grant_refinement_exp(p_player_id BIGINT, p_exp BIGINT, p_succeeded BOOLEAN)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    new_level SMALLINT;
BEGIN
    INSERT INTO player_refinement (player_id, exp, level, refined, failures)
    VALUES (p_player_id, p_exp, refinement_level_for_exp(p_exp),
            CASE WHEN p_succeeded THEN 1 ELSE 0 END,
            CASE WHEN p_succeeded THEN 0 ELSE 1 END)
    ON CONFLICT (player_id) DO UPDATE SET
        exp      = player_refinement.exp + EXCLUDED.exp,
        level    = refinement_level_for_exp(player_refinement.exp + EXCLUDED.exp),
        refined  = player_refinement.refined + EXCLUDED.refined,
        failures = player_refinement.failures + EXCLUDED.failures
    RETURNING level INTO new_level;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- apply_manual_bonus
-- ---------------------------------------------------------------------------
-- Adds a value to one of a manual's bonus columns, named at runtime.
--
-- Dynamic SQL, which is normally a smell - here it is the point. `page_types`
-- says which column each page type feeds, so refinement reads that mapping
-- instead of carrying a twelve-branch CASE that must be edited beside every
-- new bonus. The column name comes from a table this migration controls, not
-- from a caller, and it is passed through format(%I) regardless.

CREATE FUNCTION apply_manual_bonus(p_manual_id BIGINT, p_column TEXT, p_value NUMERIC)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM page_types WHERE manual_column = p_column) THEN
        RAISE EXCEPTION 'no page type feeds column %', p_column;
    END IF;

    EXECUTE format(
        'UPDATE manuals SET %I = %I + $1 WHERE manual_id = $2',
        p_column, p_column
    ) USING round(p_value, 4), p_manual_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------
-- A refined manual's name is generated from what it actually is. The words are
-- rows so a new Path arrives with its vocabulary rather than needing the
-- generator edited.

CREATE TABLE path_words (
    path_code TEXT NOT NULL REFERENCES paths (code) ON DELETE CASCADE,
    word      TEXT NOT NULL,
    PRIMARY KEY (path_code, word)
);

INSERT INTO path_words (path_code, word) VALUES
    ('fire','Blazing'),('fire','Scarlet'),('fire','Ember'),
    ('water','Azure'),('water','Tidal'),('water','Flowing'),
    ('ice','Frost'),('ice','Glacial'),('ice','Rime'),
    ('wood','Verdant'),('wood','Jade'),('wood','Green Bough'),
    ('lightning','Thunder'),('lightning','Levin'),('lightning','Storm'),
    ('earth','Mountain'),('earth','Stone'),('earth','Deep Loam'),
    ('metal','Iron'),('metal','Gilded'),('metal','Keen'),
    ('sword','Sword'),('sword','Severing'),('sword','Edge'),
    ('strength','Titan'),('strength','Vajra'),('strength','Tyrant'),
    ('blood','Crimson'),('blood','Sanguine'),('blood','Red Vein'),
    ('soul','Spirit'),('soul','Hollow'),('soul','Ghost'),
    ('wisdom','Thousand Thought'),('wisdom','Sage'),('wisdom','Clear Insight'),
    ('space','Void'),('space','Folded'),('space','Distant'),
    ('time','Aeon'),('time','Inch of Time'),('time','Waning'),
    ('luck','Fortunate'),('luck','Golden Chance'),('luck','Auspicious'),
    ('refinement','Tempered'),('refinement','Purified'),('refinement','Refined'),
    ('formation','Ninefold Array'),('formation','Warded'),('formation','Nine Palace'),
    ('enslavement','Binding'),('enslavement','Sovereign'),('enslavement','Yoked'),
    ('transformation','Shifting'),('transformation','Manifold'),('transformation','Becoming'),
    ('theft','Thieving'),('theft','Plundering'),('theft','Light-Fingered'),
    ('poison','Venomous'),('poison','Miasmic'),('poison','Blighted'),
    ('human','Myriad Mortal'),('human','Common'),('human','Ten Thousand Folk'),
    ('heaven','Heavenly'),('heaven','Celestial'),('heaven','Fated'),
    ('qi','Primeval'),('qi','Breathing'),('qi','Coiled Breath'),
    ('dream','Dreaming'),('dream','Slumbering'),('dream','Night-Wandering'),
    ('painting','Painted'),('painting','Rendered'),('painting','Ink-Drawn'),
    ('food','Sated'),('food','Nourishing'),('food','Ripe'),
    ('rule','Lawful'),('rule','Decreed'),('rule','Writ'),
    ('wind','Gale'),('wind','Tempest'),('wind','Swiftwind'),
    ('light','Radiant'),('light','Solar'),('light','Brilliant'),
    ('shadow','Shadow'),('shadow','Umbral'),('shadow','Nightfall'),
    ('illusion','Mirage'),('illusion','Phantom'),('illusion','Deceiving'),
    ('bone','Bone'),('bone','Ossuary'),('bone','Marrow'),
    ('star','Starfall'),('star','Astral'),('star','Constellate');

CREATE TABLE archetype_endings (
    archetype TEXT NOT NULL,
    ending    TEXT NOT NULL,
    PRIMARY KEY (archetype, ending)
);

INSERT INTO archetype_endings (archetype, ending) VALUES
    ('cultivation','Scripture'),('cultivation','Breathing Method'),('cultivation','Sutra'),('cultivation','Canon'),
    ('offensive','Art'),('offensive','Palm'),('offensive','Fist'),('offensive','Technique'),
    ('defensive','Body'),('defensive','Aegis Method'),('defensive','Method'),
    ('body','Body'),('body','Body Scripture'),('body','Tempering Art'),
    ('movement','Steps'),('movement','Stride Method'),('movement','Art'),
    ('breakthrough','Ascension Art'),('breakthrough','Method'),
    ('essence','Reservoir Sutra'),('essence','Method'),
    ('gathering','Manual'),('gathering','Gathering Method'),
    ('refinement','Refining Canon'),('refinement','Scripture'),
    ('hybrid','Art'),('hybrid','Manual'),('hybrid','Technique');

-- Harmony earns an honorific. Below Excellent a manual is just its Path and
-- its shape.
CREATE TABLE harmony_titles (
    min_harmony SMALLINT PRIMARY KEY,
    word        TEXT NOT NULL
);

INSERT INTO harmony_titles (min_harmony, word) VALUES
    (115, 'Divine'), (100, 'Heavenly'), (92, 'Supreme'),
    (84, 'Profound'), (75, 'True');

CREATE FUNCTION refined_manual_name(
    p_dominant TEXT, p_archetype TEXT, p_harmony SMALLINT, p_tier SMALLINT
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    title  TEXT;
    word   TEXT;
    ending TEXT;
BEGIN
    SELECT ht.word INTO title
    FROM harmony_titles ht
    WHERE ht.min_harmony <= p_harmony
    ORDER BY ht.min_harmony DESC LIMIT 1;

    SELECT pw.word INTO word
    FROM path_words pw WHERE pw.path_code = p_dominant
    ORDER BY random() LIMIT 1;

    SELECT ae.ending INTO ending
    FROM archetype_endings ae WHERE ae.archetype = p_archetype
    ORDER BY random() LIMIT 1;

    RETURN trim(both ' ' FROM
        COALESCE(title || ' ', '')
        || COALESCE(word, 'Nameless') || ' '
        || COALESCE(ending, 'Manual'));
END;
$$;

COMMENT ON FUNCTION refined_manual_name(TEXT, TEXT, SMALLINT, SMALLINT) IS
    'A name generated from what the manual turned out to be. Words live in tables so a new Path brings its own.';


-- ---------------------------------------------------------------------------
-- refine
-- ---------------------------------------------------------------------------
-- The whole pipeline, in one call: harmony, outcome, tier, stats, name, and
-- the pages consumed.
--
-- Failure destroys SOME pages, not all - the design is explicit that even a
-- failure teaches something, so EXP is granted either way and the survivors
-- come back.

CREATE FUNCTION refine(p_player_id BIGINT, p_page_ids BIGINT[])
RETURNS TABLE (
    succeeded   BOOLEAN,
    harmony     SMALLINT,
    manual_id   BIGINT,
    manual_name TEXT,
    tier        SMALLINT,
    archetype   TEXT,
    retained    NUMERIC,
    exp_gained  BIGINT,
    level_after SMALLINT,
    destroyed   INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill        SMALLINT;
    cap          SMALLINT;
    n            INTEGER;
    h            NUMERIC := 50;
    pair         RECORD;
    dominant     TEXT;
    dom_count    INTEGER;
    distinct_n   INTEGER;
    type_n       INTEGER;
    spread       INTEGER;
    avg_quality  NUMERIC;
    trait_h      INTEGER;
    resonant_n   INTEGER;
    total_power  NUMERIC;
    potential    NUMERIC;
    final_h      SMALLINT;
    keep         NUMERIC;
    new_tier     SMALLINT;
    budget       NUMERIC;
    arch         TEXT;
    lead_type    TEXT;
    new_manual   BIGINT;
    new_name     TEXT;
    gained       BIGINT;
    lvl          SMALLINT;
    killed       INTEGER := 0;
BEGIN
    -- ---- validate -------------------------------------------------------
    SELECT COALESCE(pr.level, 1) INTO skill
    FROM (SELECT 1) _ LEFT JOIN player_refinement pr ON pr.player_id = p_player_id;

    cap := refinement_max_pages(skill);
    n   := COALESCE(array_length(p_page_ids, 1), 0);

    IF n < 2 THEN
        RAISE EXCEPTION 'a refinement needs at least two pages'
            USING ERRCODE = 'check_violation';
    END IF;
    IF n > cap THEN
        RAISE EXCEPTION 'your Refinement skill allows % pages at once, not %', cap, n
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_page_ids) AS want(id)
        WHERE NOT EXISTS (
            SELECT 1 FROM manual_pages mp
            WHERE mp.page_id = want.id
              AND mp.owner_id = p_player_id
              AND mp.consumed_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'those are not all your unused pages'
            USING ERRCODE = 'check_violation';
    END IF;

    CREATE TEMP TABLE _pages ON COMMIT DROP AS
    SELECT mp.*, pt.manual_column, tr.harmony_bonus, tr.pairs_with_itself
    FROM manual_pages mp
    JOIN page_types pt ON pt.code = mp.page_type
    LEFT JOIN page_traits tr ON tr.code = mp.trait
    WHERE mp.page_id = ANY (p_page_ids);

    -- ---- harmony ---------------------------------------------------------
    FOR pair IN
        SELECT a.path_code AS pa, b.path_code AS pb
        FROM (SELECT DISTINCT path_code FROM _pages) a
        JOIN (SELECT DISTINCT path_code FROM _pages) b ON a.path_code < b.path_code
    LOOP
        h := h + pair_harmony(pair.pa, pair.pb);
    END LOOP;

    SELECT path_code, count(*) INTO dominant, dom_count
    FROM _pages GROUP BY path_code ORDER BY count(*) DESC, sum(power) DESC LIMIT 1;

    SELECT count(DISTINCT path_code), count(DISTINCT page_type),
           max(tier) - min(tier), avg(quality),
           COALESCE(sum(harmony_bonus), 0),
           count(*) FILTER (WHERE pairs_with_itself),
           sum(power)
    INTO distinct_n, type_n, spread, avg_quality, trait_h, resonant_n, total_power
    FROM _pages;

    h := h + 6 * (dom_count - 1);          -- a dominant Path steadies it
    h := h - 5 * (distinct_n - 1);         -- every extra Path is a seam
    h := h + 5 * (n - type_n);             -- pages doing the same job agree
    h := h - 3.5 * spread;                 -- mismatched grades sit badly
    h := h + (avg_quality - 75) * 0.35;
    h := h + skill * 0.75;
    h := h + trait_h;
    IF resonant_n >= 2 THEN
        h := h + 12;                       -- Resonant pages hum together
    END IF;
    h := h + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(140, round(h)))::smallint;

    -- ---- outcome ---------------------------------------------------------
    gained := GREATEST(10, round(total_power * 0.4 + final_h * 0.6));

    IF final_h < game_config_value('refinement_failure_threshold') THEN
        -- Some pages are lost, the rest come back.
        WITH doomed AS (
            SELECT page_id FROM _pages ORDER BY random() LIMIT GREATEST(1, n / 3)
        )
        DELETE FROM manual_pages WHERE page_id IN (SELECT page_id FROM doomed);
        GET DIAGNOSTICS killed = ROW_COUNT;

        lvl := grant_refinement_exp(p_player_id, gained / 3, FALSE);
        RETURN QUERY SELECT FALSE, final_h, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, 0::numeric,
                            gained / 3, lvl, killed;
        RETURN;
    END IF;

    keep := CASE
        WHEN final_h >= 100 THEN 1.30
        WHEN final_h >= 90  THEN 1.17
        WHEN final_h >= 75  THEN 1.02
        WHEN final_h >= 60  THEN 0.875
        WHEN final_h >= 40  THEN 0.70
        ELSE 0.50
    END;

    -- ---- tier ------------------------------------------------------------
    potential := total_power / game_config_value('refinement_potential_divisor');
    SELECT COALESCE(max(mt.tier), 1) INTO new_tier
    FROM manual_tiers mt WHERE mt.bonus_budget * 100 <= potential;

    SELECT mt.bonus_budget INTO budget FROM manual_tiers mt WHERE mt.tier = new_tier;
    budget := budget * keep;

    -- ---- archetype -------------------------------------------------------
    SELECT page_type INTO lead_type
    FROM _pages GROUP BY page_type ORDER BY sum(power) DESC LIMIT 1;

    arch := CASE lead_type
        WHEN 'cultivation'  THEN 'cultivation'
        WHEN 'attack'       THEN 'offensive'
        WHEN 'defense'      THEN 'defensive'
        WHEN 'vitality'     THEN 'body'
        WHEN 'speed'        THEN 'movement'
        WHEN 'breakthrough' THEN 'breakthrough'
        WHEN 'essence'      THEN 'essence'
        WHEN 'gathering'    THEN 'gathering'
        WHEN 'refinement'   THEN 'refinement'
        ELSE 'hybrid'
    END;
    IF type_n >= 3 THEN
        arch := 'hybrid';
    END IF;

    -- ---- the manual ------------------------------------------------------
    new_name := refined_manual_name(dominant, arch, final_h, new_tier);

    INSERT INTO manuals (name, tier, required_rank, archetype,
                         harmony, created_by, refined_at, description)
    VALUES (new_name, new_tier, GREATEST(1, LEAST(9, (new_tier + 1) / 2)), arch,
            final_h, p_player_id, now(),
            'Refined from ' || n || ' pages.')
    RETURNING manuals.manual_id INTO new_manual;

    -- Each page type pays into the column page_types says it feeds, in
    -- proportion to the power it brought.
    PERFORM apply_manual_bonus(new_manual, p.manual_column,
                               budget * p.share)
    FROM (
        SELECT manual_column, sum(power) / total_power AS share
        FROM _pages GROUP BY manual_column
    ) p;

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_manual, path_code, LEAST(1, sum(power) / total_power)
    FROM _pages GROUP BY path_code;

    -- A move it could plausibly teach: something of its dominant Path that a
    -- cultivator of its rank could hold. Often nothing, which is fine - most
    -- refined manuals are cultivation aids, not weapon books.
    INSERT INTO manual_techniques (manual_id, technique_id)
    SELECT new_manual, t.technique_id
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND tp.path_code = dominant
      AND t.rank <= GREATEST(1, LEAST(9, (new_tier + 1) / 2))
      AND arch = 'offensive'
    ORDER BY t.base_power DESC
    LIMIT 1
    ON CONFLICT DO NOTHING;

    UPDATE manual_pages
    SET consumed_by = new_manual, consumed_at = now()
    WHERE page_id = ANY (p_page_ids);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, new_manual);

    lvl := grant_refinement_exp(p_player_id, gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, new_manual, new_name, new_tier, arch,
                        keep, gained, lvl, 0;
END;
$$;

COMMENT ON FUNCTION refine(BIGINT, BIGINT[]) IS
    'Pages to manual. Tier comes from total page power; harmony multiplies the budget that tier grants, and may exceed it.';
