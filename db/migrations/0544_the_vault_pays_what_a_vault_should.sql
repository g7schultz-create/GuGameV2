-- 0544_the_vault_pays_what_a_vault_should
--
-- Two faults measured by rolling the drop table two hundred times at rank 18
-- and again at rank 19.
--
-- 1. THE DEEPEST ROOM IN THE GAME PAYS NO ESSENCE. Measured: 200 of 200
--    clears at rank 18 hand over Yellow Apricot essence, and 0 of 200 at rank
--    19 hand over anything.
--
--        tier := LEAST(p_rank, player_standing(...));
--        SELECT e.material_code FROM immortal_essences e WHERE e.rank = tier;
--
--    An EQUALITY, and `immortal_essences` runs 10 to 18. A standing 19 raider
--    in a rank 19 room looks for a rank 19 essence and finds none.
--
--    This is the identical trap I found in `blessed_land_settle` in 0537 and
--    clamped there - and I did not check whether anything else had the same
--    shape. This did. Immortal essence is what the immortal ladder runs on,
--    so the Vault was paying less than The Last Apricot for a harder door.
--
--    Clamped to the deepest essence that EXISTS, which is what was asked for:
--    the Vault pays Yellow Apricot, and follows standing by itself the moment
--    a rank 19 essence is written.
--
-- 2. THE GU DROP STOPS AT RANK 5. `gu_max_droppable_rank` is 5 - the WORLD's
--    ceiling, read by `roll_gu_drop`, `horde_chest_take` and the region drop
--    gate as well - so a rank 19 raid handed out a rank 5 worm while 0493 put
--    the apex at rank 9 and 0514 repriced the whole ladder around it. Raising
--    the world ceiling would change horde chests and region drops too, which
--    is not what was asked, so the dungeon gets its own.
--
--    AND THE TOP THREE GET RARER, as asked. The rank is picked by weight and
--    the weights ARE the percentages, so the table reads as the odds:
--
--        ranks 1-6   70% between them
--        rank 7      20%
--        rank 8       8%
--        rank 9       2%
--
--    Against the 12% chance of a worm at all, that is a rank 9 worm roughly
--    once in four hundred clears. A room still cannot roll above its own
--    rank, so the mortal rooms are nearly unchanged - they were already
--    weighted by how many kinds exist at each rank, and are now weighted by
--    the table instead, which moves a rank 4 room's deepest band from 23% to
--    26%.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('dungeon_gu_max_rank', 9,
     'The deepest Gu a dungeon may drop. Separate from `gu_max_droppable_rank` (5), which is the WORLD''s ceiling and governs region drops and horde chests - a room earns its own reach.');


CREATE TABLE dungeon_gu_rank_odds (
    rank   SMALLINT PRIMARY KEY,
    weight NUMERIC(6,2) NOT NULL,
    CONSTRAINT dungeon_gu_rank_odds_weight_check CHECK (weight > 0),
    CONSTRAINT dungeon_gu_rank_odds_rank_check CHECK (rank >= 1 AND rank <= 9)
);

COMMENT ON TABLE dungeon_gu_rank_odds IS
    'How likely a dropped Gu is to be of each rank. The weights are percentages across all nine, so the table reads as the odds - and a room renormalises over whatever it can actually reach, so a rank 4 room sees only the first four rows.';

INSERT INTO dungeon_gu_rank_odds (rank, weight) VALUES
    (1, 10), (2, 12), (3, 12), (4, 12), (5, 12), (6, 12),   -- 70 between them
    (7, 20),
    (8,  8),
    (9,  2);


DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('dungeon_spoils_for(bigint,smallint,numeric)'::regprocedure);

    -- ---- the essence ------------------------------------------------------
    one := '            tier := LEAST(p_rank, COALESCE(player_standing(p_player_id), 1));';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the essence tier is not where I read it';
    END IF;
    src := replace(src, one,
        '            -- The lesser of the room, the raider, and the deepest' || chr(10) ||
        '            -- essence that EXISTS. The lookup below is an equality and' || chr(10) ||
        '            -- `immortal_essences` stops at 18, so without the third' || chr(10) ||
        '            -- term a rank 19 room pays nothing at all - measured at 0' || chr(10) ||
        '            -- of 200 clears against 200 of 200 at rank 18. The same' || chr(10) ||
        '            -- trap 0537 clamped in `blessed_land_settle`.' || chr(10) ||
        '            tier := LEAST(p_rank, COALESCE(player_standing(p_player_id), 1),' || chr(10) ||
        '                          (SELECT max(e2.rank) FROM immortal_essences e2));');

    -- ---- the Gu ceiling ---------------------------------------------------
    one := '    ceiling := game_config_value(''gu_max_droppable_rank'')::smallint;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the drop ceiling is not where I read it';
    END IF;
    src := replace(src, one,
        '    -- A ROOM''S OWN REACH, not the world''s. `gu_max_droppable_rank` is' || chr(10) ||
        '    -- 5 and governs region drops and horde chests as well, so raising' || chr(10) ||
        '    -- it would change those too.' || chr(10) ||
        '    ceiling := game_config_value(''dungeon_gu_max_rank'')::smallint;');

    -- ---- and the roll, by rank rather than by how many kinds exist --------
    one := '        SELECT t.gu_type_id INTO made FROM gu_types t' || chr(10) ||
           '        WHERE t.rank <= LEAST(GREATEST(p_rank, 1), ceiling)' || chr(10) ||
           '        ORDER BY random() LIMIT 1;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the ordinary Gu roll is not where I read it';
    END IF;
    src := replace(src, one,
        '        -- THE RANK FIRST, BY WEIGHT, then a kind within it. Rolling' || chr(10) ||
        '        -- flat across every type weights the answer by how many kinds' || chr(10) ||
        '        -- happen to exist at each rank - 670 at rank 3 against 15 at' || chr(10) ||
        '        -- rank 9 - so the top of the ladder could never be the prize' || chr(10) ||
        '        -- whatever the ceiling said. `dungeon_gu_rank_odds` holds the' || chr(10) ||
        '        -- odds as percentages and the room renormalises over what it' || chr(10) ||
        '        -- can reach.' || chr(10) ||
        '        SELECT t.gu_type_id INTO made' || chr(10) ||
        '        FROM (' || chr(10) ||
        '            SELECT o.rank FROM dungeon_gu_rank_odds o' || chr(10) ||
        '            WHERE o.rank <= LEAST(GREATEST(p_rank, 1), ceiling)' || chr(10) ||
        '              AND EXISTS (SELECT 1 FROM gu_types g WHERE g.rank = o.rank)' || chr(10) ||
        '            ORDER BY -ln(random()) / o.weight' || chr(10) ||
        '            LIMIT 1' || chr(10) ||
        '        ) band' || chr(10) ||
        '        JOIN gu_types t ON t.rank = band.rank' || chr(10) ||
        '        ORDER BY random() LIMIT 1;');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Roll it and count what comes out
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_path  TEXT;
    v_scale NUMERIC;
    v_got   JSONB;
    v_ess   INTEGER := 0;
    v_deep  INTEGER := 0;
    v_nine  INTEGER := 0;
    v_rank  SMALLINT;
    i       INTEGER;
BEGIN
    IF (SELECT sum(weight) FROM dungeon_gu_rank_odds) <> 100 THEN
        RAISE EXCEPTION
            'the odds sum to %, so they are not percentages',
            (SELECT sum(weight) FROM dungeon_gu_rank_odds);
    END IF;

    -- The three deep bands get rarer, which is the thing that was asked for.
    IF NOT (
        (SELECT weight FROM dungeon_gu_rank_odds WHERE rank = 7)
        > (SELECT weight FROM dungeon_gu_rank_odds WHERE rank = 8)
        AND (SELECT weight FROM dungeon_gu_rank_odds WHERE rank = 8)
        > (SELECT weight FROM dungeon_gu_rank_odds WHERE rank = 9)
    ) THEN
        RAISE EXCEPTION 'ranks 7, 8 and 9 do not get rarer in that order';
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;
    SELECT reward_scale INTO v_scale FROM dungeon_difficulties WHERE code = 'normal';

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-962, 'loot-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());
        PERFORM venerable_ascend(v_pid);

        -- 1. ESSENCE, EVERY TIME, and it is Yellow Apricot.
        FOR i IN 1..40 LOOP
            v_got := dungeon_spoils_for(v_pid, 19::smallint, v_scale);
            IF v_got ? 'essence' THEN v_ess := v_ess + 1; END IF;
        END LOOP;

        IF v_ess <> 40 THEN
            RAISE EXCEPTION
                'the Vault paid essence on % of 40 clears', v_ess;
        END IF;
        IF (SELECT e.material_code FROM immortal_essences e
            WHERE e.rank = LEAST(19, player_standing(v_pid),
                                 (SELECT max(rank) FROM immortal_essences)))
           <> 'yellow_apricot_essence' THEN
            RAISE EXCEPTION
                'the Vault pays % rather than Yellow Apricot',
                (SELECT e.material_code FROM immortal_essences e
                 WHERE e.rank = LEAST(19, player_standing(v_pid),
                                      (SELECT max(rank) FROM immortal_essences)));
        END IF;

        -- 2. AND THE GU REACHES RANK 9. Rolled directly rather than waiting
        -- on the 12% chance, so the band weighting is what is measured.
        FOR i IN 1..2000 LOOP
            SELECT band.rank INTO v_rank
            FROM (
                SELECT o.rank FROM dungeon_gu_rank_odds o
                WHERE o.rank <= 9
                  AND EXISTS (SELECT 1 FROM gu_types g WHERE g.rank = o.rank)
                ORDER BY -ln(random()) / o.weight
                LIMIT 1
            ) band;
            IF v_rank >= 7 THEN v_deep := v_deep + 1; END IF;
            IF v_rank = 9 THEN v_nine := v_nine + 1; END IF;
        END LOOP;

        -- 30% of bands are 7 or more, 2% are rank 9. Loose bounds, because a
        -- probe that pins a random draw to two decimal places is a probe that
        -- fails on a Tuesday.
        IF v_deep NOT BETWEEN 450 AND 750 THEN
            RAISE EXCEPTION
                '% of 2000 bands were rank 7 or deeper, wanted about 600',
                v_deep;
        END IF;
        IF v_nine NOT BETWEEN 10 AND 90 THEN
            RAISE EXCEPTION
                '% of 2000 bands were rank 9, wanted about 40', v_nine;
        END IF;

        RAISE NOTICE
            'of 2000 bands, % were rank 7+ and % were rank 9', v_deep, v_nine;

        -- 3. AND A MORTAL ROOM STILL CANNOT REACH PAST ITSELF.
        FOR i IN 1..200 LOOP
            SELECT band.rank INTO v_rank
            FROM (
                SELECT o.rank FROM dungeon_gu_rank_odds o
                WHERE o.rank <= LEAST(4, 9)
                ORDER BY -ln(random()) / o.weight
                LIMIT 1
            ) band;
            IF v_rank > 4 THEN
                RAISE EXCEPTION
                    'a rank 4 room rolled a rank % band', v_rank;
            END IF;
        END LOOP;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'the Vault pays Yellow Apricot essence, and a worm as deep as rank 9';
END;
$probe$;
