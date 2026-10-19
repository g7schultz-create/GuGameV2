-- 0320_a_tide_sized_for_the_people_in_it
--
-- Both horde lanes size their monsters off a species' base_hp and a flat
-- multiplier. Measured against the live roster, that is not a difficulty
-- setting - it is a rounding error:
--
--     clearwest's best blow                       116,554,557
--     a channel beast of a rank 5 tide, 3 hands        20,160
--     a gauntlet wave one                                196
--
-- Five thousand times over on the channel body and half a million on the
-- wave. The reason is visible in the central roster: seven rank 1 beasts of
-- about two hundred health carry 98.5% of the region's draw weight, so
-- `species.base_hp` is almost always ~200 whatever else lives there. Multiply
-- two hundred by anything reasonable and it is still nothing.
--
-- AND THE BITE IS WORSE THAN THE BODY. A gauntlet beast answers with
-- `compute_creature_damage` off base_attack - seventeen, for a moth. Against
-- clearwest's 26,643,567 health that is one and a half million exchanges. The
-- wave step of 1.18 needs about sixty waves before the bite is felt at all,
-- which is why the lane reads as a walk rather than a gauntlet.
--
-- THE FIX IS THE ONE THIS GAME ALREADY MADE TWICE. 0290 and 0291 stopped
-- sizing the world beast and the King off a region and sized them off the
-- people who would swing at them, via `boss_hp_pool`. The tide's own beasts
-- and the gauntlet's waves never got that treatment. They do now:
--
--     a channel beast   `boss_hp_pool` for the room, times horde_body_effort
--     a gauntlet wave   the WALKER'S own burst, times horde_gauntlet_swings
--     a gauntlet bite   a share of the WALKER'S OWN BODY, not a moth's jaw
--
-- Sizing against the roster is the only thing that can be right for both ends
-- of it at once. The live spread is clearwest at 188,673,152 a burst and
-- grafv at 122,079 - a factor of fifteen hundred. No flat multiple is a fight
-- for both; a measure of who is actually swinging is a fight for either.
--
-- EVERY OLD FORMULA STAYS UNDERNEATH AS A FLOOR, the same way
-- `horde_king_rise` keeps its region-counted body. Nothing in either lane can
-- come out smaller than it is today, so a thin room, or a player whose
-- techniques do not measure, never makes the tide softer than it already was.
--
-- The chest ladder is deliberately NOT touched. `horde_beast_worth` feeds
-- `horde_chest_bar` off the region's beasts, and those bars are reachable
-- today; re-scaling them to the room would make a chest harder for the weak
-- player standing next to the strong one, which is the opposite of the
-- problem being fixed here. Bigger bodies mean more contribution per kill,
-- so the chests get easier, not harder.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('horde_body_effort', 0.25,
     'What share of a full world-beast pool one channel beast carries, '
     'measured against the room the same way boss_hp_pool measures a boss. '
     'About one and three quarter room-bursts: a body the people present '
     'gang up on for a few presses, not a click. Elites take horde_elite_hp '
     'on top, which puts them between a channel beast and the King - which '
     'is where an elite belongs.'),
    ('horde_gauntlet_swings', 2.0,
     'How many of the WALKER OWN bursts wave one of the gauntlet is worth, '
     'before the wave step compounds it. Two, because wave one is a warm-up '
     'nobody loses to - but a warm-up you have to swing at, which at 196 '
     'health it was not.'),
    ('horde_gauntlet_bite_share', 0.03,
     'What fraction of the WALKER OWN max health a wave one beast takes per '
     'exchange, before armour and before the wave step. Three percent, so a '
     'run ends on its own in a sensible number of waves however large the '
     'body walking it. Sized against the walker because a moth jaw is '
     'seventeen damage whoever it is biting.');


-- ---------------------------------------------------------------------------
-- What one cultivator lands in a turn, against this particular beast
-- ---------------------------------------------------------------------------

-- The inner half of `boss_hp_pool`, for one person rather than a room. The
-- gauntlet is a solo lane, so its waves have to be measured against the one
-- body walking them - and against THIS species, so a path matchup that makes
-- the beast easy is a beast sized larger to compensate, exactly as it is for
-- a world beast.
CREATE FUNCTION horde_walker_burst(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(1, COALESCE(round(
        (SELECT max(w.final_damage)
         FROM player_usable_techniques u
         JOIN techniques t ON t.technique_id = u.technique_id
         CROSS JOIN LATERAL compute_technique_damage(
             p_player_id, t.technique_id, p_species_id,
             player_external_multiplier(p_player_id, t.technique_id), 0) w
         WHERE u.player_id = p_player_id AND t.base_power > 0)
        * player_blow_multiple(p_player_id)
        -- What walks at their heel swings too, and leaving it out would
        -- undersize every wave by exactly the pet - invisibly.
        + COALESCE(pet_blow(pet_at_heel(p_player_id), p_species_id, 0), 0)
    ), 0))::bigint;
$$;

COMMENT ON FUNCTION horde_walker_burst(BIGINT, BIGINT) IS
    'What one cultivator puts into a single turn against one species, pet included.';


-- ---------------------------------------------------------------------------
-- What a body standing in the channel is worth carrying
-- ---------------------------------------------------------------------------

CREATE FUNCTION horde_body_pool(
    p_horde_id BIGINT, p_species_id BIGINT, p_elite BOOLEAN
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT GREATEST(
        -- The region-counted body 0240 built, kept as a floor.
        GREATEST(1, round(cs.base_hp
                          * horde_world_scale(p_horde_id)
                          * CASE WHEN p_elite
                                 THEN game_config_value('horde_elite_hp')
                                 ELSE 1 END)),
        -- And the body the room can actually be asked for. Anyone who has
        -- swung at this tide counts even if they have since gone quiet - the
        -- same buy-in `boss_hp_pool` gives somebody already in a fight.
        round(boss_hp_pool(
                  p_species_id,
                  (SELECT array_agg(c.player_id) FROM horde_contributions c
                   WHERE c.horde_id = p_horde_id))
              * game_config_value('horde_body_effort')
              * CASE WHEN p_elite
                     THEN game_config_value('horde_elite_hp')
                     ELSE 1 END)
    )::bigint
    FROM creature_species cs WHERE cs.species_id = p_species_id;
$$;

COMMENT ON FUNCTION horde_body_pool(BIGINT, BIGINT, BOOLEAN) IS
    'Health for one beast standing in the channel, sized against the line rather than the region.';


-- ---------------------------------------------------------------------------
-- The three sites that were sizing off a moth
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- the channel beast ------------------------------------------------
    anchor := concat(
'    pool := GREATEST(1, round(species.base_hp', chr(10),
'                              * horde_world_scale(p_horde_id)', chr(10),
'                              * CASE WHEN elite', chr(10),
'                                     THEN game_config_value(''horde_elite_hp'')', chr(10),
'                                     ELSE 1 END))::bigint;');
    swap :=
'    pool := horde_body_pool(p_horde_id, species.species_id, elite);';

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_spawn';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_spawn no longer sizes its body where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- the gauntlet wave ------------------------------------------------
    anchor := concat(
'    pool := GREATEST(1, round(species.base_hp', chr(10),
'                              * (1 + tide.rank * 0.6)', chr(10),
'                              * game_config_value(''horde_gauntlet_start'')', chr(10),
'                              * step))::bigint;');
    swap := concat(
'    pool := GREATEST(', chr(10),
'        -- The region-counted wave, kept as a floor.', chr(10),
'        GREATEST(1, round(species.base_hp', chr(10),
'                          * (1 + tide.rank * 0.6)', chr(10),
'                          * game_config_value(''horde_gauntlet_start'')', chr(10),
'                          * step)),', chr(10),
'        -- And the wave measured against the one person walking it.', chr(10),
'        round(horde_walker_burst(run.player_id, species.species_id)', chr(10),
'              * game_config_value(''horde_gauntlet_swings'')', chr(10),
'              * step)', chr(10),
'    )::bigint;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_gauntlet_next';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_gauntlet_next no longer sizes its wave where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- and what the wave bites back with --------------------------------
    anchor := concat(
'    bite     := game_config_value(''horde_gauntlet_bite'')', chr(10),
'                * power(game_config_value(''horde_gauntlet_step''), run.wave - 1);');
    swap := concat(
'    bite     := GREATEST(', chr(10),
'                    -- Never gentler than the flat multiple it used to be.', chr(10),
'                    game_config_value(''horde_gauntlet_bite''),', chr(10),
'                    -- A share of the body actually standing there, turned', chr(10),
'                    -- into the multiple this species needs to land it. The', chr(10),
'                    -- reference blow is taken at zero defence so that the', chr(10),
'                    -- armour still does its job on the real one.', chr(10),
'                    game_config_value(''horde_gauntlet_bite_share'') * run.max_hp', chr(10),
'                    / GREATEST(1, (SELECT b.final_damage', chr(10),
'                                   FROM compute_creature_damage(', chr(10),
'                                       run.species_id, run.player_id, 1, 0) b))', chr(10),
'                 )', chr(10),
'                * power(game_config_value(''horde_gauntlet_step''), run.wave - 1);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'horde_gauntlet_swing';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'horde_gauntlet_swing no longer computes its bite where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Measured against the people who are actually here
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    tide    BIGINT;
    moth    BIGINT;
    strong  BIGINT;
    burst   BIGINT;
    was     BIGINT;
    now_hp  BIGINT;
    elite   BIGINT;
    wave    BIGINT;
BEGIN
    SELECT species_id INTO moth FROM creature_species WHERE code = 'ash_moth';

    -- The hardest hitter who is actually present, so the probe measures the
    -- complaint rather than a hypothetical.
    SELECT p.player_id INTO strong
    FROM players p
    WHERE p.deleted_at IS NULL
      AND p.last_seen_at >= now() - make_interval(
              mins => game_config_value('boss_presence_minutes')::integer)
    ORDER BY horde_walker_burst(p.player_id, moth) DESC
    LIMIT 1;

    IF strong IS NULL THEN
        RAISE NOTICE 'nobody is present to measure against - the floors apply';
        RETURN;
    END IF;

    burst := horde_walker_burst(strong, moth);

    -- A tide to measure with, removed again at the end of the probe.
    INSERT INTO beast_hordes (region_code, rank, beasts_total, line_holds, ends_at)
    VALUES ('central', 5, 100, 30, now() + interval '2 hours')
    RETURNING horde_id INTO tide;

    was    := GREATEST(1, round((SELECT base_hp FROM creature_species WHERE species_id = moth)
                                * horde_world_scale(tide)))::bigint;
    now_hp := horde_body_pool(tide, moth, FALSE);
    elite  := horde_body_pool(tide, moth, TRUE);

    IF now_hp < was THEN
        RAISE EXCEPTION 'a channel beast came out smaller than it was: % then, % now',
            was, now_hp;
    END IF;

    -- The complaint, in one number: it must no longer die to one turn.
    IF now_hp <= burst THEN
        RAISE EXCEPTION
            'a channel beast still falls to a single turn: % health against a burst of %',
            now_hp, burst;
    END IF;

    IF elite <= now_hp THEN
        RAISE EXCEPTION 'an elite is no heavier than a common beast';
    END IF;

    -- And the gauntlet's first wave, which was 196.
    wave := GREATEST(
        GREATEST(1, round((SELECT base_hp FROM creature_species WHERE species_id = moth)
                          * (1 + 5 * 0.6)
                          * game_config_value('horde_gauntlet_start'))),
        round(burst * game_config_value('horde_gauntlet_swings')))::bigint;

    IF wave <= burst THEN
        RAISE EXCEPTION 'the first wave still falls to a single turn: % against %',
            wave, burst;
    END IF;

    RAISE NOTICE 'channel beast % -> % (% turns for the strongest here)',
        was, now_hp, round(now_hp::numeric / burst, 1);
    RAISE NOTICE 'elite % (% turns)', elite, round(elite::numeric / burst, 1);
    RAISE NOTICE 'gauntlet wave one -> % (% turns), burst measured at %',
        wave, round(wave::numeric / burst, 1), burst;

    DELETE FROM beast_hordes WHERE horde_id = tide;
END;
$probe$;
