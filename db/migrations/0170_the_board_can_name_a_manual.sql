-- 0170_the_board_can_name_a_manual
--
-- 0169 gave `auction_listings` a sixth kind and `auction_release` an ELSE that
-- raises rather than handing back nothing. `auction_board` needed the same
-- treatment and had the same fault in a quieter form: its `kind` was a CASE
-- ending in
--
--     ELSE 'page'
--
-- so a manual listing would have been labelled a page, and every COALESCE in
-- the view would have fallen through to NULL because no join reached the
-- manual. The board would have shown an unnamed page nobody could identify,
-- for sale, at a real price.
--
-- The CASE now names all six and ends without an ELSE, so a seventh kind
-- arrives as a NULL that a screen can notice rather than as a wrong answer
-- that reads correctly.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE VIEW auction_board AS
SELECT l.listing_id,
       l.seller_id,
       l.price,
       l.status,
       l.listed_at,
       s.discord_name AS seller_name,
       CASE
           WHEN l.material_code IS NOT NULL THEN 'material'
           WHEN l.gu_id        IS NOT NULL THEN 'gu'
           WHEN l.equipment_id IS NOT NULL THEN 'equipment'
           WHEN l.pill_id      IS NOT NULL THEN 'pill'
           WHEN l.page_id      IS NOT NULL THEN 'page'
           WHEN l.manual_id    IS NOT NULL THEN 'manual'
       END AS kind,
       COALESCE(
           m.name || ' ' || chr(215) || l.quantity,
           gt.name || ' ' || repeat(chr(9733), g.stars::integer),
           eq.name,
           pl.name || ' ' || chr(215) || pl.quantity,
           'Tier ' || pg.tier || ' ' || pp.name || ' page',
           mn.name
       ) AS label,
       COALESCE(m.emoji, gt.emoji, es.emoji, pk.emoji,
                CASE WHEN l.page_id IS NOT NULL THEN chr(128220) END,
                CASE WHEN l.manual_id IS NOT NULL THEN chr(128213) END
       ) AS emoji,
       COALESCE(m.rarity, gt.rarity, eq.quality, mn.quality, 'common') AS rarity,
       l.quantity,
       l.material_code,
       l.gu_id,
       l.equipment_id,
       l.pill_id,
       l.page_id,
       l.manual_id
FROM auction_listings l
JOIN players s ON s.player_id = l.seller_id
LEFT JOIN materials m ON m.code = l.material_code
LEFT JOIN player_gu g ON g.gu_id = l.gu_id
LEFT JOIN gu_types gt ON gt.gu_type_id = g.gu_type_id
LEFT JOIN player_equipment eq ON eq.equipment_id = l.equipment_id
LEFT JOIN equipment_slots es ON es.code = eq.slot
LEFT JOIN player_pills pl ON pl.pill_id = l.pill_id
LEFT JOIN pill_kinds pk ON pk.code = pl.kind
LEFT JOIN manual_pages pg ON pg.page_id = l.page_id
LEFT JOIN paths pp ON pp.code = pg.path_code
LEFT JOIN manuals mn ON mn.manual_id = l.manual_id;


-- Listed for real and read back off the board, then rolled away. A listing
-- the board cannot name is a listing somebody buys by accident.

DO $$
DECLARE
    book   BIGINT;
    seller BIGINT;
    listed BIGINT;
    shown  RECORD;
BEGIN
    SELECT manual_id INTO book FROM manuals ORDER BY manual_id LIMIT 1;
    IF book IS NULL THEN
        RAISE NOTICE 'no manual to probe with; tests carry it';
        RETURN;
    END IF;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-9003, 'Board Prober') RETURNING player_id INTO seller;
        INSERT INTO player_manuals (player_id, manual_id) VALUES (seller, book);
        PERFORM grant_material(seller, 'spirit_jade', 500);

        listed := auction_list_manual(seller, book, 42);

        SELECT * INTO shown FROM auction_board WHERE listing_id = listed;

        IF shown.kind <> 'manual' THEN
            RAISE EXCEPTION 'the board calls a manual a %', shown.kind;
        END IF;
        IF shown.label IS NULL OR shown.label = '' THEN
            RAISE EXCEPTION 'the board could not name it';
        END IF;
        IF shown.emoji IS NULL THEN
            RAISE EXCEPTION 'the board had no mark for it';
        END IF;
        IF shown.manual_id <> book THEN
            RAISE EXCEPTION 'the board lost track of which manual';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
