-- 0557_the_qi_line_keeps_the_rules_it_found
--
-- 0555 broke two standing rules on its way to a good idea. The suite caught
-- both, which is the whole reason they are tests rather than comments.
--
-- 1. I LIFTED A CEILING THAT WAS DELIBERATELY FLAT.
--
--    0555 gave `max_qi` a `cap_per_rank` of 0.08, reasoning that a flat lid
--    meant one rank 8 worm filled the Gu lane and the apex had nothing left to
--    sell - the same convergence 0492 fixed for critical damage and extra
--    strikes. `test_only_the_two_flattening_effects_scale` disagreed, and it
--    is right to:
--
--        'The point was never to lift every ceiling in the game - it was that
--         these two make the Gu ladder converge.'
--
--    That is a design boundary somebody drew on purpose, and widening the qi
--    pool for every cultivator in the game is not what was asked for. It was
--    asked that Gu let a cultivator cast more before bracing.
--
--    AND THE WORMS DO NOT NEED IT. Measured against a rank 18 aperture and a
--    move costing 40% of it, with the Gu lane clamped at its unchanged 0.600:
--
--        no qi worm                 2 casts
--        Divine Qi Sea Gu  (r8)     3 casts
--        Dao Qi Sea Gu     (r9)     4 casts
--
--    Two to four, on the flat lid, because 1.600 / 0.400 is exactly four. The
--    cap change bought a fourth cast that the apex worm already buys. So the
--    lid goes back to flat and the feature stands on the worms, which is where
--    it was supposed to stand.
--
--    If the qi ceiling should rise with realm, that is a separate decision
--    about every cultivator's pool, worth taking on its own evidence rather
--    than smuggled in behind nine worms.
--
-- 2. A RANK 4 OR 5 WORM MAY NOT LEND ONLY ONE THING.
--
--    0211's rule, and `test_a_rank_four_gu_pays_for_its_slot` holds it:
--
--        'A rank 4 Gu costs four of an aperture that holds six or seven. One
--         capped number is right for a rank 1 worm and thin at that price.'
--
--    Every one of the nine carried `max_qi` alone, so the rank 4 and rank 5
--    worms were exactly the thin thing 0211 forbade. They gain a second word,
--    and so do the ranks above them - at rank 9 a worm costs nine points of a
--    sixty point aperture, and one number for that price is thin wherever the
--    test happens to look.
--
--    The second word is `guard_qi`, which is the same sentence from the other
--    end: more qi to spend, and more of it back when you brace. It is also the
--    other half of what was asked - casting more before guarding is a question
--    about both sides of the exchange. Ranks 1 to 3 keep saying one thing,
--    which 0211 is explicit about wanting.
--
--    `guard_qi` stops at rank 8 exactly as `max_qi` did, so the apex gets the
--    continued curve: 0.0363 per point of aperture at rank 8 becomes 0.0375.


-- ---------------------------------------------------------------------------
-- 1. The lid goes back where it was
-- ---------------------------------------------------------------------------

UPDATE gu_effects
SET cap_per_rank = 0,
    description = 'How much the battle qi pool is widened, as a fraction of the realm''s own capacity. The lid is FLAT on purpose - 0492 raised it only for critical damage and extra strikes, the two effects where Gu volume caught Gu tier, and 0555 lifted this one too before 0557 put it back. The apex qi worm takes a cultivator from two casts to four without it.'
WHERE code = 'max_qi';


-- ---------------------------------------------------------------------------
-- 2. A second word, from rank 4 up
-- ---------------------------------------------------------------------------

INSERT INTO gu_type_effects (gu_type_id, effect_code, magnitude)
SELECT t.gu_type_id, 'guard_qi', v.magnitude
FROM (VALUES
        (4, 0.1084), (5, 0.1460), (6, 0.1884),
        (7, 0.2359), (8, 0.2904), (9, 0.3375)
     ) AS v(rank, magnitude)
JOIN gu_types t ON t.rank = v.rank AND t.code LIKE '%qi_sea_gu';


-- ---------------------------------------------------------------------------
-- The probes
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_rk   RECORD;
    v_prev NUMERIC := 0;
BEGIN
    -- 1. ONLY THE TWO FLATTENING EFFECTS SCALE, which is the rule 0555 broke.
    IF (SELECT string_agg(code, ', ' ORDER BY code)
        FROM gu_effects WHERE cap_per_rank > 0) <> 'crit_damage, multi_hit' THEN
        RAISE EXCEPTION
            'these effects still scale with realm: % - 0492 lifted two lids and '
            'meant two',
            (SELECT string_agg(code, ', ' ORDER BY code)
             FROM gu_effects WHERE cap_per_rank > 0);
    END IF;

    -- 2. NO RANK 4 OR 5 WORM LENDS ONE THING, anywhere in the roster.
    SELECT count(*) INTO v_n
    FROM gu_types t
    JOIN (SELECT gu_type_id, count(*) n FROM gu_type_effects GROUP BY 1) e
      USING (gu_type_id)
    WHERE t.rank IN (4, 5) AND e.n = 1;
    IF v_n <> 0 THEN
        RAISE EXCEPTION '% rank 4 or 5 Gu still lend one thing', v_n;
    END IF;

    -- 3. AND RANKS 1 TO 3 STILL DO, which 0211 wanted on purpose.
    SELECT count(*) INTO v_n
    FROM gu_types t
    JOIN (SELECT gu_type_id, count(*) n FROM gu_type_effects GROUP BY 1) e
      USING (gu_type_id)
    WHERE t.rank <= 3 AND e.n = 1;
    IF v_n = 0 THEN
        RAISE EXCEPTION
            'no low-rank Gu says a single thing any more - a beginner''s worm '
            'was supposed to be readable at a glance';
    END IF;

    -- 4. THE GUARD CURVE CLIMBS TOO. Same invariant 0514 put on every other
    --    effect: value per point of aperture rises with rank.
    FOR v_rk IN
        SELECT t.rank, e.magnitude / t.rank AS per_point
        FROM gu_types t JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
        WHERE t.code LIKE '%qi_sea_gu' AND e.effect_code = 'guard_qi'
        ORDER BY t.rank
    LOOP
        IF v_rk.per_point <= v_prev THEN
            RAISE EXCEPTION
                'the guard curve stalls at rank %', v_rk.rank;
        END IF;
        v_prev := v_rk.per_point;
    END LOOP;

    -- 5. AND THE APEX WORM STILL BUYS THE FOURTH CAST without the raised lid.
    --    This is the claim the whole reversal rests on, so it is measured
    --    rather than asserted: the Gu lane clamp is `cap * source_share`.
    DECLARE
        v_lane NUMERIC;
        v_ap   BIGINT;
        v_was  INTEGER;
        v_now  INTEGER;
    BEGIN
        SELECT LEAST(e.magnitude, g.cap * g.source_share) INTO v_lane
        FROM gu_types t
        JOIN gu_type_effects e ON e.gu_type_id = t.gu_type_id
        JOIN gu_effects g ON g.code = e.effect_code
        WHERE t.code = 'dao_qi_sea_gu' AND e.effect_code = 'max_qi';

        SELECT player_qi_aperture(p.player_id) INTO v_ap
        FROM players p WHERE p.deleted_at IS NULL AND p.discord_id > 0
        ORDER BY player_standing(p.player_id) DESC LIMIT 1;

        IF v_ap IS NOT NULL THEN
            v_was := floor(v_ap / ceil(0.40 * v_ap));
            v_now := floor(v_ap * (1 + v_lane) / ceil(0.40 * v_ap));
            RAISE NOTICE
                'the apex qi worm: % casts becomes % (lane clamped to %)',
                v_was, v_now, round(v_lane, 3);
            IF v_now <= v_was THEN
                RAISE EXCEPTION
                    'the apex qi worm buys no extra cast on the flat lid, so '
                    'reverting it was wrong';
            END IF;
        END IF;
    END;
END
$probe$;
