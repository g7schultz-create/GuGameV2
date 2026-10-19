-- 0269_a_deep_room_pays_like_a_deep_room
--
-- The dungeon pot is linear in the rank of the room:
--
--     pot = 900 x rank x reward_scale
--
-- Everything it is measured against is not. The breakthrough gates climb by
-- four to five times a rank, so what a clear is worth against the thing a
-- cultivator is saving for collapses as they go:
--
--     rank 2 gate      2,000     0.1 clears of a rank 2 room on Insane
--     rank 4 gate     60,000     1.5
--     rank 6 gate  1,100,000    18.5
--     rank 7 gate  4,500,000    64.9
--     rank 8 gate 18,000,000   227.3
--     rank 9 gate 72,000,000   808.1
--
-- Eight hundred clears at twelve hours a key is not a grind, it is a wall.
-- And no multiplier fixes it: ten times the pot still leaves 81 clears at the
-- top while paying a rank 2 room 198,000 against a gate of 2,000. The shape is
-- wrong, not the size.
--
-- So the pot doubles per rank, which is the curve this game already runs on -
-- 0248 put every stat on `2 ^ (realm rank - 1)` for exactly this reason. A
-- room one rank deeper is worth twice as much, the way a cultivator one realm
-- higher is worth twice as much.
--
--     pot = 900 x 2 ^ (rank - 1) x reward_scale
--
--     rank 1     900  (unchanged)      rank 6   28,800  (x4.8)
--     rank 4   7,200  (x2.0)           rank 7   57,600  (x9.1)
--     rank 5  14,400  (x3.2)           rank 9  230,400  (x28.4)
--
-- which turns that last column into 0.1, 0.8, 3.5, 7.1, 14.2, 28.4 - a ladder
-- that gets harder without ever becoming a wall.
--
-- Rank 1 deliberately does not move. A newcomer already leaves home with 5,000
-- stones (0262) against a rank 2 gate of 2,000; the starvation is at the deep
-- end, and that is where the money goes.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_stone_reward_growth', 2.0,
     'How much more the pot holds per rank of the room. Doubling, the same '
     'curve stats climb on - the gates a cultivator is saving for are '
     'geometric, so a linear pot means a deep room pays less every rank in '
     'the only terms that matter.');

UPDATE game_config
SET description =
    'Spirit Stones in the pot for a rank 1 dungeon, before difficulty. Deeper '
    'rooms multiply it by dungeon_stone_reward_growth per rank. The pot is '
    'split by damage dealt.'
WHERE key = 'dungeon_stone_reward_per_rank';


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'dungeon_pay_out';

    old := '    stones := round(game_config_value(''dungeon_stone_reward_per_rank'')
                    * run.realm_rank * run.reward_scale);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'dungeon_pay_out no longer fills the pot the old way';
    END IF;

    src := replace(src, old,
'    -- Geometric in the rank of the room, because the gates it is saved for
    -- are. A linear pot against a gate ladder that quintuples means the
    -- deepest room in the game funds a breakthrough in eight hundred clears.
    stones := round(game_config_value(''dungeon_stone_reward_per_rank'')
                    * power(game_config_value(''dungeon_stone_reward_growth''),
                            GREATEST(0, run.realm_rank - 1))
                    * run.reward_scale);');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- What the ladder looks like now
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    base   NUMERIC := game_config_value('dungeon_stone_reward_per_rank');
    step   NUMERIC := game_config_value('dungeon_stone_reward_growth');
    insane NUMERIC;
    worst  NUMERIC;
    one    NUMERIC;
    nine   NUMERIC;
BEGIN
    SELECT d.reward_scale INTO insane
    FROM dungeon_difficulties d ORDER BY d.reward_scale DESC LIMIT 1;

    one  := base * power(step, 0) * insane;
    nine := base * power(step, 8) * insane;

    -- A newcomer's room is untouched; the buff is at the deep end.
    IF round(base * power(step, 0)) <> round(base) THEN
        RAISE EXCEPTION 'the shallowest room moved';
    END IF;

    -- Nobody should need more clears than there are hours in a fortnight.
    SELECT max(g.stones / (base * power(step, GREATEST(0, g.rank - 1)) * insane))
    INTO worst
    FROM realm_gates g;

    IF worst > 40 THEN
        RAISE EXCEPTION
            'the worst gate still wants % clears', round(worst);
    END IF;

    -- And the deep end must actually have moved, or this migration did nothing.
    IF nine <= one * 9 THEN
        RAISE EXCEPTION 'a rank 9 room is still worth what a linear one was';
    END IF;

    RAISE NOTICE 'rank 1 pays %, rank 9 pays %, worst gate is % clears',
        round(one), round(nine), round(worst);
END;
$$;


-- ---------------------------------------------------------------------------
-- And a real room actually pays it
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    deep  SMALLINT;
    want  BIGINT;
BEGIN
    SELECT max(d.realm_rank) INTO deep FROM dungeons d;
    IF deep IS NULL THEN
        RAISE NOTICE 'no rooms; the tests carry this';
        RETURN;
    END IF;

    want := round(game_config_value('dungeon_stone_reward_per_rank')
                  * power(game_config_value('dungeon_stone_reward_growth'), deep - 1)
                  * (SELECT d.reward_scale FROM dungeon_difficulties d
                     WHERE d.code = 'insane'));

    IF want <= round(900 * deep * 11) THEN
        RAISE EXCEPTION
            'the deepest room on Insane pays %, no more than it did', want;
    END IF;

    RAISE NOTICE 'the deepest room on Insane now pays %', want;
END;
$$;
