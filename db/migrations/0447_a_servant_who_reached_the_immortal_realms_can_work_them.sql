-- 0447_a_servant_who_reached_the_immortal_realms_can_work_them
--
-- A servant who has crossed into the Immortal Realm may begin bringing back
-- what grows there, slowly, and faster the deeper they go.
--
-- TWO FAULTS FOUND ON THE WAY IN, both of which this has to fix before the
-- new thing can sit on top of them.
--
-- THE FIRST: THE RARE ROLL HAS NEVER FIRED. `servant_settle` rolls once per
-- hour worked for something above the common band, and asks for:
--
--     m.rarity NOT IN ('common', 'uncommon')     -- so sort_order >= 30
--     AND ra.sort_order <= 2 + v_rank            -- so sort_order <= 20 at
--                                                -- the deepest realm there is
--
-- Those two cannot both be true. It compares a REALM RANK, which runs 1 to 18,
-- against a rarity's SORT ORDER, which runs 10 to 80 in steps of ten - two
-- different scales that happen to be numbers. Zero candidates at every rank
-- since it was written, which is every servant who has ever been sent out
-- paying `servant_rare_chance` for a roll that could not land.
--
-- It is fixed by saying what was meant in a table: `servant_rarity_reach`,
-- the best a servant of a given realm may bring, on the same shape
-- `smith_rarity_caps` uses.
--
-- THE SECOND: IMMORTAL MATERIALS WERE ALREADY LEAKING. The bulk pick draws
-- from `materials` with no notion of WHERE a thing grows, so the twelve
-- immortal-region materials that happen to be common or uncommon - two and
-- ten - could be handed over by a rank 1 servant who has never left the
-- mortal world. This closes that at the same time as opening the real door,
-- because they are the same question asked twice.
--
-- WHAT AN IMMORTAL MATERIAL IS, defined once: one that grows ONLY in a region
-- no mortal can walk into. Not "rare", not "high tier" - reachability, which
-- is the thing the servants system is about in the first place.
--
-- THE RATE IS DELIBERATELY POOR. At the door a servant brings immortal
-- materials at four per cent of their ordinary haul, rising six points of that
-- per realm beyond it - so about 4% at the Immortal Realm and 7% at Yellow
-- Apricot. On the deepest servant in the game, 90 an hour ordinary, that is
-- between three and six an hour. They are not a second income; they are the
-- trickle that makes a servant worth feeding past the door.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_immortal_realm', 7,
     'The realm rank at which a servant may begin working the immortal regions. 7 is the Immortal Realm itself - the door, rather than the Dewberry rank a cultivator needs to walk there in person.'),
    ('servant_immortal_share', 0.04,
     'What share of a servant''s ordinary haul comes back as immortal material once they are past the door, before the per-realm step. Deliberately small: this is a trickle that makes feeding a servant past the Immortal Realm worth doing, not a second income.'),
    ('servant_immortal_step', 0.06,
     'How much that share grows for each realm beyond the door. At 0.06 a Yellow Apricot servant carries about 1.66x what one at the Immortal Realm does.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What a servant of a given realm may bring back
-- ---------------------------------------------------------------------------

CREATE TABLE servant_rarity_reach (
    min_rank SMALLINT PRIMARY KEY,
    rarity   TEXT NOT NULL REFERENCES rarities(code) ON DELETE RESTRICT,
    CHECK (min_rank >= 1)
);

CREATE INDEX servant_rarity_reach_rarity_idx ON servant_rarity_reach (rarity);

COMMENT ON TABLE servant_rarity_reach IS
    'The best a servant of a given realm may come back with. Replaces the arithmetic in servant_settle that compared a realm rank against a rarity sort_order - two different scales, and their overlap was empty, so the rare roll never once landed.';

-- Starts at RARE rather than uncommon, because the roll this feeds demands
-- something above the common band - a servant whose reach is "uncommon" has
-- nothing it can return, which is the fault this migration exists to fix,
-- reintroduced one step higher. Epic at 6, and legendary at 10, which is the
-- realm a cultivator would need to walk into Black Heaven themselves.
INSERT INTO servant_rarity_reach (min_rank, rarity) VALUES
    ( 1, 'rare'),
    ( 6, 'epic'),
    (10, 'legendary'),
    (14, 'mythic');


CREATE OR REPLACE FUNCTION servant_rarity_reach(p_rank smallint)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $fn$
    SELECT r.rarity FROM servant_rarity_reach r
    WHERE r.min_rank <= GREATEST(1, COALESCE(p_rank, 1))
    ORDER BY r.min_rank DESC LIMIT 1;
$fn$;


-- ---------------------------------------------------------------------------
-- What only grows where no mortal can walk
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION is_immortal_material(p_material_code text)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $fn$
    -- Reachability, not rarity. A material is immortal when every region it
    -- grows in is one a mortal cannot enter - which is the question the whole
    -- servants system turns on.
    SELECT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN regions r ON r.code = rm.region_code
        WHERE rm.material_code = p_material_code
          AND r.min_rank >= game_config_value('immortal_region_min_rank')
    ) AND NOT EXISTS (
        SELECT 1 FROM region_materials rm
        JOIN regions r ON r.code = rm.region_code
        WHERE rm.material_code = p_material_code
          AND r.min_rank < game_config_value('immortal_region_min_rank')
    );
$fn$;

INSERT INTO game_config (key, value, description) VALUES (
    'immortal_region_min_rank', 10,
    'The realm a region demands before it counts as immortal ground. Black Heaven and White Heaven both sit at 10; everything else in the world is open from rank 1.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


CREATE OR REPLACE FUNCTION servant_is_immortal(p_player_servant_id bigint)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $fn$
    SELECT COALESCE((
        SELECT r.rank >= game_config_value('servant_immortal_realm')
        FROM player_servants ps
        JOIN realms r ON r.realm_id = ps.realm_id
        WHERE ps.player_servant_id = p_player_servant_id), FALSE);
$fn$;


CREATE OR REPLACE FUNCTION servant_immortal_per_hour(p_player_servant_id bigint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- Nothing at all below the door, and a share of the ordinary haul above
    -- it that grows with the realm. Read off `servant_haul_per_hour` rather
    -- than computed afresh, so a servant's stars, their master's collection
    -- and their realm all still count exactly once.
    SELECT CASE WHEN NOT servant_is_immortal(p_player_servant_id) THEN 0
    ELSE
        servant_haul_per_hour(p_player_servant_id)
        * game_config_value('servant_immortal_share')
        * (1 + GREATEST(0, (SELECT r.rank FROM player_servants ps
                            JOIN realms r ON r.realm_id = ps.realm_id
                            WHERE ps.player_servant_id = p_player_servant_id)
                           - game_config_value('servant_immortal_realm'))
              * game_config_value('servant_immortal_step'))
    END::numeric;
$fn$;

COMMENT ON FUNCTION servant_immortal_per_hour(bigint) IS
    'What a servant brings back per hour from immortal ground. Zero below the Immortal Realm and a small share of their ordinary haul above it, growing with the realm.';


-- ---------------------------------------------------------------------------
-- The focus screen learns to ask about a particular servant
-- ---------------------------------------------------------------------------

-- The one-argument form is dropped rather than kept beside a two-argument one
-- with a default: Postgres cannot tell them apart on a one-argument call and
-- refuses it as ambiguous.
DROP FUNCTION IF EXISTS servant_may_gather(text);

CREATE OR REPLACE FUNCTION servant_may_gather(
    p_material_code text, p_player_servant_id bigint DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $fn$
    -- The same band `servant_settle` draws from, asked in one place so the
    -- screen and the settling cannot come to disagree about it.
    --
    -- Since 0447 it also asks WHO. An immortal servant may be pointed at
    -- immortal ground; everybody else is held to the mortal band, which also
    -- closes the twelve immortal materials that were common or uncommon
    -- enough to slip through the old rarity-only test.
    SELECT EXISTS (
        SELECT 1 FROM materials m
        WHERE m.code = p_material_code
          AND m.category IN ('gathering', 'beast')
          AND (
              (m.rarity IN ('common', 'uncommon')
               AND NOT is_immortal_material(m.code))
              OR (p_player_servant_id IS NOT NULL
                  AND servant_is_immortal(p_player_servant_id)
                  AND is_immortal_material(m.code)
                  AND (SELECT ra.sort_order FROM rarities ra WHERE ra.code = m.rarity)
                      <= (SELECT ra2.sort_order FROM rarities ra2
                          WHERE ra2.code = servant_rarity_reach(
                              (SELECT r.rank FROM player_servants ps
                               JOIN realms r ON r.realm_id = ps.realm_id
                               WHERE ps.player_servant_id = p_player_servant_id)))))
    );
$fn$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_focus_set' AND pronamespace = 'public'::regnamespace;

    anchor := '    WHERE NOT servant_may_gather(c);';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_focus_set no longer checks the band where it did';
    END IF;

    EXECUTE replace(body, anchor,
'    WHERE NOT servant_may_gather(c, p_player_servant_id);');
END;
$patch$;


-- ---------------------------------------------------------------------------
-- And the settling itself
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    after  TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_settle' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_settle is missing';
    END IF;

    -- 1. The variables the new block needs.
    anchor := '    v_focus INTEGER;';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer declares its focus count';
    END IF;
    after := replace(body, anchor, concat(
'    v_focus INTEGER;', chr(10),
'    v_imm   BIGINT;    -- what immortal ground pays this hour, since 0447'));

    -- 2. The bulk pick stops handing over immortal ground to a mortal servant.
    anchor := concat(
'        SELECT m.code, m.name INTO pick', chr(10),
'        FROM materials m', chr(10),
'        WHERE m.category IN (''gathering'', ''beast'')', chr(10),
'          AND m.rarity IN (''common'', ''uncommon'')', chr(10),
'        ORDER BY random() LIMIT 1;');
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer draws its bulk pick where it did';
    END IF;
    after := replace(after, anchor, concat(
'        SELECT m.code, m.name INTO pick', chr(10),
'        FROM materials m', chr(10),
'        WHERE m.category IN (''gathering'', ''beast'')', chr(10),
'          AND m.rarity IN (''common'', ''uncommon'')', chr(10),
'          -- Not immortal ground. Twelve materials that grow only in Black', chr(10),
'          -- and White Heaven are common or uncommon, and until 0447 a rank', chr(10),
'          -- 1 servant could hand them over - the bulk pick asked what a', chr(10),
'          -- thing WAS and never where it grew.', chr(10),
'          AND NOT is_immortal_material(m.code)', chr(10),
'        ORDER BY random() LIMIT 1;'));

    -- 3. The rare roll starts being able to land.
    anchor := concat(
'            SELECT m.code, m.name INTO pick', chr(10),
'            FROM materials m', chr(10),
'            JOIN rarities ra ON ra.code = m.rarity', chr(10),
'            WHERE m.category IN (''gathering'', ''beast'')', chr(10),
'              AND m.rarity NOT IN (''common'', ''uncommon'')', chr(10),
'              AND ra.sort_order <= 2 + v_rank', chr(10),
'            ORDER BY random() LIMIT 1;');
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer rolls for something rare where it did';
    END IF;
    after := replace(after, anchor, concat(
'            -- `servant_rarity_reach` since 0447. This used to read', chr(10),
'            -- `ra.sort_order <= 2 + v_rank`, comparing a realm rank of 1-18', chr(10),
'            -- against a sort order of 10-80 - and since the same query also', chr(10),
'            -- demanded a rarity above uncommon, the two conditions had no', chr(10),
'            -- overlap at any rank. This roll had never once landed.', chr(10),
'            SELECT m.code, m.name INTO pick', chr(10),
'            FROM materials m', chr(10),
'            JOIN rarities ra ON ra.code = m.rarity', chr(10),
'            WHERE m.category IN (''gathering'', ''beast'')', chr(10),
'              AND m.rarity NOT IN (''common'', ''uncommon'')', chr(10),
'              AND NOT is_immortal_material(m.code)', chr(10),
'              AND ra.sort_order <= (SELECT ra2.sort_order FROM rarities ra2', chr(10),
'                                    WHERE ra2.code = servant_rarity_reach(v_rank))', chr(10),
'            ORDER BY random() LIMIT 1;'));

    -- 4. And immortal ground pays, for those who can stand on it.
    anchor := '        -- And the hope. One roll per whole hour worked, for something above';
    IF (length(after) - length(replace(after, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_settle no longer has its hope where it did';
    END IF;
    after := replace(after, anchor, concat(
'        -- What immortal ground gave, for a servant who can stand on it.', chr(10),
'        -- Deliberately a trickle - a few per cent of the ordinary haul,', chr(10),
'        -- growing with the realm - and held to what their own cultivation', chr(10),
'        -- can reach, so the door opening does not hand over legendary', chr(10),
'        -- material on the first hour past it.', chr(10),
'        v_imm := floor(servant_immortal_per_hour(one.player_servant_id)', chr(10),
'                       * whole)::bigint;', chr(10),
'        IF v_imm >= 1 THEN', chr(10),
'            SELECT m.code, m.name INTO pick', chr(10),
'            FROM materials m', chr(10),
'            JOIN rarities ra ON ra.code = m.rarity', chr(10),
'            WHERE m.category IN (''gathering'', ''beast'')', chr(10),
'              AND is_immortal_material(m.code)', chr(10),
'              AND ra.sort_order <= (SELECT ra2.sort_order FROM rarities ra2', chr(10),
'                                    WHERE ra2.code = servant_rarity_reach(v_rank))', chr(10),
'            ORDER BY random() LIMIT 1;', chr(10),
'', chr(10),
'            IF pick.code IS NOT NULL THEN', chr(10),
'                PERFORM grant_material(p_player_id, pick.code, v_imm);', chr(10),
'                said := said || (v_imm || ''x '' || pick.name);', chr(10),
'            END IF;', chr(10),
'        END IF;', chr(10),
'', chr(10),
anchor));

    EXECUTE after;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The door opens, the leak closes, and the roll can land
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_n    INTEGER;
    v_bad  TEXT;
    r      RECORD;
BEGIN
    -- The rare roll has candidates at every realm now, which it had at none.
    FOR r IN SELECT generate_series(1, 18)::smallint AS rank LOOP
        SELECT count(*) INTO v_n
        FROM materials m JOIN rarities ra ON ra.code = m.rarity
        WHERE m.category IN ('gathering', 'beast')
          AND m.rarity NOT IN ('common', 'uncommon')
          AND NOT is_immortal_material(m.code)
          AND ra.sort_order <= (SELECT ra2.sort_order FROM rarities ra2
                                WHERE ra2.code = servant_rarity_reach(r.rank));
        IF v_n = 0 THEN
            RAISE EXCEPTION
                'a servant at realm % still has nothing to roll for', r.rank;
        END IF;
    END LOOP;

    -- Immortal ground really is unreachable from the mortal world, which is
    -- the whole definition.
    SELECT count(*) INTO v_n FROM materials m WHERE is_immortal_material(m.code);
    IF v_n < 1 THEN
        RAISE EXCEPTION 'nothing in the world counts as immortal ground';
    END IF;
    SELECT string_agg(m.code, ', ') INTO v_bad
    FROM materials m
    WHERE is_immortal_material(m.code)
      AND EXISTS (SELECT 1 FROM region_materials rm
                  JOIN regions r2 ON r2.code = rm.region_code
                  WHERE rm.material_code = m.code
                    AND r2.min_rank < game_config_value('immortal_region_min_rank'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these are called immortal and grow in the mortal world: %', v_bad;
    END IF;

    -- The leak is shut: no mortal servant may be pointed at immortal ground.
    SELECT string_agg(m.code, ', ') INTO v_bad
    FROM materials m
    WHERE is_immortal_material(m.code) AND servant_may_gather(m.code);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'a servant with no realm may still gather these: %', v_bad;
    END IF;

    -- And the door: nothing below it, something above it, and more the deeper
    -- they are.
    IF servant_immortal_per_hour(NULL) <> 0 THEN
        RAISE EXCEPTION 'a servant who does not exist works immortal ground';
    END IF;

    FOR r IN
        SELECT ps.player_servant_id, s.name, rr.rank,
               round(servant_haul_per_hour(ps.player_servant_id), 1) AS ordinary,
               round(servant_immortal_per_hour(ps.player_servant_id), 2) AS immortal,
               servant_rarity_reach(rr.rank) AS reaches
        FROM player_servants ps
        JOIN servants s ON s.servant_code = ps.servant_code
        JOIN realms rr ON rr.realm_id = ps.realm_id
        ORDER BY rr.rank DESC, ps.player_servant_id LIMIT 5
    LOOP
        IF r.rank >= game_config_value('servant_immortal_realm')
           AND r.immortal <= 0 THEN
            RAISE EXCEPTION
                '% is past the door at realm % and brings nothing back',
                r.name, r.rank;
        END IF;
        RAISE NOTICE '% (realm %) : % an hour, % of it immortal, reaches %',
            rpad(r.name, 30), lpad(r.rank::text, 2), r.ordinary, r.immortal,
            r.reaches;
    END LOOP;
END;
$probe$;
