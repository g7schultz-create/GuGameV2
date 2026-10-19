-- 0505_a_thing_that_cannot_hurt_you_is_not_strong_either
--
-- 0502 and 0503 gave a peer creature a body worth swinging at. It still
-- cannot hurt anybody. Measured against the strongest cultivator alive:
--
--     Black Heaven Demon Venerable   immortal_rank 18   bites for 0.05% of a body
--     White Heaven Rebel Venerable   immortal_rank 18   0.03%
--     Marrow Feast Tyrant            immortal_rank 14   0.01%
--
-- The hardest ordinary creature in the game needs two thousand turns to fell
-- a cultivator. So a rogue immortal now has a body that takes nine turns to
-- break and no way to use the nine turns.
--
-- `compute_creature_damage` already carries one attempt at this -
-- `creature_defense_scale_per_rank`, added because "freezing this divisor at
-- rank 9 while a cultivator's defence keeps doubling makes an immortal
-- harmless rather than hard". The reasoning was right and a per-rank divisor
-- was not enough: an attack of 6.98e8 against a defence of 3.1e11 is lost
-- whatever the divisor does, because the two curves were never tied together.
--
-- THE GAME ALREADY SOLVED THIS ONCE. 0468, for the delve: "a thing that
-- cannot hurt you is not strong" - and `delve_tile_kinds.bite` is a SHARE OF
-- MAX HP rather than a number. A share cannot fall behind a body it is
-- measured against. The bestiary gets the same rule as a FLOOR under its
-- existing arithmetic, so nothing anywhere hits softer than it does today:
--
--     beast 4%   elite 7%   rogue 10%   boss 12%   of the body, per turn
--
-- Against the turns-to-fell from 0502 that makes a peer rogue a real fight:
-- nine of your turns to break it, ten of its turns to break you.
--
-- AND IT FADES THE SAME WAY THE BODY DOES. A rank 1 rabbit must not take 4%
-- of a Venerable per bite; outgrowing things is the reward for climbing. So
-- the peer fade comes out of `creature_body_for` into its own function and
-- both readers use it - the body and the bite agree about what a peer is by
-- construction rather than by my remembering to change two places.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value) VALUES
    ('creature_bite_beast',       0.04),
    ('creature_bite_elite',       0.07),
    ('creature_bite_rogue',       0.10),
    ('creature_bite_boss',        0.12),
    ('creature_bite_world',       0.12),
    ('creature_bite_dungeon',     0.09),
    ('creature_bite_tribulation', 0.15)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ---------------------------------------------------------------------------
-- One definition of whether this thing is your peer
-- ---------------------------------------------------------------------------

CREATE FUNCTION creature_peer_share(p_player_id BIGINT, p_species_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $fn$
    -- 1.0 for something at or above your standing, fading as you climb past
    -- it, and 0 once you have thoroughly outgrown it. Extracted from
    -- creature_body_for so that a creature's BODY and its BITE cannot
    -- disagree about what a peer is.
    --
    -- One scale for ranks: realm 1-9 are the mortal realms and 10-18 the
    -- nine fruits, so a creature's `rank` needs no conversion - which 0502
    -- got wrong by doubling it and 0503 corrected.
    SELECT LEAST(1.0, power(
        game_config_value('creature_peer_falloff'),
        GREATEST(0, COALESCE(player_standing(p_player_id), 1)
                    - COALESCE(s.immortal_rank, GREATEST(1, s.rank)))
    ))
    FROM creature_species s WHERE s.species_id = p_species_id;
$fn$;

COMMENT ON FUNCTION creature_peer_share(BIGINT, BIGINT) IS
    'How much of a peer a creature is to a cultivator: 1.0 at or above their standing, fading as they climb past it. The one definition both a creature body and a creature bite are scaled by.';


CREATE OR REPLACE FUNCTION creature_body_for(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_sp     RECORD;
    v_move   BIGINT;
    v_swing  BIGINT := 0;
    v_turns  NUMERIC;
    v_peer   NUMERIC;
    swung    RECORD;
BEGIN
    SELECT s.base_hp, s.base_defense, s.kind
    INTO v_sp
    FROM creature_species s WHERE s.species_id = p_species_id;

    IF v_sp IS NULL THEN
        RETURN 1;
    END IF;

    -- The shared definition, rather than a second copy of the arithmetic.
    v_peer := creature_peer_share(p_player_id, p_species_id);

    IF COALESCE(v_peer, 0) < 0.01 THEN
        RETURN v_sp.base_hp;
    END IF;

    v_turns := CASE v_sp.kind
        WHEN 'beast'  THEN game_config_value('creature_turns_beast')
        WHEN 'elite'  THEN game_config_value('creature_turns_elite')
        WHEN 'rogue'  THEN game_config_value('creature_turns_rogue')
        WHEN 'boss'   THEN game_config_value('creature_turns_boss')
        WHEN 'world'  THEN game_config_value('creature_turns_boss')
        ELSE game_config_value('creature_turns_beast')
    END;

    v_move := dungeon_default_move(p_player_id);
    IF v_move IS NULL THEN
        RETURN v_sp.base_hp;
    END IF;

    BEGIN
        SELECT * INTO swung FROM player_swing(
            p_player_id, v_move, p_species_id,
            9223372036854775807::bigint, COALESCE(v_sp.base_defense, 0),
            NULL, NULL, 0, 'rehearsal', -p_species_id);
        v_swing := GREATEST(0, swung.dealt);
        RAISE EXCEPTION 'rehearsal-done';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rehearsal-done' THEN RAISE; END IF;
    END;

    RETURN GREATEST(
        v_sp.base_hp,
        GREATEST(1, round(v_swing * v_turns * v_peer))
    )::BIGINT;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- And the bite gets a floor it cannot fall behind
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef(
        'compute_creature_damage(bigint,bigint,numeric,bigint)'::regprocedure);

    anchor := '        CASE WHEN raw <= 0 THEN 0' || chr(10)
           || '             ELSE GREATEST(1, round(after_defense))::BIGINT' || chr(10)
           || '        END;';

    IF strpos(src, anchor) = 0 THEN
        anchor := replace(anchor, chr(10), chr(13) || chr(10));
        IF strpos(src, anchor) = 0 THEN
            RAISE EXCEPTION
                'the final_damage expression in compute_creature_damage is not as 0015 wrote it';
        END IF;
    END IF;

    src := replace(src, anchor,
        '        CASE WHEN raw <= 0 THEN 0' || chr(10) ||
        '             ELSE GREATEST(' || chr(10) ||
        '                 -- what the arithmetic says, unchanged' || chr(10) ||
        '                 GREATEST(1, round(after_defense))::BIGINT,' || chr(10) ||
        '                 -- and a floor it cannot fall behind: a share of the' || chr(10) ||
        '                 -- body it is biting, faded by how far the cultivator' || chr(10) ||
        '                 -- stands above it. 0468 settled this for the delve -' || chr(10) ||
        '                 -- "a thing that cannot hurt you is not strong" - and' || chr(10) ||
        '                 -- the bestiary was still measuring a flat attack' || chr(10) ||
        '                 -- against a defence that doubles every realm.' || chr(10) ||
        '                 COALESCE((' || chr(10) ||
        '                     SELECT round(pp.max_hp' || chr(10) ||
        '                            * creature_peer_share(p_defender_player_id,' || chr(10) ||
        '                                                  p_attacker_species_id)' || chr(10) ||
        '                            * game_config_value(''creature_bite_'' || cs.kind))' || chr(10) ||
        '                     FROM player_physique pp, creature_species cs' || chr(10) ||
        '                     WHERE pp.player_id = p_defender_player_id' || chr(10) ||
        '                       AND cs.species_id = p_attacker_species_id' || chr(10) ||
        '                 ), 0)::BIGINT' || chr(10) ||
        '             )' || chr(10) ||
        '        END;');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A peer can hurt you and a rabbit cannot
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_hp    BIGINT;
    v_stand INTEGER;
    v_rogue BIGINT;
    v_bite  BIGINT;
    v_weak  BIGINT;
    v_before BIGINT;
    v_n     INTEGER;
BEGIN
    SELECT p.player_id, pp.max_hp, player_standing(p.player_id)
    INTO v_pid, v_hp, v_stand
    FROM players p JOIN player_physique pp USING (player_id)
    WHERE p.deleted_at IS NULL AND player_standing(p.player_id) >= 17
      AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'no high-standing cultivator to measure against';
    END IF;

    -- A peer now takes a real share of the body per turn.
    SELECT s.species_id INTO v_rogue FROM creature_species s
    WHERE s.kind = 'rogue' ORDER BY COALESCE(s.immortal_rank, s.rank) DESC LIMIT 1;

    SELECT d.final_damage INTO v_bite
    FROM compute_creature_damage(v_rogue, v_pid, 1.0, NULL) d;

    IF v_bite * 100 < v_hp * game_config_value('creature_bite_rogue') * 90 THEN
        RAISE EXCEPTION
            'the toughest rogue still bites for % of a % body', v_bite, v_hp;
    END IF;

    RAISE NOTICE
        'the toughest rogue bites % of a % body - %%% per turn',
        v_bite, v_hp, round(100.0 * v_bite / v_hp, 1);

    -- And something thoroughly outgrown bites exactly what it did before, so
    -- ordinary hunting is untouched.
    SELECT s.species_id INTO v_weak FROM creature_species s
    WHERE s.immortal_rank IS NULL AND s.rank <= GREATEST(1, v_stand - 6)
    ORDER BY s.rank, s.base_attack LIMIT 1;

    IF v_weak IS NOT NULL THEN
        IF creature_peer_share(v_pid, v_weak) >= 0.01 THEN
            RAISE EXCEPTION
                'a rank % creature still counts as a peer of standing %',
                (SELECT rank FROM creature_species WHERE species_id = v_weak), v_stand;
        END IF;
        SELECT d.final_damage INTO v_before
        FROM compute_creature_damage(v_weak, v_pid, 1.0, NULL) d;
        IF v_before > v_hp / 100 THEN
            RAISE EXCEPTION
                'a creature a realm % cultivator outgrew bites % of a % body',
                v_stand, v_before, v_hp;
        END IF;
    END IF;

    -- Nothing in the game bites softer than it did. The floor is a GREATEST.
    SELECT count(*) INTO v_n
    FROM creature_species s
    CROSS JOIN LATERAL compute_creature_damage(s.species_id, v_pid, 1.0, NULL) d
    WHERE d.final_damage < 1;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% creatures bite for nothing at all', v_n;
    END IF;

    -- The body and the bite agree about peers, by sharing one function.
    IF pg_get_functiondef('creature_body_for(bigint,bigint)'::regprocedure)
       NOT LIKE '%creature_peer_share(p_player_id, p_species_id)%' THEN
        RAISE EXCEPTION 'the body still computes its own peer fade';
    END IF;
    IF pg_get_functiondef(
        'compute_creature_damage(bigint,bigint,numeric,bigint)'::regprocedure)
       NOT LIKE '%creature_peer_share(p_defender_player_id%' THEN
        RAISE EXCEPTION 'the bite does not use the shared peer fade';
    END IF;
END;
$probe$;
