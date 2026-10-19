-- 0378_an_immortal_carries_pages_the_drop_table_never_had
--
-- A rogue immortal hands over the same tier 7 page a rank 5 sect elder does.
-- 0359 put the immortals in the heavens and left them carrying the best page
-- the MORTAL world can produce, which is not the same thing as the best page.
--
-- THE STRONGER MANUALS ALREADY EXIST AND NOBODY CAN REACH THEM. `page_tiers`
-- and `manual_tiers` both run to ten, and the top three of each are marked out
-- by their own names:
--
--     8   Refined beyond the drop table
--     9   Extremely difficult refined
--     10  Pinnacle Mortal World page
--
-- Their `roll_weight` is zero. Nothing in the game drops them - they exist only
-- at the end of `fuse_pages`, three pages at a time. And because a manual's
-- tier is decided by the POWER of the pages that went into it rather than by
-- their tier, those three page tiers are exactly what a tier 8, 9 or 10 manual
-- is made of:
--
--     manual tier 7   bonus budget 0.45      manual tier 10  bonus budget 0.82
--
-- So the stronger crafted manual the request is after is already designed,
-- already balanced, and already sitting behind a fusion grind. An immortal
-- rogue is a better door to it than another eight hours of fusing.
--
-- WHY NOT NEW TIERS ELEVEN AND UP. I costed it. A manual reaches tier T when
-- its pages total `bonus_budget(T) x 400` power, and eight tier 10 pages carry
-- up to 848 - enough for a budget of 2.12 on their own. Any new manual tier
-- low enough to sit smoothly on the curve would already be reachable with
-- mortal pages, and any tier high enough to REQUIRE immortal pages would have
-- to leap past 2.12 from 0.82. The ladder is not short of rungs; it is short
-- of a way up the ones it has.
--
-- WHAT A ROGUE CARRIES NOW, by the realm it stands at:
--
--     Dewberry to Purple Mulberry    tier 8
--     Golden Peach to Green Grape    tier 9
--     Red Date to Yellow Apricot     tier 10
--
-- Minted through `mint_page_at` rather than `mint_page`, because the latter
-- refuses any tier with no roll weight - which is the guard that keeps these
-- three out of the ordinary drop table, and it stays exactly where it is.
-- Mortal rogues are untouched and still carry tier 1 to 7.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('rogue_immortal_page_step', 3,
     'Immortal realms per step up the page ladder a rogue immortal carries. At 3, Dewberry through Purple Mulberry carry tier 8, the next three carry 9, and the last three carry 10.');

COMMENT ON TABLE page_tiers IS
    'Every grade of manual page. Tiers 8 to 10 have no roll weight and never enter the ordinary drop table: they come from fusing three pages, or off a rogue immortal, and they are what a tier 8 to 10 manual is made of.';


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    -- Pages stop at tier 7, so a rogue past that carries the best that', chr(10),
'    -- exists rather than a range that runs backwards.', chr(10),
'    hi := LEAST(7, r + game_config_value(''rogue_page_tier_spread'')::smallint);', chr(10),
'    lo := LEAST(GREATEST(1, r), hi);');

    swap := concat(
'    -- What the mortal world can be carrying. Pages stop at tier 7 there, so', chr(10),
'    -- a rogue past that carries the best that exists rather than a range', chr(10),
'    -- that runs backwards.', chr(10),
'    hi := LEAST(7, r + game_config_value(''rogue_page_tier_spread'')::smallint);', chr(10),
'    lo := LEAST(GREATEST(1, r), hi);', chr(10),
chr(10),
'    -- An immortal is carrying something the drop table has never held. The', chr(10),
'    -- realm they stand at decides which: three realms to a rung, so the', chr(10),
'    -- Yellow Apricot rogue is the only reliable source of a Pinnacle page.', chr(10),
'    SELECT immortal_rank INTO mine', chr(10),
'    FROM creature_species WHERE species_id = p_species_id;', chr(10),
chr(10),
'    IF mine IS NOT NULL THEN', chr(10),
'        lo := LEAST((SELECT max(t.tier) FROM page_tiers t),', chr(10),
'                    7 + GREATEST(1, ceil(', chr(10),
'                        (mine - 9)::numeric', chr(10),
'                        / game_config_value(''rogue_immortal_page_step''))::int', chr(10),
'                    ))::smallint;', chr(10),
'        hi := lo;', chr(10),
'    END IF;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'rogue_pages';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'rogue_pages no longer picks a tier band where it did';
    END IF;
    body := replace(body, anchor, swap);

    -- The new variable.
    anchor := concat(
'    lo       SMALLINT;', chr(10),
'    hi       SMALLINT;');
    swap := concat(
'    lo       SMALLINT;', chr(10),
'    hi       SMALLINT;', chr(10),
'    mine     SMALLINT;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'rogue_pages no longer declares its band where it did';
    END IF;
    body := replace(body, anchor, swap);

    -- `mint_page` refuses a tier with no roll weight, which is exactly the
    -- guard keeping 8 to 10 out of the drop table. `mint_page_at` is the
    -- deliberate door through it.
    anchor := '        RETURN NEXT mint_page(p_player_id, lo, hi, NULL, NULL, p_region);';
    swap := concat(
'        IF lo = hi AND lo > 7 THEN', chr(10),
'            RETURN NEXT mint_page_at(p_player_id, lo, NULL, NULL, p_region);', chr(10),
'        ELSE', chr(10),
'            RETURN NEXT mint_page(p_player_id, lo, hi, NULL, NULL, p_region);', chr(10),
'        END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'rogue_pages no longer mints where it did';
    END IF;
    body := replace(body, anchor, swap);

    EXECUTE body;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every immortal carries a page no mortal can drop, and mortals are untouched
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who   BIGINT;
    r     RECORD;
    made  BIGINT;
    tier  SMALLINT;
    bad   TEXT;
    seen  INTEGER;
BEGIN
    SELECT p.player_id INTO who FROM players p WHERE p.deleted_at IS NULL LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to carry a page home';
        RETURN;
    END IF;

    BEGIN
        -- Every rogue in the game, mortal and immortal, made to hand pages
        -- over. Nothing is inferred from the arithmetic; it is all driven.
        FOR r IN
            SELECT s.species_id, s.name, s.rank, s.immortal_rank
            FROM creature_species s WHERE s.kind = 'rogue'
            ORDER BY COALESCE(s.immortal_rank, s.rank), s.name
        LOOP
            seen := 0;
            FOR made IN SELECT * FROM rogue_pages(who, r.species_id, NULL) LOOP
                SELECT mp.tier INTO tier FROM manual_pages mp WHERE mp.page_id = made;
                seen := seen + 1;

                IF r.immortal_rank IS NULL THEN
                    -- A mortal rogue must not have learned to carry these.
                    IF tier > 7 THEN
                        RAISE EXCEPTION
                            '% is mortal and carried a tier % page',
                            r.name, tier;
                    END IF;
                ELSE
                    IF tier <= 7 THEN
                        RAISE EXCEPTION
                            '% stands at realm % and still carries tier %',
                            r.name, r.immortal_rank, tier;
                    END IF;
                    IF tier > (SELECT max(t.tier) FROM page_tiers t) THEN
                        RAISE EXCEPTION
                            '% carried tier %, past the end of the ladder',
                            r.name, tier;
                    END IF;
                END IF;
            END LOOP;

            IF seen = 0 THEN
                RAISE EXCEPTION '% carried nothing at all', r.name;
            END IF;
        END LOOP;

        -- The top of the ladder is reachable, and only from the top realms.
        SELECT string_agg(DISTINCT s.name, ', ') INTO bad
        FROM creature_species s
        WHERE s.immortal_rank BETWEEN 16 AND 18;
        IF bad IS NULL THEN
            RAISE EXCEPTION 'no rogue stands high enough to carry a Pinnacle page';
        END IF;

        -- And a manual refined from them really is stronger than a tier 7 one,
        -- which is the entire point of the request.
        IF (SELECT mt.bonus_budget FROM manual_tiers mt WHERE mt.tier = 10)
           <= (SELECT mt.bonus_budget FROM manual_tiers mt WHERE mt.tier = 7) THEN
            RAISE EXCEPTION 'a tier 10 manual is no better than a tier 7 one';
        END IF;

        -- Qualified: this block declares `tier`, and a PL/pgSQL variable
        -- shadows a column of the same name.
        RAISE NOTICE
            'tier 10 manuals carry a budget of % against tier 7''s %',
            (SELECT mt.bonus_budget FROM manual_tiers mt WHERE mt.tier = 10),
            (SELECT mt.bonus_budget FROM manual_tiers mt WHERE mt.tier = 7);

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'every rogue was made to hand pages over, and rolled back';
END;
$probe$;
