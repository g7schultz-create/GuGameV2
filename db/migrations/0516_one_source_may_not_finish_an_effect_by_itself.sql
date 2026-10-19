-- 0516_one_source_may_not_finish_an_effect_by_itself
--
-- The user asked whether crit should be made harder to get, and the measured
-- answer was that crit RATE is the free part - six of six top cultivators sat
-- at exactly 0.600, the cap, and three of them reached it from GEAR ALONE
-- with nothing at all from worms. So the cap was never the thing making it
-- free. This is:
--
--     player_equipment_stats   LEAST(ef.cap, sum(ee.magnitude))
--     player_gu_stats          LEAST(gu_effect_cap(...), sum(...))
--
-- Every source is independently clamped to the WHOLE effect cap, and then
-- `player_stat` clamps their sum to the same number again. So one maxed
-- source is 100% of a stat and the other seven are redundant. That is not a
-- crit_rate problem - it is true of all thirty-two effects, and it is why
-- investing across sources has never been worth anything.
--
-- 0209 settled this exact question one level down: "Caps exist so a build is
-- assembled out of several Gu. One worm that reaches a ceiling by itself makes
-- the other slots decoration." The same sentence is true with 'source' in
-- place of 'Gu', and the rule it implies had never been applied to sources.
--
-- SO NO SINGLE SOURCE MAY GIVE MORE THAN `stat_source_share` OF AN EFFECT.
-- 0.60, the same three-fifths 0209 chose, so reaching a cap takes at least
-- two sources. What that does to crit rate, measured:
--
--     clearwest     worms .170 + gear .600 + destiny .240   0.600 -> 0.600
--     m_i_y_u_k_i.  worms .187 + gear .340 + destiny .240   0.600 -> 0.600
--     ._.visha._.   gear .347 + destiny .300               0.600 -> 0.600
--     pashu0        gear .600 + destiny .180               0.600 -> 0.540
--     sylvrime      gear .600 and nothing else             0.600 -> 0.360
--
-- The three who spread their investment keep every point. The two leaning on
-- one source pay, and sylvrime - whose crit rate was a single piece of gear -
-- pays most. That is the difference between a nerf and a choice: the cap did
-- not move, and what changed is whether one thing can finish it.
--
-- IT APPLIES TO EVERY EFFECT, not only crit_rate, because the fault was never
-- specific to it. 21 source readings across the roster currently sit at a
-- full cap; the probe names every one that moves.
--
-- Base stats are untouched in practice: base_hp caps at 960 and the largest
-- single source gives 127, so three fifths of 960 binds on nobody.
--
-- AND THE VIEWS ARE CLAMPED TOO, not just `player_stat`. 0492 changed one
-- reader of a cap and left the other, so the Gu screen told sylvrime they
-- carried 7.80 crit_damage while their blows used 2.00 - four migrations of
-- consequences. The screen and the fight read the same number here.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value) VALUES ('stat_source_share', 0.60)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


CREATE FUNCTION stat_source_cap(p_effect_code TEXT, p_player_id BIGINT DEFAULT NULL)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- The most any ONE of the eight sources may contribute. Measured against
    -- the realm-scaled lid where there is one, so the share grows with the
    -- ceiling it is a share of rather than being pinned to the flat cap.
    SELECT COALESCE(gu_effect_cap(p_effect_code, p_player_id),
                    (SELECT cap FROM gu_effects WHERE code = p_effect_code))
           * game_config_value('stat_source_share');
$fn$;

COMMENT ON FUNCTION stat_source_cap(TEXT, BIGINT) IS
    'The ceiling on one source of one effect. 0209 made this rule for worms - a single worm must not finish an effect or the other slots are decoration - and it was never applied to the eight SOURCES, so one maxed source was the whole stat.';


-- ---------------------------------------------------------------------------
-- The two views that reported a full cap from one source
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW player_gu_stats AS
SELECT e.player_id,
       te.effect_code,
       LEAST(
           stat_source_cap(te.effect_code, e.player_id),
           sum(te.magnitude * (1::numeric
               + game_config_value('gu_star_step') * (g.stars - 1)::numeric))
       ) AS total,
       sum(te.magnitude * (1::numeric
           + game_config_value('gu_star_step') * (g.stars - 1)::numeric))
           > stat_source_cap(te.effect_code, e.player_id) AS capped
FROM player_gu_equipped e
JOIN player_gu g ON g.gu_id = e.gu_id
JOIN gu_type_effects te ON te.gu_type_id = g.gu_type_id
JOIN gu_effects ef ON ef.code = te.effect_code
GROUP BY e.player_id, te.effect_code;


CREATE OR REPLACE VIEW player_equipment_stats AS
SELECT e.player_id,
       ee.effect_code,
       LEAST(stat_source_cap(ee.effect_code, e.player_id),
             sum(ee.magnitude)) AS total,
       sum(ee.magnitude) > stat_source_cap(ee.effect_code, e.player_id) AS capped
FROM player_equipped e
JOIN equipment_effects ee ON ee.equipment_id = e.equipment_id
JOIN gu_effects ef ON ef.code = ee.effect_code
GROUP BY e.player_id, ee.effect_code;


-- ---------------------------------------------------------------------------
-- And the six sources that never clamped at all
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
BEGIN
    src := pg_get_functiondef('player_stat(bigint,text)'::regprocedure);

    -- The two views above clamp themselves, so gu_stat and equipment_stat
    -- arrive already bounded. physique_stat, root_stat, dwelling_stat,
    -- manual_stat, destiny_stat and servant_stat clamp nowhere, so they are
    -- bounded below - which is also the one place a fight reads them.
    IF src NOT LIKE '%gu_effect_cap(p_effect, p_player_id)%' THEN
        RAISE EXCEPTION 'player_stat is not the version 0496 left';
    END IF;

    EXECUTE $def$
CREATE OR REPLACE FUNCTION player_stat(p_player_id BIGINT, p_effect TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $body$
    SELECT LEAST(
        -- One definition of the lid, shared with player_gu_stats.
        gu_effect_cap(p_effect, p_player_id),
        -- And no single source may finish it. 0209's rule for worms, applied
        -- to the eight sources: one maxed source used to be the whole stat,
        -- which made investing anywhere else worthless. gu_stat and
        -- equipment_stat arrive already clamped by their own views, so the
        -- LEAST here is belt and braces for those two and the actual bound
        -- for the other six, which clamp nowhere else.
        LEAST(stat_source_cap(p_effect, p_player_id), gu_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), equipment_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), physique_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), root_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), dwelling_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), manual_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), destiny_stat(p_player_id, p_effect))
        + LEAST(stat_source_cap(p_effect, p_player_id), servant_stat(p_player_id, p_effect))
    );
$body$;
    $def$;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- No source finishes anything, and the bill is itemised
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
    one   RECORD;
BEGIN
    -- 1. THE RULE. No source, for any cultivator, for any effect, reaches the
    -- whole ceiling on its own any more.
    SELECT string_agg(x.who || ' ' || x.code || ' ' || x.src, ', ') INTO v_bad
    FROM (
        SELECT p.discord_name AS who, e.code, 'worms' AS src
        FROM players p CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND gu_stat(p.player_id, e.code)
              > stat_source_cap(e.code, p.player_id) + 0.0001
        UNION ALL
        SELECT p.discord_name, e.code, 'gear'
        FROM players p CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND equipment_stat(p.player_id, e.code)
              > stat_source_cap(e.code, p.player_id) + 0.0001
        LIMIT 10
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a source still finishes an effect alone: %', v_bad;
    END IF;

    -- 2. Nobody reads above their own lid, which is what a cap is for and the
    -- thing 0496 had to go back and fix.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND player_stat(p.player_id, e.code)
          > gu_effect_cap(e.code, p.player_id) + 0.0001;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% readings sit above their own lid', v_n;
    END IF;

    -- 3. THE DIFFERENCE BETWEEN A NERF AND A CHOICE: somebody who spread
    -- their investment keeps their crit rate, and somebody leaning on one
    -- source does not. If everybody lost the same amount this would just be a
    -- cap cut wearing a different hat.
    FOR one IN
        SELECT p.discord_name,
               round(player_stat(p.player_id, 'crit_rate'), 3) AS rate,
               round(gu_stat(p.player_id, 'crit_rate'), 3) AS worms,
               round(equipment_stat(p.player_id, 'crit_rate'), 3) AS gear,
               round(destiny_stat(p.player_id, 'crit_rate'), 3) AS destiny
        FROM players p
        WHERE p.deleted_at IS NULL AND player_stat(p.player_id, 'crit_rate') > 0
        ORDER BY 2 DESC
    LOOP
        RAISE NOTICE 'crit rate % : % (worms %, gear %, destiny %)',
            one.discord_name, one.rate, one.worms, one.gear, one.destiny;
    END LOOP;

    SELECT count(*) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL
      AND player_stat(p.player_id, 'crit_rate') >= 0.5999;
    IF v_n = 0 THEN
        RAISE EXCEPTION
            'nobody can reach the crit rate cap any more - that is a cut, not a choice';
    END IF;

    RAISE NOTICE
        '% cultivators still reach the crit rate cap, by spreading rather than by one piece of gear',
        v_n;
END;
$probe$;
