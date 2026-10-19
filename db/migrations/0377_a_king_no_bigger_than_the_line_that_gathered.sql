-- 0377_a_king_no_bigger_than_the_line_that_gathered
--
-- A King rose in White Heaven with 233,670,054,054,054 health and half an hour
-- to live. Six cultivators had put about 1.1 trillion damage into the entire
-- tide behind it. That is not a hard finale, it is a wall with a timer.
--
-- WHERE IT COMES FROM. `horde_king_pool` takes the GREATEST of three numbers,
-- and the first counts the King in beasts of its own region:
--
--     average regional beast HP x world scale x horde_king_beasts (1000)
--
-- 'A King is worth a thousand ordinary beasts of this place' is a good rule
-- where a beast is fifty thousand health. A White Heaven beast averages
-- 1,058,288,288. A thousand of those, at a world scale of 220.8, is two
-- hundred and thirty-three trillion.
--
-- ONLY THE FIRST TERM IS CAPPED, AND THAT DISTINCTION COST ME A DRAFT. The
-- obvious fix - cap the whole pool against what the line can deliver - failed
-- its own probe: four old mortal Kings shrank. They were not sized by the
-- regional floor at all but by the THIRD term, 'never less than one
-- cultivator's whole burst with room to spare', which is the guarantee that a
-- thinly-attended tide still ends in a fight worth showing up for. Capping the
-- whole expression quietly ate that guarantee.
--
-- Measured over every King this game has ever raised - fifty of them - the
-- regional floor against what the line can put in:
--
--     mortal (49)   ratio 0.01 to 0.70, median 0.03
--     heaven  (1)   ratio 8884.91
--
-- In the mortal world the floor NEVER decides the size. It does exactly the
-- job it was written for and then gets out of the way. Only where the beasts
-- are immortal-scale does it run away, and it runs away by four orders of
-- magnitude. So the floor keeps its job and gains a ceiling of its own, and
-- terms two and three are left completely alone.
--
-- `horde_king_line_reach` returns NULL when nobody gathered, and LEAST ignores
-- NULLs - so a tide with no line behind it keeps the raw floor, which is the
-- case the floor exists for in the first place.
--
-- THIS IS ALSO WHY 0350 STOPPED TIDES AUTO-OPENING IN A HEAVEN. That guard was
-- right and this tide walked past it, having been opened by hand. The guard
-- stays; this makes the arithmetic survive the day somebody opens one anyway.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_king_reach', 3.0,
     'Most the REGIONAL floor may size a King at, as a multiple of what the line that gathered could put into it. Only the floor is bound by this - the line''s own term and the one-cultivator guarantee are not, so a thinly attended tide still gets a King worth gathering for.');


CREATE FUNCTION horde_king_line_reach(p_horde_id BIGINT, p_species_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- What the line that gathered could put into it, times the reach. NULL
    -- when nobody gathered: LEAST ignores NULLs, so the floor stands alone
    -- rather than being clamped to zero.
    SELECT CASE WHEN COALESCE(sum(horde_walker_burst(c.player_id, p_species_id)), 0) > 0
                THEN sum(horde_walker_burst(c.player_id, p_species_id))
                     * game_config_value('horde_king_burst')
                     * game_config_value('horde_king_bursts_expected')
                     * game_config_value('horde_king_effort')
                     * game_config_value('horde_king_reach')
                ELSE NULL END
    FROM horde_contributions c WHERE c.horde_id = p_horde_id;
$$;

COMMENT ON FUNCTION horde_king_line_reach(BIGINT, BIGINT) IS
    'The ceiling on the regional floor: what everyone who swung at this tide could put into a King, times horde_king_reach. NULL when nobody swung.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        GREATEST(1000, round(', chr(10),
'            COALESCE((SELECT sum(cs.base_hp * cr.weight)', chr(10),
'                             / NULLIF(sum(cr.weight), 0)', chr(10),
'                      FROM creature_regions cr', chr(10),
'                      JOIN creature_species cs ON cs.species_id = cr.species_id', chr(10),
'                      WHERE cr.region_code = h.region_code AND cs.kind = ''beast''),', chr(10),
'                     600)', chr(10),
'            * horde_world_scale(p_horde_id)', chr(10),
'            * game_config_value(''horde_king_beasts''))),');

    swap := concat(
'        -- Capped since 0377. In a region of billion-health beasts this term', chr(10),
'        -- reaches two hundred trillion, and a King nobody can kill is a wall', chr(10),
'        -- with a timer. The cap is NULL when no line gathered, and LEAST', chr(10),
'        -- ignores NULLs, so the floor still stands alone where it must.', chr(10),
'        LEAST(', chr(10),
'          GREATEST(1000, round(', chr(10),
'            COALESCE((SELECT sum(cs.base_hp * cr.weight)', chr(10),
'                             / NULLIF(sum(cr.weight), 0)', chr(10),
'                      FROM creature_regions cr', chr(10),
'                      JOIN creature_species cs ON cs.species_id = cr.species_id', chr(10),
'                      WHERE cr.region_code = h.region_code AND cs.kind = ''beast''),', chr(10),
'                     600)', chr(10),
'            * horde_world_scale(p_horde_id)', chr(10),
'            * game_config_value(''horde_king_beasts''))),', chr(10),
'          horde_king_line_reach(p_horde_id, p_species_id)),');

    SELECT pg_get_functiondef('horde_king_pool(bigint,bigint)'::regprocedure)
    INTO body;
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_king_pool no longer counts the sea where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The King already standing is brought inside the rule
-- ---------------------------------------------------------------------------
--
-- Proportionally, so any damage already landed still counts for the same share
-- of the fight it was worth when it landed.

UPDATE horde_encounters e
SET max_hp     = horde_king_pool(e.horde_id, e.species_id),
    hp         = GREATEST(1, round(horde_king_pool(e.horde_id, e.species_id)
                                   * (e.hp::numeric / e.max_hp)))::bigint,
    resized_at = now()
WHERE e.kind = 'king'
  AND e.status = 'alive'
  AND e.max_hp > horde_king_pool(e.horde_id, e.species_id);


-- ---------------------------------------------------------------------------
-- Every mortal King is untouched, and the heaven's can be killed
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    bad   TEXT;
    live  RECORD;
    n     INTEGER;
    moved INTEGER;
BEGIN
    -- THE CLAIM IS ABOUT THE CAP, NOT ABOUT HISTORY. A King raised months ago
    -- was sized against the cultivators of that month, so comparing its stored
    -- health to today's formula measures how much everyone has grown - which
    -- is what the second draft of this probe did, and it flagged twenty tides
    -- that this migration never touched.
    --
    -- What actually matters is whether the ceiling BINDS: is the regional
    -- floor, uncapped, ever larger than the line's reach? In the mortal world
    -- it must never be.
    SELECT count(*) INTO n
    FROM beast_hordes h
    JOIN horde_encounters e ON e.horde_id = h.horde_id AND e.kind = 'king';

    SELECT count(*), string_agg(t.horde_id || ' (' || t.region_code || ') floor '
                                || t.floor_at || ' vs reach ' || t.reach, ', ')
    INTO moved, bad
    FROM (
        SELECT h.horde_id, h.region_code,
               GREATEST(1000, round(
                   COALESCE((SELECT sum(cs.base_hp * cr.weight)
                                    / NULLIF(sum(cr.weight), 0)
                             FROM creature_regions cr
                             JOIN creature_species cs
                               ON cs.species_id = cr.species_id
                             WHERE cr.region_code = h.region_code
                               AND cs.kind = 'beast'), 600)
                   * horde_world_scale(h.horde_id)
                   * game_config_value('horde_king_beasts'))) AS floor_at,
               round(horde_king_line_reach(h.horde_id, e.species_id)) AS reach
        FROM beast_hordes h
        JOIN horde_encounters e ON e.horde_id = h.horde_id AND e.kind = 'king'
        JOIN regions r ON r.code = h.region_code
        WHERE COALESCE(r.min_rank, 1) = 1
    ) t
    WHERE t.reach IS NOT NULL AND t.floor_at > t.reach;

    IF moved > 0 THEN
        RAISE EXCEPTION
            'the ceiling bites % mortal tides, so it is not only the heaven: %',
            moved, left(bad, 300);
    END IF;

    RAISE NOTICE
        '% Kings ever raised; the ceiling binds no mortal tide among them', n;

    -- Nothing standing anywhere is now past the cap.
    SELECT string_agg(e.encounter_id || ' (' || h.region_code || ')', ', ')
    INTO bad
    FROM horde_encounters e
    JOIN beast_hordes h ON h.horde_id = e.horde_id
    WHERE e.kind = 'king' AND e.status = 'alive'
      AND e.max_hp > horde_king_pool(e.horde_id, e.species_id);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these standing Kings are still over the cap: %', bad;
    END IF;

    -- And what is standing is a fight rather than a wall.
    FOR live IN
        SELECT e.encounter_id, s.name, e.hp, e.max_hp, h.region_code,
               round(e.max_hp::numeric / NULLIF((
                   SELECT sum(horde_walker_burst(c.player_id, e.species_id))
                   FROM horde_contributions c WHERE c.horde_id = h.horde_id), 0), 1)
               AS bursts
        FROM horde_encounters e
        JOIN beast_hordes h ON h.horde_id = e.horde_id
        JOIN creature_species s ON s.species_id = e.species_id
        WHERE e.kind = 'king' AND e.status = 'alive'
    LOOP
        IF live.bursts IS NOT NULL AND live.bursts > 60 THEN
            RAISE EXCEPTION
                'the % in % still wants % collective bursts - that is not a fight',
                live.name, live.region_code, live.bursts;
        END IF;
        RAISE NOTICE '% in % : % health, about % collective bursts to fell',
            live.name, live.region_code, live.max_hp, live.bursts;
    END LOOP;
END;
$probe$;
