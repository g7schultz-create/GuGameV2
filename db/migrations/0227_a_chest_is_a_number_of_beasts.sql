-- 0227_a_chest_is_a_number_of_beasts
--
-- The first live tide earned one defender all three chests in twenty kills.
--
-- The thresholds were absolute - 2,000, 12,000, 40,000 - and contribution is
-- damage, which scales with how hard the cultivator hits AND with how much
-- health the beast had. Neither of those is fixed, so an absolute number means
-- something different in every tide: trivial for a strong cultivator in a
-- shallow one, unreachable for a weak cultivator in a deep one. The same three
-- numbers cannot do both jobs.
--
-- A CHEST IS A NUMBER OF BEASTS INSTEAD. Roughly fifteen, sixty and a hundred
-- and fifty, measured against what a beast of that tide's rank actually costs
-- to fell. The bar moves with the tide, so "turned up and swung a few times"
-- means the same thing in the rank 1 room and the rank 9 one, and a defender
-- reading `/horde` sees a number that is about their afternoon rather than
-- about arithmetic they cannot see.
--
-- The old keys stay and become the floor, so a tide in a region of unusually
-- soft beasts cannot make a chest free.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_chest_kills_one', 15,
     'Roughly how many beasts of the tide''s own rank the first chest is '
     'worth. The bar is computed from what a beast there actually costs to '
     'fell, so it means the same thing at every rank.'),
    ('horde_chest_kills_two', 60,
     'Beasts for the second chest.'),
    ('horde_chest_kills_three', 150,
     'Beasts for the third. A serious afternoon on the line at any rank.');


-- What one beast of this tide is worth to whoever fells it: its health, which
-- somebody has to deal, plus the bounty for the finishing blow.
CREATE FUNCTION horde_beast_worth(p_horde_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(1,
        COALESCE((
            SELECT avg(cs.base_hp) * (1 + h.rank * 0.6)
            FROM creature_regions cr
            JOIN creature_species cs ON cs.species_id = cr.species_id
            WHERE cr.region_code = h.region_code AND cs.kind = 'beast'
        ), 600 * (1 + h.rank * 0.6))
        + game_config_value('horde_slay_bounty') * GREATEST(1, h.rank))
    FROM beast_hordes h WHERE h.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_beast_worth(BIGINT) IS
    'What felling one beast of this tide is worth in contribution: the health somebody had to get through, plus the bounty for the last blow.';


CREATE FUNCTION horde_chest_bar(p_horde_id BIGINT, p_chest SMALLINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT GREATEST(
        -- The old absolute number is the floor, so a region of unusually soft
        -- beasts cannot make a chest free.
        game_config_value(CASE p_chest
            WHEN 1 THEN 'horde_chest_one'
            WHEN 2 THEN 'horde_chest_two'
            ELSE 'horde_chest_three' END)::bigint,
        round(horde_beast_worth(p_horde_id) * game_config_value(CASE p_chest
            WHEN 1 THEN 'horde_chest_kills_one'
            WHEN 2 THEN 'horde_chest_kills_two'
            ELSE 'horde_chest_kills_three' END))::bigint);
$$;


CREATE OR REPLACE FUNCTION horde_chests_earned(p_horde_id BIGINT, p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT (CASE
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= horde_chest_bar(p_horde_id, 3::smallint) THEN 3
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= horde_chest_bar(p_horde_id, 2::smallint) THEN 2
        WHEN horde_contribution(p_horde_id, p_player_id)
             >= horde_chest_bar(p_horde_id, 1::smallint) THEN 1
        ELSE 0
    END)::smallint;
$$;


DO $$
DECLARE
    tide BIGINT;
    who  BIGINT;
    bar1 BIGINT;
    bar3 BIGINT;
    live BIGINT;
BEGIN
    -- A tide may be running; the probe must not disturb it, and horde_open
    -- refuses while one is. Reuse whatever is there, or open one and throw it
    -- away with everything else in this block.
    SELECT h.horde_id INTO live FROM beast_hordes h
    WHERE h.status IN ('fighting', 'king') LIMIT 1;

    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0 LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to measure; the tests carry it';
        RETURN;
    END IF;

    BEGIN
        IF live IS NOT NULL THEN
            tide := live;
        ELSE
            tide := horde_open('northern', 5::smallint, NULL);
        END IF;

        bar1 := horde_chest_bar(tide, 1::smallint);
        bar3 := horde_chest_bar(tide, 3::smallint);

        IF bar1 >= bar3 THEN
            RAISE EXCEPTION 'the first chest is not cheaper than the third';
        END IF;

        -- Fifteen beasts is the first chest, so it must cost about fifteen
        -- beasts and not one.
        IF bar1 < horde_beast_worth(tide) * 10 THEN
            RAISE EXCEPTION 'the first chest costs fewer than ten beasts';
        END IF;

        -- And a deeper tide asks for more than a shallow one.
        UPDATE beast_hordes SET rank = 1 WHERE horde_id = tide;
        IF horde_chest_bar(tide, 3::smallint) >= bar3 THEN
            RAISE EXCEPTION 'a rank 1 tide asks as much as a rank 5 one';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
