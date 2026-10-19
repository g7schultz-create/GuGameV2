-- 0381_one_realm_one_rung
--
-- 0378 set `rogue_immortal_page_step` to three because the page ladder ended
-- at ten: nine immortal realms had to share three rungs, so Dewberry through
-- Purple Mulberry all carried the same tier 8 page and the Yellow Apricot
-- rogue was worth no more than the Red Date one.
--
-- 0379 took the ladder to fifteen and left that three behind. The top five
-- rungs were reachable only by fusing - three pages a rung, which is two
-- hundred and forty-three tier 10 pages for a single tier 15 - and no rogue
-- could hand one over however deep you went to find it.
--
-- One realm, one rung. Nothing about the arithmetic changes; the step was
-- always the dial and it was set for a shorter ladder:
--
--     Dewberry          8   Refined beyond the drop table
--     Jade Plum         9   Extremely difficult refined
--     Purple Mulberry  10   Pinnacle Mortal World page
--     Golden Peach     11   Immortal transcription
--     Blood Cherry     12   Heavenly inheritance
--     Green Grape      13   Venerable's own hand
--     Red Date         14   Written before the Era
--     White Litchi     15   Pinnacle of all writing
--     Yellow Apricot   15   Pinnacle of all writing
--
-- The top two share the last rung, because there are nine realms and eight
-- rungs above seven. That is the `LEAST` against the top of the ladder doing
-- its job rather than an off-by-one - and the two realms that share it are the
-- two hardest to reach, which is the right place for a ladder to run out.
--
-- WHO THIS IS ACTUALLY OPEN TO. `spawn_rogue` draws within one realm of the
-- cultivator, so a tier 15 page is not a thing a Dewberry immortal can farm -
-- it is a thing a White Litchi immortal meets. The gate was already built; it
-- is the reward behind it that had stopped climbing.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config
SET value = 1,
    description = 'Immortal realms per step up the page ladder a rogue immortal carries. At 1 each realm is its own rung: Dewberry carries tier 8 and White Litchi the top of the ladder, with Yellow Apricot sharing it because there are nine realms above nine rungs.'
WHERE key = 'rogue_immortal_page_step';


-- ---------------------------------------------------------------------------
-- Every realm its own rung, and the top of the ladder actually reachable
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who   BIGINT;
    r     RECORD;
    made  BIGINT;
    rung  SMALLINT;
    seen  INTEGER;
    tiers SMALLINT[] := ARRAY[]::SMALLINT[];
    -- `rung` rather than `tier` throughout: a PL/pgSQL variable named for a
    -- column shadows it, and this probe reads page_tiers.tier three times.
    top   SMALLINT := (SELECT max(t.tier) FROM page_tiers t);
BEGIN
    SELECT p.player_id INTO who FROM players p WHERE p.deleted_at IS NULL LIMIT 1;
    IF who IS NULL THEN
        RAISE NOTICE 'nobody to carry a page home';
        RETURN;
    END IF;

    BEGIN
        FOR r IN
            SELECT DISTINCT ON (s.immortal_rank)
                   s.species_id, s.name, s.immortal_rank
            FROM creature_species s
            WHERE s.kind = 'rogue' AND s.immortal_rank IS NOT NULL
            ORDER BY s.immortal_rank, s.name
        LOOP
            seen := 0;
            FOR made IN SELECT * FROM rogue_pages(who, r.species_id, NULL) LOOP
                SELECT mp.tier INTO rung FROM manual_pages mp
                WHERE mp.page_id = made;
                seen := seen + 1;

                IF rung <= 7 THEN
                    RAISE EXCEPTION
                        '% stands at realm % and carried rung %',
                        r.name, r.immortal_rank, rung;
                END IF;
                IF rung > top THEN
                    RAISE EXCEPTION
                        '% carried rung %, past the end of the ladder', r.name, rung;
                END IF;
            END LOOP;

            IF seen = 0 THEN
                RAISE EXCEPTION '% carried nothing', r.name;
            END IF;

            tiers := tiers || rung;
            RAISE NOTICE 'realm % : % carries rung % (%)',
                r.immortal_rank, rpad(r.name, 30), rung,
                (SELECT pt.name FROM page_tiers pt WHERE pt.tier = rung);
        END LOOP;

        -- The point of the change: the top of the ladder is now something a
        -- rogue hands over rather than something only fusion reaches.
        IF NOT (top = ANY (tiers)) THEN
            RAISE EXCEPTION
                'no rogue carries rung %, so the top rungs are still fusion-only',
                top;
        END IF;

        -- And the rungs climb with the realm rather than sitting in blocks.
        IF (SELECT count(DISTINCT t) FROM unnest(tiers) AS t) < 8 THEN
            RAISE EXCEPTION
                'nine realms produced only % distinct rungs',
                (SELECT count(DISTINCT t) FROM unnest(tiers) AS t);
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'every immortal realm was made to hand a page over, and rolled back';
END;
$probe$;
