-- 0415_the_wheel_the_duplicates_and_the_reason_to_collect
--
-- Second of four. 0414 wrote down who exists; this one lets a cultivator own
-- them, roll for them, and feed the spares to the one they are keeping.
-- Farming and feeding are 0416, and the passive reaches `player_stat` in 0417.
--
-- THE WHEEL costs jade, which is the right currency because it is the only
-- scarce one nobody can farm. The whole server holds about 2,800 of it, the
-- deepest purse is 1,029, and it arrives 8 to 20 a day from the daily plus
-- odd handfuls from bosses and tournaments. At `servant_roll_jade` a roll,
-- that is real spending rather than a formality.
--
-- A roll picks the TIER first, by weight, and then somebody inside it at
-- random. Weighting the servants directly would have made a tier likelier
-- simply by having more people in it - the thirteen Venerables would have been
-- thirteen times the intended chance. This way T7 is 0.124 in a hundred
-- whatever the roster does later.
--
-- DUPLICATES ARE THE POINT, not a consolation. A spare is fed to the copy you
-- are keeping and raises its star, which raises both what it grants you and
-- what it brings home per hour. This is deliberately the same shape as
-- `nurture_gu`: spares counted, a copy cost that climbs per star, the weakest
-- fodder eaten first so nobody loses a four-star spare to a feeding they meant
-- to spend junk on. One idea, said the same way twice, rather than two.
--
-- WHY COLLECTION PAYS INTO FARMING AND NOT INTO COMBAT. Breadth had to be
-- worth something or the wheel is just a search for one card. But the roster's
-- own first implementation note says only one servant's passive applies at a
-- time, and a collection bonus on stats would quietly undo that - a hundred
-- servants would beat any single one. So breadth pays where servants actually
-- work: every `servant_collection_step` DISTINCT servants raises what all of
-- them bring home. Wide collections are a supply line; deep ones are a stat.
--
-- Stars raise, they do not multiply away: `servant_star_scale` is
-- 1 + (stars - 1) * step, so a five-star is twice a one-star and not
-- thirty-two times it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_roll_jade', 15,
     'Jade to call one servant. Set against a server holding about 2,800 jade and earning 8 to 20 a day, so a roll is a decision.'),
    ('servant_max_stars', 5,
     'How far a servant can be raised on its own duplicates. Five, the same ceiling a Gu has, because it is the same idea.'),
    ('servant_star_step', 0.25,
     'What each star past the first adds to a servant''s bonus and its hourly haul. At 0.25 a five-star is worth twice a one-star.'),
    ('servant_copies_per_star', 1,
     'Duplicates needed per star, multiplied by the star being reached - so the first costs one spare and the fifth costs five.'),
    ('servant_collection_step', 5,
     'How many DISTINCT servants a cultivator must own before the collection bonus takes another step.'),
    ('servant_collection_bonus', 0.05,
     'What each step of the collection adds to every servant''s hourly haul. Breadth pays into farming rather than into stats, because only one servant''s passive applies and a collection bonus on stats would quietly undo that.');


-- ---------------------------------------------------------------------------
-- Who belongs to whom
-- ---------------------------------------------------------------------------

CREATE TABLE player_servants (
    player_servant_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id      BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    servant_code   TEXT   NOT NULL REFERENCES servants(servant_code) ON DELETE RESTRICT,
    stars          SMALLINT NOT NULL DEFAULT 1 CHECK (stars >= 1),
    -- A servant climbs the same ladder a cultivator does, and is fed the same
    -- things. 0416 is what moves this.
    realm_id       BIGINT NOT NULL REFERENCES realms(realm_id),
    cultivation    BIGINT NOT NULL DEFAULT 0 CHECK (cultivation >= 0),
    -- Out working, or sitting at home. `settled_at` is when their haul was
    -- last counted, not when they were sent.
    farming        BOOLEAN NOT NULL DEFAULT FALSE,
    settled_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    obtained_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Duplicates are deliberately allowed: a spare is what a star costs.
CREATE INDEX player_servants_player_idx ON player_servants (player_id);
CREATE INDEX player_servants_code_idx   ON player_servants (servant_code);
CREATE INDEX player_servants_farming_idx
    ON player_servants (player_id) WHERE farming;

COMMENT ON TABLE player_servants IS
    'Every servant a cultivator holds, duplicates included - a spare is not waste, it is what a star is bought with.';


-- The one whose passive is felt. Separate from `player_servants` so that
-- "which one is equipped" is a fact with a unique constraint on it rather
-- than a flag on sixty rows that could disagree with itself.
CREATE TABLE player_servant_attending (
    player_id         BIGINT PRIMARY KEY REFERENCES players(player_id) ON DELETE CASCADE,
    player_servant_id BIGINT NOT NULL UNIQUE
        REFERENCES player_servants(player_servant_id) ON DELETE CASCADE
);

COMMENT ON TABLE player_servant_attending IS
    'The single servant whose passive a cultivator feels. One row per player by construction, because the roster is explicit that only one applies at a time.';


-- ---------------------------------------------------------------------------
-- What a star is worth and what it costs
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_star_scale(p_stars smallint)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
    -- Raising, not compounding. A five-star is twice a one-star.
    SELECT 1 + GREATEST(0, p_stars - 1) * game_config_value('servant_star_step');
$$;

CREATE FUNCTION servant_copies_needed(p_target_stars smallint)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT GREATEST(1, p_target_stars
                       * game_config_value('servant_copies_per_star'))::integer;
$$;


CREATE FUNCTION servant_collection(p_player_id bigint)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT count(DISTINCT ps.servant_code)::integer
    FROM player_servants ps WHERE ps.player_id = p_player_id;
$$;

CREATE FUNCTION servant_collection_bonus(p_player_id bigint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- One step per `servant_collection_step` DISTINCT servants. Duplicates
    -- already pay through stars; counting them here would pay twice.
    SELECT floor(servant_collection(p_player_id)
                 / game_config_value('servant_collection_step'))
           * game_config_value('servant_collection_bonus');
$$;

COMMENT ON FUNCTION servant_collection_bonus(bigint) IS
    'What the breadth of a collection adds to every servant''s hourly haul. Distinct servants only - a duplicate is already worth a star.';


-- ---------------------------------------------------------------------------
-- The wheel
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_roll(p_player_id bigint)
RETURNS TABLE (
    servant_code TEXT,
    name         TEXT,
    tier         SMALLINT,
    rarity       TEXT,
    bonus_kind   TEXT,
    blurb        TEXT,
    trait_name   TEXT,
    is_new       BOOLEAN,
    copies_held  INTEGER,
    jade_left    BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tier SMALLINT;
    v_code TEXT;
    v_new  BOOLEAN;
    v_had  INTEGER;
    v_paid BIGINT;
    v_home BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM players WHERE player_id = p_player_id) THEN
        RAISE EXCEPTION 'no such cultivator' USING ERRCODE = 'check_violation';
    END IF;

    -- `spend_jade` refuses rather than going negative, so an unaffordable
    -- roll stops here rather than half way through one.
    PERFORM spend_jade(p_player_id,
                       game_config_value('servant_roll_jade')::bigint,
                       'servant_roll');

    -- The tier first, by weight; then somebody inside it. Weighting the
    -- servants themselves would make a crowded tier likelier for being
    -- crowded, and the roster is going to keep growing.
    SELECT t.tier INTO v_tier FROM servant_tiers t
    ORDER BY -ln(random()) / t.roll_weight LIMIT 1;

    SELECT s.servant_code INTO v_code FROM servants s
    WHERE s.tier = v_tier ORDER BY random() LIMIT 1;

    IF v_code IS NULL THEN
        RAISE EXCEPTION 'tier % has nobody in it', v_tier;
    END IF;

    SELECT count(*)::integer INTO v_had FROM player_servants ps
    WHERE ps.player_id = p_player_id AND ps.servant_code = v_code;
    v_new := (v_had = 0);

    -- A servant arrives standing where everybody starts, and is fed up the
    -- same ladder from there.
    SELECT r.realm_id INTO v_home FROM realms r ORDER BY r.realm_id LIMIT 1;

    INSERT INTO player_servants (player_id, servant_code, realm_id)
    VALUES (p_player_id, v_code, v_home);

    RETURN QUERY
    SELECT s.servant_code, s.name, s.tier, t.rarity, s.bonus_kind, s.blurb,
           s.trait_name, v_new, v_had + 1, jade_held(p_player_id)
    FROM servants s
    JOIN servant_tiers t ON t.tier = s.tier
    WHERE s.servant_code = v_code;
END;
$$;

COMMENT ON FUNCTION servant_roll(bigint) IS
    'One call of the wheel, paid in jade. Picks a tier by weight and then somebody inside it, so a tier''s odds do not drift as the roster grows.';


-- ---------------------------------------------------------------------------
-- And the spares
-- ---------------------------------------------------------------------------

CREATE VIEW servant_nursery AS
    SELECT ps.player_servant_id, ps.player_id, ps.servant_code,
           s.name, s.tier, t.rarity, s.bonus_kind, ps.stars,
           (ps.stars + 1)::smallint AS next_stars,
           servant_copies_needed((ps.stars + 1)::smallint) AS copies_needed,
           (SELECT count(*) FROM player_servants f
            WHERE f.player_id = ps.player_id
              AND f.servant_code = ps.servant_code
              AND f.player_servant_id <> ps.player_servant_id
              AND NOT EXISTS (SELECT 1 FROM player_servant_attending a
                              WHERE a.player_servant_id = f.player_servant_id)
           )::integer AS spares
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    JOIN servant_tiers t ON t.tier = s.tier;

COMMENT ON VIEW servant_nursery IS
    'Each held servant beside what raising it one more star would take. The attending servant is never counted as fodder for itself or anybody else.';


CREATE FUNCTION servant_nurture(p_player_id bigint, p_player_servant_id bigint)
RETURNS TABLE (
    name         TEXT,
    stars_before SMALLINT,
    stars_after  SMALLINT,
    eaten        INTEGER,
    spares_left  INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     RECORD;
    fodder BIGINT[];
BEGIN
    SELECT * INTO it FROM servant_nursery n
    WHERE n.player_id = p_player_id
      AND n.player_servant_id = p_player_servant_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.next_stars > game_config_value('servant_max_stars') THEN
        RAISE EXCEPTION '% is already as strong as a servant becomes', it.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.spares < it.copies_needed THEN
        RAISE EXCEPTION
            'raising % to % stars wants % more of them, and you have %',
            it.name, it.next_stars, it.copies_needed, it.spares
            USING ERRCODE = 'check_violation';
    END IF;

    -- The weakest spares first, and never the one being raised nor the one
    -- attending. A cultivator does not lose a four-star spare to a feeding
    -- they meant to spend junk on.
    SELECT array_agg(f.player_servant_id) INTO fodder
    FROM (
        SELECT f.player_servant_id FROM player_servants f
        WHERE f.player_id = p_player_id
          AND f.servant_code = it.servant_code
          AND f.player_servant_id <> p_player_servant_id
          AND NOT EXISTS (SELECT 1 FROM player_servant_attending a
                          WHERE a.player_servant_id = f.player_servant_id)
        ORDER BY f.stars, f.cultivation, f.player_servant_id
        LIMIT it.copies_needed
    ) f;

    DELETE FROM player_servants WHERE player_servant_id = ANY (fodder);

    UPDATE player_servants ps
    SET stars = it.next_stars
    WHERE ps.player_servant_id = p_player_servant_id;

    RETURN QUERY
    SELECT it.name, it.stars, it.next_stars, it.copies_needed,
           (SELECT n.spares FROM servant_nursery n
            WHERE n.player_servant_id = p_player_servant_id);
END;
$$;

COMMENT ON FUNCTION servant_nurture(bigint, bigint) IS
    'Feeds duplicates to the copy being kept, raising its star. The same shape as `nurture_gu`, because it is the same idea and should not be a second dialect of it.';


-- ---------------------------------------------------------------------------
-- A roll costs, a spare raises, and breadth is worth having
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_jade  BIGINT;
    v_first RECORD;
    v_id    BIGINT;
    v_stars SMALLINT;
    r       RECORD;
BEGIN
    -- The star curve raises rather than compounds, or a five-star is a
    -- different game from a one-star.
    IF servant_star_scale(5::smallint) <> 2 THEN
        RAISE EXCEPTION 'a five-star servant is worth % of a one-star',
            servant_star_scale(5::smallint);
    END IF;

    -- Breadth must pay something, and nothing at all until the first step.
    IF servant_collection_bonus(-1::bigint) <> 0 THEN
        RAISE EXCEPTION 'an empty collection already pays a bonus';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        PERFORM grant_material(v_who, 'spirit_jade', 10000);
        v_jade := jade_held(v_who);

        SELECT * INTO v_first FROM servant_roll(v_who);
        IF v_first.servant_code IS NULL THEN
            RAISE EXCEPTION 'the wheel gave nobody';
        END IF;
        IF jade_held(v_who) <> v_jade - game_config_value('servant_roll_jade') THEN
            RAISE EXCEPTION 'the wheel did not charge what it says it does';
        END IF;

        -- Roll until somebody has enough spares to actually be raised. Note
        -- that is `spares >= copies_needed`, not "two of them": the second
        -- star costs two spares, so three copies. Checking for a mere
        -- duplicate is how the first draft of this probe talked itself into
        -- expecting a feeding it had not paid for.
        -- Bounded, because an unbounded loop in a migration is a hang.
        FOR i IN 1..400 LOOP
            EXIT WHEN EXISTS (
                SELECT 1 FROM servant_nursery n
                WHERE n.player_id = v_who AND n.spares >= n.copies_needed);
            PERFORM servant_roll(v_who);
        END LOOP;

        SELECT n.player_servant_id INTO v_id FROM servant_nursery n
        WHERE n.player_id = v_who AND n.spares >= n.copies_needed
        ORDER BY n.tier DESC LIMIT 1;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'four hundred rolls and never the same one twice';
        END IF;

        SELECT stars_after INTO v_stars FROM servant_nurture(v_who, v_id);
        IF v_stars <> 2 THEN
            RAISE EXCEPTION 'a fed servant came out at % stars', v_stars;
        END IF;

        RAISE NOTICE
            'rolled a collection of %, one of them raised to two stars, breadth pays %',
            servant_collection(v_who), servant_collection_bonus(v_who);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT t.tier, t.rarity,
               round(100 * t.roll_weight
                     / (SELECT sum(roll_weight) FROM servant_tiers), 3) AS pct,
               round(game_config_value('servant_roll_jade')
                     * (SELECT sum(roll_weight) FROM servant_tiers)
                     / t.roll_weight) AS jade_per_one
        FROM servant_tiers t ORDER BY t.tier DESC
    LOOP
        RAISE NOTICE 'T% %: % in a hundred, about % jade apiece',
            r.tier, rpad(r.rarity, 10), r.pct, r.jade_per_one;
    END LOOP;
END;
$probe$;
