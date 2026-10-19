-- 0290_the_king_is_measured_against_the_room
--
-- The King is one-shot again. 0272 multiplied its health by 125 and that held
-- for a while, which is the tell: the number was wrong, but the reason the
-- number keeps going wrong is that it is a number at all.
--
-- WHAT IT WAS. `horde_king_rise` sized the King off the region it rose in -
-- the average base health of the local beasts, times the tide's world scale,
-- times a thousand. Not one term in that expression knows anything about the
-- people who will be swinging at it. So the King tracked the bestiary while
-- the roster tracked gear, realms, techniques and now pets, and the gap
-- between them widened every week whether anybody was watching or not.
--
-- Today, in the northern tide, that formula makes a King of 31,882,667.
-- m_i_y_u_k_i. lands 193,952,872 in a single blow. The finale of a tide dies
-- six times over before the rest of the room takes its first swing, and
-- clearwest is not far behind at 73,579,112.
--
-- WHAT THE WORLD BEAST DOES INSTEAD. `boss_hp_pool` counts the roster: every
-- cultivator seen in the last week, their hardest actual blow against this
-- particular species, what walks at their heel, times the swings one is
-- expected to land across the window. It is why the world beast has never
-- needed this migration. The King gets the same shape.
--
-- WHY IT BORROWS THE BEAST'S FUNCTION RATHER THAN COPYING IT. Two roster
-- measures that drift apart is the same bug as one measure that drifts from
-- the roster. Tuning the beast now moves the King with it, in proportion,
-- which is what "counted rather than set" in this King's own config already
-- promised and did not deliver.
--
-- THE TWO DIALS IT KEEPS FOR ITSELF. `horde_king_effort` is what share of a
-- world beast a King is worth - it stands thirty minutes rather than an
-- evening, so it is not simply the same fight. `horde_king_rank_step` is how
-- much a deeper tide raises it, because the region's own scale left the
-- expression when the roster came in and a rank 4 tide should still end
-- harder than a rank 2.
--
-- WHAT IT COMES OUT AT. Against today's roster a rank 3 King is about 2.9
-- billion. The two deepest cultivators together land 1.78 billion in one full
-- burst of five strikes each, so it survives an opening burst and needs a
-- second - and the stand-off is seven minutes against a thirty minute stand,
-- which leaves room for four or five. A fight, rather than a race or a wall.
--
-- The old formula stays as a floor. A thin week must never produce a King
-- smaller than the sea it came behind.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_effort', 0.75,
     'What share of a world beast''s health a King carries, measured against '
     'the same roster. Below 1 because it stands for thirty minutes rather '
     'than an evening.'),
    ('horde_king_rank_step', 0.15,
     'How much each rank of the tide past the first raises the King, now that '
     'the region''s own scale is no longer what sizes it.');


DO $$
DECLARE
    body TEXT;
    old_anchor TEXT :=
'    pool := GREATEST(1000, round(
        COALESCE((SELECT avg(cs.base_hp)
                  FROM creature_regions cr
                  JOIN creature_species cs ON cs.species_id = cr.species_id
                  WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),
                 600)
        * horde_world_scale(p_horde_id)
        * game_config_value(''horde_king_beasts'')))::bigint;';
BEGIN
    SELECT pg_get_functiondef(oid) INTO body
    FROM pg_proc WHERE proname = 'horde_king_rise';

    IF body IS NULL THEN
        RAISE EXCEPTION 'horde_king_rise is missing';
    END IF;

    IF (length(body) - length(replace(body, old_anchor, '')))
       / length(old_anchor) <> 1 THEN
        RAISE EXCEPTION 'the old king-sizing block is not where it was';
    END IF;

    body := replace(body, old_anchor,
'    -- Counted against the people who will swing at it, the same way
    -- `boss_hp_pool` counts a world beast - including what walks at their
    -- heel. The region-counted formula stays underneath as a floor, so a
    -- thin week never makes a King smaller than the sea it came behind.
    pool := GREATEST(
        GREATEST(1000, round(
            COALESCE((SELECT avg(cs.base_hp)
                      FROM creature_regions cr
                      JOIN creature_species cs ON cs.species_id = cr.species_id
                      WHERE cr.region_code = tide.region_code AND cs.kind = ''beast''),
                     600)
            * horde_world_scale(p_horde_id)
            * game_config_value(''horde_king_beasts''))),
        round(boss_hp_pool(who)
              * game_config_value(''horde_king_effort'')
              * (1 + game_config_value(''horde_king_rank_step'')
                     * GREATEST(0, COALESCE(tide.rank, 1) - 1)))
    )::bigint;');

    EXECUTE body;
END;
$$;


COMMENT ON FUNCTION horde_king_rise(BIGINT) IS
    'Raises the King once the sea behind it is empty, sized against the roster that will fight it.';


-- ---------------------------------------------------------------------------
-- A King no longer dies to one cultivator's opening blow
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    sp      BIGINT;
    pool    BIGINT;
    biggest BIGINT;
    who     TEXT;
    burst   NUMERIC := game_config_value('horde_king_burst');
BEGIN
    -- The King the northern tide would raise, and the hardest single blow on
    -- the server against it.
    SELECT cs.species_id INTO sp
    FROM creature_regions cr
    JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'northern' AND cs.kind IN ('beast', 'elite')
    ORDER BY cs.rank DESC, cs.base_hp DESC
    LIMIT 1;

    IF sp IS NULL THEN
        RAISE NOTICE 'the northern region has nothing to crown; the tests carry this';
        RETURN;
    END IF;

    pool := round(boss_hp_pool(sp) * game_config_value('horde_king_effort'));

    SELECT p.discord_name,
           (SELECT dealt FROM player_swing(
                p.player_id, dungeon_default_move(p.player_id), sp,
                99999999999::bigint,
                (SELECT cs.base_defense FROM creature_species cs
                 WHERE cs.species_id = sp)::bigint))
    INTO who, biggest
    FROM players p
    WHERE p.deleted_at IS NULL
      AND dungeon_default_move(p.player_id) IS NOT NULL
      AND p.last_seen_at >= now() - interval '30 days'
    ORDER BY 2 DESC NULLS LAST
    LIMIT 1;

    IF biggest IS NULL OR biggest <= 0 THEN
        RAISE NOTICE 'nobody can swing at it; the tests carry this';
        RETURN;
    END IF;

    IF biggest >= pool THEN
        RAISE EXCEPTION
            '% still one-shots the King: % against a pool of %',
            who, biggest, pool;
    END IF;

    -- And a full burst from the hardest hitter must not end it either, or the
    -- finale is one person's turn rather than the room's.
    IF biggest * burst >= pool THEN
        RAISE EXCEPTION
            'one burst from % ends the King: % x % against %',
            who, biggest, burst, pool;
    END IF;

    RAISE NOTICE
        'a King of % stands against %''s hardest blow of % (% per full burst)',
        pool, who, biggest, biggest * burst;
END;
$$;


-- ---------------------------------------------------------------------------
-- It never got smaller than the King it replaces
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    r    RECORD;
    old  BIGINT;
    new  BIGINT;
BEGIN
    FOR r IN
        SELECT h.horde_id, h.region_code, h.rank
        FROM beast_hordes h
        ORDER BY h.horde_id DESC
        LIMIT 8
    LOOP
        old := GREATEST(1000, round(
            COALESCE((SELECT avg(cs.base_hp)
                      FROM creature_regions cr
                      JOIN creature_species cs ON cs.species_id = cr.species_id
                      WHERE cr.region_code = r.region_code AND cs.kind = 'beast'),
                     600)
            * horde_world_scale(r.horde_id)
            * game_config_value('horde_king_beasts')))::bigint;

        SELECT round(boss_hp_pool(cs.species_id)
                     * game_config_value('horde_king_effort')
                     * (1 + game_config_value('horde_king_rank_step')
                            * GREATEST(0, COALESCE(r.rank, 1) - 1)))::bigint
        INTO new
        FROM creature_regions cr
        JOIN creature_species cs ON cs.species_id = cr.species_id
        WHERE cr.region_code = r.region_code AND cs.kind IN ('beast', 'elite')
        ORDER BY cs.rank DESC, cs.base_hp DESC
        LIMIT 1;

        IF new IS NULL THEN
            CONTINUE;
        END IF;

        IF GREATEST(old, new) < old THEN
            RAISE EXCEPTION 'tide % would raise a smaller King than before',
                r.horde_id;
        END IF;

        RAISE NOTICE 'tide % (% rank %): % -> %',
            r.horde_id, r.region_code, r.rank, old, GREATEST(old, new);
    END LOOP;
END;
$$;
