-- 0057_alchemy
--
-- Herbs become pills.
--
-- NO RECIPE LIST. The herb document asks for ingredients that "contribute
-- actual properties rather than requiring every recipe to use exact predefined
-- items", and to reuse "the same Harmony philosophy used by Manual Pages". So
-- alchemy is shaped like `refine()` and not like a cookbook: put herbs in,
-- their Paths and tiers decide what comes out, and two players with similar
-- herbs get different pills. A recipe table would have made gathering a
-- shopping list, which is the exact failure the document names - herbs should
-- be wanted for their properties, not for their price.
--
-- WHAT A PILL DOES IS DECIDED BY WHAT THIS ENGINE CAN PAY. There is no buff
-- system, no duration, nothing that outlives a command - so a pill grants
-- something INSTANT that already has a function behind it: cultivation,
-- physique XP, Path insight, health, battle Qi. Every one of those is a call
-- this schema already makes. A temporary +12% would have been a promise in a
-- table nobody reads, and the roster document's own "Primary Use" column asks
-- for exactly these five things anyway.
--
-- THE PATH DECIDES WHICH. `path_pill_kinds` maps all thirty-four Paths onto
-- the five, in a table rather than a CASE, so a new Path arrives with an
-- opinion about brewing instead of needing this function edited.
--
-- ALCHEMY IS THE SECOND PROFESSION, which is the whole reason 0038 made
-- professions sparse rows: this is an INSERT into `professions` and not a
-- second table with four columns copied out of the first.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- What a pill can be
-- ---------------------------------------------------------------------------

CREATE TABLE pill_kinds (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,

    -- What one point of a pill's magnitude is worth in that kind's own
    -- currency. Cultivation is counted in hundreds and health in tens, so the
    -- scale cannot live in the pill.
    per_point   NUMERIC(10, 2) NOT NULL CHECK (per_point > 0),

    emoji       TEXT NOT NULL DEFAULT '💊',
    description TEXT NOT NULL DEFAULT ''
);

INSERT INTO pill_kinds (code, name, per_point, emoji, description) VALUES
    ('cultivation', 'Cultivation', 60, '🌿',
     'Cultivation, granted at once. It stops at the next realm''s door like every other source.'),
    ('physique',    'Body Tempering', 50, '💪',
     'Physique XP, and the body is re-derived on the spot.'),
    ('insight',     'Insight', 40, '📖',
     'Insight into the pill''s own Path.'),
    ('healing',     'Healing', 25, '❤️',
     'Health, up to what the body can hold.'),
    ('qi',          'Qi Restoration', 8, '💧',
     'Battle Qi, up to the realm''s capacity.');

CREATE TABLE path_pill_kinds (
    path_code TEXT PRIMARY KEY REFERENCES paths (code) ON DELETE CASCADE,
    kind      TEXT NOT NULL REFERENCES pill_kinds (code) ON DELETE RESTRICT
);

CREATE INDEX path_pill_kinds_kind_idx ON path_pill_kinds (kind);

INSERT INTO path_pill_kinds (path_code, kind) VALUES
    ('qi','cultivation'),('heaven','cultivation'),('star','cultivation'),
    ('time','cultivation'),('luck','cultivation'),('space','cultivation'),
    ('rule','cultivation'),

    ('strength','physique'),('blood','physique'),('bone','physique'),
    ('earth','physique'),('metal','physique'),('transformation','physique'),
    ('ice','physique'),

    ('wisdom','insight'),('dream','insight'),('painting','insight'),
    ('illusion','insight'),('formation','insight'),('refinement','insight'),
    ('theft','insight'),('human','insight'),('enslavement','insight'),

    ('wood','healing'),('water','healing'),('light','healing'),('food','healing'),

    ('fire','qi'),('lightning','qi'),('wind','qi'),('sword','qi'),
    ('poison','qi'),('shadow','qi'),('soul','qi');


-- ---------------------------------------------------------------------------
-- What the cauldron is worth
-- ---------------------------------------------------------------------------
-- Potency is the sum of every herb's tier times how many went in, so three
-- Tier 1 herbs are 3 and one Tier 7 is 7. Cumulative, so the grade is one
-- indexed range scan - the same shape realms and body ranks use.

CREATE TABLE pill_tiers (
    tier              SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 7),
    potency_required  NUMERIC(8, 2) NOT NULL CHECK (potency_required >= 0),
    base_magnitude    NUMERIC(8, 2) NOT NULL CHECK (base_magnitude > 0)
);

INSERT INTO pill_tiers (tier, potency_required, base_magnitude) VALUES
    (1,   3,  1),
    (2,   8,  2),
    (3,  18,  4),
    (4,  36,  8),
    (5,  70, 15),
    (6, 130, 28),
    (7, 240, 50);


-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------
-- The same machinery 0026 built for refined manuals: a word from the Path and
-- an ending from what the thing does, both rows, so a new Path or a new pill
-- kind brings its own vocabulary rather than needing the generator edited.

CREATE TABLE pill_endings (
    kind   TEXT NOT NULL REFERENCES pill_kinds (code) ON DELETE CASCADE,
    ending TEXT NOT NULL,
    PRIMARY KEY (kind, ending)
);

INSERT INTO pill_endings (kind, ending) VALUES
    ('cultivation','Foundation Pill'),('cultivation','Ascension Elixir'),('cultivation','Spirit Pill'),
    ('physique','Marrow Pill'),('physique','Tempering Elixir'),('physique','Body Pill'),
    ('insight','Clarity Pill'),('insight','Comprehension Elixir'),('insight','Mind Pill'),
    ('healing','Restoration Pill'),('healing','Mending Elixir'),('healing','Vitality Pill'),
    ('qi','Meridian Pill'),('qi','Breath Elixir'),('qi','Qi Pill');

CREATE FUNCTION brewed_pill_name(p_path TEXT, p_kind TEXT, p_harmony SMALLINT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    title  TEXT;
    word   TEXT;
    ending TEXT;
BEGIN
    SELECT ht.word INTO title
    FROM harmony_titles ht WHERE ht.min_harmony <= p_harmony
    ORDER BY ht.min_harmony DESC LIMIT 1;

    SELECT pw.word INTO word
    FROM path_words pw WHERE pw.path_code = p_path ORDER BY random() LIMIT 1;

    SELECT pe.ending INTO ending
    FROM pill_endings pe WHERE pe.kind = p_kind ORDER BY random() LIMIT 1;

    RETURN trim(both ' ' FROM
        COALESCE(title || ' ', '') || COALESCE(word, 'Nameless') || ' '
        || COALESCE(ending, 'Pill'));
END;
$$;


-- ---------------------------------------------------------------------------
-- player_pills
-- ---------------------------------------------------------------------------
-- A batch is a row. Two brews are never the same pill - potency, harmony and
-- the roll all move - so they cannot stack, but everything out of one cauldron
-- is identical and carries a quantity.

CREATE TABLE player_pills (
    pill_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    owner_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,

    name       TEXT     NOT NULL,
    tier       SMALLINT NOT NULL REFERENCES pill_tiers (tier) ON DELETE RESTRICT,
    kind       TEXT     NOT NULL REFERENCES pill_kinds (code) ON DELETE RESTRICT,
    path_code  TEXT     NOT NULL REFERENCES paths (code) ON DELETE RESTRICT,

    -- What one pill pays, already in the kind's own currency.
    magnitude  BIGINT   NOT NULL CHECK (magnitude > 0),
    quantity   SMALLINT NOT NULL CHECK (quantity > 0),
    harmony    SMALLINT NOT NULL CHECK (harmony BETWEEN 0 AND 150),

    brewed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX player_pills_owner_idx ON player_pills (owner_id);
CREATE INDEX player_pills_kind_idx  ON player_pills (kind);
CREATE INDEX player_pills_tier_idx  ON player_pills (tier);
CREATE INDEX player_pills_path_idx  ON player_pills (path_code);


-- ---------------------------------------------------------------------------
-- The profession, and its dials
-- ---------------------------------------------------------------------------

INSERT INTO professions (code, name, exp_per_level, description) VALUES
    ('alchemy', 'Alchemist', 200,
     'Brews herbs into pills. Level steadies the cauldron and widens it.');

INSERT INTO game_config (key, value, description) VALUES
    ('alchemy_base_herbs', 2,
     'Distinct herbs a novice alchemist can hold in one cauldron.'),
    ('alchemy_herbs_per_levels', 5,
     'Alchemist levels per additional herb.'),
    ('alchemy_max_herbs', 6,
     'Hard ceiling on distinct herbs in one brew.'),
    ('alchemy_failure_threshold', 25,
     'Harmony below this and the cauldron is spoiled.'),
    ('alchemy_refund', 0.5,
     'Fraction of every herb swept back out of a spoiled cauldron.'),
    ('alchemy_exp_per_tier', 45,
     'PLACEHOLDER - Alchemist EXP per tier of the pill brewed.'),
    ('alchemy_batch_divisor', 2,
     'Potency past a tier''s requirement, divided by this multiple of it, is an extra pill.'),
    ('alchemy_max_batch', 5,
     'Most pills one cauldron yields, however far the potency overshoots.');

CREATE FUNCTION alchemy_herb_slots(p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT LEAST(
        game_config_value('alchemy_max_herbs'),
        game_config_value('alchemy_base_herbs')
        + floor(p_level / game_config_value('alchemy_herbs_per_levels'))
    )::smallint;
$$;


-- ---------------------------------------------------------------------------
-- brew
-- ---------------------------------------------------------------------------
-- Harmony is scored the way a refinement is: agreement between the Paths in
-- the pot, repetition of the dominant one, a penalty for mixing grades, the
-- alchemist's own steadiness, and a roll.
--
-- A body that softens Path conflict softens it here too. `refine_conflict_relief`
-- was written for manuals, but a cauldron holding Fire and Water is the same
-- problem in a different vessel, and a physique that reads as tolerant of one
-- and not the other would be a distinction nobody could explain.

CREATE FUNCTION brew(
    p_player_id  BIGINT,
    p_codes      TEXT[],
    p_quantities INTEGER[]
)
RETURNS TABLE (
    succeeded    BOOLEAN,
    harmony      SMALLINT,
    potency      NUMERIC,
    pill_id      BIGINT,
    pill_name    TEXT,
    pill_tier    SMALLINT,
    pill_kind    TEXT,
    path_code    TEXT,
    magnitude    BIGINT,
    quantity     SMALLINT,
    exp_gained   BIGINT,
    level_after  SMALLINT,
    spent_total  BIGINT,
    handed_back  BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    skill     SMALLINT;
    slots     SMALLINT;
    n_herbs   INTEGER;
    known     INTEGER;
    refund    NUMERIC;
    relief    NUMERIC;
    total     NUMERIC := 0;
    h         NUMERIC := 50;
    pair_sum  NUMERIC := 0;
    lead_path TEXT;
    lead_n    INTEGER;
    distinct_n INTEGER;
    spread    INTEGER;
    final_h   SMALLINT;
    grade     SMALLINT;
    floor_p   NUMERIC;
    base_mag  NUMERIC;
    keep      NUMERIC;
    kind_code TEXT;
    per_point NUMERIC;
    made_mag  BIGINT;
    batch     SMALLINT;
    made_name TEXT;
    made_id   BIGINT;
    gained    BIGINT;
    lvl       SMALLINT;
    spent     BIGINT := 0;
    back      BIGINT := 0;
BEGIN
    -- ---- the cauldron ---------------------------------------------------
    n_herbs := COALESCE(array_length(p_codes, 1), 0);
    IF n_herbs <> COALESCE(array_length(p_quantities, 1), 0) THEN
        RAISE EXCEPTION 'every herb needs a quantity' USING ERRCODE = 'check_violation';
    END IF;
    IF n_herbs < 2 THEN
        RAISE EXCEPTION 'a brew needs at least two herbs' USING ERRCODE = 'check_violation';
    END IF;
    IF n_herbs <> (SELECT count(DISTINCT x) FROM unnest(p_codes) AS x) THEN
        RAISE EXCEPTION 'name each herb once, with its whole quantity'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(p_quantities) AS q WHERE q <= 0) THEN
        RAISE EXCEPTION 'a herb with none of it in is not in the cauldron'
            USING ERRCODE = 'check_violation';
    END IF;

    skill := profession_level(p_player_id, 'alchemy');
    slots := alchemy_herb_slots(skill);
    IF n_herbs > slots THEN
        RAISE EXCEPTION 'your cauldron holds % herbs, not %', slots, n_herbs
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO known
    FROM unnest(p_codes) AS u (code)
    JOIN materials m ON m.code = u.code
    WHERE m.tier IS NOT NULL;

    IF known <> n_herbs THEN
        RAISE EXCEPTION 'only herbs go in a cauldron, and one of those is not'
            USING ERRCODE = 'check_violation';
    END IF;

    -- ---- spend ----------------------------------------------------------
    PERFORM spend_material(p_player_id, u.code, u.quantity)
    FROM unnest(p_codes, p_quantities) AS u (code, quantity);

    spent := COALESCE((SELECT sum(q) FROM unnest(p_quantities) AS q), 0);

    -- ---- what is in the pot ---------------------------------------------
    SELECT COALESCE(sum(m.tier * u.quantity), 0),
           count(DISTINCT m.path_code),
           max(m.tier) - min(m.tier)
    INTO total, distinct_n, spread
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code;

    SELECT m.path_code, count(*)
    INTO lead_path, lead_n
    FROM unnest(p_codes, p_quantities) AS u (code, quantity)
    JOIN materials m ON m.code = u.code
    GROUP BY m.path_code
    ORDER BY sum(m.tier * u.quantity) DESC, count(*) DESC
    LIMIT 1;

    -- ---- harmony --------------------------------------------------------
    relief := LEAST(1, physique_stat(p_player_id, 'refine_conflict_relief'));

    SELECT COALESCE(sum(
        CASE WHEN pair_harmony(a.p, b.p) < 0
             THEN pair_harmony(a.p, b.p) * (1 - relief)
             ELSE pair_harmony(a.p, b.p) END
    ), 0)
    INTO pair_sum
    FROM (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_codes) AS u (code) JOIN materials m ON m.code = u.code) a
    JOIN (SELECT DISTINCT m.path_code AS p
          FROM unnest(p_codes) AS u (code) JOIN materials m ON m.code = u.code) b
      ON a.p < b.p;

    h := h
       + pair_sum
       + 8 * (lead_n - 1)          -- one Path repeated steadies the pot
       - 4 * (distinct_n - 1)      -- every extra Path is another seam
       - 2 * spread                -- grades that do not match sit badly
       + skill * 0.75
       + (random() * 8 - 4);

    final_h := GREATEST(0, LEAST(150, round(h)))::smallint;

    -- ---- spoiled --------------------------------------------------------
    IF final_h < game_config_value('alchemy_failure_threshold') THEN
        refund := game_config_value('alchemy_refund');

        PERFORM grant_material(p_player_id, u.code, floor(u.quantity * refund)::bigint)
        FROM unnest(p_codes, p_quantities) AS u (code, quantity)
        WHERE floor(u.quantity * refund) > 0;

        back := COALESCE((SELECT sum(floor(q * refund)) FROM unnest(p_quantities) AS q), 0);

        gained := GREATEST(10, round(total * game_config_value('alchemy_exp_per_tier') / 6));
        lvl := grant_profession_exp(p_player_id, 'alchemy', gained, FALSE);

        RETURN QUERY SELECT FALSE, final_h, total, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, lead_path, NULL::bigint,
                            NULL::smallint, gained, lvl, spent, back;
        RETURN;
    END IF;

    -- ---- the pill -------------------------------------------------------
    SELECT pt.tier, pt.potency_required, pt.base_magnitude
    INTO grade, floor_p, base_mag
    FROM pill_tiers pt WHERE pt.potency_required <= total
    ORDER BY pt.tier DESC LIMIT 1;

    IF grade IS NULL THEN
        RAISE EXCEPTION 'there is not enough in the pot to make anything'
            USING ERRCODE = 'check_violation';
    END IF;

    keep := CASE
        WHEN final_h >= 100 THEN 1.30
        WHEN final_h >= 90  THEN 1.17
        WHEN final_h >= 75  THEN 1.02
        WHEN final_h >= 60  THEN 0.875
        WHEN final_h >= 40  THEN 0.70
        ELSE 0.50
    END;

    SELECT ppk.kind INTO kind_code FROM path_pill_kinds ppk WHERE ppk.path_code = lead_path;
    SELECT pk.per_point INTO per_point FROM pill_kinds pk WHERE pk.code = kind_code;

    made_mag := GREATEST(1, round(base_mag * per_point * keep));

    -- Overshooting a grade fills the cauldron rather than wasting it.
    batch := LEAST(
        game_config_value('alchemy_max_batch'),
        1 + floor((total - floor_p)
                  / GREATEST(1, floor_p * game_config_value('alchemy_batch_divisor')))
    )::smallint;

    made_name := brewed_pill_name(lead_path, kind_code, final_h);

    INSERT INTO player_pills
        (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
    VALUES (p_player_id, made_name, grade, kind_code, lead_path, made_mag, batch, final_h)
    RETURNING player_pills.pill_id INTO made_id;

    gained := GREATEST(10, grade * game_config_value('alchemy_exp_per_tier'));
    lvl := grant_profession_exp(p_player_id, 'alchemy', gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, total, made_id, made_name, grade, kind_code,
                        lead_path, made_mag, batch, gained, lvl, spent, 0::bigint;
END;
$$;

COMMENT ON FUNCTION brew(BIGINT, TEXT[], INTEGER[]) IS
    'Herbs to pills. The Paths in the pot decide what it becomes; harmony decides how much of it survives.';


-- ---------------------------------------------------------------------------
-- take_pill
-- ---------------------------------------------------------------------------
-- Every kind pays out through a function that already exists, which is why
-- these five and not a duration system.

CREATE FUNCTION take_pill(p_player_id BIGINT, p_pill_id BIGINT)
RETURNS TABLE (
    pill_name  TEXT,
    kind       TEXT,
    granted    BIGINT,
    detail     TEXT,
    remaining  SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    it      player_pills%ROWTYPE;
    before  BIGINT;
    after   BIGINT;
    said    TEXT;
    left_n  SMALLINT;
BEGIN
    SELECT * INTO it FROM player_pills
    WHERE pill_id = p_pill_id AND owner_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not yours to take' USING ERRCODE = 'check_violation';
    END IF;

    IF it.kind = 'cultivation' THEN
        SELECT pc.cultivation INTO before FROM player_cultivation pc WHERE pc.player_id = p_player_id;
        PERFORM apply_cultivation_xp(p_player_id, it.magnitude);
        SELECT pc.cultivation INTO after FROM player_cultivation pc WHERE pc.player_id = p_player_id;
        after := after - before;
        said := CASE WHEN after < it.magnitude
                     THEN 'The bottleneck took the rest.'
                     ELSE 'Cultivation, at once.' END;

    ELSIF it.kind = 'physique' THEN
        PERFORM apply_physique_xp(p_player_id, it.magnitude);
        after := it.magnitude;
        said := 'The body is re-derived on the spot.';

    ELSIF it.kind = 'insight' THEN
        PERFORM grant_path_insight(p_player_id, it.path_code, it.magnitude, 0, 0);
        after := it.magnitude;
        said := 'Insight into ' || it.path_code || '.';

    ELSIF it.kind = 'healing' THEN
        UPDATE player_physique pp
        SET current_hp = LEAST(pp.max_hp, pp.current_hp + it.magnitude)
        WHERE pp.player_id = p_player_id
        RETURNING pp.current_hp - LEAST(pp.max_hp, pp.current_hp) INTO after;

        SELECT LEAST(pp.max_hp - pp.current_hp + it.magnitude, it.magnitude) INTO after
        FROM player_physique pp WHERE pp.player_id = p_player_id;
        after := GREATEST(0, LEAST(after, it.magnitude));
        said := 'Health, up to what the body can hold.';

    ELSE
        UPDATE player_cultivation pc
        SET qi = LEAST(
                (SELECT r.qi_capacity FROM realms r WHERE r.realm_id = pc.realm_id),
                pc.qi + it.magnitude)
        WHERE pc.player_id = p_player_id;
        after := it.magnitude;
        said := 'Battle Qi, up to the realm''s capacity.';
    END IF;

    IF it.quantity > 1 THEN
        UPDATE player_pills SET quantity = quantity - 1 WHERE pill_id = p_pill_id
        RETURNING quantity INTO left_n;
    ELSE
        DELETE FROM player_pills WHERE pill_id = p_pill_id;
        left_n := 0;
    END IF;

    RETURN QUERY SELECT it.name, it.kind, COALESCE(after, 0), said, left_n;
END;
$$;

COMMENT ON FUNCTION take_pill(BIGINT, BIGINT) IS
    'Swallows one. Every kind pays through a function that already existed, which is why a pill is instant rather than a buff nobody could have read.';
