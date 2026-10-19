-- 0325_one_turn_is_the_honest_size_of_a_wave
--
-- 0324 brought `horde_gauntlet_swings` from 2 to 1.2 and traced again:
--
--     wave one 237,480,745
--     swing 1  dealt 116,893,266
--     swing 2  dealt 118,063,840   bar empty, beast on 2,523,639
--
-- One percent of a beast left standing and no qi to reach it. Better than
-- stranding a hundred and sixty million short, and still the worst shape a
-- fight can end in.
--
-- MEASURED RATHER THAN REASONED. Forty real swings against the same beast:
--
--     lowest 121,724,542   mean 185,281,850   highest 418,333,519
--
-- The mean matches `horde_walker_burst`'s 197,900,621 closely enough - the
-- estimator is good. The LOW TAIL is what a wave has to survive being sized
-- against, and it is thirty-five percent under the mean. A wave priced at
-- 1.2 expected turns is 2.03 low turns, and the bar holds exactly two.
--
-- ONLY TWO CULTIVATORS ARE EVEN IN THIS BIND. Priced by their cheapest
-- attack: clearwest 0.48 of a bar and pashu0 0.45 - two swings. Everyone else
-- on the roster runs 0.32 down to 0.05, which is three to twenty. The two
-- people who hit hardest own the techniques that cost half a bar to throw,
-- so they are the only ones who can be one swing short, and they are exactly
-- who this lane was too easy for.
--
-- At 1.0 a wave is one expected turn - about 198 million for clearwest,
-- against the 295 it held before 0320. Two low rolls still clear it with room
-- to spare. The wave step keeps compounding at 1.18, so within a few waves a
-- full bar really is two swings and guarding starts to matter, which is the
-- lane doing what it says rather than refusing.
--
-- GUARDING IS THE DESIGNED ESCAPE, and it is wired: the gauntlet screen marks
-- techniques you cannot afford with 'not enough qi' and carries a Guard
-- button that returns `guard_qi_restore` of the bar. A run that runs dry does
-- not end there - it gets slower while the bite keeps compounding, which is
-- how it is supposed to finish.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1.0,
    description = 'How many of the walker own EXPECTED turns wave one is '
                  'worth, before the wave step compounds it. One, because a '
                  'real turn varies about a third either side of its '
                  'expectation and the dearest techniques on the roster buy '
                  'only two turns a bar - a wave that takes three is a wave '
                  'nobody can finish, and qi only returns on a wave CLEARED.'
WHERE key = 'horde_gauntlet_swings';


-- ---------------------------------------------------------------------------
-- A bad roll still fells wave one, at the worst price on the roster
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad    TEXT;
    swings NUMERIC := game_config_value('horde_gauntlet_swings');
    -- What a turn is worth when nothing crits and nothing multi-hits, as a
    -- fraction of its expectation. Measured, not assumed: 121,724,542 against
    -- a mean of 185,281,850 over forty swings is 0.657, taken at 0.60 so the
    -- rule holds a little past the worst roll actually seen.
    low    NUMERIC := 0.60;
BEGIN
    SELECT string_agg(t.discord_name || ' (' || t.per_bar || ' turns a bar)', ', ')
    INTO bad
    FROM (
        SELECT p.discord_name,
               floor(1.0 / GREATEST(0.0001, min(tt.qi_cost_pct))) AS per_bar
        FROM players p
        JOIN player_usable_techniques u ON u.player_id = p.player_id
        JOIN techniques tt ON tt.technique_id = u.technique_id
        WHERE p.deleted_at IS NULL AND tt.base_power > 0
        GROUP BY p.player_id, p.discord_name
    ) t
    WHERE t.per_bar * low < swings;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a full bar of low rolls does not fell wave one for: %', bad;
    END IF;

    RAISE NOTICE
        'wave one is % expected turns; the tightest bar on the roster buys % even on low rolls',
        swings,
        (SELECT round(min(t.per_bar) * low, 2)
         FROM (SELECT floor(1.0 / GREATEST(0.0001, min(tt.qi_cost_pct))) AS per_bar
               FROM players p
               JOIN player_usable_techniques u ON u.player_id = p.player_id
               JOIN techniques tt ON tt.technique_id = u.technique_id
               WHERE p.deleted_at IS NULL AND tt.base_power > 0
               GROUP BY p.player_id) t);
END;
$probe$;
