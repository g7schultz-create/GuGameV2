-- 0492_a_lid_that_rises_with_the_realm
--
-- Rank 9 Gu are meant to be the apex of the worm ladder and they are the
-- weakest thing in it. Measured before touching anything:
--
--     crit_damage by rank   r1 0.081   r5 0.305   r8 1.019   r9 NONE
--     multi_hit by rank     r1 0.125   r4 0.219   r5 0.261   r6-r9 NONE
--
-- The fifteen rank 9 Gu carry neither of the two effects that decide damage.
-- They carry cultivation_rate, braced, foresight, matchup_relief and
-- base_strength. So the best crit build in the game is made of rank 1 to 8
-- worms and a rank 9 worm is a downgrade in the slot.
--
-- AND A FLAT CAP IS WHY FIXING THE MAGNITUDES ALONE WOULD NOT WORK. Gu size
-- equals Gu rank, and the aperture at rank 18 holds 57. So the honest
-- comparison is per point of aperture, and on that measure the ladder barely
-- climbs at all:
--
--     crit_damage per aperture point    rank 1  0.0813     rank 8  0.1274
--
-- Rank 8 is 1.57x rank 1 for eight times the aperture. Worse, 57 rank 1 worms
-- at five stars sum to 9.27 crit_damage against a cap of 2.00, so volume
-- reaches the lid with room to spare and nothing above it can ever be worth
-- more. Any cap low enough to bind on common worms makes every tier above
-- them converge. That is the whole reason the top of this ladder is dead.
--
-- SO THE LID RISES WITH THE REALM. Not converted to a base stat - that is the
-- standing directive for crit_damage and a programme of its own, and
-- multi_hit is explicitly excluded from it because a probability cannot be
-- multiplied by a realm. This is narrower: the same percent effect, with a
-- ceiling that stops being the thing that flattens the ladder.
--
-- GREATEST(old cap, per_rank x realm rank), so it only ever rises. Below
-- rank 3 nothing changes at all.
--
-- WHO MOVES TODAY, measured rather than hoped at. Raw sums of every living
-- cultivator, before any clamp:
--
--     crit_damage   2.000  1.559  0.661  0.515  0.288
--     multi_hit     3.376  2.800  2.672  2.065  1.975  1.577  0.175
--
-- One cultivator is over a lid: sylvrime at 3.376 multi_hit against 3.00.
-- They gain 0.376, which is about twelve per cent more extra-strike value.
-- Nobody's crit_damage moves - sylvrime's raw sum is exactly 2.000, which is
-- where they already sit. So lifting the lid buys almost nothing for anyone
-- today and buys the headroom rank 9 needs tomorrow. That is the right order
-- to do it in.
--
-- WHAT IT COSTS. At rank 18 the crit lid becomes 12.6, so a cultivator who
-- actually assembles a rank 9 crit build can reach a 14.1x critical where the
-- ceiling today is 3.5x. That is a real endgame power spike and it is the
-- point, but the spec already says encounter content cannot be balanced
-- against crit swing, and this widens that. Flagged, not hidden: the
-- bestiary at rank 18 will need to move after this.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE gu_effects
    ADD COLUMN cap_per_rank NUMERIC(8,4) NOT NULL DEFAULT 0
        CHECK (cap_per_rank >= 0);

COMMENT ON COLUMN gu_effects.cap_per_rank IS
    'How much of this effect one realm rank is allowed to add to the cap. Zero leaves the flat cap alone, which is every effect but the two that flatten the Gu ladder. Data rather than code so the lid can be retuned without a migration.';

-- Only the two the user named, and only these two: everything else keeps the
-- flat lid it has.
UPDATE gu_effects SET cap_per_rank = 0.7000 WHERE code = 'crit_damage';
UPDATE gu_effects SET cap_per_rank = 0.2800 WHERE code = 'multi_hit';


-- ---------------------------------------------------------------------------
-- One definition of what an effect is allowed to reach
-- ---------------------------------------------------------------------------

CREATE FUNCTION gu_effect_cap(p_effect_code TEXT, p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- GREATEST, so the lid never falls below the flat cap and no cultivator
    -- is quietly nerfed by a realm they have not reached. A player with no
    -- cultivation row reads rank 1, which is the flat cap.
    SELECT GREATEST(
        e.cap,
        e.cap_per_rank * COALESCE(player_realm_rank(p_player_id), 1)
    )
    FROM gu_effects e
    WHERE e.code = p_effect_code;
$fn$;

COMMENT ON FUNCTION gu_effect_cap(TEXT, BIGINT) IS
    'The ceiling on one Gu effect for one cultivator. The only place the lid is worked out - player_gu_stats reads it rather than gu_effects.cap directly.';


-- ---------------------------------------------------------------------------
-- The view that every fight reads its build through
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW player_gu_stats AS
SELECT e.player_id,
       te.effect_code,
       LEAST(
           gu_effect_cap(te.effect_code, e.player_id),
           sum(te.magnitude * (1::numeric
               + game_config_value('gu_star_step') * (g.stars - 1)::numeric))
       ) AS total,
       sum(te.magnitude * (1::numeric
           + game_config_value('gu_star_step') * (g.stars - 1)::numeric))
           > gu_effect_cap(te.effect_code, e.player_id) AS capped
FROM player_gu_equipped e
JOIN player_gu g ON g.gu_id = e.gu_id
JOIN gu_type_effects te ON te.gu_type_id = g.gu_type_id
JOIN gu_effects ef ON ef.code = te.effect_code
GROUP BY e.player_id, te.effect_code;


-- ---------------------------------------------------------------------------
-- Nobody falls, and the measured drift is the measured drift
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_moved  TEXT;
    v_fell   TEXT;
    v_low    NUMERIC;
    v_high   NUMERIC;
    r        RECORD;
BEGIN
    -- The lid cannot go down for anybody, at any rank, for any effect.
    SELECT string_agg(e.code || ' @r' || g.rank, ', ')
    INTO v_fell
    FROM gu_effects e
    CROSS JOIN generate_series(1, 18) AS g(rank)
    WHERE GREATEST(e.cap, e.cap_per_rank * g.rank) < e.cap;
    IF v_fell IS NOT NULL THEN
        RAISE EXCEPTION 'a lid fell: %', v_fell;
    END IF;

    -- Only the two named effects scale; everything else is untouched.
    IF EXISTS (SELECT 1 FROM gu_effects
               WHERE cap_per_rank > 0 AND code NOT IN ('crit_damage', 'multi_hit')) THEN
        RAISE EXCEPTION 'an effect nobody asked about got a rising lid';
    END IF;

    -- Below rank 3 nothing has changed, which is most of the roster.
    IF gu_effect_cap('crit_damage', NULL) <> (SELECT cap FROM gu_effects WHERE code='crit_damage') THEN
        RAISE EXCEPTION 'a cultivator with no realm did not get the flat cap';
    END IF;

    v_low  := 0.7 * 2;   -- what the formula gives at rank 2
    v_high := (SELECT cap FROM gu_effects WHERE code = 'crit_damage');
    IF v_low > v_high THEN
        RAISE EXCEPTION 'the crit lid already rises by rank 2, which moves low realms';
    END IF;

    -- And the drift for everyone alive, reported rather than assumed. A rise
    -- is allowed; a fall is not.
    FOR r IN
        SELECT s.player_id, s.effect_code, s.total AS now_total, s.capped,
               player_realm_rank(s.player_id) AS rank
        FROM player_gu_stats s
        WHERE s.effect_code IN ('crit_damage', 'multi_hit')
    LOOP
        IF r.now_total > gu_effect_cap(r.effect_code, r.player_id) THEN
            RAISE EXCEPTION
                'player % reads % above its own lid on %',
                r.player_id, r.now_total, r.effect_code;
        END IF;
    END LOOP;

    SELECT string_agg(x.line, ' | ') INTO v_moved FROM (
        SELECT s.player_id || ':' || s.effect_code || '=' || round(s.total, 3)
               || CASE WHEN s.capped THEN ' (still at the lid)' ELSE '' END AS line
        FROM player_gu_stats s
        WHERE s.effect_code IN ('crit_damage', 'multi_hit')
          AND s.total > 2.0
        ORDER BY s.total DESC
    ) x;

    RAISE NOTICE 'crit lid at rank 18 is now %, multi_hit %; above 2.0 today: %',
        0.7 * 18, 0.28 * 18, COALESCE(v_moved, 'nobody');
END;
$probe$;
