-- 0131_two_ways_a_killer_move_reaches_you
--
-- 0129 made advanced techniques and 0130 made the manuals that carry them, and
-- so far there is no way on earth to get one. This is the half that matters:
-- an unobtainable reward is the same as no reward, and it is invisible in the
-- code, because every function works perfectly on content nobody can reach.
--
-- Two routes, deliberately different in feel.
--
--   FOUND. Off something that was hard to kill. `roll_manual_drop` already
--   dropped a manual on 4% of kills; it now rolls for a technique manual
--   FIRST, at its own rate, and only off an elite, a boss or a world beast. An
--   ordinary beast has never been the sort of thing that is carrying a killer
--   move, and now it is not.
--
--   MADE. Out of a refinement that went unusually well. An attack refinement
--   coming out at high harmony now produces a technique manual instead of a
--   stat manual. Harmony is the right dial: it is already the measure of how
--   well the pages agreed, it is visible in the forecast BEFORE committing,
--   and it is the number a refiner is already trying to raise. This is the
--   route that works at every rank, because tier follows the pages rather than
--   what happens to live in the region.
--
-- And a thing that quietly stops: refinement used to attach the strongest
-- BASIC technique of the dominant Path. After 0126 that is a move the player
-- could simply have bought, so it was a reward indistinguishable from no
-- reward. Refinement now attaches an advanced move or nothing.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('technique_manual_drop_chance', 0.06,
     'Chance an elite, boss or world beast was carrying a technique manual. Rolled before the ordinary manual drop, and only for those three kinds.'),
    ('technique_manual_harmony', 105,
     'Harmony an attack refinement must reach for a killer move to fall out of it. The failure threshold is 45 and the ceiling is 140, so this is a good refinement rather than a lucky one.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- A refined technique manual needs a name that sounds like one.
INSERT INTO archetype_endings (archetype, ending) VALUES
    ('technique', 'Killer Move'),
    ('technique', 'Secret Art'),
    ('technique', 'Severing Canon'),
    ('technique', 'True Form')
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- roll_manual_drop, from 0033_trading
-- ---------------------------------------------------------------------------
-- Two rolls where there was one. The technique roll goes first because it is
-- the rarer and better outcome, and a kill that hands over a killer move
-- should not also hand over a stat manual.
--
-- The ordinary roll now excludes archetype 'technique' explicitly. Without
-- that line the eighteen manuals 0130 added would have been folded into the
-- common pool and become the most reliable way to get one - which is the exact
-- opposite of what they are for.

CREATE OR REPLACE FUNCTION roll_manual_drop(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    beast RECORD;
    found BIGINT;
BEGIN
    SELECT cs.rank, cs.kind INTO beast
    FROM creature_species cs WHERE cs.species_id = p_species_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- The hard fights, and only them.
    IF beast.kind IN ('elite', 'boss', 'world')
       AND random() < game_config_value('technique_manual_drop_chance') THEN
        SELECT m.manual_id INTO found
        FROM manuals m
        WHERE m.code IS NOT NULL
          AND m.archetype = 'technique'
          AND m.required_rank <= GREATEST(beast.rank, 1)
          AND NOT EXISTS (
              SELECT 1 FROM player_manuals pm
              WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
          )
        ORDER BY random()
        LIMIT 1;

        IF found IS NOT NULL THEN
            INSERT INTO player_manuals (player_id, manual_id)
            VALUES (p_player_id, found)
            ON CONFLICT DO NOTHING;
            RETURN found;
        END IF;
    END IF;

    IF random() >= game_config_value('manual_drop_chance') THEN
        RETURN NULL;
    END IF;

    SELECT m.manual_id INTO found
    FROM manuals m
    WHERE m.code IS NOT NULL
      AND m.archetype <> 'technique'
      AND m.required_rank <= GREATEST(beast.rank, 1)
      AND NOT EXISTS (
          SELECT 1 FROM player_manuals pm
          WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
      )
    ORDER BY random()
    LIMIT 1;

    IF found IS NULL THEN
        RETURN NULL;
    END IF;

    INSERT INTO player_manuals (player_id, manual_id) VALUES (p_player_id, found)
    ON CONFLICT DO NOTHING;

    RETURN found;
END;
$$;

COMMENT ON FUNCTION roll_manual_drop(BIGINT, BIGINT) IS
    'A manual off a corpse. Elites, bosses and world beasts roll first for a technique manual; everything else can only ever yield an ordinary one.';


-- ---------------------------------------------------------------------------
-- refine, from 0087_jade_protects_what_it_can
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION refine(
    p_player_id BIGINT,
    p_page_ids  BIGINT[],
    p_protect   BIGINT DEFAULT NULL
)
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
    destroyed   INTEGER,
    quality     TEXT,
    draws       INTEGER
)
LANGUAGE plpgsql
AS $$
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
          AND t.rank <= GREATEST(1, LEAST(9, (look.forecast_tier + 1) / 2))
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
$$;


-- ---------------------------------------------------------------------------
-- Both routes have to be able to reach every rank
-- ---------------------------------------------------------------------------
-- The drop route cannot, on today's bestiary, and that is worth knowing rather
-- than discovering: the highest elite is rank 5, and above it there is one
-- rank 7 boss and one rank 9 world beast. Ranks 6 and 8 have nothing to drop
-- them. Refinement covers those, because its tier comes from the pages rather
-- than from what happens to live nearby - so the check below is on refinement,
-- which is the route that must never have a hole in it.

DO $$
DECLARE
    gap SMALLINT;
BEGIN
    SELECT r.rank INTO gap
    FROM generate_series(1, 9) AS r (rank)
    WHERE NOT EXISTS (
        SELECT 1 FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL AND t.grade = 'advanced' AND t.rank = r.rank
    )
    ORDER BY r.rank LIMIT 1;

    IF gap IS NOT NULL THEN
        RAISE EXCEPTION 'refinement can never produce a rank % killer move', gap;
    END IF;

    -- The harmony bar has to be reachable. Above the ceiling and this route is
    -- shut without saying so.
    IF game_config_value('technique_manual_harmony') > 140 THEN
        RAISE EXCEPTION 'the harmony bar for a technique manual cannot be cleared';
    END IF;

    IF game_config_value('technique_manual_harmony')
       <= game_config_value('refinement_failure_threshold') THEN
        RAISE EXCEPTION 'every surviving refinement would produce a killer move';
    END IF;
END;
$$;
