-- 0187_a_killer_move_is_worth_carrying_early
--
-- 0130 wrote the eighteen technique manuals at HALF their tier's bonus
-- budget. The reasoning was sound - a book that gives a killer move and full
-- stats beats a stat manual of the same tier on both counts - but the result
-- is that the rarest drop in the game is the weakest thing of its tier:
--
--   tier 4   stat manual 0.21     technique manual 0.105
--   tier 6   stat manual 0.36     technique manual 0.180
--
-- And its realm gate is the technique's rank, so clearwest won a tier 7
-- Heaven-Defying Edge Canon off a rank 7 world beast, could not equip it at
-- realm 3, and got nothing at all from the best item on the server.
--
-- Both halves change. A technique manual now spends its whole tier budget,
-- and asks half the realm its tier would rather than the rank of the move it
-- carries - so the BOOK is worth carrying while you climb toward the MOVE.
--
-- The move itself is not loosened. `player_usable_techniques` still refuses
-- anything above your realm rank, in SQL, whatever is equipped. That gate is
-- the one that matters and it is untouched: clearwest can wear the Canon
-- today for +45%, and Heaven-Defying Edge stays dark until realm 6.
--
-- Refined technique manuals already spent the full budget - `refine` applies
-- `budget * share.part` whatever the archetype - so only the seeded books
-- were short. What refine did share was the old realm gate, which is why it
-- is patched here too.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION technique_manual_required_rank(p_tier SMALLINT)
RETURNS SMALLINT
LANGUAGE sql
IMMUTABLE
AS $$
    -- Half the tier, floor, never below one. A stat manual asks about
    -- tier - 1; a book carrying a killer move asks half that tier, because
    -- the move has its own gate and this one is only about the ink.
    SELECT GREATEST(1, LEAST(9, COALESCE(p_tier, 1) / 2))::smallint;
$$;


-- The whole budget, into the stat these books have always spent it on.
UPDATE manuals m
SET attack_bonus = mt.bonus_budget,
    required_rank = technique_manual_required_rank(m.tier)
FROM manual_tiers mt
WHERE mt.tier = m.tier
  AND m.archetype = 'technique'
  AND m.code IS NOT NULL;


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
            CASE WHEN arch = 'technique'
                 THEN technique_manual_required_rank(look.forecast_tier)
                 ELSE GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2))
            END, arch,
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


DO $$
DECLARE
    wrong TEXT;
BEGIN
    -- Every seeded technique manual spends its tier in full.
    SELECT string_agg(m.name || ' (' || manual_total_bonus(m.manual_id)
                      || ' of ' || mt.bonus_budget || ')', ', ' ORDER BY m.tier)
    INTO wrong
    FROM manuals m
    JOIN manual_tiers mt ON mt.tier = m.tier
    WHERE m.archetype = 'technique' AND m.code IS NOT NULL
      AND manual_total_bonus(m.manual_id) <> mt.bonus_budget;

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'these still spend less than their tier: %', wrong;
    END IF;

    -- And none of them asks more realm than the move it carries, or the
    -- book would still be dead weight until the move was live anyway. A rank
    -- 1 move is the exception by arithmetic: there is no realm below 1 to
    -- open the book at, so the two gates land together and always will.
    SELECT string_agg(m.name || ' (book ' || m.required_rank
                      || ', move ' || t.rank || ')', ', ')
    INTO wrong
    FROM manuals m
    JOIN manual_techniques mt2 ON mt2.manual_id = m.manual_id
    JOIN techniques t ON t.technique_id = mt2.technique_id
    WHERE m.archetype = 'technique' AND m.code IS NOT NULL
      AND t.rank > 1
      AND m.required_rank >= t.rank;

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION
            'the book is gated no earlier than its move: %', wrong;
    END IF;

    -- The move's own gate is untouched. A rank 6 technique must still be
    -- refused to a realm 3 cultivator however the book is worn.
    IF EXISTS (
        SELECT 1 FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        JOIN player_cultivation pc ON pc.player_id = u.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE t.rank > r.rank
    ) THEN
        RAISE EXCEPTION 'somebody can wield a technique above their realm';
    END IF;

    -- And refine hands out the same softer gate rather than its own.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'refine')
       NOT LIKE '%technique_manual_required_rank%' THEN
        RAISE EXCEPTION 'refine still gates a technique manual by the old rule';
    END IF;
END;
$$;
