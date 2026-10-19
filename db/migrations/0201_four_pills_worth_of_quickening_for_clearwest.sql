-- 0201_four_pills_worth_of_quickening_for_clearwest
--
-- 0200 for the other cultivator. clearwest is holding 305 hours at +50.64%,
-- another average that 0199 could stop making but could not un-mix, and it is
-- replaced with what four of HIS grade 7 pills are worth.
--
-- His are not miyuki's. The same grade 7 Quickened Cultivation pill is a
-- different size in a different cauldron, because `brew` takes its hours from
-- the brewer's harmony and harmony carries alchemy skill at 0.75 a level:
--
--     m_i_y_u_k_i.   alchemy  57   harmony  83   keep 1.02   153 hours
--     clearwest      alchemy 200   harmony 150   keep 1.30   203 hours
--
-- He also carries +4% brew potency off his gear, which the other does not, so
-- 50 x 3 x 1.30 x 1.04 lands on 203 rather than 195. Measured by brewing one
-- against his real stock in a transaction that was thrown away, not computed
-- here - the same way 0200 found 153 after I had assumed 195.
--
--     4 x 203 hours at +240%   =   812 hours
--
-- Granted through `take_pill` on four real pills, so nothing about swallowing
-- one is bypassed. Only his cultivation_rate boost is touched; his Quickened
-- Insight - 2,993 hours at +25% - is left alone, and so is everybody else's.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    him   BIGINT;
    pill  BIGINT;
    hours NUMERIC := 203;   -- one grade 7 pill at his own harmony
    doses INTEGER := 4;
    was_att RECORD;
    others  INTEGER;
    got   RECORD;
BEGIN
    SELECT p.player_id INTO him FROM players p
    WHERE p.discord_name = 'clearwest' AND p.deleted_at IS NULL;

    IF him IS NULL THEN
        RAISE EXCEPTION 'no such cultivator';
    END IF;

    SELECT b.magnitude, b.hours_left INTO was_att FROM player_boosts b
    WHERE b.player_id = him AND b.kind = 'attainment_rate';

    SELECT count(*) INTO others FROM player_boosts b WHERE b.player_id <> him;

    DELETE FROM player_boosts b
    WHERE b.player_id = him AND b.kind = 'cultivation_rate';

    FOR i IN 1..doses LOOP
        INSERT INTO player_pills (owner_id, name, tier, kind, path_code,
                                  magnitude, quantity, harmony)
        VALUES (him, 'Divine Heavenly Quickening Elixir', 7,
                'cultivation_rate', 'heaven', hours, 1, 150)
        RETURNING pill_id INTO pill;

        PERFORM take_pill(him, pill);
    END LOOP;

    SELECT * INTO got FROM player_boost_standing s
    WHERE s.player_id = him AND s.kind = 'cultivation_rate';

    IF got.magnitude <> (SELECT pt.rate_bonus FROM pill_tiers pt WHERE pt.tier = 7) THEN
        RAISE EXCEPTION 'the new rate is %%% rather than the grade 7 rate',
            round(100 * got.magnitude);
    END IF;

    IF got.hours_left <> hours * doses THEN
        RAISE EXCEPTION 'he holds % hours rather than %',
            got.hours_left, hours * doses;
    END IF;

    IF got.stacks <> 1 THEN
        RAISE EXCEPTION
            'four pills of one rate should be one stack, not %', got.stacks;
    END IF;

    IF EXISTS (SELECT 1 FROM player_pills p
               WHERE p.owner_id = him AND p.quantity > 0
                 AND p.name = 'Divine Heavenly Quickening Elixir'
                 AND p.harmony = 150 AND p.magnitude = hours) THEN
        RAISE EXCEPTION 'a granted pill was not swallowed';
    END IF;

    -- His is the bigger pill, and that must survive the change: a migration
    -- that quietly handed both cultivators the same 153 would have erased the
    -- entire point of his alchemy 200.
    IF hours <= 153 THEN
        RAISE EXCEPTION
            'his pill is % hours, no better than a novice brew', hours;
    END IF;

    IF (SELECT b.magnitude FROM player_boosts b
        WHERE b.player_id = him AND b.kind = 'attainment_rate')
       IS DISTINCT FROM was_att.magnitude THEN
        RAISE EXCEPTION 'his insight boost was disturbed';
    END IF;

    IF (SELECT count(*) FROM player_boosts b WHERE b.player_id <> him)
       <> others THEN
        RAISE EXCEPTION 'somebody else''s boosts were disturbed';
    END IF;

    RAISE NOTICE 'he now holds % hours at %%%',
        got.hours_left, round(100 * got.magnitude);
END;
$$;
