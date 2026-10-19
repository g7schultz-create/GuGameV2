-- 0104_the_binder_takes_manuals_apart
--
-- A manual can be unbound back into pages.
--
-- Levelling Refinement means refining, and every refinement makes a manual
-- whether or not it makes a good one. A refiner at level 6 is holding a
-- dozen Tier 1 books they will never equip and cannot get rid of: manuals
-- are not sellable on the auction house by the piece, and nothing consumes
-- them. The clutter is the visible half. The real problem is that the only
-- way to practise the craft was to bury the materials.
--
-- IT MUST LOSE. Refining takes pages and makes a manual; unbinding takes a
-- manual and makes pages. Put those two together at par and you have a
-- machine that turns two pages into two pages forever while paying
-- Refinement EXP each way. So unbinding returns a SHARE of what went in, the
-- share is well under half, and it grants no EXP at all. Practice has to cost
-- something or it is not practice.
--
-- WHAT A MANUAL IS WORTH, EXACTLY. `refine_forecast` derives a manual's tier
-- from total page power: tier T is the highest whose `bonus_budget * 100` is
-- within `total_power / refinement_potential_divisor`. Invert that and a
-- tier-T manual implies at least
--
--     bonus_budget(T) * 100 * refinement_potential_divisor
--
-- page power went into it. The Binder returns `manual_unbind_share` of that,
-- as pages one tier below the manual - so an unbound manual never yields a
-- page as good as the manual itself was.
--
-- Derived rather than tabulated on purpose: the day somebody retunes
-- `bonus_budget` or the divisor, this follows them. A table of yields would
-- have to be remembered.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('manual_unbind_share', 0.35,
     'How much of the page power that made a manual comes back when it is unbound. Well under half, so unbinding is never a way to farm pages.');


-- ---------------------------------------------------------------------------
-- Minting one page of a stated tier
-- ---------------------------------------------------------------------------
-- `mint_page` picks a tier by roll weight, which is right for a drop and
-- wrong here: tiers 8 to 10 carry weight 0 precisely so they cannot be found,
-- and an unbound Tier 9 manual has to be able to return a Tier 8 page.
--
-- So the rolling of power, quality and trait moves into a function that takes
-- the tier as given, and `mint_page` becomes "choose a tier, then that". One
-- implementation of what a page is, two ways in.

CREATE FUNCTION mint_page_at(
    p_owner_id BIGINT,
    p_tier     SMALLINT,
    p_path     TEXT DEFAULT NULL,
    p_type     TEXT DEFAULT NULL,
    p_region   TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    chosen_path  TEXT;
    chosen_type  TEXT;
    chosen_trait TEXT;
    lo           SMALLINT;
    hi           SMALLINT;
    q            SMALLINT;
    pow          SMALLINT;
    new_id       BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM page_tiers WHERE tier = p_tier) THEN
        RAISE EXCEPTION 'there is no page tier %', p_tier
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
    FROM page_tiers t WHERE t.tier = p_tier;

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
    VALUES (p_owner_id, p_tier, chosen_path, chosen_type, chosen_trait, pow, q, p_region)
    RETURNING page_id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION mint_page_at(BIGINT, SMALLINT, TEXT, TEXT, TEXT) IS
    'One page of exactly this tier, ignoring roll weight. What a drop cannot reach, a conversion can.';


CREATE OR REPLACE FUNCTION mint_page(
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
    chosen_tier SMALLINT;
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

    RETURN mint_page_at(p_owner_id, chosen_tier, p_path, p_type, p_region);
END;
$$;

COMMENT ON FUNCTION mint_page(BIGINT, SMALLINT, SMALLINT, TEXT, TEXT, TEXT) IS
    'Rolls one page. The tier is drawn from the weights in page_tiers - 8 to 10 carry weight 0 and never drop - and the page itself is minted by mint_page_at.';


-- ---------------------------------------------------------------------------
-- What a manual comes apart into
-- ---------------------------------------------------------------------------

CREATE FUNCTION manual_unbind_yield(p_tier SMALLINT)
RETURNS TABLE (pages INTEGER, page_tier SMALLINT, power_returned NUMERIC)
LANGUAGE sql STABLE
AS $$
    WITH worth AS (
        SELECT mt.bonus_budget * 100
               * game_config_value('refinement_potential_divisor') AS implied,
               -- Never a page as good as the book it came out of. A Tier 1
               -- manual bottoms out at Tier 1 pages rather than at nothing.
               GREATEST(1, p_tier - 1)::smallint AS back_at
        FROM manual_tiers mt WHERE mt.tier = p_tier
    ),
    band AS (
        SELECT w.implied * game_config_value('manual_unbind_share') AS returned,
               w.back_at,
               (pt.power_min + pt.power_max) / 2.0 AS per_page
        FROM worth w JOIN page_tiers pt ON pt.tier = w.back_at
    )
    -- At least one page: a manual that unbound into nothing would be a button
    -- that destroys your property and thanks you for it.
    SELECT GREATEST(1, floor(b.returned / b.per_page))::integer,
           b.back_at,
           round(b.returned, 1)
    FROM band b;
$$;

COMMENT ON FUNCTION manual_unbind_yield(SMALLINT) IS
    'How many pages, and of what tier, a manual of this tier comes apart into. Derived from the page power its tier implies, so retuning the tiers retunes this.';


-- ---------------------------------------------------------------------------
-- The Binder
-- ---------------------------------------------------------------------------

CREATE FUNCTION unbind_manuals(p_player_id BIGINT, p_manual_ids BIGINT[])
RETURNS TABLE (
    manuals_taken INTEGER,
    pages_made    INTEGER,
    top_tier      SMALLINT,
    page_ids      BIGINT[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    book    RECORD;
    yield   RECORD;
    made    BIGINT[] := '{}';
    taken   INTEGER := 0;
    best    SMALLINT := 0;
    lead    TEXT;
    i       INTEGER;
BEGIN
    IF p_manual_ids IS NULL OR array_length(p_manual_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'choose at least one manual to unbind'
            USING ERRCODE = 'check_violation';
    END IF;

    FOR book IN
        SELECT m.manual_id, m.name, m.tier, m.code
        FROM unnest(p_manual_ids) AS u (manual_id)
        JOIN manuals m ON m.manual_id = u.manual_id
        JOIN player_manuals pm
          ON pm.manual_id = m.manual_id AND pm.player_id = p_player_id
        ORDER BY m.tier DESC, m.manual_id
    LOOP
        -- An equipped manual is refused rather than quietly unequipped: the
        -- slot table CASCADEs, so without this a bulk unbind would strip the
        -- book you were reading and say nothing about it.
        IF EXISTS (
            SELECT 1 FROM player_manual_slots s
            WHERE s.player_id = p_player_id AND s.manual_id = book.manual_id
        ) THEN
            RAISE EXCEPTION '% is equipped. Take it off first', book.name
                USING ERRCODE = 'check_violation';
        END IF;

        SELECT * INTO yield FROM manual_unbind_yield(book.tier);

        -- The pages come back on the manual's own leading Path, which is what
        -- makes them worth having: pages of one Path refine together.
        SELECT mp.path_code INTO lead
        FROM manual_paths mp WHERE mp.manual_id = book.manual_id
        ORDER BY mp.weight DESC, mp.path_code LIMIT 1;

        FOR i IN 1..yield.pages LOOP
            made := made || mint_page_at(
                p_player_id, yield.page_tier, lead, NULL, NULL
            );
        END LOOP;

        DELETE FROM player_manuals
        WHERE player_id = p_player_id AND manual_id = book.manual_id;

        taken := taken + 1;
        best  := GREATEST(best, book.tier);
    END LOOP;

    IF taken = 0 THEN
        RAISE EXCEPTION 'none of those are yours to unbind'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN QUERY SELECT taken, COALESCE(array_length(made, 1), 0), best, made;
END;
$$;

COMMENT ON FUNCTION unbind_manuals(BIGINT, BIGINT[]) IS
    'Takes manuals apart into pages of their own leading Path. Refuses an equipped book, grants no EXP, and always returns less than went in.';
