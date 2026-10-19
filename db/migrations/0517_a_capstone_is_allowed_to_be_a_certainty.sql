-- 0517_a_capstone_is_allowed_to_be_a_certainty
--
-- 0516 bounded every source at three fifths of an effect, and a standing test
-- caught the one place that is wrong:
--
--     test_a_death_ward_fires_once_and_the_fight_remembers
--     "Divine death_ward is capped at 1.0, so it is a certainty rather than a
--      gamble"
--
-- A Divine body's death ward is a deliberate capstone - the whole point of
-- the roll is that it is a certainty, and a flat share turns it into a 60%
-- chance. That is not the thing anybody asked for; it is collateral from
-- applying one number to thirty-two effects.
--
-- So the share becomes per-effect, the same way `cap_per_rank` did in 0492:
-- a column with a sensible default and one exception, rather than a rule with
-- a special case hidden inside a function. `death_ward` keeps 1.00 and every
-- other effect takes 0.60.
--
-- AND TWO SOURCES WERE REPORTING MORE THAN THEY GIVE. `physique_stat` and
-- `root_stat` clamp internally - to the WHOLE cap - so a Divine body read
-- 0.300 dodge while the fight used 0.240. That is the 0492 fault exactly, and
-- a standing test found it inside the hour this time:
--
--     test_a_body_and_a_sword_share_one_ceiling
--     assert player_stat(divine, 'dodge') == physique_stat(divine, 'dodge')
--
-- Both now clamp to the source cap, so what a body says it gives is what a
-- blow uses. The other four unclamped sources are bounded by `player_stat`
-- and report raw, which is honest because nothing reads them directly.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE gu_effects
    ADD COLUMN source_share NUMERIC(4,3) NOT NULL DEFAULT 0.600
        CHECK (source_share > 0 AND source_share <= 1);

COMMENT ON COLUMN gu_effects.source_share IS
    'The most any ONE of the eight stat sources may contribute, as a share of this effect''s ceiling. 0.600 everywhere so a cap takes two sources to reach - except where one source finishing it is the design, which is what a Divine body''s death ward is for.';

-- The one capstone. A Divine body's death ward is a certainty by design and a
-- standing test says so in those words.
UPDATE gu_effects SET source_share = 1.000 WHERE code = 'death_ward';


CREATE OR REPLACE FUNCTION stat_source_cap(p_effect_code TEXT, p_player_id BIGINT DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- Per effect since 0517. Measured against the realm-scaled lid where
    -- there is one, so the share grows with the ceiling it is a share of.
    SELECT COALESCE(gu_effect_cap(p_effect_code, p_player_id), e.cap)
           * e.source_share
    FROM gu_effects e
    WHERE e.code = p_effect_code;
$fn$;


-- ---------------------------------------------------------------------------
-- The two sources that clamped to the whole cap
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src   TEXT;
    one   TEXT;
    alias TEXT;
    found TEXT;
    hits  INTEGER;
BEGIN
    FOREACH one IN ARRAY ARRAY['physique_stat', 'root_stat']::TEXT[] LOOP
        src := pg_get_functiondef(
            (SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = one));

        -- The two functions alias `gu_effects` differently, so the cap
        -- reference is found rather than assumed. My first attempt guessed
        -- `f.cap` and `ef.cap`; it is `e.cap` in both.
        found := NULL;
        FOREACH alias IN ARRAY ARRAY['e.cap', 'ef.cap', 'f.cap',
                                     'gu_effects.cap']::TEXT[] LOOP
            IF strpos(src, 'LEAST(' || alias) > 0 THEN
                found := alias;
                EXIT;
            END IF;
        END LOOP;

        IF found IS NULL THEN
            RAISE EXCEPTION
                '% does not clamp to a cap under any alias I know', one;
        END IF;

        hits := (length(src) - length(replace(src, 'LEAST(' || found, '')))
                / length('LEAST(' || found);
        IF hits <> 1 THEN
            RAISE EXCEPTION '% clamps % times, expected once', one, hits;
        END IF;

        EXECUTE replace(src, 'LEAST(' || found,
                        'LEAST(stat_source_cap(p_effect, p_player_id)');
    END LOOP;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A certainty stays certain, and no source outruns what it gives
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
BEGIN
    -- The capstone is a capstone again.
    IF stat_source_cap('death_ward')
       <> (SELECT cap FROM gu_effects WHERE code = 'death_ward') THEN
        RAISE EXCEPTION
            'a death ward from one source is % of its ceiling, not all of it',
            stat_source_cap('death_ward');
    END IF;

    -- And it is the ONLY exception, so this stays a rule with a reason rather
    -- than a list of favours.
    SELECT string_agg(code, ', ') INTO v_bad FROM gu_effects
    WHERE source_share >= 1 AND code <> 'death_ward';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these effects were quietly exempted too: %', v_bad;
    END IF;

    -- Crit rate still takes two sources, which is the thing 0516 was for.
    IF stat_source_cap('crit_rate')
       >= (SELECT cap FROM gu_effects WHERE code = 'crit_rate') THEN
        RAISE EXCEPTION 'crit rate went back to being reachable from one source';
    END IF;

    -- WHAT A SOURCE SAYS IS WHAT A BLOW USES. The 0492 fault, asserted for
    -- every cultivator and every effect rather than the two that had it.
    SELECT string_agg(x.who || ' ' || x.code, ', ') INTO v_bad
    FROM (
        SELECT p.discord_name AS who, e.code
        FROM players p CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND (physique_stat(p.player_id, e.code)
                   > stat_source_cap(e.code, p.player_id) + 0.0001
            OR root_stat(p.player_id, e.code)
                   > stat_source_cap(e.code, p.player_id) + 0.0001
            OR gu_stat(p.player_id, e.code)
                   > stat_source_cap(e.code, p.player_id) + 0.0001
            OR equipment_stat(p.player_id, e.code)
                   > stat_source_cap(e.code, p.player_id) + 0.0001)
        LIMIT 8
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a source reports more than it gives: %', v_bad;
    END IF;

    -- Nobody is above their own lid.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND player_stat(p.player_id, e.code)
          > gu_effect_cap(e.code, p.player_id) + 0.0001;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% readings sit above their own lid', v_n;
    END IF;

    RAISE NOTICE
        'one source gives at most %%% of an effect, and all of a death ward',
        round(game_config_value('stat_source_share') * 100);
END;
$probe$;
