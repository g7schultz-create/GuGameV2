-- 0351_what_a_king_and_a_general_are_actually_worth
--
-- Both heaven bosses were handing over something far under their weight. The
-- Heavenly Court General - 3,300,000,000 health, twenty turns to fell - paid
-- a rank 2 uncommon; the Shadow Demon King paid a rank 6. 0349 wired the
-- first as specified and said at the time that it was modest.
--
-- They now carry the two things at the very top of the catalogue, and they
-- are a matched pair rather than two separate picks:
--
--     Heavenly Court General   Heavenly Web Gu
--                              rank 9, heaven, attack
--                              attack_power 0.858, suppression 0.472
--
--     Shadow Demon King        Heaven-Defying Chaos Gu
--                              rank 9, rule, attack
--                              attack_power 0.805, matchup_relief 0.443
--
-- The Court casts a web over everything and Black Heaven is what defies it.
-- One is the mandate and the other is the refusal of it, which is the same
-- shape as the two regions themselves.
--
-- THERE IS NO SOUL PATH AT THIS HEIGHT, which is why Spectral Soul's legacy
-- hands over a rule Gu rather than a soul one. The catalogue holds nothing
-- soul-Path above rank 7; the rule Path is where defiance of heaven lives in
-- this game, and 'Heaven-Defying' is the word actually on the worm.
--
-- THIS MAKES THE TWO BOSSES THE ONLY SOURCE OF A RANK 9 GU IN THE GAME, which
-- is deliberate and worth being explicit about. The bench stops at
-- `gu_max_refinable_rank` = 6 and no region hands out past
-- `gu_max_immortal_droppable_rank` = 8, so the fourteen rank 9 worms in the
-- catalogue have been unreachable by any route since they were written. Two
-- of them now have exactly one door each, and it is a 3.3 billion health door
-- behind a rank 10 gate. The probe checks that claim rather than asserting it
-- in a comment.
--
-- Forward-only. Do not edit once applied.


UPDATE creature_species
SET signature_gu_type_id = (SELECT gu_type_id FROM gu_types WHERE name = 'Heavenly Web Gu')
WHERE code = 'heavenly_court_general';

UPDATE creature_species
SET signature_gu_type_id = (SELECT gu_type_id FROM gu_types WHERE name = 'Heaven-Defying Chaos Gu')
WHERE code = 'shadow_demon_king';


-- ---------------------------------------------------------------------------
-- Worth felling, and the only way to either of them
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r        RECORD;
    n        INTEGER;
    who      BIGINT;
    granted  BIGINT;
BEGIN
    FOR r IN
        SELECT cs.name AS boss, cs.base_hp, g.name AS carries, g.rank, g.rarity
        FROM creature_species cs
        JOIN gu_types g ON g.gu_type_id = cs.signature_gu_type_id
        WHERE cs.signature_gu_type_id IS NOT NULL
    LOOP
        IF r.rank < 9 THEN
            RAISE EXCEPTION
                '% holds % health and hands over a rank % %',
                r.boss, r.base_hp, r.rank, r.carries;
        END IF;
        RAISE NOTICE '% -> % (rank %, %)', r.boss, r.carries, r.rank, r.rarity;
    END LOOP;

    -- Both of them, not one.
    SELECT count(*) INTO n FROM creature_species WHERE signature_gu_type_id IS NOT NULL;
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected two bosses carrying a Gu, found %', n;
    END IF;

    -- Nothing else in the game yields a rank 9: not the bench, not a region.
    IF game_config_value('gu_max_refinable_rank') >= 9 THEN
        RAISE EXCEPTION 'the bench can make a rank 9, so the bosses are not the only door';
    END IF;
    SELECT max(t.rank) INTO n
    FROM gu_region_drops d JOIN gu_types t ON t.gu_type_id = d.gu_type_id;
    IF n >= 9 THEN
        RAISE EXCEPTION 'a region scatters rank 9 Gu, so the bosses are not the only door';
    END IF;

    -- And the grant actually works at that rank - `grant_gu` is called
    -- directly by `claim_boss_reward` and skips every cap on the way in, so
    -- this is the one thing worth proving rather than reasoning about.
    SELECT p.player_id INTO who FROM players p WHERE p.deleted_at IS NULL LIMIT 1;
    IF who IS NOT NULL THEN
        BEGIN
            granted := grant_gu(
                who,
                (SELECT gu_type_id FROM gu_types WHERE name = 'Heavenly Web Gu'),
                'white_heaven');
            IF granted IS NULL THEN
                RAISE EXCEPTION 'a rank 9 Gu could not be handed over at all';
            END IF;
            RAISE EXCEPTION 'probe-ok';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
        END;
        RAISE NOTICE 'a rank 9 Gu can be handed over';
    END IF;
END;
$probe$;
