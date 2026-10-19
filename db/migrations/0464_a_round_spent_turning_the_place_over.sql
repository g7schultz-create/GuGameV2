-- 0464_a_round_spent_turning_the_place_over
--
-- The greed axis, finally, and in the place it belongs: a round. A raider may
-- spend their turn looting instead of swinging. They deal nothing, apply
-- nothing, answer nothing - and they come out with what the room was holding.
--
-- IT PAYS WHAT A DUNGEON PAYS. `dungeon_spoils_for(player, rank, scale)`
-- already grants herbs, pages and the rest against a realm, and it is what the
-- deepest room in the game hands out. A Trial draws from that rather than from
-- a table of its own, because two loot tables for one game is two loot tables
-- to keep in step. `trial_cache_spoils` stays empty and unused; it was built
-- for a loot system that turned out to already exist.
--
-- AND NOT SPIRIT STONES, which was my first answer and was wrong. The economy
-- says so: cultivators at realm 18 hold four hundred and twelve trillion
-- stones on average and the dearest technique in the game costs a hundred and
-- sixty-four thousand. A stone payout would be a reward nobody could feel.
--
-- WHAT IT COSTS IS THE ROUND. 0454 sizes the creature off what the party puts
-- out while ATTACKING, so every looted round is a round the health bar does
-- not move and one more roll on the threat table. Greed makes the fight longer
-- and the fight is what kills you. Nothing else needs to punish it.
--
-- EXCEPT THAT THE ROOM RUNS OUT. Without a limit a party could simply refuse
-- to fight: loot every round, let the twenty-round cap end it as `outlasted`,
-- and walk away with sixty rounds of spoils between three of them. So each
-- raider may turn the place over twice, and after that there is nothing left
-- to find. The limit is per raider per fight, which also means a beast tile
-- and the gate are looted separately - the map is a route, and a route with
-- more fights on it is worth more.
--
-- YOU KEEP WHAT YOU TOOK. A party that wipes still carries out what it found,
-- because it found it before it died and taking it back would mean holding the
-- spoils in escrow for a fight that has no other escrow in it.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_loot_scale', 0.25,
     'What one looted round is worth against a dungeon''s whole payout at the same realm. A quarter: two of them is half a dungeon run, which is worth two rounds of a fight you then have to survive longer.'),
    ('trial_loot_limit', 2,
     'How many rounds one raider may spend looting in one fight. Without a cap a party could decline to fight at all, ride the round limit to `outlasted`, and farm the spoils of a creature it never hurt.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


ALTER TABLE trial_raiders
    ADD COLUMN looting BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN loots_taken SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN trial_raiders.looting IS
    'Whether this raider means to turn the place over this round rather than swing. Cleared with the rest of the intents when the round resolves.';

COMMENT ON COLUMN trial_raiders.loots_taken IS
    'How many rounds this raider has already spent looting in this fight. The room only has so much in it - see trial_loot_limit.';


-- `chose_at` has meant "they picked a technique" since 0452:
--
--     CHECK ((intent_id IS NULL) = (chose_at IS NULL))
--
-- Looting is a third thing a raider can have decided, so the invariant is now
-- that they have decided SOMETHING. The old constraint caught this the first
-- time trial_loot ran, which is the whole reason it was written that way.
ALTER TABLE trial_raiders DROP CONSTRAINT trial_raiders_check;

ALTER TABLE trial_raiders ADD CONSTRAINT trial_raiders_has_decided
    CHECK ((intent_id IS NOT NULL OR looting) = (chose_at IS NOT NULL));


CREATE OR REPLACE FUNCTION trial_loot(p_player_id bigint)
RETURNS TABLE(run_id bigint, taken integer, left_to_take integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_run  BIGINT;
    v_done INTEGER;
    v_cap  INTEGER;
BEGIN
    v_run := trial_of(p_player_id);
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'you are not in a trial' USING ERRCODE = 'check_violation';
    END IF;

    SELECT x.loots_taken INTO v_done FROM trial_raiders x
    WHERE x.run_id = v_run AND x.player_id = p_player_id;
    IF v_done IS NULL THEN
        RAISE EXCEPTION 'you are not in this fight' USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT x.current_hp FROM trial_raiders x
        WHERE x.run_id = v_run AND x.player_id = p_player_id) <= 0 THEN
        RAISE EXCEPTION 'you are down' USING ERRCODE = 'check_violation';
    END IF;

    v_cap := game_config_value('trial_loot_limit')::int;
    IF v_done >= v_cap THEN
        RAISE EXCEPTION
            'you have already turned this place over twice and there is nothing left'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Looting and swinging are the same slot. Choosing one puts the other down.
    UPDATE trial_raiders x
    SET looting = TRUE, intent_id = NULL, chose_at = now()
    WHERE x.run_id = v_run AND x.player_id = p_player_id;

    RETURN QUERY SELECT v_run, v_done, v_cap - v_done;
END;
$fn$;

COMMENT ON FUNCTION trial_loot(bigint) IS
    'Spend this round turning the place over instead of fighting. The cost is the round: a creature sized off what the party deals while attacking does not lose health to somebody going through its things.';


-- ---------------------------------------------------------------------------
-- Choosing a technique puts the loot bag down again
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_choose' AND pronamespace = 'public'::regnamespace;

    anchor := concat(
'    UPDATE trial_raiders', chr(10),
'    SET intent_id = p_technique_id, chose_at = now()', chr(10),
'    WHERE trial_raiders.run_id = v_run AND trial_raiders.player_id = p_player_id;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_choose no longer records an intent where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    UPDATE trial_raiders', chr(10),
'    SET intent_id = p_technique_id, chose_at = now(), looting = FALSE', chr(10),
'    WHERE trial_raiders.run_id = v_run AND trial_raiders.player_id = p_player_id;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The round itself
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'trial_resolve_round'
      AND pronamespace = 'public'::regnamespace;

    -- ---- the loop has to know who is looting -----------------------------
    anchor := concat(
'        SELECT x.player_id, x.intent_id, x.current_hp, x.max_hp, p.discord_name');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_resolve_round no longer gathers its raiders so';
    END IF;

    body := replace(body, anchor, concat(
'        SELECT x.player_id, x.intent_id, x.current_hp, x.max_hp, p.discord_name,', chr(10),
'               x.looting, x.loots_taken'));

    -- ---- and a looter takes the round off --------------------------------
    anchor := concat(
'        move := COALESCE(one.intent_id, dungeon_default_move(one.player_id));');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_resolve_round no longer picks a move where it did';
    END IF;

    body := replace(body, anchor, concat(
'        -- 0464: greed. No damage, no effects, nothing answered - and what', chr(10),
'        -- the room was holding. The cost is the round itself.', chr(10),
'        IF one.looting', chr(10),
'           AND one.loots_taken < game_config_value(''trial_loot_limit'')::int THEN', chr(10),
'            UPDATE trial_raiders x', chr(10),
'            SET loots_taken = x.loots_taken + 1', chr(10),
'            WHERE x.run_id = p_run_id AND x.player_id = one.player_id;', chr(10),
'', chr(10),
'            v_lines := v_lines || jsonb_build_object(', chr(10),
'                ''who'', one.discord_name, ''kind'', ''loot'',', chr(10),
'                ''found'', dungeon_spoils_for(one.player_id, run.realm_rank,', chr(10),
'                            game_config_value(''trial_loot_scale'')),', chr(10),
'                ''text'', ''goes through the place while the rest of you hold it'');', chr(10),
'            CONTINUE;', chr(10),
'        END IF;', chr(10),
'', chr(10),
'        move := COALESCE(one.intent_id, dungeon_default_move(one.player_id));'));

    -- ---- and the bag goes down with the rest of the intents --------------
    anchor := concat(
'    UPDATE trial_raiders x SET intent_id = NULL, chose_at = NULL', chr(10),
'    WHERE x.run_id = p_run_id;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'trial_resolve_round no longer clears its intents so';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    UPDATE trial_raiders x', chr(10),
'    SET intent_id = NULL, chose_at = NULL, looting = FALSE', chr(10),
'    WHERE x.run_id = p_run_id;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Greed costs a round, pays a dungeon's coin, and runs out
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_lead  BIGINT;
    v_party BIGINT;
    v_run   BIGINT;
    v_cap   INTEGER;
    v_hp0   BIGINT;
    v_hp1   BIGINT;
    v_mat0  BIGINT;
    v_mat1  BIGINT;
    got     RECORD;
    r       RECORD;
    i       INTEGER;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_lead FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM player_techniques pt WHERE pt.player_id = p.player_id)
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_lead IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_lead);
        FOR r IN
            SELECT p.player_id FROM players p
            WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
              AND player_realm_rank(p.player_id) = player_realm_rank(v_lead)
              AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
            ORDER BY p.player_id LIMIT 2
        LOOP
            PERFORM trial_party_invite(v_lead, r.player_id);
            PERFORM trial_party_answer(r.player_id, v_party, TRUE);
        END LOOP;
        PERFORM trial_party_seal(v_lead);

        SELECT t.run_id INTO v_run FROM trial_begin(v_lead) t;

        -- Everybody loots. The creature must come out of the round untouched.
        SELECT r2.boss_hp INTO v_hp0 FROM trial_runs r2 WHERE r2.run_id = v_run;
        -- Sum, not count: a cultivator who already owns these herbs gains
        -- quantity on rows that already exist, and counting kinds would call
        -- a real payout nothing.
        SELECT COALESCE(sum(pm.quantity), 0) INTO v_mat0 FROM player_materials pm
        WHERE pm.player_id = v_lead;

        FOR r IN SELECT x.player_id FROM trial_raiders x WHERE x.run_id = v_run
        LOOP
            PERFORM trial_loot(r.player_id);
        END LOOP;

        SELECT * INTO got FROM trial_resolve_round(v_run);
        SELECT r2.boss_hp INTO v_hp1 FROM trial_runs r2 WHERE r2.run_id = v_run;

        IF got.dealt <> 0 THEN
            RAISE EXCEPTION
                'a party that all looted still dealt %', got.dealt;
        END IF;
        IF v_hp1 <> v_hp0 THEN
            RAISE EXCEPTION 'the creature lost health to nobody hitting it';
        END IF;

        SELECT COALESCE(sum(pm.quantity), 0) INTO v_mat1 FROM player_materials pm
        WHERE pm.player_id = v_lead;
        IF v_mat1 <= v_mat0 THEN
            RAISE EXCEPTION 'turning the place over found nothing at all';
        END IF;

        RAISE NOTICE
            'a looted round: the creature took %, and the leader came away with % more material',
            got.dealt, v_mat1 - v_mat0;

        -- The bag goes down at the end of the round.
        IF EXISTS (SELECT 1 FROM trial_raiders x
                   WHERE x.run_id = v_run AND x.looting) THEN
            RAISE EXCEPTION 'somebody is still holding the loot bag';
        END IF;

        -- Choosing a technique puts the bag back down.
        PERFORM trial_loot(v_lead);
        PERFORM trial_choose(v_lead, (SELECT pt.technique_id
                                      FROM player_techniques pt
                                      WHERE pt.player_id = v_lead LIMIT 1));
        IF (SELECT x.looting FROM trial_raiders x
            WHERE x.run_id = v_run AND x.player_id = v_lead) THEN
            RAISE EXCEPTION 'picking a technique left them still looting';
        END IF;

        -- And the room runs out.
        v_cap := game_config_value('trial_loot_limit')::int;
        FOR i IN 1..v_cap LOOP
            BEGIN
                PERFORM trial_loot(v_lead);
                PERFORM trial_resolve_round(v_run);
            EXCEPTION WHEN check_violation THEN
                NULL;
            END;
        END LOOP;

        BEGIN
            PERFORM trial_loot(v_lead);
            RAISE EXCEPTION 'the room can be turned over for ever';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE NOTICE 'the room gave out after % rounds of looting', v_cap;

        -- The widened invariant still refuses a raider who has decided
        -- nothing but is marked as having decided when.
        BEGIN
            UPDATE trial_raiders x
            SET intent_id = NULL, looting = FALSE, chose_at = now()
            WHERE x.run_id = v_run AND x.player_id = v_lead;
            RAISE EXCEPTION 'a raider may now have chosen nothing at a time';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END;
$probe$;
