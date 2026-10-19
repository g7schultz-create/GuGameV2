-- 0474_a_carcass_worth_the_fight_it_cost
--
-- Measured against a real cultivator in a real delve:
--
--     a seam    168 units, for one action
--     a beast   2.71 units, for a whole fight and a quarter of your health
--
-- A seam is worth SIXTY-TWO BEASTS. Walking into something is strictly worse
-- than walking around it, and the only reason anybody fights at all is that
-- the tile is in the way. "One Beast Blood" was the whole of what the first
-- live kill paid out.
--
-- IT IS THE SAME FAULT AS EVERYTHING ELSE THIS WEEK. A seam's yield scales
-- with the cultivator - mining level, the gathering_yield stat, manual
-- bonuses, all of it - and `creature_drops` is a flat one-to-six units per
-- entry, written for a beast you meet in passing. A flat number against a
-- growing player stops meaning anything, and this one stopped early.
--
-- SO A CARCASS IS BUTCHERED PROPERLY. A kill rolls the creature's own table
-- several times over rather than once, and the quantity rides the same stack
-- `gather` and `mine` ride:
--
--     (1 + manual gathering bonus + player_stat('gathering_yield'))
--
-- which runs from 1.15 to 7.11 across the live roster. There is no butchering
-- profession to add a third term, which is why this is the whole stack rather
-- than a copy of `gather`'s - one definition of "how much a cultivator brings
-- back", minus the part that does not exist.
--
--     a beast          8 rolls   roughly one seam, for a fight
--     the deep thing  24 rolls   and the Gu it already gave
--
-- ROLLS, NOT A MULTIPLIER, because each roll tests each drop's own chance
-- independently. A Sovereign Nine-Tail Fox carries a Sovereign Fang at one in
-- five, and twenty-four rolls is the difference between that being a thing
-- that exists and a thing anybody has seen.
--
-- SEARCHING THE LAIR gets a quarter of the rolls, at full chance rather than
-- the half-chance it used. Going through its things while it is still
-- standing on you should be worth less than killing it, not worth nothing.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE delve_tile_kinds
    ADD COLUMN drop_rolls SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN delve_tile_kinds.drop_rolls IS
    'How many times a kill rolls the creature''s own drop table. Rolls rather than a multiplier so each entry''s chance is tested independently and the rare lines on a table actually appear.';

UPDATE delve_tile_kinds SET drop_rolls = 8  WHERE kind = 'beast';
UPDATE delve_tile_kinds SET drop_rolls = 24 WHERE kind = 'deep';


CREATE OR REPLACE FUNCTION delve_spoils(p_player_id bigint, p_species_id bigint,
                                        p_rolls integer)
RETURNS JSONB
LANGUAGE plpgsql
AS $fn$
DECLARE
    one   RECORD;
    v_mul NUMERIC;
    v_qty BIGINT;
    v_got JSONB := '{}'::jsonb;
    i     INTEGER;
BEGIN
    IF p_rolls < 1 THEN
        RETURN '[]'::jsonb;
    END IF;

    -- The same stack a forage rides, less the profession term - there is no
    -- butchering to level. A Gu that finds more in a meadow finds more on a
    -- carcass, which is the only reading under which one stat means one thing.
    v_mul := 1
             + COALESCE((SELECT b.gathering_bonus FROM player_manual_bonuses b
                         WHERE b.player_id = p_player_id), 0)
             + COALESCE(player_stat(p_player_id, 'gathering_yield'), 0);

    FOR i IN 1..p_rolls LOOP
        FOR one IN
            SELECT cd.material_code, cd.chance, cd.min_quantity,
                   cd.max_quantity, m.name
            FROM creature_drops cd
            JOIN materials m ON m.code = cd.material_code
            WHERE cd.species_id = p_species_id
        LOOP
            CONTINUE WHEN random() >= one.chance;
            v_qty := GREATEST(1, round(
                (one.min_quantity
                 + floor(random() * (one.max_quantity - one.min_quantity + 1)))
                * v_mul))::bigint;
            PERFORM grant_material(p_player_id, one.material_code, v_qty);
            -- Totalled by name, so one kill reads as "40x Beast Blood" rather
            -- than as eight separate lines saying five.
            v_got := jsonb_set(v_got, ARRAY[one.name],
                to_jsonb(COALESCE((v_got ->> one.name)::bigint, 0) + v_qty));
        END LOOP;
    END LOOP;

    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('what', k, 'how_many', v::bigint)
                         ORDER BY v::bigint DESC, k)
        FROM jsonb_each_text(v_got) AS e (k, v)
    ), '[]'::jsonb);
END;
$fn$;

COMMENT ON FUNCTION delve_spoils(bigint, bigint, integer) IS
    'Butchers one creature a given number of times, granting as it goes and returning what came off it. The one place a delve turns a dead thing into materials, so a kill and a search cannot drift apart about what a carcass is worth.';


-- ---------------------------------------------------------------------------
-- And both places that take something off a beast use it
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'delve_act' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'delve_act is missing';
    END IF;

    -- ---- the kill --------------------------------------------------------
    anchor := concat(
'        FOR one IN', chr(10),
'            SELECT cd.material_code, cd.chance, cd.min_quantity,', chr(10),
'                   cd.max_quantity, m.name', chr(10),
'            FROM creature_drops cd', chr(10),
'            JOIN materials m ON m.code = cd.material_code', chr(10),
'            WHERE cd.species_id = f.species_id', chr(10),
'        LOOP', chr(10),
'            CONTINUE WHEN random() >= one.chance;', chr(10),
'            v_qty := one.min_quantity', chr(10),
'                     + floor(random() * (one.max_quantity - one.min_quantity + 1));', chr(10),
'            PERFORM grant_material(p_player_id, one.material_code, v_qty);', chr(10),
'            v_found := v_found || jsonb_build_object(', chr(10),
'                ''what'', one.name, ''how_many'', v_qty);', chr(10),
'        END LOOP;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer butchers a kill where it did';
    END IF;

    body := replace(body, anchor, concat(
'        -- 0474: the table, several times over, scaled by what this', chr(10),
'        -- cultivator brings back from anything else.', chr(10),
'        v_found := v_found || delve_spoils(p_player_id, f.species_id,', chr(10),
'            COALESCE((SELECT k.drop_rolls FROM delve_tile_kinds k', chr(10),
'                      WHERE k.kind = f.tile_kind), 1));'));

    -- ---- and the search --------------------------------------------------
    anchor := concat(
'        FOR one IN', chr(10),
'            SELECT cd.material_code, cd.chance, cd.min_quantity,', chr(10),
'                   cd.max_quantity, m.name', chr(10),
'            FROM creature_drops cd', chr(10),
'            JOIN materials m ON m.code = cd.material_code', chr(10),
'            WHERE cd.species_id = f.species_id', chr(10),
'        LOOP', chr(10),
'            CONTINUE WHEN random() >= one.chance / 2;', chr(10),
'            v_qty := one.min_quantity', chr(10),
'                     + floor(random() * (one.max_quantity - one.min_quantity + 1));', chr(10),
'            PERFORM grant_material(p_player_id, one.material_code, v_qty);', chr(10),
'            v_found := v_found || jsonb_build_object(', chr(10),
'                ''what'', one.name, ''how_many'', v_qty);', chr(10),
'        END LOOP;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'delve_act no longer searches a lair where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'        -- A quarter of what killing it is worth, at the table''''s own', chr(10),
'        -- chances rather than half of them. Going through its things while', chr(10),
'        -- it stands over you should pay less than killing it, not nothing.', chr(10),
'        v_found := v_found || delve_spoils(p_player_id, f.species_id,', chr(10),
'            GREATEST(1, COALESCE((SELECT k.drop_rolls FROM delve_tile_kinds k', chr(10),
'                                  WHERE k.kind = f.tile_kind), 4) / 4));'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- A beast is worth fighting
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_p    BIGINT;
    v_spec BIGINT;
    v_one  NUMERIC;
    v_got  JSONB;
    v_sum  BIGINT;
    v_seam NUMERIC;
BEGIN
    -- Both fighting tiles butcher, and the deep one far more.
    IF (SELECT k.drop_rolls FROM delve_tile_kinds k WHERE k.kind = 'beast') < 2 THEN
        RAISE EXCEPTION 'an ordinary beast is still worth one roll';
    END IF;
    IF (SELECT k.drop_rolls FROM delve_tile_kinds k WHERE k.kind = 'deep')
       <= (SELECT k.drop_rolls FROM delve_tile_kinds k WHERE k.kind = 'beast') THEN
        RAISE EXCEPTION 'the deep thing carries no more than a boar';
    END IF;
    IF EXISTS (SELECT 1 FROM delve_tile_kinds k
               WHERE NOT k.is_beast AND k.drop_rolls > 0) THEN
        RAISE EXCEPTION 'a seam is being butchered';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_p FROM players p
        JOIN player_location pl ON pl.player_id = p.player_id
        WHERE p.deleted_at IS NULL
        ORDER BY player_realm_rank(p.player_id) DESC, p.player_id LIMIT 1;
        IF v_p IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        SELECT cr.species_id INTO v_spec
        FROM creature_regions cr
        JOIN player_location pl ON pl.region_code = cr.region_code
        JOIN creature_drops cd ON cd.species_id = cr.species_id
        WHERE pl.player_id = v_p
        GROUP BY cr.species_id ORDER BY cr.species_id LIMIT 1;
        IF v_spec IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- What its table is worth once, as a baseline.
        SELECT sum(cd.chance * (cd.min_quantity + cd.max_quantity) / 2.0)
        INTO v_one FROM creature_drops cd WHERE cd.species_id = v_spec;

        v_got := delve_spoils(v_p, v_spec,
            (SELECT k.drop_rolls FROM delve_tile_kinds k WHERE k.kind = 'beast'));

        SELECT COALESCE(sum((e ->> 'how_many')::bigint), 0) INTO v_sum
        FROM jsonb_array_elements(v_got) e;

        RAISE NOTICE
            'that beast''s table is worth about % once; a kill paid %',
            round(v_one, 2), v_sum;

        IF v_sum <= v_one * 2 THEN
            RAISE EXCEPTION
                'a kill paid % against a single roll of %, which is no better',
                v_sum, round(v_one, 2);
        END IF;

        -- Nothing is reported twice: a name appears once however many rolls
        -- turned it up.
        IF (SELECT count(*) FROM jsonb_array_elements(v_got) e)
           <> (SELECT count(DISTINCT e ->> 'what')
               FROM jsonb_array_elements(v_got) e) THEN
            RAISE EXCEPTION 'the same material is listed more than once';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Both paths go through the one butcher.
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_act'
        AND pronamespace = 'public'::regnamespace)
       NOT LIKE '%delve_spoils%' THEN
        RAISE EXCEPTION 'delve_act butchers its own way again';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'delve_act'
        AND pronamespace = 'public'::regnamespace)
       LIKE '%one.chance / 2%' THEN
        RAISE EXCEPTION 'the search still halves the table''s own chances';
    END IF;
END;
$probe$;
