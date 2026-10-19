-- 0479_a_cache_of_jade_and_a_hundred_sided_die
--
-- A cache of jade in the deep places, opened by rolling a hundred-sided die.
--
-- THE DIE IS THE DRAMA, NOT THE PAYOUT. One to a hundred jade would be an
-- enormous faucet: the daily hands out eight to twenty, a boss four to thirty,
-- a servant roll COSTS fifteen, and the whole live roster averages two hundred
-- and nine jade held. A tile paying up to a hundred would be five servant
-- rolls for one step.
--
-- So the die is read off a table instead, which is also a better roll than a
-- flat one - there is a bottom, a middle, a good result and a thing that
-- happens on a hundred:
--
--     1-50    1-2 jade     a few chips
--     51-80   3-5          a decent pocket
--     81-95   6-10         somebody's savings
--     96-99   11-20        a merchant's purse
--     100     50           the whole seam
--
-- That averages 4.25 jade a cache. With sixteen actions against thirty dark
-- tiles a delver finds a given tile about half the time, so this is roughly
-- two jade an hour to somebody delving every hour - against a daily of eight
-- to twenty. Generous, and deliberately on the low side of a dial I expect to
-- be turned: `delve_jade_rolls` is a table, and changing what a band pays is
-- an UPDATE rather than an argument with a function.
--
-- IT GOES ON THE TALLY like everything else, as Spirit Jade, so the haul says
-- what the trip was worth in one place.
--
-- THE SCATTER NEEDED NO CHANGE. `delve_open` already walks `delve_tile_kinds`
-- and asks `game_config_value('delve_' || kind || 's')` for how many to place,
-- so a new kind with a `delve_jades` config beside it places itself. That is
-- what that loop was for.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('delve_jades', 1,
     'Caches of jade on a delve map. One: jade is the scarcest thing a cultivator counts, and a map that reliably held two would be a jade faucet with a mining theme.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


INSERT INTO delve_tile_kinds
    (kind, emoji, label, is_work, is_beast, scale, blurb, bite, drop_rolls)
VALUES
    ('jade', '💚', 'a cache of jade', TRUE, FALSE, NULL,
     'Somebody buried this and meant to come back. Roll for what is in it.',
     0, 0);


CREATE TABLE delve_jade_rolls (
    low      SMALLINT NOT NULL,
    high     SMALLINT NOT NULL,
    jade_min INTEGER NOT NULL,
    jade_max INTEGER NOT NULL,
    said     TEXT NOT NULL,
    PRIMARY KEY (low),
    CHECK (low >= 1 AND high <= 100 AND high >= low),
    CHECK (jade_min >= 1 AND jade_max >= jade_min)
);

COMMENT ON TABLE delve_jade_rolls IS
    'What a hundred-sided die is worth in jade. A table rather than arithmetic so the bands can be retuned with an UPDATE, and so the roll has a shape - a bottom, a middle, and something that happens on a hundred.';

INSERT INTO delve_jade_rolls (low, high, jade_min, jade_max, said) VALUES
    (  1,  50,  1,  2, 'A few chips, scattered loose.'),
    ( 51,  80,  3,  5, 'A decent pocket of it.'),
    ( 81,  95,  6, 10, 'Somebody''s savings, and they never came back.'),
    ( 96,  99, 11, 20, 'A merchant''s purse, still tied.'),
    (100, 100, 50, 50, 'The whole seam. You will not see this again.');


CREATE OR REPLACE FUNCTION delve_roll_jade(p_player_id bigint)
RETURNS TABLE(die integer, jade bigint, said text, held bigint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_die  INTEGER;
    band   RECORD;
    v_jade BIGINT;
    v_held BIGINT;
BEGIN
    v_die := 1 + floor(random() * 100)::int;

    SELECT * INTO band FROM delve_jade_rolls r
    WHERE v_die BETWEEN r.low AND r.high;
    IF NOT FOUND THEN
        -- A die that lands on no band would mean the table has a hole in it,
        -- which the probe below refuses - but a cultivator should not be the
        -- one who finds out.
        RETURN QUERY SELECT v_die, 0::bigint,
            'The cache is empty.'::text, 0::bigint;
        RETURN;
    END IF;

    v_jade := band.jade_min
              + floor(random() * (band.jade_max - band.jade_min + 1));
    v_held := grant_jade(p_player_id, v_jade, 'delve_cache');

    RETURN QUERY SELECT v_die, v_jade, band.said, v_held;
END;
$fn$;

COMMENT ON FUNCTION delve_roll_jade(bigint) IS
    'Rolls a hundred-sided die against delve_jade_rolls and pays the band it lands in. The die is shown because the drama is the point; the band is what keeps a tile from being worth five servant rolls.';


-- ---------------------------------------------------------------------------
-- And the tile does something when you stand on it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_step' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_step is missing';
    END IF;

    anchor := '    ELSIF v_kind IN (''beast'', ''deep'') THEN';

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_step no longer branches on its beasts where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    ELSIF v_kind = ''jade'' THEN', chr(10),
'        -- 0479. The die is shown; the band is what it is worth.', chr(10),
'        DECLARE', chr(10),
'            rolled RECORD;', chr(10),
'        BEGIN', chr(10),
'            SELECT * INTO rolled FROM delve_roll_jade(p_player_id);', chr(10),
'            v_said := ''You roll '' || rolled.die || ''. '' || rolled.said;', chr(10),
'            IF rolled.jade > 0 THEN', chr(10),
'                v_found := v_found || jsonb_build_object(', chr(10),
'                    ''what'', ''Spirit Jade'', ''how_many'', rolled.jade);', chr(10),
'            END IF;', chr(10),
'        END;', chr(10),
'', chr(10),
anchor));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The die always lands somewhere, and what it pays is a jade purse
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    i      INTEGER;
    v_miss INTEGER := 0;
    v_sum  NUMERIC := 0;
    v_p    BIGINT;
    v_id   BIGINT;
    at     RECORD;
    mv     RECORD;
    v_was  BIGINT;
    v_now  BIGINT;
    band   RECORD;
BEGIN
    -- Every face of the die lands on exactly one band. A hole here is a
    -- cultivator opening a cache and being told it is empty.
    FOR i IN 1..100 LOOP
        IF (SELECT count(*) FROM delve_jade_rolls r
            WHERE i BETWEEN r.low AND r.high) <> 1 THEN
            v_miss := v_miss + 1;
        END IF;
    END LOOP;
    IF v_miss > 0 THEN
        RAISE EXCEPTION '% faces of the die land on no band, or on two', v_miss;
    END IF;

    -- And the bands climb, or the roll means nothing.
    IF EXISTS (
        SELECT 1 FROM delve_jade_rolls a JOIN delve_jade_rolls b ON b.low > a.low
        WHERE b.jade_max < a.jade_max
    ) THEN
        RAISE EXCEPTION 'a higher roll pays less than a lower one';
    END IF;

    -- What it averages, stated rather than hoped at.
    SELECT sum((r.high - r.low + 1) * (r.jade_min + r.jade_max) / 2.0) / 100
    INTO v_sum FROM delve_jade_rolls r;
    RAISE NOTICE 'a cache of jade averages % a roll', round(v_sum, 2);

    IF v_sum > 20 THEN
        RAISE EXCEPTION
            'a cache averages % jade, which is a daily every hour', round(v_sum, 2);
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND delve_of(p.player_id) IS NULL
        ORDER BY p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT COALESCE(pm.quantity, 0) INTO v_was FROM player_materials pm
        WHERE pm.player_id = v_p AND pm.material_code = 'spirit_jade';

        DELETE FROM player_cooldowns WHERE player_id = v_p AND action = 'delve';
        v_id := delve_open(v_p);
        SELECT dr.at_x, dr.at_y INTO at FROM delve_runs dr WHERE dr.delve_id = v_id;
        UPDATE delve_tiles t SET kind = 'jade', spent = FALSE
        WHERE t.delve_id = v_id AND t.x = at.at_x AND t.y = at.at_y - 1;

        SELECT * INTO mv FROM delve_step(v_p, 'up');

        SELECT COALESCE(pm.quantity, 0) INTO v_now FROM player_materials pm
        WHERE pm.player_id = v_p AND pm.material_code = 'spirit_jade';

        IF v_now <= COALESCE(v_was, 0) THEN
            RAISE EXCEPTION 'the cache paid no jade at all';
        END IF;

        RAISE NOTICE '%  (and the tally says: %)', mv.said,
            delve_haul_of(v_id);

        -- It is on the tally, with its own glyph.
        IF NOT EXISTS (SELECT 1 FROM delve_haul h
                       WHERE h.delve_id = v_id AND h.what = 'Spirit Jade'
                         AND h.emoji IS NOT NULL) THEN
            RAISE EXCEPTION 'the jade never reached the tally';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- The scatter places it, which needed no code because the loop was
    -- written to read the table.
    IF game_config_value('delve_jades') < 1 THEN
        RAISE EXCEPTION 'no jade is ever placed on a map';
    END IF;
END;
$probe$;
