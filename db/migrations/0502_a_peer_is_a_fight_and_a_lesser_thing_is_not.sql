-- 0502_a_peer_is_a_fight_and_a_lesser_thing_is_not
--
-- The last lane sized off a table instead of a cultivator, and the worst of
-- them. `battle_open` sets a creature's body straight from the bestiary:
--
--     VALUES (b_id, 1, 1, p_species_id, ..., species.base_hp, species.base_hp, ...)
--
-- That is every ordinary fight in the game - every hunt, every rogue ambush,
-- every encounter while exploring, in every region. And the immortal curve it
-- reads is `2.0e9 * 2^(rank-10)`:
--
--     immortal_rank 10   2.0e9        immortal_rank 18   5.1e11
--
-- against a measured swing of 2.35e15 from the strongest cultivator alive. A
-- rank 18 rogue immortal - a peer, the hardest ordinary thing in the game -
-- is one-shot FOUR THOUSAND SIX HUNDRED TIMES OVER. At the old flat caps it
-- was still a thousand times over, so this is not something 0496 caused; it
-- is the oldest and largest hole of the lot, and it is why the heavens feel
-- empty.
--
-- WHY NOT RESCALE THE CURVE. I would have to guess player damage at every
-- rank from 10 to 18 having only measured 17 and 18, and the guess would rot
-- the next time anything moved - which is the mistake this session has
-- already made twice. Every lane that works sizes itself against the party at
-- encounter time. This one should too.
--
-- BUT NOT UNCONDITIONALLY, and this is the part worth getting right. Scaling
-- every creature to the cultivator would hand a Venerable a rank 1 rabbit
-- with ten quadrillion health. Outgrowing things is the REWARD for climbing,
-- and taking it away would be a worse bug than the one being fixed.
--
-- So the body is sized to the cultivator only in so far as the creature is
-- their PEER, and `base_hp` stands alone once it is beneath them:
--
--     creature at or above your standing   a real fight, sized to you
--     one rank below                       most of the way there
--     far below                            base_hp, and it dies in a blow
--
-- The falloff is `creature_peer_falloff ^ (your standing - its rank)`, so the
-- table keeps deciding relative difficulty WITHIN a rank - a Radiant beast is
-- still softer than an Immemorial one - while the absolute numbers stop being
-- a guess that ages.
--
-- `base_hp` is also a floor, always. Nothing gets easier than it is today:
-- a weak cultivator meeting something terrible still meets the whole of it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value) VALUES
    -- Turns a peer should last for the cultivator who met it, by what it is.
    ('creature_turns_beast',   3),
    ('creature_turns_elite',   6),
    ('creature_turns_rogue',   9),
    ('creature_turns_boss',   12),
    -- How fast a creature stops being your peer as you climb past it.
    ('creature_peer_falloff', 0.45)
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;


-- ---------------------------------------------------------------------------
-- What this creature is worth as a body, to this cultivator
-- ---------------------------------------------------------------------------

CREATE FUNCTION creature_body_for(p_player_id BIGINT, p_species_id BIGINT)
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

    -- How far above this thing the cultivator stands. An immortal creature
    -- carries its rank in `immortal_rank`; everything else in `rank`, which
    -- runs 1 to 9 against a realm ladder that runs 1 to 18, so a mortal
    -- creature's rank is doubled to put the two on one scale.
    v_its := COALESCE(v_sp.immortal_rank, GREATEST(1, v_sp.rank * 2));
    v_stand := COALESCE(player_realm_rank(p_player_id), 1);

    v_peer := LEAST(1.0, power(game_config_value('creature_peer_falloff'),
                               GREATEST(0, v_stand - v_its)));

    -- Below the point where it is anybody's peer, the bestiary answers alone
    -- and the thing dies in a blow, which is the whole reward for climbing.
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

    -- One real swing, rolled back. The same trick trial_rehearse, delve_rehearse
    -- and dungeon_rehearse use, for the same reason: no fitted ratio survives a
    -- build whose damage is multiplied by a number between one and thirty.
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

    -- A floor, always. Nothing in the game gets softer than it is today.
    RETURN GREATEST(
        v_sp.base_hp,
        GREATEST(1, round(v_swing * v_turns * v_peer))
    )::BIGINT;
END;
$fn$;

COMMENT ON FUNCTION creature_body_for(BIGINT, BIGINT) IS
    'The body an ordinary creature brings to a fight with this cultivator: a rehearsed swing times the turns its kind should last, faded out as the cultivator climbs past its rank, and never below the bestiary''s own number. The bestiary keeps deciding relative difficulty; it stops deciding absolute size.';


-- ---------------------------------------------------------------------------
-- And the one place an ordinary fight begins
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('battle_open(bigint,bigint)'::regprocedure);

    anchor := '            species.base_hp, species.base_hp,';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the body assignment in battle_open is not there exactly once';
    END IF;

    src := replace(src, anchor,
        '            -- Sized to the cultivator in so far as this thing is' || chr(10) ||
        '            -- their peer, and never below the bestiary''s own body.' || chr(10) ||
        '            -- Was `species.base_hp` twice, which left a rank 18' || chr(10) ||
        '            -- rogue one-shot four thousand times over.' || chr(10) ||
        '            creature_body_for(p_player_id, p_species_id),' || chr(10) ||
        '            creature_body_for(p_player_id, p_species_id),');

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A peer stands up and a lesser thing still falls over
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_peer  BIGINT;
    v_weak  BIGINT;
    v_body  BIGINT;
    v_swing BIGINT;
    v_base  BIGINT;
    v_n     INTEGER;
    v_b     RECORD;
BEGIN
    SELECT p.player_id INTO v_pid FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
      AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
      AND COALESCE(player_realm_rank(p.player_id), 1) >= 17
    ORDER BY player_blow_multiple(p.player_id) DESC LIMIT 1;

    IF v_pid IS NULL THEN
        RAISE EXCEPTION 'no high-realm cultivator to measure against';
    END IF;

    -- A peer: the toughest rogue in the game, which is the hardest ordinary
    -- thing a cultivator can meet.
    SELECT s.species_id, s.base_hp INTO v_peer, v_base
    FROM creature_species s WHERE s.kind = 'rogue'
    ORDER BY COALESCE(s.immortal_rank, s.rank) DESC, s.base_hp DESC LIMIT 1;

    v_body := creature_body_for(v_pid, v_peer);

    SELECT GREATEST(1, (player_swing(
               v_pid, dungeon_default_move(v_pid), v_peer,
               9223372036854775807::bigint, 0::bigint)).dealt)
    INTO v_swing;

    IF v_body <= v_swing THEN
        RAISE EXCEPTION
            'the toughest rogue still falls to one swing: % against %',
            v_body, v_swing;
    END IF;
    IF v_body < v_base THEN
        RAISE EXCEPTION 'a creature came out under its own bestiary body';
    END IF;

    RAISE NOTICE
        'the toughest rogue: bestiary said %, it now brings % against a swing of %',
        v_base, v_body, v_swing;

    -- And a lesser thing is still a lesser thing. A rank 1 beast must not
    -- grow to meet a realm 18 cultivator.
    SELECT s.species_id, s.base_hp INTO v_weak, v_base
    FROM creature_species s WHERE s.kind = 'beast' AND s.immortal_rank IS NULL
    ORDER BY s.rank, s.base_hp LIMIT 1;

    IF creature_body_for(v_pid, v_weak) <> v_base THEN
        RAISE EXCEPTION
            'a rank % beast was puffed up from % to % for a realm % cultivator',
            (SELECT rank FROM creature_species WHERE species_id = v_weak),
            v_base, creature_body_for(v_pid, v_weak), player_realm_rank(v_pid);
    END IF;

    -- Nothing anywhere gets softer than the bestiary says.
    SELECT count(*) INTO v_n
    FROM creature_species s
    WHERE creature_body_for(v_pid, s.species_id) < s.base_hp;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% creatures came out under their own body', v_n;
    END IF;

    -- The patch landed and a fight actually opens.
    IF pg_get_functiondef('battle_open(bigint,bigint)'::regprocedure)
       NOT LIKE '%creature_body_for(p_player_id, p_species_id)%' THEN
        RAISE EXCEPTION 'battle_open still reads base_hp';
    END IF;

    BEGIN
        DELETE FROM player_active_battle WHERE player_id = v_pid;
        PERFORM battle_open(v_pid, v_peer);

        SELECT c.max_hp, c.current_hp INTO v_b
        FROM battle_combatants c
        JOIN player_active_battle ab ON ab.battle_id = c.battle_id
        WHERE ab.player_id = v_pid AND c.side = 1;

        IF v_b.max_hp IS NULL OR v_b.max_hp <= v_swing THEN
            RAISE EXCEPTION 'a fight opened with a body of %', v_b.max_hp;
        END IF;
        IF v_b.max_hp <> v_b.current_hp THEN
            RAISE EXCEPTION 'a fight opened already wounded: % of %',
                v_b.current_hp, v_b.max_hp;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    IF EXISTS (SELECT 1 FROM battle_effects WHERE scope = 'rehearsal') THEN
        RAISE EXCEPTION 'rehearsal effects survived a rollback';
    END IF;
END;
$probe$;
