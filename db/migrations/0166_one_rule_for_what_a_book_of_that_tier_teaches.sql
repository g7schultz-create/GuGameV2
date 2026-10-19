-- 0166_one_rule_for_what_a_book_of_that_tier_teaches
--
-- Two ways a killer move reaches you, 0131 said, and they priced it
-- differently. 0130 wrote the canonical technique manuals at tier = rank + 1,
-- so Thunder Gale Dismemberment - rank 3 - lives in a tier 4 book. 0131 then
-- had `refine` grant the strongest advanced technique of rank
-- <= (forecast_tier + 1) / 2, which needs a tier 5 or 6 refinement for that
-- same move.
--
-- The gap is not constant, which is what makes it a bug rather than a price:
--
--   rank 1   canonical tier 2    refine at 1-2      agrees
--   rank 2   canonical tier 3    refine at 3-4      one tier over
--   rank 3   canonical tier 4    refine at 5-6      two tiers over
--   rank 4   canonical tier 5    refine at 7-8      three tiers over
--   rank 5   canonical tier 6    refine at 9-10     four tiers over
--   rank 6   canonical tier 7    unreachable
--   rank 7   canonical tier 8    unreachable
--   rank 8   canonical tier 9    unreachable
--   rank 9   canonical tier 10   unreachable
--
-- Half the killer moves in the game could not be refined for at all. Tier 10
-- is the top of the crafting ladder and it handed back a rank 5 move, while
-- the book that teaches rank 9 is also tier 10. So the migration whose title
-- is "two ways a killer move reaches you" had one way for ranks 6 and up.
--
-- Both rules come out into functions, and each is the other's inverse. A
-- refinement now teaches exactly what a canonical book of that tier teaches -
-- which is the sentence the two systems were each trying to express alone.
--
-- Only the technique's rank cap changes. `required_rank` on a refined manual
-- still reads (tier + 1) / 2: that governs every refined manual including
-- the stat ones, and re-tuning the realm gate on all of them is a different
-- change from fixing which move falls out.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_manual_tier(p_rank SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
IMMUTABLE
AS $$
    -- 0130's rule, which was written inline in an INSERT and therefore could
    -- not be read by the code that had to agree with it.
    SELECT LEAST(10, GREATEST(1, p_rank + 1))::smallint;
$$;


CREATE FUNCTION technique_manual_rank(p_tier SMALLINT)
RETURNS SMALLINT
RETURNS NULL ON NULL INPUT
LANGUAGE sql
IMMUTABLE
AS $$
    -- The inverse, and the only place refinement is allowed to decide how
    -- strong a move a tier is worth.
    SELECT GREATEST(1, LEAST(9, p_tier - 1))::smallint;
$$;


CREATE OR REPLACE FUNCTION public.refine(p_player_id bigint, p_page_ids bigint[], p_protect bigint DEFAULT NULL::bigint)
 RETURNS TABLE(succeeded boolean, harmony smallint, manual_id bigint, manual_name text, tier smallint, archetype text, retained numeric, exp_gained bigint, level_after smallint, destroyed integer, quality text, draws integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    arch       TEXT;
    killer     BIGINT;
    skill      SMALLINT;
    cap        SMALLINT;
    n          INTEGER;
    look       RECORD;
    final_h    SMALLINT;
    keep       NUMERIC;
    band       TEXT;
    lift       NUMERIC;
    n_draws    INTEGER;
    budget     NUMERIC;
    new_manual BIGINT;
    new_name   TEXT;
    gained     BIGINT;
    lvl        SMALLINT;
    killed     INTEGER := 0;
    guard_cost BIGINT := 0;
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


    -- Insurance, paid before the attempt. `spend_jade` refuses rather than
    -- going negative, so an unaffordable protection stops the craft here
    -- rather than half way through it.
    IF p_protect IS NOT NULL THEN
        IF NOT (p_protect = ANY (p_page_ids)) THEN
            RAISE EXCEPTION 'you can only protect a page that is in the refinement'
                USING ERRCODE = 'check_violation';
        END IF;
        PERFORM spend_jade(p_player_id, jade_protection_cost(
            (SELECT mp.tier FROM manual_pages mp WHERE mp.page_id = p_protect)), 'protect_page');
    END IF;

    -- ---- what the pages are worth ---------------------------------------
    SELECT * INTO look FROM refine_forecast(p_player_id, p_page_ids);
    IF look IS NULL THEN
        RAISE EXCEPTION 'those pages could not be read'
            USING ERRCODE = 'check_violation';
    END IF;

    final_h := GREATEST(0, LEAST(140, round(look.base_harmony + (random() * 8 - 4))))::smallint;

    gained := GREATEST(10, round(look.total_power * 0.4 + final_h * 0.6));

    -- ---- failure ---------------------------------------------------------
    IF final_h < game_config_value('refinement_failure_threshold') THEN
        WITH doomed AS (
            SELECT mp.page_id FROM manual_pages mp
            WHERE mp.page_id = ANY (p_page_ids)
              AND mp.page_id IS DISTINCT FROM p_protect
            ORDER BY random() LIMIT GREATEST(1, n / 3)
        )
        DELETE FROM manual_pages WHERE page_id IN (SELECT page_id FROM doomed);
        GET DIAGNOSTICS killed = ROW_COUNT;

        lvl := grant_refinement_exp(p_player_id, gained / 3, FALSE);
        RETURN QUERY SELECT FALSE, final_h, NULL::bigint, NULL::text,
                            NULL::smallint, NULL::text, 0::numeric,
                            gained / 3, lvl, killed, NULL::text, 0;
        RETURN;
    END IF;

    keep := refinement_keep(final_h);

    -- ---- the last roll ---------------------------------------------------
    n_draws := manual_quality_draws(final_h);
    band    := roll_manual_quality(final_h);
    SELECT mq.budget_multiplier INTO lift
    FROM manual_qualities mq WHERE mq.rarity = band;

    SELECT mt.bonus_budget INTO budget
    FROM manual_tiers mt WHERE mt.tier = look.forecast_tier;
    budget := budget * keep * lift;

    -- ---- did a killer move fall out of it? -------------------------------
    -- An advanced technique cannot be bought (0129). This is the other way it
    -- reaches a player, and the only one that does not depend on finding the
    -- right corpse: an attack refinement that comes out at high harmony is a
    -- technique manual rather than a stat manual.
    --
    -- Harmony is the right dial because it is already the measure of how well
    -- the pages agreed, it is visible in the forecast before committing, and
    -- it is the number a refiner is already trying to raise.
    arch := look.archetype;

    IF arch = 'offensive'
       AND final_h >= game_config_value('technique_manual_harmony') THEN
        SELECT t.technique_id INTO killer
        FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL
          AND t.grade = 'advanced'
          AND tp.path_code = look.dominant
          AND t.rank <= technique_manual_rank(look.forecast_tier::smallint)
        ORDER BY t.rank DESC, t.base_power DESC
        LIMIT 1;

        IF killer IS NOT NULL THEN
            arch := 'technique';
        END IF;
    END IF;

    -- ---- the manual ------------------------------------------------------
    new_name := refined_manual_name(look.dominant, arch, final_h,
                                    look.forecast_tier);

    INSERT INTO manuals (name, tier, required_rank, archetype,
                         harmony, quality, created_by, refined_at, description)
    VALUES (new_name, look.forecast_tier,
            GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2)), arch,
            final_h, band, p_player_id, now(),
            'Refined from ' || n || ' pages.')
    RETURNING manuals.manual_id INTO new_manual;

    -- Each page type pays into the column page_types says it feeds, in
    -- proportion to the power it brought.
    PERFORM apply_manual_bonus(new_manual, share.manual_column,
                               budget * share.part)
    FROM (
        SELECT pt.manual_column, sum(mp.power) / look.total_power AS part
        FROM manual_pages mp
        JOIN page_types pt ON pt.code = mp.page_type
        WHERE mp.page_id = ANY (p_page_ids)
        GROUP BY pt.manual_column
    ) AS share;

    INSERT INTO manual_paths (manual_id, path_code, weight)
    SELECT new_manual, mp.path_code,
           LEAST(1, sum(mp.power) / look.total_power)
    FROM manual_pages mp
    WHERE mp.page_id = ANY (p_page_ids)
    GROUP BY mp.path_code;

    -- The move, if one fell out. Only ever an advanced one now: this used to
    -- attach the strongest BASIC technique of the dominant Path, which after
    -- 0126 is a thing the player could simply have bought - a reward that was
    -- indistinguishable from no reward.
    IF killer IS NOT NULL THEN
        INSERT INTO manual_techniques (manual_id, technique_id)
        VALUES (new_manual, killer)
        ON CONFLICT DO NOTHING;
    END IF;

    UPDATE manual_pages
    SET consumed_by = new_manual, consumed_at = now()
    WHERE page_id = ANY (p_page_ids);

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, new_manual);

    lvl := grant_refinement_exp(p_player_id, gained, TRUE);

    RETURN QUERY SELECT TRUE, final_h, new_manual, new_name, look.forecast_tier,
                        arch, keep * lift, gained, lvl, 0, band, n_draws;
END;
$function$;


-- The two functions have to be each other's inverse across the whole ladder,
-- and the canonical books have to be where that inverse says they are. This
-- is the check whose absence let two inlined rules drift for 35 migrations.

DO $$
DECLARE
    broken TEXT;
BEGIN
    SELECT string_agg(r.rank::text, ', ') INTO broken
    FROM generate_series(1, 9) AS r (rank)
    WHERE technique_manual_rank(technique_manual_tier(r.rank::smallint)) <> r.rank;

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION 'rank(tier(rank)) does not come home for rank(s) %',
            broken;
    END IF;

    -- Every canonical technique manual, against the rule it was written from.
    SELECT string_agg(
               m.name || ' (tier ' || m.tier || ' teaches rank ' || t.rank || ')',
               ', ' ORDER BY t.rank)
    INTO broken
    FROM manuals m
    JOIN manual_techniques mt ON mt.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt.technique_id
    WHERE m.archetype = 'technique' AND m.created_by IS NULL
      AND (m.tier <> technique_manual_tier(t.rank)
           OR technique_manual_rank(m.tier) <> t.rank);

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION 'these books disagree with the tier rule: %', broken;
    END IF;

    -- And the thing that was actually wrong: every rank a book exists for
    -- must now be reachable by refining at that book's tier.
    SELECT string_agg(DISTINCT t.rank::text, ', ') INTO broken
    FROM techniques t
    WHERE t.grade = 'advanced' AND t.created_by IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM generate_series(1, 10) AS tier (tier)
          WHERE technique_manual_rank(tier.tier::smallint) = t.rank
      );

    IF broken IS NOT NULL THEN
        RAISE EXCEPTION
            'no refinement tier can reach advanced rank(s) %', broken;
    END IF;
END;
$$;
