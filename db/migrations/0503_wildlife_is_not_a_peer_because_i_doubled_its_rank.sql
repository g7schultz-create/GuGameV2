-- 0503_wildlife_is_not_a_peer_because_i_doubled_its_rank
--
-- 0502 sized a creature against the cultivator in so far as it is their peer,
-- and worked out how far above it they stand like this:
--
--     v_its := COALESCE(s.immortal_rank, GREATEST(1, s.rank * 2));
--
-- The doubling was my invention and it is wrong. I reasoned that creature
-- `rank` runs 1 to 9 against a realm ladder running 1 to 18, so the two
-- needed putting on one scale. They are already on one scale: realm ranks 1
-- to 9 ARE the mortal realms, and 10 to 18 are the nine fruits above them. A
-- rank 9 beast is a rank 9 beast.
--
-- What the doubling did, measured immediately after:
--
--     Night Terror Beast        bestiary 8.6e8  ->  brought 7.61e15
--     Sovereign Nine-Tail Fox   bestiary 8.9e6  ->  brought 1.19e16
--
-- Every rank 9 beast in the game became a peer of a realm 18 cultivator and
-- grew by seven orders of magnitude. Ordinary wildlife - the thing a hunt
-- kills for materials - would have taken three turns each for the strongest
-- players in the game, which quietly breaks the gathering economy rather than
-- the combat one. It shipped for exactly one migration.
--
-- WITHOUT THE DOUBLING the shape is the one I actually wanted:
--
--     rank 18 rogue   vs realm 18    0 above    a real fight
--     rank 13 rogue   vs realm 18    5 above    0.45^5, a shadow of one
--     rank 9 beast    vs realm 18    9 above    under the floor, so base_hp
--
-- So the peers of a Venerable are the rogue immortals, which is what 0359
-- built them for - "rogue immortals walk the heavens" - and the wildlife
-- stays wildlife. The heavens' beasts are rank 9 with no immortal rank; they
-- are ambient, not opposition, and a cultivator who has outgrown them is
-- supposed to have outgrown them.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION creature_body_for(p_player_id BIGINT, p_species_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_sp     RECORD;
    v_move   BIGINT;
    v_swing  BIGINT := 0;
    v_turns  NUMERIC;
    v_stand  INTEGER;
    v_its    INTEGER;
    v_peer   NUMERIC;
    swung    RECORD;
BEGIN
    SELECT s.base_hp, s.base_defense, s.kind, s.rank, s.immortal_rank
    INTO v_sp
    FROM creature_species s WHERE s.species_id = p_species_id;

    IF v_sp IS NULL THEN
        RETURN 1;
    END IF;

    -- How far above this thing the cultivator stands. One scale, because
    -- there only ever was one: realm ranks 1-9 are the mortal realms and
    -- 10-18 the nine fruits, so a creature's `rank` needs no conversion.
    -- 0502 doubled it and turned every rank 9 beast into a Venerable's peer.
    v_its := COALESCE(v_sp.immortal_rank, GREATEST(1, v_sp.rank));
    v_stand := COALESCE(player_realm_rank(p_player_id), 1);

    v_peer := LEAST(1.0, power(game_config_value('creature_peer_falloff'),
                               GREATEST(0, v_stand - v_its)));

    IF v_peer < 0.01 THEN
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
-- Wildlife is wildlife and a rogue is a fight
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_stand INTEGER;
    v_swing BIGINT;
    v_grown INTEGER;
    v_rogue BIGINT;
    v_base  BIGINT;
    v_body  BIGINT;
BEGIN
    SELECT p.player_id, COALESCE(player_realm_rank(p.player_id), 1)
    INTO v_pid, v_stand
    FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
      AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
      AND COALESCE(player_realm_rank(p.player_id), 1) >= 17
    ORDER BY player_blow_multiple(p.player_id) DESC LIMIT 1;

    -- THE ONE 0502 GOT WRONG. Nothing a realm 18 cultivator has outgrown may
    -- come out above its own bestiary body - which for every mortal-rank
    -- creature means exactly its bestiary body.
    SELECT count(*) INTO v_grown
    FROM creature_species s
    WHERE s.immortal_rank IS NULL
      AND s.rank <= v_stand - 3
      AND creature_body_for(v_pid, s.species_id) <> s.base_hp;
    IF v_grown > 0 THEN
        RAISE EXCEPTION
            '% creatures a realm % cultivator has outgrown are still being grown',
            v_grown, v_stand;
    END IF;

    -- And a peer still stands up. The toughest rogue is the hardest ordinary
    -- thing in the game and must not fall to one blow.
    SELECT s.species_id, s.base_hp INTO v_rogue, v_base
    FROM creature_species s WHERE s.kind = 'rogue'
    ORDER BY COALESCE(s.immortal_rank, s.rank) DESC, s.base_hp DESC LIMIT 1;

    v_body := creature_body_for(v_pid, v_rogue);
    SELECT GREATEST(1, (player_swing(
               v_pid, dungeon_default_move(v_pid), v_rogue,
               9223372036854775807::bigint, 0::bigint)).dealt)
    INTO v_swing;

    IF v_body <= v_swing THEN
        RAISE EXCEPTION
            'the toughest rogue falls to one swing again: % against %',
            v_body, v_swing;
    END IF;

    -- Nothing anywhere is softer than the bestiary says.
    SELECT count(*) INTO v_grown
    FROM creature_species s
    WHERE creature_body_for(v_pid, s.species_id) < s.base_hp;
    IF v_grown > 0 THEN
        RAISE EXCEPTION '% creatures came out under their own body', v_grown;
    END IF;

    RAISE NOTICE
        'rogue brings % against a swing of %; everything a realm % cultivator outgrew is untouched',
        v_body, v_swing, v_stand;
END;
$probe$;
