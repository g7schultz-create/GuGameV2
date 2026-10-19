-- 0283_everything_starts_from_baby
--
-- 0282 left the twenty beasts hatched before stages existed standing at
-- adult, on the grounds that demoting them was taking back something people
-- had already gone and got. That was the cautious call and it was mine to
-- offer, not to make. It has been made the other way: everything starts from
-- baby.
--
-- The case for it is the better one. Those beasts were hatched inside an hour
-- of hatching existing, from eggs that had been piling up for weeks with
-- nothing to do - so grandfathering them did not protect a long investment,
-- it rewarded being quick on the day. And it left the game with two classes
-- of beast that looked identical and were not, which is exactly the sort of
-- thing nobody remembers in six months.
--
-- Every beast goes to baby with nothing banked. Nothing else about them
-- moves: species, tier, shell, name and which one walks at your heel are all
-- untouched, and the food to raise them again is the ore and bone and pills
-- they were always going to be raised on.
--
-- Forward-only. Do not edit once applied.


UPDATE player_beasts SET stage = 'baby', fed = 0;


DO $$
DECLARE
    grown INTEGER;
    total INTEGER;
    heels INTEGER;
BEGIN
    SELECT count(*) FILTER (WHERE stage <> 'baby'), count(*),
           count(*) FILTER (WHERE at_heel)
    INTO grown, total, heels
    FROM player_beasts;

    IF grown > 0 THEN
        RAISE EXCEPTION '% of % beasts did not go back to baby', grown, total;
    END IF;

    IF EXISTS (SELECT 1 FROM player_beasts WHERE fed <> 0) THEN
        RAISE EXCEPTION 'a beast went back to baby with a full belly';
    END IF;

    -- Everything else about them is theirs and stays theirs. One beast per
    -- owner still walks, and nobody lost the one they had chosen.
    IF heels <> (SELECT count(DISTINCT owner_id) FROM player_beasts) THEN
        RAISE EXCEPTION
            'somebody lost the beast that was walking with them: % at heel across % owners',
            heels, (SELECT count(DISTINCT owner_id) FROM player_beasts);
    END IF;

    RAISE NOTICE 'all % beasts start from baby, % still at heel', total, heels;
END;
$$;
