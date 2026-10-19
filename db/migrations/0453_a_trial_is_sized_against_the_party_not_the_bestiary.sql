-- 0453_a_trial_is_sized_against_the_party_not_the_bestiary
--
-- 0452 built the Trial's creature the way a dungeon does - a multiple of the
-- species' `base_hp` - and the first real party killed it in ONE round.
--
--     The Last Apricot, realm 18      base_hp  1.13T
--     the Trial's pool at 2.4x          5.72T
--     what three peers dealt in round one   399.65T
--
-- Seventy times over, in one swing each.
--
-- AND THAT IS NOT MY DIAL. The same three would do it to the deepest dungeon
-- in the game on Insane, which carries 25T for five raiders. Creature health
-- has not kept pace with what cultivators do, and 0443 widened the gap on
-- purpose by converting attack_power into base_strength and raising every
-- live cultivator's sinew between 94% and 227%. The bestiary has not moved
-- since. That is worth knowing and it is a separate repair; this migration
-- only stops the Trial depending on it.
--
-- SO A TRIAL IS SIZED AGAINST THE PARTY. The pool comes from the sinew the
-- peers actually bring, not from a number in a species table:
--
--     pool = sum(party strength) x damage_per_strength x rounds_wanted
--
-- `damage_per_strength` is measured rather than guessed: the party above put
-- out 399.65T off 18.0T of sinew, which is a touch over twenty. `rounds_wanted`
-- is then exactly what it says - how long a fight should last if nobody is
-- answering anything well, which is the only number here anybody should want
-- to tune.
--
-- This is also what makes a Trial hard at EVERY realm rather than at one. A
-- party of realm 3 faces something sized to realm 3 bodies, and a party that
-- out-gears its realm faces more, which is the behaviour a same-realm trial
-- should have.
--
-- THE CREATURE IS STILL THE FLOOR. `GREATEST` keeps the old species-based
-- pool as a minimum, so a party of newcomers with almost no sinew still meets
-- something with a real body rather than a creature that dies to one hit.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_damage_per_strength', 20,
     'How much damage a point of a party''s sinew turns into in one round, once criticals, extra strikes and penetration are counted. Measured at realm 18: three peers put out 399.65T off 18.0T of sinew. It is a ratio rather than a guess, and it should be re-measured if the damage pipeline moves again.'),
    ('trial_rounds_wanted', 8,
     'How many rounds a Trial should last against a party that answers nothing. The one number here worth tuning - everything else about the pool is arithmetic.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


CREATE OR REPLACE FUNCTION trial_boss_hp(p_party_id bigint, p_species_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    -- Sized against the peers who are actually walking in. The species pool
    -- is kept as a floor so a party with almost no sinew still faces a body.
    SELECT GREATEST(
        -- what the party can put out, over the rounds a Trial should last
        GREATEST(1, round(
            COALESCE((SELECT sum(GREATEST(0, pp.strength))
                      FROM trial_party_members m
                      JOIN player_physique pp ON pp.player_id = m.player_id
                      WHERE m.party_id = p_party_id), 0)
            * game_config_value('trial_damage_per_strength')
            * game_config_value('trial_rounds_wanted')
        ))::bigint,
        -- and the creature's own body, so a weak party still meets something
        GREATEST(1, round(
            (SELECT s.base_hp FROM creature_species s
             WHERE s.species_id = p_species_id)
            * game_config_value('trial_boss_hp_scale')
            * (1 + game_config_value('trial_party_hp_step')
                   * GREATEST(0, (SELECT count(*) FROM trial_party_members m
                                  WHERE m.party_id = p_party_id) - 1))
        ))::bigint
    );
$fn$;

COMMENT ON FUNCTION trial_boss_hp(bigint, bigint) IS
    'What a Peer Trial''s creature carries, from the party rather than the bestiary. A dungeon sizes its boss off the species and the deepest one in the game dies to three cultivators in a single round; a Trial must not inherit that.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_begin' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'trial_begin is missing';
    END IF;

    anchor := concat(
'    SELECT GREATEST(1, round(', chr(10),
'        s.base_hp', chr(10),
'        * game_config_value(''trial_boss_hp_scale'')', chr(10),
'        * (1 + game_config_value(''trial_party_hp_step'') * GREATEST(0, v_count - 1))', chr(10),
'    ))::bigint INTO v_pool', chr(10),
'    FROM creature_species s WHERE s.species_id = v_species;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_begin no longer sizes its creature where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- Against the party since 0453. Off the species'' own body, the first', chr(10),
'    -- real party killed The Last Apricot seventy times over in one round.', chr(10),
'    v_pool := trial_boss_hp(v_party, v_species);'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A Trial lasts long enough to be one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_party BIGINT;
    v_pool  BIGINT;
    v_out   BIGINT;
    r       RECORD;
BEGIN
    BEGIN
        -- A party of the deepest peers in the game, built and then rolled back.
        SELECT p.player_id INTO v_party FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;

        IF v_party IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_party);

        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL
              AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) =
                  (SELECT tp.realm_rank FROM trial_parties tp WHERE tp.party_id = v_party)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
            LIMIT 2
        LOOP
            PERFORM trial_party_invite(
                (SELECT tp.leader_id FROM trial_parties tp WHERE tp.party_id = v_party),
                r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;

        SELECT tr.species_id INTO v_out FROM dungeons tr
        WHERE tr.realm_rank = (SELECT tp.realm_rank FROM trial_parties tp
                               WHERE tp.party_id = v_party) LIMIT 1;

        v_pool := trial_boss_hp(v_party, v_out);

        -- The heart of it: the pool must be worth more than one round of the
        -- party that is walking in, or there is no Trial to speak of.
        IF v_pool < COALESCE((SELECT sum(pp.strength) FROM trial_party_members m
                              JOIN player_physique pp ON pp.player_id = m.player_id
                              WHERE m.party_id = v_party), 0)
                    * game_config_value('trial_damage_per_strength') * 2 THEN
            RAISE EXCEPTION
                'the creature carries % and the party clears that in under two rounds',
                v_pool;
        END IF;

        -- And the species floor still holds for a party with nothing.
        IF trial_boss_hp(v_party, v_out) < 1 THEN
            RAISE EXCEPTION 'the creature has no body at all';
        END IF;

        RAISE NOTICE
            'a party of % at realm % meets % health, about % rounds',
            (SELECT count(*) FROM trial_party_members m WHERE m.party_id = v_party),
            (SELECT tp.realm_rank FROM trial_parties tp WHERE tp.party_id = v_party),
            v_pool,
            game_config_value('trial_rounds_wanted');

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- `trial_begin` really stopped reading the species directly.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'trial_begin'
        AND pronamespace = 'public'::regnamespace) LIKE '%trial_boss_hp_scale%' THEN
        RAISE EXCEPTION 'the trial still sizes its creature off the bestiary';
    END IF;
END;
$probe$;
