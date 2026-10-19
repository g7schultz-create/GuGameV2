-- 0397_qi_comes_back_on_its_own
--
-- m_i_y_u_k_i reported that their destiny technique stopped working after a
-- realm breakthrough. The technique is fine - it is learned, it is usable, and
-- the damage pipeline hands back 39.8 billion for it. What is not fine is
-- that they cannot pay for it:
--
--     qi pool      8,192,000
--     qi in hand       2,765        0.03 per cent
--     cheapest cast  517,735
--
-- And it is not their technique, or their realm, or their breakthrough. It is
-- everybody:
--
--     m_i_y_u_k_i  (15)      2,765 of 8,192,000    cannot cast anything
--     pashu0       (14)     19,041 of 4,096,000    cannot cast anything
--     sylvrime     (13)      1,079 of 2,048,000    cannot cast anything
--     clearwest    (10)      6,140 of   371,200    cannot cast anything
--     visha        (10)      2,305 of   340,480    cannot cast anything
--     shinonn      (10)          0 of   256,000    cannot cast anything
--     grafv         (7)          0 of    32,000    cannot cast anything
--     luckymate     (6)         84 of    17,512    cannot cast anything
--
-- Eight of eight. Every cultivator in this game is standing at under two per
-- cent of their aperture and none of them can throw a single technique.
--
-- WHY. Qi never comes back on its own. Health does - `settle_passive_cultivation`
-- has restored it on every tick since it was written, `paid * 60 * regeneration`,
-- right in the middle of the same function. Qi has no such line. The only four
-- things in the entire schema that put qi back are `take_pill`, a guarded
-- round inside a fight, a horde wave, and `battle_act` spending it. So the
-- only way to refill is to walk into a fight you cannot use techniques in and
-- guard until the bar fills.
--
-- WHY THE BREAKTHROUGH IS WHAT THEY NOTICED. A technique costs a share of the
-- APERTURE, and the aperture quadruples with the realm. Their stored qi did
-- not move when they crossed, so the same 2,765 went from awkward to absurd in
-- one step. The breakthrough did not break it - it was already broken, and
-- crossing a realm is what made it impossible to miss.
--
-- TWO LINES, BOTH WHERE THE THING THEY MIRROR ALREADY LIVES.
--
--   Qi returns on the settle tick, beside the health that already did. A
--   fraction of the pool per hour rather than a flat number, because the pool
--   quadruples every realm and a flat number would be this same bug again in
--   four realms' time.
--
--   And a crossing fills it. Thematically the aperture has just been remade;
--   mechanically it is what stops a cultivator emerging from the best moment
--   in the game unable to act.
--
-- AND EVERYBODY IS FILLED NOW. Eight people cannot presently play. Waiting
-- `qi_regen_per_hour` out would be making them pay for a bug none of them
-- caused.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('qi_regen_per_hour', 0.25,
     'Share of the qi pool that returns every hour of settled time. A fraction rather than a flat number because the pool quadruples with every realm - a flat one would strand the deepest cultivators again in four realms. At 0.25 an empty aperture is full in four hours, and the passive cap still bounds how much one absence is worth.');


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- it returns on the tick, beside the health that already did -------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'settle_passive_cultivation';

    IF body IS NULL THEN
        RAISE EXCEPTION 'settle_passive_cultivation is missing';
    END IF;

    anchor := concat(
'    hp_gain := GREATEST(0, COALESCE(hp_after, 0) - COALESCE(hp_before, 0));');

    swap := concat(anchor, chr(10),
'', chr(10),
'    -- And the aperture, which until 0397 came back from nothing but a pill', chr(10),
'    -- or a guarded round in a fight. A SHARE of the pool, because the pool', chr(10),
'    -- quadruples with the realm and a flat number would strand the deepest', chr(10),
'    -- cultivators all over again a few realms from here.', chr(10),
'    UPDATE player_cultivation pc', chr(10),
'    SET qi = LEAST(player_max_qi(p_player_id),', chr(10),
'                   pc.qi + floor(paid * game_config_value(''qi_regen_per_hour'')', chr(10),
'                                 * player_max_qi(p_player_id))::bigint)', chr(10),
'    WHERE pc.player_id = p_player_id;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'settle_passive_cultivation no longer measures its healing where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- and a crossing fills it ------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'breakthrough';

    IF body IS NULL THEN
        RAISE EXCEPTION 'breakthrough is missing';
    END IF;

    anchor := concat(
'    -- The ceiling has just moved, so whatever was waiting behind the old one', chr(10),
'    -- goes in now. This is the entire point of the reserve, and it happens', chr(10),
'    -- before anything below reads a cultivation total.', chr(10),
'    drawn := draw_from_reserve(p_player_id);');

    swap := concat(
'    -- The aperture has just been remade, so it comes out of this full. Before', chr(10),
'    -- 0397 a cultivator crossed a realm, watched their pool quadruple, kept', chr(10),
'    -- whatever qi they happened to be holding, and emerged from the best', chr(10),
'    -- moment in the game unable to throw anything.', chr(10),
'    UPDATE player_cultivation pc SET qi = player_max_qi(p_player_id)', chr(10),
'    WHERE pc.player_id = p_player_id;', chr(10),
'', chr(10),
anchor);

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'breakthrough no longer draws its reserve where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Nobody is left standing there unable to act
-- ---------------------------------------------------------------------------

UPDATE player_cultivation pc
SET qi = player_max_qi(pc.player_id)
FROM players p
WHERE p.player_id = pc.player_id AND p.deleted_at IS NULL;


-- ---------------------------------------------------------------------------
-- Everybody can throw something, and it comes back if they spend it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r       RECORD;
    v_bad   TEXT;
    v_who   BIGINT;
    v_pool  BIGINT;
    v_after BIGINT;
BEGIN
    -- THE REPORT: every cultivator can pay for at least one of their own
    -- techniques. This is the thing that was false for all eight of them.
    SELECT string_agg(t.discord_name || ' (' || t.qi || ' of ' || t.need || ')',
                      ', ') INTO v_bad
    FROM (
        SELECT p.discord_name, pc.qi,
               (SELECT min(ceil(tq.qi_cost_pct * player_qi_aperture(p.player_id)))
                FROM player_usable_techniques u
                JOIN techniques tq ON tq.technique_id = u.technique_id
                WHERE u.player_id = p.player_id AND tq.base_power > 0) AS need
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        WHERE p.deleted_at IS NULL
    ) t
    WHERE t.need IS NOT NULL AND t.qi < t.need;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these still cannot throw anything: %', left(v_bad, 300);
    END IF;

    -- And it actually comes back. Emptied, wound back an hour, settled.
    SELECT p.player_id INTO v_who
    FROM players p JOIN player_cultivation pc ON pc.player_id = p.player_id
    WHERE p.deleted_at IS NULL ORDER BY player_max_qi(p.player_id) DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody to measure; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        v_pool := player_max_qi(v_who);
        UPDATE player_cultivation
        SET qi = 0, last_tick_at = now() - interval '1 hour'
        WHERE player_id = v_who;

        PERFORM settle_passive_cultivation(v_who);

        SELECT pc.qi INTO v_after FROM player_cultivation pc
        WHERE pc.player_id = v_who;

        IF v_after <= 0 THEN
            RAISE EXCEPTION 'an hour of rest returned no qi at all';
        END IF;
        IF v_after > v_pool THEN
            RAISE EXCEPTION 'the aperture overfilled: % of %', v_after, v_pool;
        END IF;

        RAISE NOTICE
            'an hour returns % of a % pool - about % hours from empty to full',
            v_after, v_pool,
            round(1.0 / game_config_value('qi_regen_per_hour'), 1);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;

    -- The two things that put qi back both know about it now.
    IF (SELECT count(*) FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('settle_passive_cultivation', 'breakthrough')
          AND p.prosrc LIKE '%player_max_qi%') <> 2 THEN
        RAISE EXCEPTION 'the tick or the crossing does not refill the aperture';
    END IF;

    FOR r IN
        SELECT p.discord_name, rr.rank, pc.qi, player_max_qi(p.player_id) AS pool
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms rr ON rr.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND rr.rank >= 5
        ORDER BY rr.rank DESC
    LOOP
        RAISE NOTICE '% (realm %) : % of %',
            rpad(r.discord_name, 14), r.rank, r.qi, r.pool;
    END LOOP;
END;
$probe$;
