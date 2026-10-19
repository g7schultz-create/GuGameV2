-- 0262_a_cultivator_leaves_home_with_a_purse
--
-- A new character is handed a manual, a technique, and nothing to spend. The
-- second technique costs 25 spirit stones and the shelf is full of them, so
-- the first real decision in the game is one a newcomer cannot make until they
-- have hunted enough to afford it. Meanwhile woctora holds 9 stones,
-- lanttenna 9, shinonn 16, night_bloom 14, twilightreader and yoski_36 none at
-- all - the whole shelf is priced out of reach of everyone who arrived
-- recently.
--
-- So a cultivator leaves home with a purse. Five thousand buys the rank 1
-- shelf many times over (25 each), the rank 2 shelf (75), and reaches into
-- rank 5 (2,025) - which is to say it buys choices, not power. What a
-- newcomer may actually learn is realm-gated regardless; what the stones
-- remove is the wait before the choosing starts.
--
-- Two halves, and they must not overlap:
--
--   * NEW characters get it from the confirmation trigger. That trigger fires
--     exactly once, on the transition into confirmed, and it already hands out
--     the starter manual - so the purse belongs beside the manual rather than
--     in a second mechanism that can drift from it.
--
--   * EVERY character alive today gets a flat 5,000, once, below.
--
-- Two things the backfill has to know about the players table, both learned by
-- looking rather than assuming:
--
--   * `The Auction House` is a players row. It is the house, it holds the
--     escrow, and it is not a cultivator - so the backfill joins through
--     `player_character`, which is what actually distinguishes a person from
--     an account.
--
--   * `confirmed_at IS NULL` does not mean "has not started". night.moth_ has
--     been playing since the 4th, holds a dungeon key and a learned technique,
--     and has never confirmed. Paying only confirmed characters would have
--     skipped an active player, so the backfill pays everyone with a
--     character and lets the trigger's own guard prevent the second payment.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('starter_spirit_stones', 5000,
     'What a cultivator is handed on their way out the door, in spirit '
     'stones. Enough to choose a second technique on the day they arrive '
     'rather than after a week of hunting for the price of one.');


-- ---------------------------------------------------------------------------
-- The purse itself
-- ---------------------------------------------------------------------------

CREATE FUNCTION grant_starter_stones(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    purse BIGINT;
BEGIN
    -- Guarded the way `grant_starter_manual` is guarded: by asking whether the
    -- thing has already been handed over. After the backfill below, every
    -- character that exists today holds stones, so this is also what stops
    -- anyone being paid twice by confirming afterwards.
    IF EXISTS (
        SELECT 1 FROM player_materials pm
        WHERE pm.player_id = p_player_id AND pm.material_code = 'spirit_stone'
    ) THEN
        RETURN NULL;
    END IF;

    purse := game_config_value('starter_spirit_stones')::bigint;
    PERFORM grant_material(p_player_id, 'spirit_stone', purse);
    RETURN purse;
END;
$$;

COMMENT ON FUNCTION grant_starter_stones(BIGINT) IS
    'The spirit stones a character is confirmed with. Returns NULL and grants nothing if they have ever held a stone, so calling it twice pays once.';


-- ---------------------------------------------------------------------------
-- Both halves of the starting kit, under one name that says so
-- ---------------------------------------------------------------------------

CREATE FUNCTION grant_starter_kit_on_confirm()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM grant_starter_manual(NEW.player_id);
    PERFORM grant_starter_stones(NEW.player_id);
    RETURN NULL;
END;
$$;

DROP TRIGGER player_character_grants_a_starter_manual ON player_character;
DROP FUNCTION grant_starter_manual_on_confirm();

CREATE TRIGGER player_character_grants_a_starter_kit
    AFTER UPDATE OF confirmed_at ON player_character
    FOR EACH ROW
    WHEN (OLD.confirmed_at IS NULL AND NEW.confirmed_at IS NOT NULL)
    EXECUTE FUNCTION grant_starter_kit_on_confirm();


-- ---------------------------------------------------------------------------
-- And everyone who arrived before there was a purse to be handed
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    purse  BIGINT := game_config_value('starter_spirit_stones')::bigint;
    before BIGINT;
    heads  INTEGER;
    paid   INTEGER := 0;
    who    RECORD;
BEGIN
    SELECT COALESCE(sum(pm.quantity), 0) INTO before
    FROM player_materials pm
    WHERE pm.material_code = 'spirit_stone';

    SELECT count(*) INTO heads
    FROM players p
    JOIN player_character pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL;

    FOR who IN
        SELECT p.player_id
        FROM players p
        JOIN player_character pc ON pc.player_id = p.player_id
        WHERE p.deleted_at IS NULL
        ORDER BY p.player_id
    LOOP
        PERFORM grant_material(who.player_id, 'spirit_stone', purse);
        paid := paid + 1;
    END LOOP;

    IF paid <> heads OR paid = 0 THEN
        RAISE EXCEPTION 'paid % cultivators of %', paid, heads;
    END IF;

    -- The house is not a cultivator and must not have been handed anything.
    IF EXISTS (
        SELECT 1 FROM player_materials pm
        JOIN players p ON p.player_id = pm.player_id
        LEFT JOIN player_character pc ON pc.player_id = p.player_id
        WHERE pc.player_id IS NULL AND pm.material_code = 'spirit_stone'
          AND pm.quantity >= purse AND p.discord_id = 0
    ) THEN
        RAISE EXCEPTION 'the auction house was paid a starting purse';
    END IF;

    -- Every one of them, by exactly the purse, and nobody else touched.
    IF (SELECT COALESCE(sum(pm.quantity), 0)
        FROM player_materials pm
        WHERE pm.material_code = 'spirit_stone')
       <> before + purse * paid THEN
        RAISE EXCEPTION 'the books do not balance after paying % cultivators', paid;
    END IF;

    RAISE NOTICE 'paid % cultivators % stones each', paid, purse;
END;
$$;


-- ---------------------------------------------------------------------------
-- What a character actually arrives holding
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    newcomer BIGINT;
    race     TEXT;
    root     TEXT;
    stones   BIGINT;
    books    INTEGER;
    dearest  BIGINT;
    purse    BIGINT := game_config_value('starter_spirit_stones')::bigint;
BEGIN
    BEGIN
        SELECT r.code INTO race FROM races r LIMIT 1;
        SELECT rt.code INTO root FROM roots rt LIMIT 1;

        -- Not 0. That is the auction house, and discord_id is unique.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1, 'a probe that is about to be rolled back')
        RETURNING player_id INTO newcomer;

        INSERT INTO player_character (player_id, race_code, root_code, character_name)
        VALUES (newcomer, race, root, 'Probe');

        -- Nothing yet: the kit is handed over at confirmation, not creation.
        IF EXISTS (SELECT 1 FROM player_materials pm WHERE pm.player_id = newcomer) THEN
            RAISE EXCEPTION 'an unconfirmed character is already holding something';
        END IF;

        UPDATE player_character SET confirmed_at = now() WHERE player_id = newcomer;

        SELECT COALESCE(pm.quantity, 0) INTO stones
        FROM player_materials pm
        WHERE pm.player_id = newcomer AND pm.material_code = 'spirit_stone';

        IF COALESCE(stones, 0) <> purse THEN
            RAISE EXCEPTION 'a new cultivator arrived with % stones, not %',
                COALESCE(stones, 0), purse;
        END IF;

        -- The half that was already there. Repointing the trigger must not
        -- have cost them the book.
        SELECT count(*) INTO books
        FROM player_manuals pm WHERE pm.player_id = newcomer;

        IF books < 1 THEN
            RAISE EXCEPTION 'a new cultivator arrived without a manual';
        END IF;

        -- Confirming is the only thing that pays. A second call does not.
        IF grant_starter_stones(newcomer) IS NOT NULL THEN
            RAISE EXCEPTION 'the purse can be collected twice';
        END IF;

        -- And it buys what it was sized to buy: the whole shelf they are
        -- allowed to reach on the day they arrive.
        SELECT COALESCE(max(s.stone_cost), 0) INTO dearest
        FROM technique_shelf(newcomer) s
        WHERE NOT s.known AND s.realm_ok AND s.tier_ok AND s.grade <> 'advanced';

        IF purse < dearest THEN
            RAISE EXCEPTION
                'the purse is % and the shelf a newcomer can reach tops out at %',
                purse, dearest;
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
