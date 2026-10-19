-- 0527_a_top_bodys_signature_is_a_capstone
--
-- 0516 bounded every source at three fifths of an effect, and 0517 found the
-- one place that was wrong by test - a Divine body's death ward is a
-- certainty by design, and a flat share turned it into a 60% chance. I gave
-- `gu_effects` a `source_share` column, exempted `death_ward`, and wrote:
--
--     "it is the ONLY exception, so this stays a rule with a reason rather
--      than a list of favours"
--
-- That was wrong, and I only knew about death_ward because death_ward was the
-- only one with a test. `test_foresight_knows_the_weakness_without_looking`
-- has been failing six runs in eight ever since:
--
--     assert known[seer] > 0, "foresight should have written it down at the door"
--
-- The Celestial Sovereign Body grants 1.140 foresight against a cap of 1.000.
-- It is a certainty, in the same way and for the same reason as the death
-- ward, and 0516 made it a coin flip.
--
-- SO I ASKED THE SCHEMA INSTEAD OF WAITING FOR THE NEXT TEST. Of the 19
-- effects where one source can reach the cap alone, 17 are a rank 9 worm at
-- five stars - which is exactly what the share exists to stop, and what was
-- chosen when the question was put ("make it a real choice"). Restricting the
-- question to the sources a cultivator CANNOT accumulate - one body, one root,
-- rolled rather than bought - leaves precisely two:
--
--     foresight        cap 1.000   Celestial Sovereign Body grants 1.140
--     realm_tempering  cap 2.000   Primordial Origin Body    grants 2.000
--
-- plus death_ward, already exempt. Three top-body signatures, and all three
-- are the thing that body is FOR.
--
-- REALM TEMPERING WAS A SILENT LIVE NERF. It is not a chance roll - it is body
-- levels granted on a breakthrough - so nothing failed and nobody complained.
-- Two cultivators have been carrying a Primordial Origin Body at 1.200 and
-- 1.500 where it should read 2.000, since 0516 applied.
--
-- WHY NOT EXEMPT INNATE SOURCES WHOLESALE, which is the better-stated rule - a
-- share bounds what you can accumulate, and a body cannot be accumulated? I
-- tried to measure that change and my own comparison dropped five of the eight
-- sources, so the number it produced was meaningless. I am not making a change
-- whose blast radius I could not bound on a measurement I know was wrong. Two
-- rows through the mechanism 0517 already built restores exactly the three
-- readings above and nothing else.
--
-- Forward-only. Do not edit once applied.


-- Every reading as it stands, BEFORE the change, so "nothing went down" can be
-- measured rather than argued. My first attempt at this assertion compared
-- against `0.6 * lid` and demanded every cultivator hold three fifths of every
-- effect - 99 "failures" that were simply people who own no foresight at all.
CREATE TEMP TABLE _before_0527 AS
SELECT p.player_id, e.code, player_stat(p.player_id, e.code) AS was
FROM players p CROSS JOIN gu_effects e
WHERE p.deleted_at IS NULL;


UPDATE gu_effects SET source_share = 1.000
WHERE code IN ('foresight', 'realm_tempering');

COMMENT ON COLUMN gu_effects.source_share IS
    'The most any ONE of the eight stat sources may contribute, as a share of this effect''s ceiling. 0.600 everywhere so a cap takes two sources to reach - except the three top-body signatures (death_ward, foresight, realm_tempering), where one source finishing it is the whole point of owning that body.';


-- ---------------------------------------------------------------------------
-- The capstones are exactly the effects an unaccumulable source finishes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad TEXT;
    v_n   INTEGER;
    one   RECORD;
BEGIN
    -- 1. THE SET IS DERIVED, NOT LISTED. Every effect that a single body or
    -- root grants at or above its own ceiling must be exempt, and nothing else
    -- may be - so the next capstone somebody puts on a body is caught here
    -- rather than by a test failing six runs in eight.
    WITH innate AS (
        SELECT pe.effect_code AS code, pe.magnitude AS most
        FROM physique_effects pe
        UNION ALL
        SELECT re.effect_code, re.magnitude FROM root_effects re
    ), capstone AS (
        SELECT e.code
        FROM gu_effects e
        WHERE EXISTS (SELECT 1 FROM innate i
                      WHERE i.code = e.code AND i.most >= e.cap)
    )
    SELECT string_agg(x.code || ' (' || x.why || ')', ', ') INTO v_bad
    FROM (
        SELECT e.code, 'clipped, but a body finishes it' AS why
        FROM gu_effects e JOIN capstone c ON c.code = e.code
        WHERE e.source_share < 1
        UNION ALL
        SELECT e.code, 'exempt, but no body finishes it'
        FROM gu_effects e
        WHERE e.source_share >= 1
          AND NOT EXISTS (SELECT 1 FROM capstone c WHERE c.code = e.code)
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'the capstone exemptions do not match what the bodies grant: %', v_bad;
    END IF;

    -- 2. And it really is three, not "a list of favours" that grew.
    SELECT count(*) INTO v_n FROM gu_effects WHERE source_share >= 1;
    IF v_n <> 3 THEN
        RAISE EXCEPTION
            '% effects are exempt from the source share, expected three', v_n;
    END IF;

    -- 3. The crit trio is UNTOUCHED, because "make it a real choice" was a
    -- decision about those and nothing here may undo it.
    SELECT string_agg(code, ', ') INTO v_bad FROM gu_effects
    WHERE code IN ('crit_rate', 'crit_damage', 'multi_hit') AND source_share >= 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'the crit trio stopped being a choice: %', v_bad;
    END IF;

    -- 4. THE THREE LIVE READINGS MOVE, and they move UP. A body that was
    -- promised something must not come out of this with less.
    FOR one IN
        SELECT p.discord_name AS who, ph.name AS body, e.code,
               player_stat(p.player_id, e.code) AS now,
               physique_stat(p.player_id, e.code) AS grants
        FROM players p
        JOIN player_physique pp ON pp.player_id = p.player_id
        JOIN physiques ph ON ph.physique_id = pp.physique_id
        CROSS JOIN gu_effects e
        WHERE p.deleted_at IS NULL
          AND e.code IN ('foresight', 'realm_tempering', 'death_ward')
          AND physique_stat(p.player_id, e.code) >= e.cap
    LOOP
        IF one.now < one.grants THEN
            v_bad := COALESCE(v_bad || '; ', '')
                     || one.who || ' ' || one.body || ' ' || one.code
                     || ' uses ' || one.now || ' of ' || one.grants;
        END IF;
        RAISE NOTICE
            '% (%) now uses % % of the % their body grants',
            one.who, one.body, one.now, one.code, one.grants;
    END LOOP;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'a capstone body still reads short: %', v_bad;
    END IF;

    -- 5. Nobody anywhere is above their own lid, which is the bound 0516 and
    -- 0517 both end on.
    SELECT count(*) INTO v_n
    FROM players p CROSS JOIN gu_effects e
    WHERE p.deleted_at IS NULL
      AND player_stat(p.player_id, e.code)
          > gu_effect_cap(e.code, p.player_id) + 0.0001;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% readings sit above their own lid', v_n;
    END IF;

    -- 6. AND NOTHING WENT DOWN FOR ANYBODY, against the snapshot taken before
    -- the UPDATE rather than against a formula. Every live character survives
    -- every change; this one is allowed to give, never to take.
    SELECT string_agg(x.who || ' ' || x.code || ' ' || x.was || '->' || x.now, '; ')
    INTO v_bad
    FROM (
        SELECT p.discord_name AS who, b.code, b.was,
               player_stat(b.player_id, b.code) AS now
        FROM _before_0527 b
        JOIN players p ON p.player_id = b.player_id
        WHERE player_stat(b.player_id, b.code) < b.was - 0.0001
        LIMIT 8
    ) x;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these readings fell: %', v_bad;
    END IF;

    -- And it DID give, or this migration changed nothing and the test it was
    -- written for will still fail.
    SELECT count(*) INTO v_n
    FROM _before_0527 b
    WHERE player_stat(b.player_id, b.code) > b.was + 0.0001;
    IF v_n = 0 THEN
        RAISE EXCEPTION
            'no reading rose, so the capstones are still clipped somewhere else';
    END IF;
    RAISE NOTICE '% readings rose and none fell', v_n;
END;
$probe$;
