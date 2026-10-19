-- 0585_the_cart_names_a_beast_part
--
-- A slot on the merchant's cart read "None".
--
--     slot 6 | beast | vitality_sap |  <null>  | 22
--
-- 0580 added the `beast` kind and taught TWO of the three functions that care
-- about it. `market_stock_for` writes it and `market_buy` grants it, but
-- `market_today` - the one that builds the label the player reads - switches on
-- kind like this:
--
--     CASE s.kind
--         WHEN 'material' THEN material_name(s.code)
--         WHEN 'essence'  THEN material_name(s.code)
--         WHEN 'gu'       THEN (SELECT name FROM gu_types ...)
--         ELSE (SELECT name FROM creature_species ...)   -- "it must be an egg"
--     END
--
-- The ELSE is the egg branch by assumption rather than by name, so a beast
-- material - whose code is a MATERIAL code - got looked up in
-- `creature_species`, found nothing, and came back NULL. The cog printed None.
--
-- A GUARD MOVED AND A READER DID NOT, for the fourth time this week. 0580's own
-- probes bought a part off the cart and checked it was granted, which is why the
-- BUYING worked perfectly; nothing looked at what the slot was called.
--
-- THE FIX, in two parts.
--
-- Every kind is named explicitly, beast among them. And the ELSE stops being
-- "assume egg" and becomes a COALESCE across all three namespaces, so the next
-- kind somebody adds degrades to the right name instead of to None. A fallback
-- is not a substitute for the explicit branch - it is what keeps a miss from
-- reaching a player's screen while somebody writes it.
--
-- The probe is the part that matters: it reads the allowed kinds OUT OF THE
-- CHECK CONSTRAINT and fails if any of them labels NULL, and fails again if a
-- kind exists that it has no sample for. Adding a sixth kind without labelling
-- it is now a migration that will not apply.
--
-- Labels are derived on read, not stored, so the carts already standing are
-- fixed by this the moment it applies.


CREATE OR REPLACE FUNCTION market_today(p_player_id BIGINT)
RETURNS TABLE (slot_no SMALLINT, kind TEXT, code TEXT, label TEXT,
               quantity BIGINT, price BIGINT, taken BOOLEAN,
               turns_at TIMESTAMPTZ)
LANGUAGE plpgsql AS $$
DECLARE
    v_hour TIMESTAMPTZ := date_trunc('hour', now());
BEGIN
    PERFORM market_stock_for(v_hour);

    RETURN QUERY
    SELECT s.slot_no, s.kind, s.code,
           CASE s.kind
               -- All three of these carry a MATERIAL code. `beast` was the one
               -- 0580 added and this CASE never learned, which is how a tusk
               -- came to be called None.
               WHEN 'material' THEN material_name(s.code)
               WHEN 'essence'  THEN material_name(s.code)
               WHEN 'beast'    THEN material_name(s.code)
               WHEN 'gu'       THEN (SELECT t.name FROM gu_types t
                                     WHERE t.code = s.code)
               WHEN 'egg'      THEN (SELECT cs.name FROM creature_species cs
                                     WHERE cs.code = s.code)
               -- NOT "assume egg" any more. The old ELSE sent every unknown
               -- kind to `creature_species` and handed back NULL when it was
               -- not a species. A kind nobody has labelled yet should look
               -- wrong in the logs, not blank on the cart.
               ELSE COALESCE(
                   material_name(s.code),
                   (SELECT t.name FROM gu_types t WHERE t.code = s.code),
                   (SELECT cs.name FROM creature_species cs WHERE cs.code = s.code)
               )
           END,
           s.quantity, s.price,
           EXISTS (SELECT 1 FROM market_bought b
                   WHERE b.stocked_for = s.stocked_for
                     AND b.slot_no = s.slot_no
                     AND b.player_id = p_player_id),
           v_hour + interval '1 hour'
    FROM market_stall s
    WHERE s.stocked_for = v_hour
    ORDER BY s.slot_no;
END;
$$;


-- ---------------------------------------------------------------------------
-- The probe
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_allowed TEXT[];
    v_sampled TEXT[];
    v_missing TEXT[];
    v_who     BIGINT;
    v_hour    TIMESTAMPTZ := date_trunc('hour', now());
    v_slot    SMALLINT := 0;
    k         TEXT;
    v_code    TEXT;
    bad       TEXT;
BEGIN
    -- EVERY KIND THE TABLE ALLOWS, read off the constraint rather than typed
    -- out here. A list written by hand is a list that stops matching.
    SELECT array_agg(m[1] ORDER BY m[1]) INTO v_allowed
    FROM pg_constraint c,
         LATERAL regexp_matches(pg_get_constraintdef(c.oid),
                                '''([a-z_]+)''::text', 'g') AS m
    WHERE c.conrelid = 'market_stall'::regclass
      AND c.conname = 'market_stall_kind_check';

    IF v_allowed IS NULL OR array_length(v_allowed, 1) < 2 THEN
        RAISE EXCEPTION
            'could not read the allowed kinds off market_stall_kind_check';
    END IF;
    RAISE NOTICE 'the cart may stock: %', array_to_string(v_allowed, ', ');

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-1106, 'cart-label-probe') RETURNING player_id INTO v_who;

        DELETE FROM market_stall WHERE stocked_for = v_hour;

        -- One real row per kind. If a kind has no sample here the probe says
        -- so rather than passing by not testing it.
        v_sampled := ARRAY[]::TEXT[];
        FOREACH k IN ARRAY v_allowed LOOP
            v_code := CASE k
                WHEN 'material' THEN
                    (SELECT m.code FROM materials m
                     WHERE m.tier IS NOT NULL ORDER BY m.code LIMIT 1)
                WHEN 'beast' THEN
                    (SELECT m.code FROM materials m
                     WHERE m.category = 'beast' ORDER BY m.code LIMIT 1)
                WHEN 'essence' THEN
                    (SELECT ie.material_code FROM immortal_essences ie
                     ORDER BY ie.rank LIMIT 1)
                WHEN 'gu' THEN
                    (SELECT t.code FROM gu_types t ORDER BY t.code LIMIT 1)
                WHEN 'egg' THEN
                    (SELECT cs.code FROM creature_species cs
                     WHERE cs.kind IN ('beast', 'elite') ORDER BY cs.code LIMIT 1)
                ELSE NULL
            END;

            IF v_code IS NULL THEN
                v_missing := COALESCE(v_missing, ARRAY[]::TEXT[]) || k;
                CONTINUE;
            END IF;

            v_slot := v_slot + 1;
            INSERT INTO market_stall
                (stocked_for, slot_no, kind, code, quantity, price)
            VALUES (v_hour, v_slot, k, v_code, 1, 1000);
            v_sampled := v_sampled || k;
        END LOOP;

        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION
                'the cart allows these kinds and this probe has no sample for '
                'them, so nothing checks what they are called: %',
                array_to_string(v_missing, ', ');
        END IF;

        -- 1. NOT ONE SLOT IS NAMELESS. This is the whole bug: the row existed,
        --    the price was right, the purchase worked, and the name was blank.
        SELECT string_agg(t.kind || '/' || t.code, ', ') INTO bad
        FROM market_today(v_who) t
        WHERE t.label IS NULL OR btrim(t.label) = '';

        IF bad IS NOT NULL THEN
            RAISE EXCEPTION 'these slots came back with no name: %', bad;
        END IF;

        -- 2. AND THE NAMES ARE THE RIGHT ONES, not merely non-null. A label of
        --    the code itself would satisfy the check above and still read badly.
        SELECT string_agg(t.kind || ' -> ' || t.label, ', ') INTO bad
        FROM market_today(v_who) t
        WHERE t.label = t.code;
        IF bad IS NOT NULL THEN
            RAISE EXCEPTION
                'these slots are labelled with their raw code: %', bad;
        END IF;

        RAISE NOTICE 'all % kinds label correctly: %',
            array_length(v_sampled, 1),
            (SELECT string_agg(t.kind || '=' || t.label, ', ' ORDER BY t.kind)
             FROM market_today(v_who) t);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;
END
$probe$;
