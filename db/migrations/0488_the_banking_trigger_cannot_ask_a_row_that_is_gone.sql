-- 0488_the_banking_trigger_cannot_ask_a_row_that_is_gone
--
-- 0487's probe tested the teardown it was written around and passed. A test
-- written straight afterwards failed on the case it did not think to try:
--
--     equip a worm for ten hours, then DELETE the worm
--     -> gu_carried_seconds returns 0
--
-- `bank_gu_carry_tally` finds the kind of worm it is banking by joining
-- `player_gu` on OLD.gu_id. When the equipped row dies because the WORM died,
-- the cascade has already removed that row, the join matches nothing, and the
-- UPDATE banks nothing. The tally survives reading zero.
--
-- The 0487 probe deleted a PLAYER, where the equipped row and the worm both
-- cascade and the player_gu row happens to still be readable. Deleting the
-- worm alone is the path it missed, and it is not a corner:
--
--     nurture_gu does DELETE FROM player_gu WHERE gu_id = ANY(fodder)
--
-- Feeding copies of a worm to raise another one's stars destroys the copies,
-- and anybody who had a copy equipped lost everything it had banked. Every
-- fault this month has been this shape - a fact needed at the moment a row
-- dies, read from a table that died first.
--
-- THE FIX IS TO STOP ASKING. The equipped row carries the kind of worm it is,
-- so the banking trigger needs nothing but OLD. A gu's type is fixed for its
-- whole life - nothing in the schema or the bot ever writes
-- `player_gu.gu_type_id` after the INSERT that creates it, and `nurture_gu`
-- only ever reads it to match fodder and only ever writes `stars` - so this
-- cannot drift. A BEFORE INSERT trigger derives it rather than trusting the
-- caller, which is also how the bot's two-column INSERT keeps working.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE player_gu_equipped
    ADD COLUMN gu_type_id BIGINT REFERENCES gu_types(gu_type_id);

UPDATE player_gu_equipped e
SET gu_type_id = g.gu_type_id
FROM player_gu g
WHERE g.gu_id = e.gu_id;

ALTER TABLE player_gu_equipped
    ALTER COLUMN gu_type_id SET NOT NULL;

COMMENT ON COLUMN player_gu_equipped.gu_type_id IS
    'The kind of worm this is, copied from player_gu when it goes in. Here so the banking trigger can read it off OLD when the row dies - including when it dies because the worm itself was destroyed, which is what nurture_gu does to fodder. Always derived, never taken from the caller.';


-- ---------------------------------------------------------------------------
-- Derive it on the way in
-- ---------------------------------------------------------------------------

CREATE FUNCTION stamp_gu_kind_on_equip()
RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
BEGIN
    -- Overwritten rather than defaulted, so no caller can set it wrong and no
    -- caller has to know it exists.
    SELECT g.gu_type_id INTO NEW.gu_type_id
    FROM player_gu g WHERE g.gu_id = NEW.gu_id;

    IF NEW.gu_type_id IS NULL THEN
        RAISE EXCEPTION 'cannot equip gu % - there is no such worm', NEW.gu_id;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER player_gu_equipped_stamps_its_kind
    BEFORE INSERT ON player_gu_equipped
    FOR EACH ROW EXECUTE FUNCTION stamp_gu_kind_on_equip();


-- ---------------------------------------------------------------------------
-- Bank from OLD alone
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION bank_gu_carry_tally()
RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
BEGIN
    -- No join. The row being deleted already says which kind of worm it was,
    -- so it does not matter whether the worm, the player or neither is still
    -- there. Still UPDATE-only: an INSERT here would resurrect a tally row
    -- behind a cascade that had already swept it and break deleting a
    -- cultivator, which is why 0487 put the INSERT on the equip side.
    UPDATE player_gu_carried c
    SET seconds_carried = c.seconds_carried
                        + GREATEST(0, floor(extract(epoch FROM (now() - OLD.equipped_at))))::BIGINT,
        last_banked_at = now()
    WHERE c.player_id = OLD.player_id
      AND c.gu_type_id = OLD.gu_type_id;
    RETURN OLD;
END;
$fn$;


-- The open-stint read has the same dependency and the same cure.
CREATE OR REPLACE FUNCTION gu_carried_seconds(p_player_id BIGINT, p_gu_type_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
        (SELECT seconds_carried FROM player_gu_carried
         WHERE player_id = p_player_id AND gu_type_id = p_gu_type_id), 0)
    + COALESCE((
        SELECT sum(GREATEST(0, floor(extract(epoch FROM (now() - e.equipped_at)))))::BIGINT
        FROM player_gu_equipped e
        WHERE e.player_id = p_player_id AND e.gu_type_id = p_gu_type_id
    ), 0);
$fn$;


-- ---------------------------------------------------------------------------
-- Every way an equipped row can die
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid  BIGINT;
    v_gid  BIGINT;
    v_type BIGINT;
    v_secs BIGINT;
    v_n    INTEGER;
BEGIN
    -- The backfill reached all of them.
    SELECT count(*) INTO v_n
    FROM player_gu_equipped e
    JOIN player_gu g ON g.gu_id = e.gu_id
    WHERE e.gu_type_id <> g.gu_type_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% equipped rows disagree with their worm', v_n;
    END IF;

    SELECT min(gu_type_id) INTO v_type FROM gu_types;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-992, 'kind-probe') RETURNING player_id INTO v_pid;

        -- 1. THE ONE THAT WAS BROKEN: the worm is destroyed, as nurture_gu
        -- destroys fodder. The time it was worn was still worn.
        INSERT INTO player_gu (owner_id, gu_type_id, stars)
        VALUES (v_pid, v_type, 1) RETURNING gu_id INTO v_gid;
        INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at)
        VALUES (v_gid, v_pid, now() - INTERVAL '10 hours');

        DELETE FROM player_gu WHERE gu_id = v_gid;

        v_secs := gu_carried_seconds(v_pid, v_type);
        IF v_secs < 35000 THEN
            RAISE EXCEPTION
                'destroying a worm lost its stint: % seconds of ten hours', v_secs;
        END IF;

        -- 2. The ordinary unequip still banks.
        INSERT INTO player_gu (owner_id, gu_type_id, stars)
        VALUES (v_pid, v_type, 1) RETURNING gu_id INTO v_gid;
        INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at)
        VALUES (v_gid, v_pid, now() - INTERVAL '2 hours');
        DELETE FROM player_gu_equipped WHERE gu_id = v_gid;

        v_secs := gu_carried_seconds(v_pid, v_type);
        IF v_secs < 42000 THEN
            RAISE EXCEPTION 'the second stint did not add on: % seconds', v_secs;
        END IF;

        -- 3. The kind is derived, not taken from the caller.
        INSERT INTO player_gu_equipped (gu_id, player_id, gu_type_id)
        VALUES (v_gid, v_pid, (SELECT max(gu_type_id) FROM gu_types));
        IF (SELECT gu_type_id FROM player_gu_equipped WHERE gu_id = v_gid) <> v_type THEN
            RAISE EXCEPTION 'a caller was allowed to declare the wrong kind';
        END IF;

        -- 4. And deleting the cultivator still passes both cascades, which is
        -- the thing the UPDATE-only rule exists for.
        DELETE FROM players WHERE player_id = v_pid;
        IF EXISTS (SELECT 1 FROM player_gu_carried WHERE player_id = v_pid) THEN
            RAISE EXCEPTION 'deleting a cultivator left their tally behind';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Equipping a worm that is not there is still refused, and NOT by the new
    -- trigger: `enforce_gu_capacity` has guarded this since 0036 and sorts
    -- ahead of the stamp on trigger name, so it answers first. The NULL check
    -- inside stamp_gu_kind_on_equip is therefore unreachable defence rather
    -- than the gate - worth keeping, not worth claiming.
    --
    -- Caught as check_violation, which is this schema's convention for a
    -- refusal a player should read. A handler written for the default
    -- raise_exception does not see any of them, and that is how this probe
    -- failed first time round.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-993, 'ghost-probe') RETURNING player_id INTO v_pid;
        BEGIN
            INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (-1, v_pid);
            RAISE EXCEPTION 'equipping a worm that does not exist was allowed';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM <> 'that Gu is not yours' THEN RAISE; END IF;
        END;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a stint survives the worm, the loadout and the cultivator';
END;
$probe$;
