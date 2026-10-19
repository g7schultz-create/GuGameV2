-- 0366_a_room_pays_some_essence_not_a_stage_of_it
--
-- 0362 gave the immortal rooms an essence payout of `3 x reward_scale`, and
-- reward_scale is not a gentle number: it runs 1.0, 2.2, 4.8, 11.0 across
-- Normal, Hard, Hell and Insane. So an Insane clear paid THIRTY-THREE units,
-- and it pays every raider separately - a party of five walked out with 165.
--
-- An advancement stage costs twenty to thirty-five. One Insane run was a whole
-- stage, five times over. That is not a reward, it is the ladder deleted.
--
-- TWO THINGS ARE WRONG AND THEY ARE DIFFERENT PROBLEMS.
--
-- THE SCALE. `dungeon_spoils_for` already computed the right multiplier on its
-- first line and this payout ignored it:
--
--     lean NUMERIC := sqrt(GREATEST(p_scale, 1));  -- difficulty, gently
--
-- Every other drop in that function leans on `lean` rather than on the raw
-- reward_scale, for exactly this reason. The essence now does too, at 2 a
-- clear: 2, 3, 4, 7 across the four difficulties. Two keys a day means a
-- fortnight of Normal or four Insane runs for one stage, which is a real
-- contribution alongside rogues and a blessed land without being the only
-- thing anyone does.
--
-- THE TIER, which is the more serious one. The room handed out essence of the
-- ROOM'S realm, and any door in the game opens for anybody - `dungeon_open`
-- checks that the door exists and that you are not already in one, and that is
-- all. So a fresh Dewberry immortal carried through the Yellow Apricot room by
-- a party would collect Yellow Apricot Essence, worth 243,000,000 times their
-- own, and `absorb_essence` would take it at face value. That is not a deep
-- run being rewarding, it is a taxi service past eight realms.
--
-- The essence is now the lesser of the room's realm and the raider's own. An
-- eighteenth-realm cultivator in the eighteenth room still gets the best
-- essence in the game; the passenger gets what a passenger has earned.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    IF p_rank >= 10 THEN', chr(10),
'        DECLARE', chr(10),
'            ess  TEXT;', chr(10),
'            many BIGINT;', chr(10),
'        BEGIN', chr(10),
'            SELECT e.material_code INTO ess', chr(10),
'            FROM immortal_essences e WHERE e.rank = p_rank;', chr(10),
'            IF ess IS NOT NULL THEN', chr(10),
'                many := GREATEST(1, round(3 * p_scale))::bigint;');

    swap := concat(
'    IF p_rank >= 10 THEN', chr(10),
'        DECLARE', chr(10),
'            ess  TEXT;', chr(10),
'            many BIGINT;', chr(10),
'            tier SMALLINT;', chr(10),
'        BEGIN', chr(10),
'            -- The lesser of the room and the raider. Any door opens for', chr(10),
'            -- anybody, so without this a Dewberry immortal could be carried', chr(10),
'            -- through the Yellow Apricot room and absorb essence worth', chr(10),
'            -- 243,000,000 times their own standing.', chr(10),
'            SELECT LEAST(p_rank, r.rank) INTO tier', chr(10),
'            FROM player_cultivation pc', chr(10),
'            JOIN realms r ON r.realm_id = pc.realm_id', chr(10),
'            WHERE pc.player_id = p_player_id;', chr(10),
chr(10),
'            SELECT e.material_code INTO ess', chr(10),
'            FROM immortal_essences e WHERE e.rank = tier;', chr(10),
'            IF ess IS NOT NULL THEN', chr(10),
'                -- `lean`, like every other drop here. reward_scale reaches 11', chr(10),
'                -- on Insane and a stage costs twenty - the raw scale paid out', chr(10),
'                -- a whole stage per raider per clear.', chr(10),
'                many := GREATEST(1, round(2 * lean))::bigint;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_spoils_for';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_spoils_for no longer pays essence where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Some, at every difficulty, and never above your own standing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who     BIGINT;
    mine    SMALLINT;
    d       RECORD;
    loot    JSONB;
    before  BIGINT;
    after   BIGINT;
    ess     TEXT;
    stage   NUMERIC := (SELECT min(essence_units) FROM immortal_stage_costs);
    paid    BIGINT;
    above   BIGINT;
BEGIN
    SELECT pc.player_id, r.rank INTO who, mine
    FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id
    WHERE r.rank >= 10 ORDER BY r.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to pay - the payout is unmeasured';
        RETURN;
    END IF;

    SELECT e.material_code INTO ess FROM immortal_essences e WHERE e.rank = mine;

    BEGIN
        FOR d IN SELECT code, reward_scale FROM dungeon_difficulties
                 ORDER BY sort_order
        LOOP
            SELECT COALESCE(quantity, 0) INTO before FROM player_materials
            WHERE player_id = who AND material_code = ess;

            loot := dungeon_spoils_for(who, mine, d.reward_scale);

            SELECT COALESCE(quantity, 0) INTO after FROM player_materials
            WHERE player_id = who AND material_code = ess;
            paid := after - before;

            -- It pays SOMETHING. The whole point of the room.
            IF paid < 1 THEN
                RAISE EXCEPTION '% paid no essence at all', d.code;
            END IF;

            -- And never a stage of it in one clear, which is what this fixes.
            IF paid >= stage / 2 THEN
                RAISE EXCEPTION
                    '% paid % units against a stage costing % - still too much',
                    d.code, paid, stage;
            END IF;

            RAISE NOTICE '% pays % essence (a stage is %)', d.code, paid, stage;
        END LOOP;

        -- A passenger gets their own tier, not the room's. Driven by asking
        -- the deepest room to pay this Dewberry cultivator.
        SELECT COALESCE(quantity, 0) INTO before FROM player_materials
        WHERE player_id = who AND material_code = ess;

        SELECT COALESCE(sum(pm.quantity), 0) INTO above FROM player_materials pm
        JOIN immortal_essences e ON e.material_code = pm.material_code
        WHERE pm.player_id = who AND e.rank > mine;

        loot := dungeon_spoils_for(who, 18::smallint, 1.0);

        SELECT COALESCE(quantity, 0) INTO after FROM player_materials
        WHERE player_id = who AND material_code = ess;

        IF after <= before THEN
            RAISE EXCEPTION
                'the deepest room paid this rank % cultivator nothing of their own tier',
                mine;
        END IF;

        -- The DELTA, not the holdings. Two cultivators are already carrying
        -- Jade Plum at rank 10, legitimately: `spawn_rogue` draws one realm
        -- above on purpose at a quarter weight, which is the overmatch fight
        -- and not a carry. Asserting on the shelf would have called that a
        -- failure; what is being tested is whether THIS room hands anything
        -- over above the raider's realm.
        IF above <> (
            SELECT COALESCE(sum(pm.quantity), 0) FROM player_materials pm
            JOIN immortal_essences e ON e.material_code = pm.material_code
            WHERE pm.player_id = who AND e.rank > mine
        ) THEN
            RAISE EXCEPTION
                'the deepest room handed a rank % cultivator essence above their realm',
                mine;
        END IF;

        RAISE NOTICE
            'the Yellow Apricot room pays a rank % cultivator in their own essence',
            mine;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'every difficulty pays, none of them pays a stage, rolled back';
END;
$probe$;
