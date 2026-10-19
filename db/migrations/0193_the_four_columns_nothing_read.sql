-- 0193_the_four_columns_nothing_read
--
-- `refine` spends a manual's whole stat budget across twelve columns, chosen
-- by which page types went into it. Eight of those columns are read by
-- something. Four are read by nothing at all:
--
--     cultivation_rate_bonus -> settle_passive_cultivation, cultivation_per_hour
--     physique_rate_bonus    -> settle_passive_cultivation
--     attainment_rate_bonus  -> player_attainment_rate
--     hp/defense/strength    -> apply_physique_xp
--     attack_bonus           -> player_external_multiplier
--     gathering_bonus        -> mine, gather
--
--     speed_bonus            -> NOTHING
--     breakthrough_bonus     -> NOTHING
--     essence_bonus          -> NOTHING
--     refinement_bonus       -> NOTHING
--
-- So a refinement made entirely of speed pages spends its entire budget on a
-- number that is displayed and never consulted. The best stat manual
-- clearwest can currently build - tier 8, harmony 135, six speed pages - comes
-- out at "+85.9% Speed" and does exactly nothing. 61 of the 157 manuals alive
-- carry budget in these four columns.
--
-- The four are wired to effects THAT ALREADY EXIST AND ARE ALREADY READ, so
-- nothing here is a new system:
--
--     speed_bonus       -> dodge                   (battle_act, line 283)
--     breakthrough_bonus-> realm_tempering         (breakthrough, line 59)
--     essence_bonus     -> max_qi                  (player_max_qi)
--     refinement_bonus  -> refine_conflict_relief  (refine_forecast)
--
-- THE MAPPING GOES THROUGH `player_stat`, which is what makes it cheap: every
-- one of those four effects is already fetched with `player_stat`, so adding
-- manuals as a sixth source lights all four up at once, and the effect's own
-- `cap` applies to them exactly as it does to Gu, gear, body, root and
-- dwelling. A tier 8 speed manual pays +0.86 into a dodge cap of 0.40, which
-- is the game's existing statement about how much dodge is too much - a
-- manual now competes for that ceiling instead of being ignored.
--
-- Only the four dead columns are mapped. The eight live ones are read
-- directly at their point of use and would be counted twice.
--
-- NO EXISTING MANUAL IS EDITED. The budget is already sitting in those
-- columns; this makes it count. All 61 start working the moment this applies.
--
-- One reader has to move: `refine_forecast` asks `physique_stat` for
-- refine_conflict_relief rather than `player_stat`, so it would not see a
-- manual. Only physiques grant that effect today (3 rows; gu and equipment
-- have none), so widening it to `player_stat` changes nothing for anybody and
-- is what the other three already do.
--
-- Forward-only. Do not edit once applied.


-- Which manual column pays into which effect. A table rather than a CASE so
-- the invariant below can read it, and so a thirteenth column added later has
-- somewhere obvious to be declared or deliberately left out.
CREATE TABLE manual_effect_columns (
    manual_column TEXT PRIMARY KEY,
    effect_code   TEXT NOT NULL REFERENCES gu_effects (code) ON DELETE CASCADE,
    note          TEXT NOT NULL DEFAULT ''
);

CREATE INDEX manual_effect_columns_effect_idx
    ON manual_effect_columns (effect_code);

INSERT INTO manual_effect_columns (manual_column, effect_code, note) VALUES
    ('speed_bonus', 'dodge',
     'Speed as evasion: the blow arrives where the reader is not.'),
    ('breakthrough_bonus', 'realm_tempering',
     'What crossing a realm does to the body, which is the only part of a '
     'breakthrough that is not automatic.'),
    ('essence_bonus', 'max_qi',
     'A deeper aperture. The essence RESOURCE is still unimplemented - '
     'nothing grants or spends player_cultivation.essence - so this pays into '
     'the aperture depth that is real.'),
    ('refinement_bonus', 'refine_conflict_relief',
     'A book about refining makes the next refining tolerate Paths that '
     'fight each other.');


CREATE FUNCTION manual_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT CASE c.manual_column
                   WHEN 'speed_bonus'        THEN b.speed_bonus
                   WHEN 'breakthrough_bonus' THEN b.breakthrough_bonus
                   WHEN 'essence_bonus'      THEN b.essence_bonus
                   WHEN 'refinement_bonus'   THEN b.refinement_bonus
               END
        FROM manual_effect_columns c
        JOIN player_manual_bonuses b ON b.player_id = p_player_id
        WHERE c.effect_code = p_effect
    ), 0)::numeric;
$$;

COMMENT ON FUNCTION manual_stat(BIGINT, TEXT) IS
    'What a cultivator''s EQUIPPED manuals pay into one effect. Only the four '
    'columns nothing else reads; the other eight are consulted directly where '
    'they are used and would be double counted here.';


-- The sixth source. Unchanged otherwise, cap and all.
CREATE OR REPLACE FUNCTION player_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    SELECT LEAST(
        (SELECT ef.cap FROM gu_effects ef WHERE ef.code = p_effect),
        gu_stat(p_player_id, p_effect)
        + equipment_stat(p_player_id, p_effect)
        + physique_stat(p_player_id, p_effect)
        + root_stat(p_player_id, p_effect)
        + dwelling_stat(p_player_id, p_effect)
        + manual_stat(p_player_id, p_effect)
    );
$$;


DO $$
DECLARE
    src TEXT;
BEGIN
    -- `refine_forecast` reads relief from the body only, so a manual would
    -- never reach it. Lifted and patched rather than retyped.
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc
    WHERE proname = 'refine_forecast';

    IF position('physique_stat(p_player_id, ''refine_conflict_relief'')' IN src) = 0 THEN
        RAISE EXCEPTION 'refine_forecast no longer reads relief the old way';
    END IF;

    EXECUTE replace(
        src,
        'physique_stat(p_player_id, ''refine_conflict_relief'')',
        'player_stat(p_player_id, ''refine_conflict_relief'')'
    );
END;
$$;


-- ---------------------------------------------------------------------------
-- Every column of a manual's budget now reaches something.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    thin TEXT;
    who  BIGINT;
    book BIGINT;
    was  NUMERIC;
    now_ NUMERIC;
BEGIN
    -- Stated over `page_types`, which is what decides where `refine` puts the
    -- budget - so a page type pointed at a new column has to answer this too.
    SELECT string_agg(pt.manual_column, ', ' ORDER BY pt.manual_column)
    INTO thin
    FROM (SELECT DISTINCT manual_column FROM page_types) pt
    WHERE NOT EXISTS (SELECT 1 FROM manual_effect_columns c
                      WHERE c.manual_column = pt.manual_column)
      -- The eight read directly at their point of use.
      AND pt.manual_column NOT IN (
          'cultivation_rate_bonus', 'hp_bonus', 'defense_bonus',
          'strength_bonus', 'attack_bonus', 'gathering_bonus');

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these columns still reach nothing: %', thin;
    END IF;

    -- Every mapped effect must be one somebody can actually hold.
    SELECT string_agg(c.manual_column, ', ') INTO thin
    FROM manual_effect_columns c
    JOIN gu_effects e ON e.code = c.effect_code
    WHERE NOT e.is_live OR e.cap <= 0;

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'mapped onto a dead effect: %', thin;
    END IF;

    -- And the eight live columns must NOT be mapped, or they count twice.
    SELECT string_agg(c.manual_column, ', ') INTO thin
    FROM manual_effect_columns c
    WHERE c.manual_column IN (
        'cultivation_rate_bonus', 'physique_rate_bonus', 'attainment_rate_bonus',
        'hp_bonus', 'defense_bonus', 'strength_bonus', 'attack_bonus',
        'gathering_bonus');

    IF thin IS NOT NULL THEN
        RAISE EXCEPTION 'these are already read elsewhere and would double: %', thin;
    END IF;

    -- ---- and it actually moves a real cultivator's numbers ----------------
    SELECT p.player_id INTO who FROM players p
    JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
    ORDER BY p.player_id LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no live cultivator; tests carry it';
        RETURN;
    END IF;

    BEGIN
        was := player_stat(who, 'dodge');

        -- `manuals_refinement_is_whole`: harmony and refined_at travel
        -- together or not at all.
        INSERT INTO manuals (name, tier, required_rank, archetype, harmony,
                             refined_at, quality, speed_bonus, description)
        VALUES ('Probe Manual', 1, 1, 'movement', 50, now(), 'common', 0.05,
                'probe')
        RETURNING manual_id INTO book;

        INSERT INTO player_manuals (player_id, manual_id) VALUES (who, book);
        -- There are two slots, 0 and 1, and this cultivator may be using
        -- both. The whole block is thrown away below, so borrowing one is
        -- free.
        DELETE FROM player_manual_slots WHERE player_id = who;
        INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
        VALUES (who, 0, book);

        now_ := player_stat(who, 'dodge');

        IF now_ <= was AND was < (SELECT cap FROM gu_effects WHERE code = 'dodge') THEN
            RAISE EXCEPTION
                'an equipped speed manual still pays nothing: dodge % -> %',
                was, now_;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
