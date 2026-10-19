-- 0189_a_gu_you_have_fed_for_a_while
--
-- `player_gu.stars` already decides how strong a Gu is. `player_gu_stats`
-- scales every effect by `1 + gu_star_step * (stars - 1)`, so a five-star Gu
-- is worth double a one-star of the same type. And nothing has ever raised
-- them: `refine_gu` sets stars when a Gu is made and no other function in the
-- schema touches the column. 117 of the 137 Gu alive are one star.
--
-- Meanwhile duplicates pile up with nothing to do. m_i_y_u_k_i. holds
-- sixteen Bookworms and fourteen Signal Gu; clearwest seven Bookworms. They
-- are drops of a type he already has, and the only thing to do with one is
-- sell it.
--
-- So: feed the duplicates to the original. Going to star N costs N copies of
-- the same type and a purse of stones, and the Gu keeps its own identity -
-- the same row, the same harmony, the same date it was found. One to five is
-- fourteen fodder Gu, which is a long enough acquaintance to be worth the
-- word nurture.
--
-- RANK IS NOT THE AXIS, and cannot be. `gu_types.rank` belongs to the TYPE -
-- every Bookworm in the world shares it - so raising one cultivator's Gu a
-- rank would mean turning it into a different Gu. Stars are the per-creature
-- measure, they already feed the damage pipeline, and they were the half of
-- this that was already built.
--
-- No failure roll. Feeding five duplicates and being told they died would be
-- gambling, and this is meant to reward keeping something.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('gu_nurture_copies_per_star', 1,
     'Duplicate Gu eaten per star of the target. Going to star N costs N '
     'copies, so one to five is fourteen in all.'),
    ('gu_nurture_stone_base', 50,
     'Spirit Stones per rank per star of the target. A rank 1 Gu costs 700 '
     'stones across the whole climb to five.');


CREATE FUNCTION gu_nurture_copies(p_target_stars SMALLINT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT GREATEST(1, p_target_stars
                       * game_config_value('gu_nurture_copies_per_star'))::integer;
$$;


CREATE FUNCTION gu_nurture_cost(p_rank SMALLINT, p_target_stars SMALLINT)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT GREATEST(1, round(game_config_value('gu_nurture_stone_base')
                             * GREATEST(1, p_rank)
                             * GREATEST(1, p_target_stars)))::bigint;
$$;


-- What a screen offers, and the single authority for whether a feeding may
-- happen. `nurture_gu` reads the same view rather than deciding again.
CREATE VIEW gu_nursery AS
SELECT g.owner_id AS player_id,
       g.gu_id,
       t.gu_type_id,
       t.name,
       t.emoji,
       t.rank,
       g.stars,
       (g.stars + 1)::smallint AS next_stars,
       -- Everything else of the type that is not this Gu and not worn. An
       -- equipped Gu is refused rather than silently unequipped: eating what
       -- somebody is standing in is not a thing to do quietly.
       (SELECT count(*) FROM player_gu f
        WHERE f.owner_id = g.owner_id
          AND f.gu_type_id = g.gu_type_id
          AND f.gu_id <> g.gu_id
          AND NOT EXISTS (SELECT 1 FROM player_gu_equipped e
                          WHERE e.gu_id = f.gu_id)) AS spares,
       gu_nurture_copies((g.stars + 1)::smallint) AS copies_needed,
       gu_nurture_cost(t.rank, (g.stars + 1)::smallint) AS stone_cost,
       COALESCE((SELECT pm.quantity FROM player_materials pm
                 WHERE pm.player_id = g.owner_id
                   AND pm.material_code = 'spirit_stone'), 0) AS stones_held
FROM player_gu g
JOIN gu_types t ON t.gu_type_id = g.gu_type_id;


CREATE FUNCTION nurture_gu(p_player_id BIGINT, p_gu_id BIGINT)
RETURNS TABLE (
    gu_name      TEXT,
    stars_before SMALLINT,
    stars_after  SMALLINT,
    eaten        INTEGER,
    stones_spent BIGINT,
    stones_left  BIGINT,
    spares_left  INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    it     RECORD;
    fodder BIGINT[];
    left_n BIGINT;
BEGIN
    SELECT * INTO it FROM gu_nursery n
    WHERE n.player_id = p_player_id AND n.gu_id = p_gu_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'that is not one of your Gu'
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.next_stars > 5 THEN
        RAISE EXCEPTION '% is already as strong as a Gu of its kind becomes',
            it.name USING ERRCODE = 'check_violation';
    END IF;

    IF it.spares < it.copies_needed THEN
        RAISE EXCEPTION
            'feeding % to % stars wants % more of the same, and you have %',
            it.name, it.next_stars, it.copies_needed, it.spares
            USING ERRCODE = 'check_violation';
    END IF;

    IF it.stones_held < it.stone_cost THEN
        RAISE EXCEPTION 'that feeding costs % Spirit Stones', it.stone_cost
            USING ERRCODE = 'check_violation';
    END IF;

    -- The weakest spares go first, so a cultivator holding a three-star spare
    -- does not lose it to a feeding they meant to spend junk on.
    SELECT array_agg(f.gu_id) INTO fodder
    FROM (
        SELECT f.gu_id FROM player_gu f
        WHERE f.owner_id = p_player_id
          AND f.gu_type_id = it.gu_type_id
          AND f.gu_id <> p_gu_id
          AND NOT EXISTS (SELECT 1 FROM player_gu_equipped e
                          WHERE e.gu_id = f.gu_id)
        ORDER BY f.stars, f.harmony, f.gu_id
        LIMIT it.copies_needed
    ) f;

    left_n := spend_material(p_player_id, 'spirit_stone', it.stone_cost);

    DELETE FROM player_gu WHERE gu_id = ANY(fodder);

    UPDATE player_gu SET stars = it.next_stars WHERE gu_id = p_gu_id;

    RETURN QUERY
    SELECT it.name, it.stars, it.next_stars,
           it.copies_needed, it.stone_cost, left_n,
           (SELECT n2.spares FROM gu_nursery n2
            WHERE n2.player_id = p_player_id AND n2.gu_id = p_gu_id)::integer;
END;
$$;


-- Fed for real on a live cultivator, inside a subtransaction that is thrown
-- away. A feeding that eats the spares and does not raise the star is the
-- failure worth catching.

DO $$
DECLARE
    who    BIGINT;
    target BIGINT;
    before SMALLINT;
    held   BIGINT;
    got    RECORD;
BEGIN
    SELECT n.player_id, n.gu_id, n.stars INTO who, target, before
    FROM gu_nursery n
    WHERE n.spares >= n.copies_needed
      AND n.stones_held >= n.stone_cost
      AND n.next_stars <= 5
    ORDER BY n.spares DESC
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody can feed a Gu yet; tests carry it';
        RETURN;
    END IF;

    BEGIN
        SELECT count(*) INTO held FROM player_gu WHERE owner_id = who;
        SELECT * INTO got FROM nurture_gu(who, target);

        IF got.stars_after <> before + 1 THEN
            RAISE EXCEPTION 'fed from % to %', before, got.stars_after;
        END IF;
        IF (SELECT stars FROM player_gu WHERE gu_id = target) <> got.stars_after THEN
            RAISE EXCEPTION 'the star was reported but not written';
        END IF;
        IF (SELECT count(*) FROM player_gu WHERE owner_id = who)
           <> held - got.eaten THEN
            RAISE EXCEPTION 'the wrong number of spares went in';
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
