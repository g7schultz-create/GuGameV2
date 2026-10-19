-- 0236_a_listing_says_what_it_does
--
-- "Divine Everwinter Horn Halberd - 50 Jade". That is the whole listing.
--
-- Nothing on the auction house says what any of it DOES. A halberd's tier,
-- what slot it goes in, what it grants; a Gu's rank and its effects at the
-- stars it actually has; a pill's potency; a manual's bonuses. All of it is a
-- name, a rarity colour and a number, and the buyer is expected to know the
-- item already or guess. The one screen in this game where somebody is asked
-- to price a thing with their own money is the screen that tells them least
-- about it.
--
-- `auction_board` exists precisely so no screen has to know that a listing
-- holds one of six different things - it already resolves the label, the emoji
-- and the rarity for all six. Resolving what the thing DOES belongs in exactly
-- the same place, so the board, the buy menu and anything built later read one
-- answer instead of each growing their own.
--
-- Star scaling is the live one, not the printed one: a Gu's effects are
-- multiplied by its stars the way `player_gu_stats` multiplies them, so what
-- the listing advertises is what the buyer will actually equip.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE VIEW auction_board AS
SELECT
    l.listing_id, l.seller_id, l.price, l.status, l.listed_at,
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
        gt.name || ' ' || repeat(chr(9733), g.stars),
        eq.name,
        pl.name || ' ' || chr(215) || pl.quantity,
        'Tier ' || pg.tier || ' ' || pp.name || ' page',
        mn.name
    ) AS label,
    COALESCE(m.emoji, gt.emoji, es.emoji, pk.emoji,
        CASE WHEN l.page_id IS NOT NULL THEN chr(128220) END,
        CASE WHEN l.manual_id IS NOT NULL THEN chr(128213) END) AS emoji,
    COALESCE(m.rarity, gt.rarity, eq.quality, mn.quality, 'common') AS rarity,
    l.quantity, l.material_code, l.gu_id, l.equipment_id, l.pill_id, l.page_id,
    l.manual_id,

    -- ---- what it is, in one line -----------------------------------------
    COALESCE(
        -- A material says what kind of thing it is; nothing else is true of it
        -- that the name does not already carry.
        CASE WHEN l.material_code IS NOT NULL THEN
            initcap(m.category)
            || CASE WHEN m.tier IS NOT NULL THEN ', tier ' || m.tier ELSE '' END
        END,
        CASE WHEN l.gu_id IS NOT NULL THEN
            'Rank ' || gt.rank || ' ' || gp.name
            || ' ' || chr(183) || ' aperture ' || gt.size
            || ' ' || chr(183) || ' ' || g.stars || chr(9733)
        END,
        CASE WHEN l.equipment_id IS NOT NULL THEN
            'Tier ' || eq.tier || ' ' || es.name
            || ' ' || chr(183) || ' ' || initcap(eq.quality)
            || ' ' || chr(183) || ' harmony ' || eq.harmony
            || COALESCE(' ' || chr(183) || ' ' || ep.name, '')
        END,
        CASE WHEN l.pill_id IS NOT NULL THEN
            'Tier ' || pl.tier || ' ' || pk.name
            || ' ' || chr(183) || ' ' || ppp.name
            || ' ' || chr(183) || ' harmony ' || pl.harmony
            || COALESCE(' ' || chr(183) || ' potency '
                        || round(100 * pl.potency) || '%', '')
        END,
        CASE WHEN l.page_id IS NOT NULL THEN
            'Tier ' || pg.tier || ' ' || pp.name || ' page'
        END,
        CASE WHEN l.manual_id IS NOT NULL THEN
            'Tier ' || mn.tier || ' ' || initcap(mn.archetype) || ' manual'
            || ' ' || chr(183) || ' needs rank ' || mn.required_rank
        END
    ) AS detail,

    -- ---- and what it grants ----------------------------------------------
    COALESCE(
        -- A Gu, at the stars it actually has rather than the ones on the page.
        (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                           || round(100 * te.magnitude
                                    * (1 + game_config_value('gu_star_step')
                                           * (g.stars - 1))) || '%',
                           ' ' || chr(183) || ' ' ORDER BY ef.sort_order)
         FROM gu_type_effects te
         JOIN gu_effects ef ON ef.code = te.effect_code
         WHERE te.gu_type_id = g.gu_type_id),

        (SELECT string_agg(ef.emoji || ' ' || ef.name || ' '
                           || round(100 * ee.magnitude) || '%',
                           ' ' || chr(183) || ' ' ORDER BY ef.sort_order)
         FROM equipment_effects ee
         JOIN gu_effects ef ON ef.code = ee.effect_code
         WHERE ee.equipment_id = eq.equipment_id),

        -- A pill's magnitude is the whole of what it does.
        CASE WHEN l.pill_id IS NOT NULL THEN
            pk.name || ' ' || to_char(pl.magnitude, 'FM999,999,999,999')
        END,

        -- A manual's bonuses, only the ones it actually carries.
        CASE WHEN l.manual_id IS NOT NULL THEN
            NULLIF(array_to_string(ARRAY[
                CASE WHEN mn.cultivation_rate_bonus <> 0
                     THEN 'cultivation +' || round(100 * mn.cultivation_rate_bonus) || '%' END,
                CASE WHEN mn.physique_rate_bonus <> 0
                     THEN 'physique +' || round(100 * mn.physique_rate_bonus) || '%' END,
                CASE WHEN mn.attainment_rate_bonus <> 0
                     THEN 'attainment +' || round(100 * mn.attainment_rate_bonus) || '%' END,
                CASE WHEN mn.hp_bonus <> 0
                     THEN 'health +' || round(100 * mn.hp_bonus) || '%' END,
                CASE WHEN mn.defense_bonus <> 0
                     THEN 'defence +' || round(100 * mn.defense_bonus) || '%' END
            ], ' ' || chr(183) || ' '), '')
        END
    ) AS grants

FROM auction_listings l
JOIN players s ON s.player_id = l.seller_id
LEFT JOIN materials m         ON m.code = l.material_code
LEFT JOIN player_gu g         ON g.gu_id = l.gu_id
LEFT JOIN gu_types gt         ON gt.gu_type_id = g.gu_type_id
LEFT JOIN paths gp            ON gp.code = gt.path_code
LEFT JOIN player_equipment eq ON eq.equipment_id = l.equipment_id
LEFT JOIN equipment_slots es  ON es.code = eq.slot
LEFT JOIN paths ep            ON ep.code = eq.path_code
LEFT JOIN player_pills pl     ON pl.pill_id = l.pill_id
LEFT JOIN pill_kinds pk       ON pk.code = pl.kind
LEFT JOIN paths ppp           ON ppp.code = pl.path_code
LEFT JOIN manual_pages pg     ON pg.page_id = l.page_id
LEFT JOIN paths pp            ON pp.code = pg.path_code
LEFT JOIN manuals mn          ON mn.manual_id = l.manual_id;

COMMENT ON VIEW auction_board IS
    'A listing as a line: what it is, what it does, what it costs, who is selling it. The six kinds are resolved here so no screen has to - `detail` is what the thing is, `grants` is what it will do for whoever buys it.';


DO $$
DECLARE
    said RECORD;
    seen INTEGER := 0;
BEGIN
    -- Every listing has to be able to say what it is. A kind that comes back
    -- blank is the hole this migration exists to close, written again.
    FOR said IN
        SELECT b.listing_id, b.kind, b.label, b.detail FROM auction_board b
    LOOP
        seen := seen + 1;
        IF said.kind IS NULL THEN
            RAISE EXCEPTION 'listing % is of no kind at all', said.listing_id;
        END IF;
        IF said.detail IS NULL OR said.detail = '' THEN
            RAISE EXCEPTION 'listing % (%) says nothing about itself',
                said.listing_id, said.kind;
        END IF;
    END LOOP;

    IF seen = 0 THEN
        RAISE NOTICE 'no listings to check; the tests carry it';
    END IF;
END;
$$;
