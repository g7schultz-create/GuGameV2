-- 0365_a_blessed_land_that_makes_essence_while_you_sleep
--
-- The dwelling ladder stops at a Grotto-Heaven and an immortal has nothing
-- left to build. This adds the rung above it: a land that produces immortal
-- essence on its own, every day, forever, of whatever realm its owner stands
-- at.
--
-- A NOTE ON THE NAME, because it is not the one that was asked for. 'Blessed
-- Land' is already taken - it is stage 9 of this ladder, gated at Dao Seeking,
-- with Grotto-Heaven sitting above it at stage 10. Reverend Insanity has them
-- that way round too: a blessed land is what an immortal opens, and a
-- grotto-heaven is what it becomes. This game handed both names out on the
-- mortal ladder long before the immortal one existed, and `dwelling_stages`
-- has a UNIQUE on name, so the new rung cannot simply be called Blessed Land
-- without either colliding or renaming somebody's house out from under them.
--
-- So it is an IMMORTAL Blessed Land, sitting above the Grotto-Heaven: the
-- thing that was asked for, under the only name left for it. Renaming stage 9
-- to something else and freeing up the name is a small migration if that is
-- preferred - it is not done here because two players are living in one.
--
-- HOW IT PRODUCES. The same shape as every other passive in the game and
-- deliberately not a new one: `player_cultivation.last_tick_at` drives offline
-- cultivation against a `passive_cap_hours` ceiling of 24, and this reads its
-- own clock the same way against the same ceiling. Sleep through a week and
-- you collect a day of it, exactly as you collect a day of cultivation.
--
-- WHAT IT PRODUCES IS WHERE THE REALM COMES IN. Not a bigger pile at higher
-- realms - a BETTER one. A Dewberry land makes Dewberry Essence and a Yellow
-- Apricot land makes Yellow Apricot Essence, and the second is worth two
-- hundred and forty-three million times the first. Two units a day at every
-- realm, which is about a fortnight of sleeping for one stage of advancement
-- at ANY point on the ladder, so the land stays exactly as relevant at the top
-- as it is on the day it is built.
--
-- Partial days are not thrown away: the clock advances by exactly the whole
-- units it paid out, so the remainder is still sitting there tomorrow.
--
-- Forward-only. Do not edit once applied.


INSERT INTO dwelling_stages
    (stage, name, emoji, realm_required, facility_slots, stone_cost,
     ore_weight, beast_weight, jade_cost, description, flavour)
VALUES (
    11, 'Immortal Blessed Land', '🪷',
    (SELECT min(realm_id) FROM realms WHERE rank = 10),
    7, 1000000, 800000, 140000, 1600,
    'A pocket of the world folded shut and made to answer to you. The qi '
    'inside it is not the qi outside it, and what condenses out of it is not '
    'something the mortal world has a name for.',
    'Every immortal in the histories eventually stops travelling and starts '
    'gardening.');


ALTER TABLE player_dwelling
    ADD COLUMN essence_settled_at TIMESTAMPTZ NOT NULL DEFAULT now();

COMMENT ON COLUMN player_dwelling.essence_settled_at IS
    'The blessed land''s own clock. Advanced by exactly the whole units it has paid out, so a partial day carries rather than being lost, and capped like every other passive.';


INSERT INTO game_config (key, value, description) VALUES
    ('blessed_land_stage', 11,
     'Dwelling stage at which a home starts condensing immortal essence on its own.'),
    ('blessed_land_essence_per_day', 2,
     'Units of essence a blessed land condenses per day. Flat at every realm because WHICH essence is what the realm decides - two Yellow Apricot is worth 243,000,000 times two Dewberry, so a flat rate is already an enormous curve.');


-- ---------------------------------------------------------------------------
-- What the land made while you were away
-- ---------------------------------------------------------------------------

CREATE FUNCTION blessed_land_settle(p_player_id BIGINT)
RETURNS TABLE(units BIGINT, essence TEXT, essence_name TEXT, held BIGINT,
              hours_per_unit NUMERIC, ready_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    home     RECORD;
    mine     SMALLINT;
    ess_code     TEXT;
    per_day  NUMERIC := game_config_value('blessed_land_essence_per_day');
    cap      NUMERIC := game_config_value('passive_cap_hours');
    each     NUMERIC;
    elapsed  NUMERIC;
    made     BIGINT;
    total    BIGINT;
BEGIN
    SELECT pd.* INTO home FROM player_dwelling pd
    WHERE pd.player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND OR home.stage < game_config_value('blessed_land_stage') THEN
        RETURN;
    END IF;

    -- Whatever realm they stand at NOW, not the one they built it at. The
    -- land answers to its owner.
    SELECT r.rank INTO mine
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;

    SELECT e.material_code INTO ess_code
    FROM immortal_essences e WHERE e.rank = mine;

    IF ess_code IS NULL OR per_day <= 0 THEN
        RETURN;
    END IF;

    each := 24.0 / per_day;

    -- Sleeping through a fortnight pays a day, exactly as it does for
    -- cultivation. The forfeit happens BEFORE the units are counted, so the
    -- overflow cannot be banked by the arithmetic below.
    elapsed := EXTRACT(EPOCH FROM (now() - home.essence_settled_at)) / 3600.0;
    IF elapsed > cap THEN
        UPDATE player_dwelling
        SET essence_settled_at = now() - make_interval(secs => cap * 3600)
        WHERE player_id = p_player_id;
        elapsed := cap;
    END IF;

    made := floor(elapsed / each)::bigint;

    IF made > 0 THEN
        total := grant_material(p_player_id, ess_code, made);
        -- Advanced by what was PAID, not to now(): the remainder of a part-
        -- finished unit is still there in the morning.
        UPDATE player_dwelling
        SET essence_settled_at =
            essence_settled_at + make_interval(secs => (made * each * 3600)::int)
        WHERE player_id = p_player_id;
    ELSE
        SELECT COALESCE(pm.quantity, 0) INTO total FROM player_materials pm
        WHERE pm.player_id = p_player_id AND pm.material_code = ess_code;
    END IF;

    RETURN QUERY
    SELECT made, ess_code, m.name, COALESCE(total, 0), each,
           (SELECT pd.essence_settled_at FROM player_dwelling pd
            WHERE pd.player_id = p_player_id)
           + make_interval(secs => (each * 3600)::int)
    FROM materials m WHERE m.code = ess_code;
END;
$$;

COMMENT ON FUNCTION blessed_land_settle(BIGINT) IS
    'Collect whatever the blessed land condensed since it was last read. Returns nothing at all for a home below the blessed land stage or an owner with no essence of their own realm.';


-- ---------------------------------------------------------------------------
-- It settles wherever the game already settles
-- ---------------------------------------------------------------------------
--
-- Hung off `settle_passive_cultivation` rather than given a command of its
-- own, because that is the function every cog already calls before it shows
-- anybody anything. A land that only pays out when you remember to go and look
-- at it is not producing per day, it is producing per visit.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    IF NOT FOUND THEN', chr(10),
'        RAISE EXCEPTION ''player % has no cultivation row'', p_player_id;', chr(10),
'    END IF;');

    swap := concat(anchor, chr(10),
chr(10),
'    -- A blessed land condenses on its own clock against its own ceiling, so', chr(10),
'    -- it is settled here rather than woven into the cultivation arithmetic', chr(10),
'    -- below. PERFORM because nothing in this function''s result is about the', chr(10),
'    -- dwelling - the screens read it back from blessed_land_settle directly.', chr(10),
'    PERFORM blessed_land_settle(p_player_id);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'settle_passive_cultivation';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'settle_passive_cultivation no longer opens the way it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A day away is a day of essence, and a week away is still a day
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    got    RECORD;
    before BIGINT;
    after  BIGINT;
    code   TEXT;
    stage  SMALLINT := game_config_value('blessed_land_stage')::smallint;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 10 ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to build a blessed land for';
        RETURN;
    END IF;

    SELECT e.material_code INTO code FROM immortal_essences e
    JOIN player_cultivation pc ON pc.player_id = who
    JOIN realms r ON r.realm_id = pc.realm_id AND r.rank = e.rank;

    BEGIN
        INSERT INTO player_dwelling (player_id, stage, essence_settled_at)
        VALUES (who, stage, now())
        ON CONFLICT (player_id) DO UPDATE
            SET stage = EXCLUDED.stage, essence_settled_at = now();

        -- Freshly built: nothing owed yet.
        SELECT * INTO got FROM blessed_land_settle(who);
        IF COALESCE(got.units, 0) <> 0 THEN
            RAISE EXCEPTION 'a land built this second already paid % units', got.units;
        END IF;

        SELECT COALESCE(quantity, 0) INTO before FROM player_materials
        WHERE player_id = who AND material_code = code;

        -- A full day owed pays exactly the day's rate.
        UPDATE player_dwelling SET essence_settled_at = now() - interval '24 hours'
        WHERE player_id = who;
        SELECT * INTO got FROM blessed_land_settle(who);

        IF got.units <> game_config_value('blessed_land_essence_per_day')::bigint THEN
            RAISE EXCEPTION 'a day owed paid % units, wanted %',
                got.units, game_config_value('blessed_land_essence_per_day');
        END IF;

        SELECT COALESCE(quantity, 0) INTO after FROM player_materials
        WHERE player_id = who AND material_code = code;
        IF after <> before + got.units THEN
            RAISE EXCEPTION 'it reported % units and handed over %',
                got.units, after - before;
        END IF;

        -- And a week owed pays a day, not a week. This is the cap, and it is
        -- the assertion that stops a blessed land being an idle jackpot.
        UPDATE player_dwelling SET essence_settled_at = now() - interval '7 days'
        WHERE player_id = who;
        SELECT * INTO got FROM blessed_land_settle(who);
        IF got.units <> game_config_value('blessed_land_essence_per_day')::bigint THEN
            RAISE EXCEPTION 'a week away paid % units', got.units;
        END IF;

        -- A part day carries rather than vanishing: settle at half a unit,
        -- take nothing, and the clock must NOT have jumped to now().
        UPDATE player_dwelling
        SET essence_settled_at = now() - interval '6 hours'
        WHERE player_id = who;
        SELECT * INTO got FROM blessed_land_settle(who);
        IF got.units <> 0 THEN
            RAISE EXCEPTION 'six hours paid % units early', got.units;
        END IF;
        IF (SELECT essence_settled_at FROM player_dwelling WHERE player_id = who)
           > now() - interval '5 hours' THEN
            RAISE EXCEPTION 'the part-finished unit was thrown away';
        END IF;

        -- A mortal home makes nothing, whoever lives in it.
        UPDATE player_dwelling SET stage = 10,
               essence_settled_at = now() - interval '24 hours'
        WHERE player_id = who;
        SELECT * INTO got FROM blessed_land_settle(who);
        IF got IS NOT NULL AND COALESCE(got.units, 0) <> 0 THEN
            RAISE EXCEPTION 'a Grotto-Heaven condensed essence';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'a blessed land pays % a day of the owner''s own essence, capped at % hours',
        game_config_value('blessed_land_essence_per_day'),
        game_config_value('passive_cap_hours');
END;
$probe$;
