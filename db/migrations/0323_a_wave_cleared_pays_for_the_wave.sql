-- 0323_a_wave_cleared_pays_for_the_wave
--
-- 0320 made a gauntlet wave worth two of the walker's turns instead of a
-- fiftieth of one. That is the fix that was wanted, and it moved the lane's
-- limiter onto a dial that cannot pay for it.
--
-- Driving a real run: clearwest cleared two swings and then
--
--     ERROR: not enough qi for Sovereign Immortal Killer Move
--
-- Their two attack techniques cost 0.50 and 0.48 of the qi pool. Two swings
-- IS the pool. Clearing a wave hands back `horde_gauntlet_wave_qi` = 0.25 of
-- it. So a wave costs a hundred percent and repays twenty-five, and the run
-- dead-ends on wave two however much health is left in the body walking it.
--
-- The old lane hid this because a wave died to one blow - and even then the
-- arithmetic only stretched to five or six waves before the bar was empty.
-- The dial was always short; sizing waves honestly is just what exposed it.
--
-- `horde_gauntlet_wave_qi` says in its own description what it is for:
--
--     'Clearing is meant to be a breather, not a slow bleed toward a
--      stalemate nobody can break.'
--
-- It has never done that. Clearing a wave now fills the bar. The run then
-- ends where the lane always said it ends - on the 1.18 step, when the
-- compounding bite finally outpaces what the walker can heal through - and
-- not on a resource that quietly counts down behind it.
--
-- THIS IS NOT A GIFT TO THE STRONG. A wave is sized at two of YOUR OWN turns
-- and bites a share of YOUR OWN body, so a full bar buys everybody the same
-- two swings against the same relative wall. What it removes is an accidental
-- second limiter that fell hardest on exactly the cultivators whose
-- techniques cost the most - which is to say on the people the depth was
-- meant to be for.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1.00,
    description = 'Fraction of the qi pool handed back for felling a wave. '
                  'A full bar: a wave is sized at two of the walker own '
                  'turns, so anything less makes the dearest techniques in '
                  'the game dead-end a run inside two waves. Clearing is a '
                  'breather - the run is meant to end on the wave step, not '
                  'on an empty bar.'
WHERE key = 'horde_gauntlet_wave_qi';


-- ---------------------------------------------------------------------------
-- Nobody can be stranded mid-run with a full clear behind them
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad     TEXT;
    swings  NUMERIC := game_config_value('horde_gauntlet_swings');
    back    NUMERIC := game_config_value('horde_gauntlet_wave_qi');
BEGIN
    -- For everyone who could actually walk the line: having just cleared a
    -- wave, can they afford the swings the next one is sized to want? The
    -- cheapest usable technique is the fair test - it is the one you fall
    -- back on when the bar is low.
    SELECT string_agg(t.discord_name || ' (cheapest ' || t.cheapest
                      || ' x ' || swings || ' > ' || back || ')', ', ')
    INTO bad
    FROM (
        SELECT p.discord_name, min(tt.qi_cost_pct) AS cheapest
        FROM players p
        JOIN player_usable_techniques u ON u.player_id = p.player_id
        JOIN techniques tt ON tt.technique_id = u.technique_id
        WHERE p.deleted_at IS NULL AND tt.base_power > 0
        GROUP BY p.player_id, p.discord_name
    ) t
    WHERE t.cheapest * swings > back;

    IF bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these cultivators would strand on an empty bar mid-run: %', bad;
    END IF;

    RAISE NOTICE
        'a wave wants % swings and clearing one returns % of the bar - nobody strands',
        swings, back;
END;
$probe$;
