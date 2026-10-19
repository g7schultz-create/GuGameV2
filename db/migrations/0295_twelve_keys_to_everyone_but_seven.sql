-- 0295_twelve_keys_to_everyone_but_seven
--
-- Twelve dungeon keys to every live cultivator except seven named accounts.
--
-- WHO IS EXCLUDED, AND WHAT IT ACTUALLY CHANGES. The seven are given by
-- Discord id below. Six of them - couhpgnort, s4pttps4, s5pttps5, s7pttps7,
-- shikute18_ and tohnoemily - were all made on the same day, hold two
-- materials each and know no techniques, so they were never going to spend a
-- key. The seventh is m_i_y_u_k_i., who is the deepest cultivator on the
-- server. So in practice this excludes one real player and six accounts that
-- have not started.
--
-- WHY THE POPULATION IS NOT "CONFIRMED CHARACTERS". The obvious filter is
-- `player_character.confirmed_at IS NOT NULL`, which is what `horde_watchers`
-- uses. It would have been wrong here: night.moth_ never pressed confirm and
-- is nevertheless playing - fourteen materials, a technique, a body, and a
-- blow recorded against the world beast. Filtering on confirmation would have
-- quietly cut a real player out of a giveaway they were entitled to, and
-- nothing would have reported it.
--
-- So the population is the literal one: alive, a real Discord account, not
-- one of the seven. Seventeen cultivators, holding fifty-seven keys between
-- them today, receiving two hundred and four more.
--
-- A key is a material, not a currency - 0228 settled that - so this is
-- `grant_material` and nothing else. Keys already held are added to, never
-- replaced.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    barred BIGINT[] := ARRAY[
        1448195548887908494,
        1447607969775616081,
        1447607041089867856,
        1447606113963868283,
        1442155677568073770,
         819217525015314442,
        1405983698171465762
    ];
    each_gets INTEGER := 12;
    who       RECORD;
    given     INTEGER := 0;
    before    BIGINT;
    after     BIGINT;
BEGIN
    SELECT COALESCE(sum(quantity), 0) INTO before
    FROM player_materials WHERE material_code = 'dungeon_key';

    FOR who IN
        SELECT p.player_id, p.discord_name
        FROM players p
        WHERE p.deleted_at IS NULL
          AND p.discord_id > 0
          AND NOT (p.discord_id = ANY (barred))
        ORDER BY p.player_id
    LOOP
        PERFORM grant_material(who.player_id, 'dungeon_key', each_gets);
        given := given + 1;
    END LOOP;

    SELECT COALESCE(sum(quantity), 0) INTO after
    FROM player_materials WHERE material_code = 'dungeon_key';

    IF given = 0 THEN
        RAISE EXCEPTION 'nobody received a key';
    END IF;

    -- The house's own escrow holds keys people have listed, so this counts
    -- the change rather than the total: what arrived must be exactly what was
    -- handed out, and nothing else may have moved.
    IF after - before <> given * each_gets THEN
        RAISE EXCEPTION
            'handed % cultivators % keys each but the world gained %',
            given, each_gets, after - before;
    END IF;

    RAISE NOTICE '% cultivators received % keys each; % keys in the world now',
        given, each_gets, after;
END;
$$;


-- ---------------------------------------------------------------------------
-- The seven got nothing, and everybody else got exactly twelve
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    barred BIGINT[] := ARRAY[
        1448195548887908494, 1447607969775616081, 1447607041089867856,
        1447606113963868283, 1442155677568073770, 819217525015314442,
        1405983698171465762
    ];
    missed  TEXT := '';
    who     RECORD;
BEGIN
    -- Every excluded account is still here and still owns whatever it owned.
    FOR who IN
        SELECT p.discord_id, p.discord_name FROM players p
        WHERE p.discord_id = ANY (barred)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM players p2
                       WHERE p2.discord_id = who.discord_id
                         AND p2.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'excluding % deleted them', who.discord_name;
        END IF;
    END LOOP;

    IF (SELECT count(*) FROM players p WHERE p.discord_id = ANY (barred)) <> 7 THEN
        RAISE EXCEPTION 'one of the seven named accounts does not exist';
    END IF;

    -- And nobody who should have been paid was skipped.
    FOR who IN
        SELECT p.discord_name FROM players p
        WHERE p.deleted_at IS NULL AND p.discord_id > 0
          AND NOT (p.discord_id = ANY (barred))
          AND NOT EXISTS (
              SELECT 1 FROM player_materials m
              WHERE m.player_id = p.player_id
                AND m.material_code = 'dungeon_key'
                AND m.quantity >= 12)
    LOOP
        missed := missed || ' ' || who.discord_name;
    END LOOP;

    IF missed <> '' THEN
        RAISE EXCEPTION 'these cultivators are short of their twelve:%', missed;
    END IF;
END;
$$;
