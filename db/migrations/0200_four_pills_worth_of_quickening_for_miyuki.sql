-- 0200_four_pills_worth_of_quickening_for_miyuki
--
-- m_i_y_u_k_i.'s cultivation boost is the last thing left holding the average
-- 0199 removed: 1,130 hours at +101%, which is 978 cheap hours and one grade 7
-- pill blended into a single number. The doses that went into it were not
-- recorded anywhere, so 0199 could not un-mix it - it could only stop the
-- blending from happening again.
--
-- So it is replaced by hand, at the owner's request, with what four of her own
-- grade 7 pills are worth.
--
-- FOUR PILLS OF HERS, NOT FOUR IDEAL ONES. A tier 7 Quickened Cultivation
-- pill is not a fixed size: `brew` sets its hours from the brewer's harmony,
-- and harmony carries the alchemist's skill at 0.75 a level. At her alchemy 57
-- a heaven brew lands near harmony 83, `keep` is 1.02 rather than 1.30, and
-- the pill is 153 hours - which is exactly what the one she swallowed said:
--
--     +153  -  +240% for 153 hours of cultivation, 1131 banked in total.
--
-- Verified by brewing one in a transaction that was thrown away rather than by
-- restating brew's arithmetic here, because the arithmetic is the part I would
-- have got wrong: the obvious guess is 195 hours, and it assumes a harmony
-- she cannot currently reach.
--
--     4 x 153 hours at +240%   =   612 hours
--
-- Granted through `take_pill` on four real pills rather than by writing a row
-- into `player_boosts`, so every rule that applies to swallowing one applies
-- here too - including `pill_potency`, which is 0 for her today and will not
-- be forever.
--
-- Only her cultivation_rate boost is touched. Her Quickened Insight - 310
-- hours at +151% - is left exactly as it is, and so is everybody else's.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    her   BIGINT;
    pill  BIGINT;
    hours NUMERIC := 153;   -- one grade 7 pill at her own harmony
    doses INTEGER := 4;
    was_att RECORD;
    others  INTEGER;
    got   RECORD;
BEGIN
    SELECT p.player_id INTO her FROM players p
    WHERE p.discord_name = 'm_i_y_u_k_i.' AND p.deleted_at IS NULL;

    IF her IS NULL THEN
        RAISE EXCEPTION 'no such cultivator';
    END IF;

    -- Held so the checks below can prove they were not disturbed.
    SELECT b.magnitude, b.hours_left INTO was_att FROM player_boosts b
    WHERE b.player_id = her AND b.kind = 'attainment_rate';

    SELECT count(*) INTO others FROM player_boosts b WHERE b.player_id <> her;

    DELETE FROM player_boosts b
    WHERE b.player_id = her AND b.kind = 'cultivation_rate';

    FOR i IN 1..doses LOOP
        INSERT INTO player_pills (owner_id, name, tier, kind, path_code,
                                  magnitude, quantity, harmony)
        VALUES (her, 'Divine Heavenly Quickening Elixir', 7,
                'cultivation_rate', 'heaven', hours, 1, 150)
        RETURNING pill_id INTO pill;

        PERFORM take_pill(her, pill);
    END LOOP;

    -- ---- what she is left holding -----------------------------------------
    SELECT * INTO got FROM player_boost_standing s
    WHERE s.player_id = her AND s.kind = 'cultivation_rate';

    IF got.magnitude <> (SELECT pt.rate_bonus FROM pill_tiers pt WHERE pt.tier = 7) THEN
        RAISE EXCEPTION 'the new rate is %%% rather than the grade 7 rate',
            round(100 * got.magnitude);
    END IF;

    IF got.hours_left <> hours * doses THEN
        RAISE EXCEPTION 'she holds % hours rather than %',
            got.hours_left, hours * doses;
    END IF;

    IF got.stacks <> 1 THEN
        RAISE EXCEPTION
            'four pills of one rate should be one stack, not %', got.stacks;
    END IF;

    -- No pill was left in her bag by the granting.
    IF EXISTS (SELECT 1 FROM player_pills p
               WHERE p.owner_id = her AND p.quantity > 0
                 AND p.name = 'Divine Heavenly Quickening Elixir'
                 AND p.harmony = 150 AND p.magnitude = hours) THEN
        RAISE EXCEPTION 'a granted pill was not swallowed';
    END IF;

    -- ---- and nothing else moved -------------------------------------------
    IF (SELECT b.magnitude FROM player_boosts b
        WHERE b.player_id = her AND b.kind = 'attainment_rate')
       IS DISTINCT FROM was_att.magnitude THEN
        RAISE EXCEPTION 'her insight boost was disturbed';
    END IF;

    IF (SELECT count(*) FROM player_boosts b WHERE b.player_id <> her)
       <> others THEN
        RAISE EXCEPTION 'somebody else''s boosts were disturbed';
    END IF;

    RAISE NOTICE 'she now holds % hours at %%%',
        got.hours_left, round(100 * got.magnitude);
END;
$$;
