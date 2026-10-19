-- 0465_a_servant_may_be_sent_after_rarer_ground
--
-- A servant can be pointed at common and uncommon material and at nothing
-- else. `servant_may_gather` has said so since it was written:
--
--     m.rarity IN ('common', 'uncommon') AND NOT is_immortal_material(...)
--
-- so every rare, epic and legendary material in the mortal realms is closed to
-- every servant at every rank. The only way one has ever reached a cultivator
-- is the lottery at the foot of `servant_settle` - one roll an hour, one unit
-- if it lands, and nobody can aim it.
--
-- SO RARER GROUND OPENS, AND GIVES LESS OF ITSELF. A servant may now be sent
-- after anything their own cultivation can reach, and what comes back is a
-- share of the ordinary haul rather than the whole of it:
--
--     rare        from rank 1     30 per cent of the haul
--     epic        from rank 6     12
--     legendary   from rank 10     5
--
-- and the share grows five per cent of itself for every rank past the door, so
-- a servant who has gone on cultivating brings back more of the same ground.
-- Measured against the live roster, where a rank 1 servant hauls 3 an hour and
-- a rank 18 servant hauls 53:
--
--     rank 1  rare        0.9 an hour        rank 18  rare       29 an hour
--     rank 10 legendary   0.8                rank 18  legendary   3.7
--
-- Slow enough that a legendary pile is a week's work and not an afternoon's,
-- and never faster than the common haul - the share is clamped at one, so no
-- amount of rank makes rare ground as generous as a meadow.
--
-- MYTHIC AND ABOVE STAY SHUT. The ask was rare to legendary, and a rate table
-- with three rows in it says exactly which bands are open - a material whose
-- rarity has no row cannot be gathered at all, rather than falling through to
-- some default that nobody chose.
--
-- COMMON AND UNCOMMON DO NOT MOVE. Their share is one, exactly, so every
-- servant now working carries on at the rate they were. That is checked below
-- against the live roster rather than asserted.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE servant_rarity_rates (
    rarity   TEXT PRIMARY KEY REFERENCES rarities(code) ON DELETE RESTRICT,
    min_rank SMALLINT NOT NULL,
    share    NUMERIC(6,4) NOT NULL,
    step     NUMERIC(6,4) NOT NULL DEFAULT 0,
    CHECK (min_rank >= 1),
    CHECK (share > 0 AND share <= 1),
    CHECK (step >= 0)
);

COMMENT ON TABLE servant_rarity_rates IS
    'Which bands of material a servant may be sent after, and how much slower the rarer ground gives. A rarity with no row here cannot be gathered at all - that is how mythic and above stay shut without a second list saying so.';

COMMENT ON COLUMN servant_rarity_rates.step IS
    'How much the share grows, as a fraction of itself, for each rank past min_rank. The same shape as servant_immortal_per_hour: going on cultivating is what makes hard ground easier.';

INSERT INTO servant_rarity_rates (rarity, min_rank, share, step) VALUES
    ('common',    1, 1.0000, 0.0000),
    ('uncommon',  1, 1.0000, 0.0000),
    ('rare',      1, 0.3000, 0.0500),
    ('epic',      6, 0.1200, 0.0500),
    ('legendary', 10, 0.0500, 0.0500);


CREATE OR REPLACE FUNCTION servant_rarity_share(p_rarity text, p_rank smallint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- Nothing at all below the door, and a share above it that grows with the
    -- rank - never past the common haul, because rare ground being as
    -- generous as a meadow would make the meadow pointless.
    SELECT COALESCE((
        SELECT LEAST(1.0, r.share
                          * (1 + GREATEST(0, GREATEST(1, COALESCE(p_rank, 1))
                                             - r.min_rank) * r.step))
        FROM servant_rarity_rates r
        WHERE r.rarity = p_rarity
          AND r.min_rank <= GREATEST(1, COALESCE(p_rank, 1))
    ), 0)::numeric;
$fn$;

COMMENT ON FUNCTION servant_rarity_share(text, smallint) IS
    'What share of a servant''s ordinary haul a material of this rarity comes in at, for a servant of this rank. Zero means they cannot be sent after it at all, which is the one place that question is answered.';


-- ---------------------------------------------------------------------------
-- Where a servant may be sent
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_may_gather'
      AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_may_gather is missing';
    END IF;

    anchor := concat(
'              (m.rarity IN (''common'', ''uncommon'')', chr(10),
'               AND NOT is_immortal_material(m.code))');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_may_gather no longer bounds the mortal band so';
    END IF;

    EXECUTE replace(body, anchor, concat(
'              -- 0465: anything their own cultivation reaches, which for', chr(10),
'              -- common and uncommon is everything and above that is a', chr(10),
'              -- question servant_rarity_rates answers.', chr(10),
'              (NOT is_immortal_material(m.code)', chr(10),
'               AND servant_rarity_share(m.rarity,', chr(10),
'                       (SELECT r.rank FROM player_servants ps', chr(10),
'                        JOIN realms r ON r.realm_id = ps.realm_id', chr(10),
'                        WHERE ps.player_servant_id = p_player_servant_id)) > 0)'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And what rarer ground actually gives
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

    -- ---- somewhere to put the slowed figure ------------------------------
    anchor := '    v_imm   BIGINT;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer declares its immortal haul';
    END IF;
    body := replace(body, anchor, concat(
'    v_slow  BIGINT;    -- what rarer ground gave this hour, since 0465', chr(10),
anchor));

    -- ---- the focus rows have to carry their rarity -----------------------
    -- Anchored on a line with no per-cent sign in it: the share expression
    -- two lines below uses `made MOD v_focus`, and a literal per-cent in this
    -- file would be read by psycopg as a placeholder marker.
    anchor := '                SELECT m.code, m.name,';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer splits its focus so';
    END IF;
    body := replace(body, anchor, '                SELECT m.code, m.name, m.rarity,');

    -- ---- and the rarer the ground the less of it comes back --------------
    anchor := concat(
'                CONTINUE WHEN pick.share < 1;', chr(10),
'                PERFORM grant_material(p_player_id, pick.code, pick.share);', chr(10),
'                said := said || (pick.share || ''x '' || pick.name);');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer hands over a focused haul so';
    END IF;

    EXECUTE replace(body, anchor, concat(
'                -- 0465: rarer ground gives less of itself. Common and', chr(10),
'                -- uncommon share is exactly one, so an ordinary order is', chr(10),
'                -- paid precisely as it was before this line existed.', chr(10),
'                v_slow := floor(pick.share', chr(10),
'                          * servant_rarity_share(pick.rarity, v_rank))::bigint;', chr(10),
'                CONTINUE WHEN v_slow < 1;', chr(10),
'                PERFORM grant_material(p_player_id, pick.code, v_slow);', chr(10),
'                said := said || (v_slow || ''x '' || pick.name);'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Rarer ground opens, gives less, and the meadow is untouched
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_srv   BIGINT;
    v_rank  SMALLINT;
    r       RECORD;
    v_code  TEXT;
    v_bad   TEXT;
BEGIN
    -- Common and uncommon pay exactly what they always did. This is the one
    -- that matters: every servant now working must carry on unchanged.
    IF servant_rarity_share('common', 1::smallint) <> 1
       OR servant_rarity_share('uncommon', 18::smallint) <> 1 THEN
        RAISE EXCEPTION 'the ordinary haul moved';
    END IF;

    -- The rarer bands are slower, in the order they are rarer.
    IF NOT (servant_rarity_share('legendary', 18::smallint)
            < servant_rarity_share('epic', 18::smallint)
            AND servant_rarity_share('epic', 18::smallint)
            < servant_rarity_share('rare', 18::smallint)
            AND servant_rarity_share('rare', 18::smallint) < 1) THEN
        RAISE EXCEPTION 'the rarer bands are not slower than the commoner ones';
    END IF;

    -- Nothing is reachable below its door, and everything is above it.
    FOR r IN SELECT * FROM servant_rarity_rates WHERE min_rank > 1 LOOP
        IF servant_rarity_share(r.rarity, (r.min_rank - 1)::smallint) <> 0 THEN
            RAISE EXCEPTION
                '% can be gathered at rank %, below its own door of %',
                r.rarity, r.min_rank - 1, r.min_rank;
        END IF;
        IF servant_rarity_share(r.rarity, r.min_rank) <= 0 THEN
            RAISE EXCEPTION '% cannot be gathered at its own door', r.rarity;
        END IF;
    END LOOP;

    -- Mythic and above stay shut, at any rank at all.
    SELECT string_agg(ra.code, ', ') INTO v_bad
    FROM rarities ra
    WHERE ra.sort_order > (SELECT sort_order FROM rarities WHERE code = 'legendary')
      AND servant_rarity_share(ra.code, 18::smallint) > 0;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these opened and should not have: %', v_bad;
    END IF;

    -- And a real servant may now be pointed at real rare ground.
    SELECT ps.player_servant_id, rl.rank INTO v_srv, v_rank
    FROM player_servants ps JOIN realms rl ON rl.realm_id = ps.realm_id
    ORDER BY rl.rank DESC, ps.player_servant_id LIMIT 1;

    IF v_srv IS NOT NULL THEN
        SELECT m.code INTO v_code FROM materials m
        WHERE m.category IN ('gathering', 'beast')
          AND m.rarity = 'rare' AND NOT is_immortal_material(m.code)
        ORDER BY m.code LIMIT 1;

        IF v_code IS NOT NULL AND NOT servant_may_gather(v_code, v_srv) THEN
            RAISE EXCEPTION
                'a rank % servant still cannot be sent after rare ground',
                v_rank;
        END IF;

        -- A legendary material is still shut to a servant below rank 10.
        SELECT m.code INTO v_code FROM materials m
        WHERE m.category IN ('gathering', 'beast')
          AND m.rarity = 'legendary' AND NOT is_immortal_material(m.code)
        ORDER BY m.code LIMIT 1;

        IF v_code IS NOT NULL THEN
            SELECT ps.player_servant_id INTO v_srv
            FROM player_servants ps JOIN realms rl ON rl.realm_id = ps.realm_id
            WHERE rl.rank < 10 ORDER BY ps.player_servant_id LIMIT 1;

            IF v_srv IS NOT NULL AND servant_may_gather(v_code, v_srv) THEN
                RAISE EXCEPTION
                    'a servant below rank 10 was let onto legendary ground';
            END IF;
        END IF;
    END IF;

    RAISE NOTICE
        'rare % of the haul, epic %, legendary % at rank 18',
        round(servant_rarity_share('rare', 18::smallint), 3),
        round(servant_rarity_share('epic', 18::smallint), 3),
        round(servant_rarity_share('legendary', 18::smallint), 3);
END;
$probe$;
