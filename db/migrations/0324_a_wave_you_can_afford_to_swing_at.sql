-- 0324_a_wave_you_can_afford_to_swing_at
--
-- 0320 set `horde_gauntlet_swings` at 2 without checking what two swings
-- cost. Traced against a live cultivator:
--
--     clearwest, bar 128,000, wave one 395,801,242
--     swing 1  dealt 116,106,486  bar 64,000
--     swing 2  dealt 117,269,181  bar 0
--     swing 3  REFUSED - not enough qi, beast still on 162,425,575
--
-- Their two attack techniques cost 0.50 and 0.48 of the bar. Two swings IS
-- the bar, so a wave sized at two swings has exactly zero margin - and
-- `horde_gauntlet_wave_qi` only pays out on a CLEARED wave, so falling one
-- swing short does not stall, it strands. Guard returns 0.20 a round against
-- a 0.50 technique, which is three guarded rounds per swing: not a recovery,
-- a grind, with the wave step compounding the bite through every round of it.
--
-- THE SIZING ITSELF IS SOUND. `horde_walker_burst` is the EXPECTED damage of
-- a turn - `player_blow_multiple` folds in multi-hit and crit as an average,
-- so 188,673,152 is right and the two 116 million rolls above are simply a
-- turn where neither landed. Two swings of expected damage against a wave
-- sized at two swings is a coin flip, and the losing side of that flip is a
-- stranded run rather than a third swing.
--
-- So the dial comes down to 1.2. A wave is a bit over one expected turn, which
-- costs about 0.58 of the worst-priced bar on the roster and leaves room for
-- a turn where nothing crits. The step still compounds at 1.18, so by the
-- fourth or fifth wave a full bar is genuinely two swings and guarding starts
-- to matter - which is the lane working as described rather than failing.
--
-- Wave one for clearwest lands at about 226 million against the 295 it held
-- before 0320. The complaint is still answered by a factor of three quarters
-- of a million; what is removed is only the part that made the lane refuse.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1.2,
    description = 'How many of the walker own EXPECTED turns wave one is '
                  'worth, before the wave step compounds it. Held below what '
                  'a full qi bar buys at the worst technique price on the '
                  'roster, with margin for a turn where nothing crits - a '
                  'wave you cannot finish does not stall a run, it strands '
                  'it, because the qi only comes back on a wave CLEARED.'
WHERE key = 'horde_gauntlet_swings';


-- ---------------------------------------------------------------------------
-- A full bar buys the wave, with room for a bad roll
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad    TEXT;
    swings NUMERIC := game_config_value('horde_gauntlet_swings');
    back   NUMERIC := game_config_value('horde_gauntlet_wave_qi');
    margin NUMERIC := 0.75;
BEGIN
    -- Everyone who could walk the line, priced at the cheapest attack they
    -- own - the one they fall back on when the bar is low. Felling wave one
    -- must cost meaningfully less than the bar clearing it hands back, or
    -- the lane can refuse a swing with the beast still standing.
    SELECT string_agg(t.discord_name || ' (' || t.cheapest || ' x ' || swings
                      || ' = ' || round(t.cheapest * swings, 3) || ')', ', ')
    INTO bad
    FROM (
        SELECT p.discord_name, min(tt.qi_cost_pct) AS cheapest
        FROM players p
        JOIN player_usable_techniques u ON u.player_id = p.player_id
        JOIN techniques tt ON tt.technique_id = u.technique_id
        WHERE p.deleted_at IS NULL AND tt.base_power > 0
        GROUP BY p.player_id, p.discord_name
    ) t
    WHERE t.cheapest * swings > back * margin;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'wave one leaves no margin for these cultivators: % (bar returns %)',
            bad, back;
    END IF;

    RAISE NOTICE
        'wave one costs at most % of a bar that refills to % on a clear',
        (SELECT round(max(t.cheapest) * swings, 3)
         FROM (SELECT min(tt.qi_cost_pct) AS cheapest
               FROM players p
               JOIN player_usable_techniques u ON u.player_id = p.player_id
               JOIN techniques tt ON tt.technique_id = u.technique_id
               WHERE p.deleted_at IS NULL AND tt.base_power > 0
               GROUP BY p.player_id) t),
        back;
END;
$probe$;
