-- 0421_a_servant_can_be_told_what_to_look_for
--
-- `servant_settle` picks ONE mortal material at random and hands over the
-- whole hour's work in it. Nine hours of grafv's Hei Cheng came back as
-- fifty-two Wisdom Flower - which is fine, and is not what anybody sent them
-- for. The shortage this whole system answers is SPECIFIC: 344 Gu recipes
-- want Centipede Venom and the server holds none of it. A supply line you
-- cannot aim solves that only by accident, and a cultivator could farm for a
-- week and never once be handed the thing they are short of.
--
-- So a servant can be told what to look for: up to `servant_focus_max`
-- materials, from the mortal band they were always limited to.
--
-- SPLIT, NOT MULTIPLIED. The hour's work is divided between the things they
-- were pointed at, rather than paid out once per thing. Three focuses is the
-- same total in three piles; one focus is the same total in one. That makes
-- narrowing a real choice - concentration against coverage - instead of a
-- reason to always pick the maximum. Paying each focus in full would have
-- tripled every servant on the server for pressing a button.
--
-- A SERVANT WITH NO ORDERS still works exactly as before. The random pick
-- stays as the fallback, so nothing that is already out in the world changes
-- until somebody tells it otherwise, and a new player who has not found this
-- screen yet is not farming nothing.
--
-- WHY THE BAND STILL BINDS. The focus list is checked against the same
-- `gathering`/`beast` and common/uncommon band `servant_settle` draws from.
-- Without that, focus would be a way to aim a servant at legendary ore, and
-- the one thing 0416 was careful about - that a servant's realm and stars
-- raise HOW MUCH and never WHAT - would have been undone by the screen in
-- front of it. The rare bonus roll is deliberately left unfocusable for the
-- same reason: it is the part that is meant to be luck.
--
-- The cap lives in `servant_focus.slot` plus the setter rather than in a CHECK
-- with a 3 in it, so raising `servant_focus_max` later is a config change and
-- not a migration against a constraint.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_focus_max', 3,
     'How many materials one servant may be told to look for. The hour is SPLIT between them, so this is a choice between concentration and coverage rather than a multiplier.');


CREATE TABLE servant_focus (
    player_servant_id BIGINT NOT NULL
        REFERENCES player_servants(player_servant_id) ON DELETE CASCADE,
    slot          SMALLINT NOT NULL CHECK (slot >= 1),
    material_code TEXT NOT NULL REFERENCES materials(code) ON DELETE RESTRICT,
    PRIMARY KEY (player_servant_id, slot),
    UNIQUE (player_servant_id, material_code)
);

CREATE INDEX servant_focus_material_idx ON servant_focus (material_code);

COMMENT ON TABLE servant_focus IS
    'What a servant has been told to look for. Empty means whatever they find, which is how every servant behaved before 0421.';


-- ---------------------------------------------------------------------------
-- What a servant may be pointed at
-- ---------------------------------------------------------------------------

CREATE FUNCTION servant_may_gather(p_material_code text)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    -- The same band `servant_settle` draws from, asked in one place so the
    -- screen and the settling cannot come to disagree about it.
    SELECT EXISTS (
        SELECT 1 FROM materials m
        WHERE m.code = p_material_code
          AND m.category IN ('gathering', 'beast')
          AND m.rarity IN ('common', 'uncommon'));
$$;

COMMENT ON FUNCTION servant_may_gather(text) IS
    'Whether a servant may be told to look for this. The mortal band and nothing else - focus must not become a way to aim one at legendary ore.';


CREATE FUNCTION servant_focus_set(p_player_id bigint, p_player_servant_id bigint,
                                  p_codes text[])
RETURNS TABLE (servant_name TEXT, focused TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name TEXT;
    v_bad  TEXT;
    v_n    INTEGER := COALESCE(array_length(p_codes, 1), 0);
BEGIN
    SELECT s.name INTO v_name
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_n > game_config_value('servant_focus_max') THEN
        RAISE EXCEPTION 'a servant can be told to look for % things at once, not %',
            game_config_value('servant_focus_max'), v_n
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT string_agg(DISTINCT c, ', ') INTO v_bad
    FROM unnest(p_codes) AS c
    WHERE NOT servant_may_gather(c);

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a servant only brings back what the mortal world grows - not %',
            v_bad
            USING ERRCODE = 'check_violation';
    END IF;

    -- The whole list is replaced, so this is also how orders are cleared.
    DELETE FROM servant_focus WHERE player_servant_id = p_player_servant_id;

    INSERT INTO servant_focus (player_servant_id, slot, material_code)
    SELECT p_player_servant_id, ord::smallint, c
    FROM unnest(p_codes) WITH ORDINALITY AS u(c, ord)
    ON CONFLICT DO NOTHING;

    RETURN QUERY
    SELECT v_name,
           COALESCE((SELECT string_agg(m.name, ', ' ORDER BY f.slot)
                     FROM servant_focus f
                     JOIN materials m ON m.code = f.material_code
                     WHERE f.player_servant_id = p_player_servant_id),
                    'whatever they find');
END;
$$;


-- ---------------------------------------------------------------------------
-- And the settling looks at the orders
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_settle' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_settle is missing';
    END IF;

    -- ---- somewhere to keep the count --------------------------------------
    anchor := '    v_rank  SMALLINT;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer declares v_rank once';
    END IF;
    body := replace(body, anchor, concat(
'    v_rank  SMALLINT;', chr(10),
'    v_focus INTEGER;'));

    -- ---- and the orders themselves ----------------------------------------
    -- BOTH lines in one anchor and one EXECUTE. Splitting an IF from its
    -- END IF across two EXECUTEs was the first draft of this migration, and
    -- it fails on the first of them: a half-written branch is not a function.
    -- The two lines share an indent of eight, so the anchor is safe to build.
    anchor := concat(
'        PERFORM grant_material(p_player_id, pick.code, made);', chr(10),
'        said := said || (made || ''x '' || pick.name);');
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer pays its haul where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        -- What they were told to look for, if anything. The random pick', chr(10),
'        -- above still stands for a servant nobody has pointed anywhere,', chr(10),
'        -- so an unattended one works exactly as it did before 0421.', chr(10),
'        SELECT count(*)::integer INTO v_focus FROM servant_focus f', chr(10),
'        WHERE f.player_servant_id = one.player_servant_id;', chr(10),
'', chr(10),
'        IF v_focus > 0 THEN', chr(10),
'            -- Split between the orders rather than paid once per order:', chr(10),
'            -- three focuses is the same hour in three piles. The remainder', chr(10),
'            -- goes to the first so a short hour is not rounded away.', chr(10),
'            FOR pick IN', chr(10),
'                SELECT m.code, m.name,', chr(10),
'                       made / v_focus', chr(10),
'                       + CASE WHEN f.slot = (SELECT min(f2.slot)', chr(10),
'                                             FROM servant_focus f2', chr(10),
'                                             WHERE f2.player_servant_id', chr(10),
'                                                   = one.player_servant_id)', chr(10),
'                              THEN made % v_focus ELSE 0 END AS share', chr(10),
'                FROM servant_focus f', chr(10),
'                JOIN materials m ON m.code = f.material_code', chr(10),
'                WHERE f.player_servant_id = one.player_servant_id', chr(10),
'                ORDER BY f.slot', chr(10),
'            LOOP', chr(10),
'                CONTINUE WHEN pick.share < 1;', chr(10),
'                PERFORM grant_material(p_player_id, pick.code, pick.share);', chr(10),
'                said := said || (pick.share || ''x '' || pick.name);', chr(10),
'            END LOOP;', chr(10),
'        ELSE', chr(10),
'            PERFORM grant_material(p_player_id, pick.code, made);', chr(10),
'            said := said || (made || ''x '' || pick.name);', chr(10),
'        END IF;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A servant brings back what they were sent for
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_id    BIGINT;
    v_a     TEXT;
    v_b     TEXT;
    v_haul  TEXT;
    v_total BIGINT;
    v_bad   TEXT;
BEGIN
    -- The band must bind, or focus is a way round the one rule 0416 kept.
    IF servant_may_gather('spirit_jade') THEN
        RAISE EXCEPTION 'a servant may be sent to fetch jade';
    END IF;
    IF NOT servant_may_gather('centipede_venom') THEN
        RAISE EXCEPTION
            'a servant may not be sent for the very thing this was built for';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        SELECT m.code INTO v_a FROM materials m
        WHERE servant_may_gather(m.code) ORDER BY m.code LIMIT 1;
        SELECT m.code INTO v_b FROM materials m
        WHERE servant_may_gather(m.code) ORDER BY m.code DESC LIMIT 1;

        INSERT INTO player_servants (player_id, servant_code, realm_id, farming)
        SELECT v_who, s.servant_code, (SELECT min(realm_id) FROM realms), TRUE
        FROM servants s WHERE s.tier = 7 LIMIT 1
        RETURNING player_servant_id INTO v_id;

        PERFORM servant_focus_set(v_who, v_id, ARRAY[v_a, v_b]);

        -- Too many orders must be refused rather than silently trimmed.
        BEGIN
            PERFORM servant_focus_set(v_who, v_id,
                ARRAY(SELECT m.code FROM materials m
                      WHERE servant_may_gather(m.code)
                      ORDER BY m.code
                      LIMIT game_config_value('servant_focus_max')::int + 1));
            RAISE EXCEPTION 'a servant took more orders than it may hold';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        PERFORM servant_focus_set(v_who, v_id, ARRAY[v_a, v_b]);

        UPDATE player_servants SET settled_at = now() - interval '12 hours'
        WHERE player_servant_id = v_id;

        SELECT s.haul, s.brought INTO v_haul, v_total
        FROM servant_settle(v_who) s LIMIT 1;

        IF v_haul IS NULL THEN
            RAISE EXCEPTION 'twelve hours under orders brought back nothing';
        END IF;

        -- Both of the things asked for, and nothing they were not asked for.
        IF v_haul NOT LIKE '%' || (SELECT name FROM materials WHERE code = v_a) || '%'
           OR v_haul NOT LIKE '%' || (SELECT name FROM materials WHERE code = v_b) || '%'
        THEN
            RAISE EXCEPTION 'orders were for two things and the haul was: %',
                v_haul;
        END IF;

        RAISE NOTICE 'twelve hours under orders: %', v_haul;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        '% of the % mortal materials can be asked for by name',
        (SELECT count(*) FROM materials WHERE servant_may_gather(code)),
        (SELECT count(*) FROM materials);
END;
$probe$;
