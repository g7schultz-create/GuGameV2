-- 0239_more_greenery_off_a_battlefield
--
-- Herbs double again in the three ladder chests, 6 to 12. The King's chest is
-- untouched: this is about the reward somebody gets for turning up and holding
-- a line for an afternoon, not about the finale.
--
-- THIS CROSSES A LINE 0238 DREW and the line was mine rather than the game's.
-- 0238 refused to let herbs meet beast parts, on the reasoning that a horde
-- paying more plants than beasts would be 0234 undone. What 0234 actually
-- established is that the horde is A WAY TO GET BEAST MATERIALS - which it
-- still very much is, at 100 x rank of them across a full opening. It never
-- said beasts had to outnumber everything else in the chest, and a two hour
-- battlefield in a region full of plants handing over a decent pile of them is
-- not a contradiction of anything.
--
-- What is worth guarding is the thing that was actually broken before 0234:
-- beast materials being a rounding error. So the invariant becomes a share
-- rather than a comparison - the parts have to be a real part of the haul, and
-- nothing stops the greenery growing beside them.
--
-- Ladder totals per rank, for the record: 60 in parts against 72 in herbs.
-- Across a full four chest opening with the King, 100 against 102.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 12,
    description = 'The herb pile in a ladder chest, times the chest number and '
                  'the rank. A battlefield in a region full of plants is worth '
                  'walking; gathering is still where a targeted haul comes from.'
WHERE key = 'horde_chest_herbs';


DO $$
DECLARE
    parts NUMERIC;
    herbs NUMERIC;
    share NUMERIC;
BEGIN
    -- A full opening, counting every chest, at any rank - the ratios do not
    -- depend on the rank because every pile scales by it.
    parts := game_config_value('horde_chest_beast_parts') * 6
             + game_config_value('horde_king_chest_beast_parts');
    herbs := game_config_value('horde_chest_herbs') * 6
             + game_config_value('horde_king_chest_herbs');

    share := parts / (parts + herbs);

    -- Not "parts beat herbs" - that was a line drawn by hand and this
    -- migration is deliberately stepping over it. The rule is that beast
    -- materials cannot become the rounding error they were before 0234.
    IF share < 0.35 THEN
        RAISE EXCEPTION
            'beast materials are only % of the haul; the horde is a herb faucet again',
            round(100 * share) || '%';
    END IF;

    -- And the spill is still a roll rather than a printed list.
    IF position('sqrt(d.chance)' IN
                (SELECT pg_get_functiondef(oid) FROM pg_proc
                 WHERE proname = 'horde_spill_parts')) = 0 THEN
        RAISE EXCEPTION 'the pick is no longer weighted so uncommons surface';
    END IF;

    RAISE NOTICE 'beast materials are % of a full opening', round(100 * share) || '%';
END;
$$;
