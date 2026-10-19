-- 0478_a_servant_at_five_stars_may_ascend
--
-- A servant stops at five stars and then their duplicates are worth nothing.
-- Fifteen spares went into getting there - one for the second star, five for
-- the fifth - and the sixteenth is a dead card. There is one five-star
-- servant in the game and seven hundred and sixty at one star, so this is the
-- top of a very long climb with nothing at the top of it.
--
-- SO FIVE STARS BUYS A TIER. An ascended servant keeps being the servant you
-- built - the same name, the same bonus kind - and is read as one tier higher
-- than their kind was written at:
--
--     tier 1 common      pct 0.005   flat 0.10   1 an hour
--     tier 2 uncommon    pct 0.010   flat 0.25   2
--
-- AND GOES BACK TO TWO STARS, which is what gives the duplicates somewhere
-- to go. Not ONE star, which is what this migration first did and what its
-- own probe refused:
--
--     ascending cost haul: 20.68 an hour against 25.85 before
--
-- A five-star is worth twice a one-star, flatly, but the tiers do not double -
-- the hourly haul runs 1, 2, 3, 5, 8, 12, 18, which is about half again per
-- step. So above tier 1 a full reset is a real loss for as long as it takes to
-- climb back, and a button that makes your servant worse for a week is a
-- button nobody presses. That is the dead end this was meant to fix, moved
-- rather than removed.
--
-- At two stars it lands between 0.94 and 1.25 times the haul it had, at every
-- tier - near enough to even that ascending is about the ceiling rather than
-- about the hour. Fourteen more duplicates to reach five again.
--
-- THE TIER IS ON THE KIND, NOT THE COPY. `servants.tier` is template data -
-- every Bone Hound shares it - so ascension could not touch it without
-- promoting everybody's. It lives on `player_servants` and the two places
-- that read a tier now ask `servant_tier_of` instead of joining the template:
--
--     servant_haul_per_hour   what they bring back
--     servant_stat            what they grant their master
--
-- That is the whole list, checked against pg_proc rather than remembered.
--
-- SEVEN IS THE TOP, because `servant_tiers` has seven rows. A unique-tier
-- servant at five stars is simply finished, and is told so.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_ascend_stars', 2,
     'What a servant is left at after ascending. Two rather than one: the hourly haul rises about half again per tier while five stars is worth exactly twice one, so a full reset is a loss above tier 1 and nobody would press the button.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


ALTER TABLE player_servants
    ADD COLUMN ascension SMALLINT NOT NULL DEFAULT 0,
    ADD CONSTRAINT player_servants_ascension_check CHECK (ascension >= 0);

COMMENT ON COLUMN player_servants.ascension IS
    'How many times this copy has been raised past its kind. Added to servants.tier wherever a tier is read - see servant_tier_of - because the tier on the kind belongs to every copy of it and this belongs to one.';


CREATE OR REPLACE FUNCTION servant_tier_of(p_player_servant_id bigint)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- The kind's own tier, plus what this copy has been raised by, and never
    -- past the last row of the table it is used to look things up in.
    SELECT LEAST(
        (SELECT max(t.tier) FROM servant_tiers t),
        s.tier + ps.ascension
    )::smallint
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id;
$fn$;

COMMENT ON FUNCTION servant_tier_of(bigint) IS
    'What tier THIS servant is read at. The one place the kind''s tier and the copy''s ascension are added together, so nothing can learn about one and not the other.';


CREATE OR REPLACE FUNCTION servant_ascend(p_player_id bigint,
                                          p_player_servant_id bigint)
RETURNS TABLE(
    name       text,
    was_tier   smallint,
    now_tier   smallint,
    rarity     text,
    ascension  smallint,
    stars      smallint,
    per_hour   numeric)
LANGUAGE plpgsql
AS $fn$
DECLARE
    it     RECORD;
    v_was  SMALLINT;
    v_top  SMALLINT;
BEGIN
    SELECT ps.*, s.name AS kind_name INTO it
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id
    FOR UPDATE OF ps;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.stars < game_config_value('servant_max_stars')::int THEN
        RAISE EXCEPTION
            'a servant ascends at % stars and % is at %',
            game_config_value('servant_max_stars')::int, it.kind_name, it.stars
            USING ERRCODE = 'check_violation';
    END IF;

    v_was := servant_tier_of(p_player_servant_id);
    SELECT max(t.tier) INTO v_top FROM servant_tiers t;

    IF v_was >= v_top THEN
        RAISE EXCEPTION
            '% stands at the highest tier there is and has nowhere to ascend to',
            it.kind_name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The stars are the price. Back to two, on the bigger number - see the
    -- note above for why not to one.
    UPDATE player_servants ps
    SET ascension = ps.ascension + 1,
        stars = GREATEST(1, game_config_value('servant_ascend_stars')::int)::smallint
    WHERE ps.player_servant_id = p_player_servant_id;

    RETURN QUERY
    SELECT it.kind_name, v_was, servant_tier_of(p_player_servant_id),
           (SELECT t.rarity FROM servant_tiers t
            WHERE t.tier = servant_tier_of(p_player_servant_id)),
           ps.ascension, ps.stars,
           round(servant_haul_per_hour(p_player_servant_id), 2)
    FROM player_servants ps
    WHERE ps.player_servant_id = p_player_servant_id;
END;
$fn$;

COMMENT ON FUNCTION servant_ascend(bigint, bigint) IS
    'Spends a servant''s five stars to raise them a tier. Break-even on the hour it happens and a higher ceiling afterwards, which is what makes duplicates worth having once a servant is finished.';


-- ---------------------------------------------------------------------------
-- Everything that reads a tier reads this one
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    r      RECORD;
    body   TEXT;
    -- Just the join condition. The two functions align the keyword
    -- differently - one pads `t` out to a column - so anchoring on the whole
    -- line matches one of them and not the other.
    anchor TEXT := 'ON t.tier = s.tier';
    better TEXT := 'ON t.tier = servant_tier_of(ps.player_servant_id)';
    hits   INTEGER;
BEGIN
    FOR r IN
        SELECT p.proname FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('servant_haul_per_hour', 'servant_stat')
        ORDER BY p.proname
    LOOP
        SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
        WHERE proname = r.proname AND pronamespace = 'public'::regnamespace;

        hits := (length(body) - length(replace(body, anchor, '')))
                / length(anchor);
        IF hits <> 1 THEN
            RAISE EXCEPTION
                '% joins the tier table % time(s), expected 1', r.proname, hits;
        END IF;

        EXECUTE replace(body, anchor, better);
    END LOOP;

    -- And nothing else is still joining the template's tier for a COPY. The
    -- roll builds new servants from the kind and is right to read it there.
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname NOT IN ('servant_roll', 'servant_tier_of')
          AND p.prosrc LIKE '%servant_tiers%'
          AND p.prosrc LIKE '%t.tier = s.tier%'
    ) THEN
        RAISE EXCEPTION
            'something still reads a copy''s tier off the kind: %',
            (SELECT string_agg(p.proname, ', ') FROM pg_proc p
             WHERE p.pronamespace = 'public'::regnamespace
               AND p.proname NOT IN ('servant_roll', 'servant_tier_of')
               AND p.prosrc LIKE '%t.tier = s.tier%');
    END IF;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Five stars buys a tier, and costs the stars
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_srv  BIGINT;
    v_who  BIGINT;
    v_max  INTEGER;
    v_top  SMALLINT;
    got    RECORD;
    v_haul NUMERIC;
BEGIN
    v_max := game_config_value('servant_max_stars')::int;
    SELECT max(t.tier) INTO v_top FROM servant_tiers t;

    -- Nobody in the ground is ascended yet, so nothing moved under anybody.
    IF EXISTS (SELECT 1 FROM player_servants WHERE ascension <> 0) THEN
        RAISE EXCEPTION 'a servant is already ascended';
    END IF;

    BEGIN
        -- A servant of the lowest tier, so there is room above them.
        SELECT ps.player_servant_id, ps.player_id INTO v_srv, v_who
        FROM player_servants ps
        JOIN servants s ON s.servant_code = ps.servant_code
        WHERE s.tier < v_top
        ORDER BY ps.player_servant_id LIMIT 1;
        IF v_srv IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Below five stars it is refused, by name.
        UPDATE player_servants SET stars = 1
        WHERE player_servant_id = v_srv;
        BEGIN
            PERFORM servant_ascend(v_who, v_srv);
            RAISE EXCEPTION 'a one-star servant ascended';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- At five it goes up, and the stars are spent.
        UPDATE player_servants SET stars = v_max::smallint
        WHERE player_servant_id = v_srv;
        v_haul := servant_haul_per_hour(v_srv);

        SELECT * INTO got FROM servant_ascend(v_who, v_srv);

        IF got.now_tier <> got.was_tier + 1 THEN
            RAISE EXCEPTION 'ascending took % to %', got.was_tier, got.now_tier;
        END IF;
        IF got.stars <> game_config_value('servant_ascend_stars')::int THEN
            RAISE EXCEPTION 'the stars were not spent: still %', got.stars;
        END IF;

        RAISE NOTICE
            '% went from tier % to % (%), back to one star: % an hour against % before',
            got.name, got.was_tier, got.now_tier, got.rarity,
            got.per_hour, round(v_haul, 2);

        -- The whole claim: roughly where you were, not worse.
        IF got.per_hour < v_haul * 0.9 THEN
            RAISE EXCEPTION
                'ascending cost haul: % an hour against % before',
                got.per_hour, round(v_haul, 2);
        END IF;

        -- And the copy's tier really is read everywhere, not the kind's.
        IF servant_tier_of(v_srv) <> got.now_tier THEN
            RAISE EXCEPTION 'the copy and the readers disagree about the tier';
        END IF;

        -- A servant at the top is told so rather than silently stalling.
        UPDATE player_servants ps
        SET stars = v_max::smallint,
            ascension = (v_top - (SELECT s.tier FROM servants s
                                  WHERE s.servant_code = ps.servant_code))::smallint
        WHERE ps.player_servant_id = v_srv;
        BEGIN
            PERFORM servant_ascend(v_who, v_srv);
            RAISE EXCEPTION 'a servant ascended past the last tier';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
