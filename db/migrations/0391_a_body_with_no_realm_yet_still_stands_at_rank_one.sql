-- 0391_a_body_with_no_realm_yet_still_stands_at_rank_one
--
-- 0390's realm gate reads the opener's rank and falls back to 0 when there is
-- no `player_cultivation` row:
--
--     COALESCE((SELECT r.rank FROM player_cultivation pc ...), 0)
--
-- Zero is below the bottom of the realm ladder, so a character without that
-- row is refused EVERY door including the first one - The Sunken Armoury,
-- written for rank 1, which should open for anybody who can walk.
--
-- The probe in 0390 could not see it: every live cultivator has a cultivation
-- row, so every live cultivator was measured correctly. Five tests found it
-- immediately, which is what they are for.
--
-- One is the right fallback rather than zero. The realm ladder starts at 1 and
-- a body that has not been given a place on it has not been given a place
-- BELOW it. A character in that state can do nothing else in this game either;
-- being told the first room in the world is beyond them is a worse answer than
-- letting them try it.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_open';

    IF body IS NULL THEN
        RAISE EXCEPTION 'dungeon_open is missing';
    END IF;

    anchor := concat(
'                   WHERE pc.player_id = p_player_id), 0)', chr(10),
'         + game_config_value(''dungeon_realm_reach'') THEN');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_open no longer falls back where 0390 put it';
    END IF;

    EXECUTE replace(body, anchor, concat(
'                   WHERE pc.player_id = p_player_id), 1)', chr(10),
'         + game_config_value(''dungeon_realm_reach'') THEN'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The first room opens for anybody, and the deep ones still do not
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who     BIGINT;
    v_shallow SMALLINT;
    v_deep    SMALLINT;
    v_opened  BOOLEAN := FALSE;
BEGIN
    SELECT dg.dungeon_id INTO v_shallow FROM dungeons dg
    ORDER BY dg.realm_rank ASC LIMIT 1;
    SELECT dg.dungeon_id INTO v_deep FROM dungeons dg
    ORDER BY dg.realm_rank DESC LIMIT 1;

    -- A character with no realm at all, which is the state that found this.
    INSERT INTO players (discord_id, discord_name)
    VALUES (-773911, 'probe-no-realm')
    RETURNING player_id INTO v_who;

    INSERT INTO player_physique (player_id, physique_id)
    VALUES (v_who, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1));

    BEGIN
        PERFORM dungeon_open(v_who, v_shallow, 'normal');
        v_opened := TRUE;
    EXCEPTION
        WHEN check_violation THEN
            RAISE EXCEPTION
                'the first room in the world refused a body with no realm: %',
                SQLERRM;
    END;

    IF NOT v_opened THEN
        RAISE EXCEPTION 'the first room did not open and did not refuse';
    END IF;

    DELETE FROM dungeon_raiders WHERE player_id = v_who;
    DELETE FROM dungeon_runs WHERE leader_id = v_who;

    -- And the deepest one is still shut, which is the whole point of 0390.
    BEGIN
        PERFORM dungeon_open(v_who, v_deep, 'normal');
        RAISE EXCEPTION 'the deepest room opened for a body with no realm';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%realm you have not reached%' THEN
                RAISE;
            END IF;
    END;

    DELETE FROM dungeon_raiders WHERE player_id = v_who;
    DELETE FROM dungeon_runs WHERE leader_id = v_who;
    DELETE FROM player_physique WHERE player_id = v_who;
    DELETE FROM players WHERE player_id = v_who;

    RAISE NOTICE 'the first room opens for anybody; the last still does not';
END;
$probe$;
