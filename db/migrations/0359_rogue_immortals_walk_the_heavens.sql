-- 0359_rogue_immortals_walk_the_heavens
--
-- 0334 built the immortal ladder and gave it nine essences, and 0335 made
-- essence the only way up it. Nothing in the game has ever handed one over.
-- Every immortal in the server has been standing on a ladder with no rungs.
--
-- Rogue immortals are the first source: cultivators who went up and stayed up,
-- and who are carrying what they climbed on.
--
-- ALMOST NONE OF THIS IS NEW MACHINERY, WHICH IS THE POINT. `spawn_rogue` has
-- drawn ambushes since 0025 and `rogue_spawn_chance` already describes itself
-- as 'chance any gather, hunt or explore is interrupted by a rogue cultivator'.
-- Both call sites already exist: /hunt rolls one, and the seam screen behind
-- /gather, /mine and /explore rolls one per try. A beaten rogue already pays
-- out through `creature_drops` in `battle_conclude`, Fortune already taking its
-- share of the miss. What was missing was rogues standing in the heavens at
-- all - both regions hold fifteen beasts and a boss and nothing else.
--
-- So this adds the cultivators and fixes the three things that were in the way.
--
-- WHY A ROGUE'S REALM IS A NEW COLUMN AND NOT ITS `rank`. Essence is keyed to
-- the realm ladder: immortal_essences.rank runs 10 to 18, Dewberry to Yellow
-- Apricot, one per immortal realm. The obvious move is to give the rogue
-- creature_species.rank 10 to 18 and join. It is the wrong move twice over:
--
--   * `creature_species_rank_check` stops at 9 and everything downstream was
--     built for a ladder of nine. `compute_creature_damage` softens defence by
--     `defense_scale * 4^(rank-1)`; at rank 18 that is 10^12, which does not
--     make a rogue stronger, it makes the PLAYER'S DEFENCE STOP COUNTING. An
--     ambush nobody can armour against is not what was asked for.
--   * Every rank 9 creature in both heavens - fifteen beasts and a boss apiece,
--     sized by 0347 - is already 'immortal strength'. Rank 9 IS the immortal
--     band as far as the bestiary is concerned.
--
-- So the creature stays rank 9 and carries `immortal_rank`: the realm the
-- cultivator themselves stands at. Mortal creatures leave it NULL and nothing
-- about them changes. It is also the honest reading of the request - a rogue's
-- rank, said out loud, is Dewberry or Yellow Apricot, not a bestiary integer.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE creature_species
    ADD COLUMN immortal_rank SMALLINT
        CHECK (immortal_rank IS NULL OR immortal_rank >= 10);

COMMENT ON COLUMN creature_species.immortal_rank IS
    'For a cultivator who has gone past the mortal ladder: the realm rank they stand at, 10 (Dewberry) to 18 (Yellow Apricot), matching realms.rank and immortal_essences.rank. NULL for everything mortal, which leaves rank doing the work as before.';


-- ---------------------------------------------------------------------------
-- A rogue immortal is not made of beast parts
-- ---------------------------------------------------------------------------
--
-- `creature_drops` has taken beast materials only since 0017, which is right
-- for a table that was only ever describing carcasses. What an immortal is
-- carrying is not a carcass. Widened exactly far enough: essence, and only off
-- something that is actually an immortal.

CREATE OR REPLACE FUNCTION check_drop_is_beast_material()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
    kind_of TEXT;
BEGIN
    SELECT category INTO kind_of FROM materials WHERE code = NEW.material_code;

    IF kind_of = 'essence' THEN
        -- Only a cultivator who climbed the ladder is holding essence, so a
        -- stray essence row on a boar is still refused.
        IF NOT EXISTS (SELECT 1 FROM creature_species s
                       WHERE s.species_id = NEW.species_id
                         AND s.immortal_rank IS NOT NULL) THEN
            RAISE EXCEPTION
                'only an immortal carries essence, and % is not one',
                (SELECT code FROM creature_species WHERE species_id = NEW.species_id);
        END IF;
        RETURN NEW;
    END IF;

    IF kind_of <> 'beast' THEN
        RAISE EXCEPTION 'creature_drops takes beast materials only, got %', NEW.material_code;
    END IF;
    RETURN NEW;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- A rogue above rank 7 was carrying an impossible page
-- ---------------------------------------------------------------------------
--
-- `rogue_pages` reads `lo := GREATEST(1, r)` and `hi := LEAST(7, r + spread)`.
-- For any rogue past rank 7 that is lo > hi - a backwards range handed to
-- mint_page. It has never fired because the strongest rogue in the game is
-- rank 5, and it would have fired the moment these rank 9 ones landed.
--
-- The ceiling of 7 is deliberate and stays: pages stop at tier 7 and a rogue
-- cannot carry what does not exist. It is the floor that has to give way.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    lo := GREATEST(1, r);', chr(10),
'    hi := LEAST(7, r + game_config_value(''rogue_page_tier_spread'')::smallint);');

    swap := concat(
'    -- Pages stop at tier 7, so a rogue past that carries the best that', chr(10),
'    -- exists rather than a range that runs backwards.', chr(10),
'    hi := LEAST(7, r + game_config_value(''rogue_page_tier_spread'')::smallint);', chr(10),
'    lo := LEAST(GREATEST(1, r), hi);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'rogue_pages';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'rogue_pages no longer picks a tier range where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- An ambush finds someone of your own standing
-- ---------------------------------------------------------------------------
--
-- 0198 taught spawn_rogue to draw near the cultivator's own rank so a Nascent
-- Soul stopped being mugged by herb thieves. That has to keep working when the
-- rank in question is a realm past the mortal ladder - otherwise a fresh
-- Dewberry immortal meets a Yellow Apricot rogue and walks home with essence
-- worth two hundred and forty-three million times what their own realm asks
-- for, which would end the ladder rather than supply it.
--
-- One substitution: the rank being compared is the one the creature actually
-- stands at. Mortal rogues have no immortal_rank, so COALESCE leaves every
-- existing draw exactly as it was.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'      AND s.rank <= mine + 1', chr(10),
'    ORDER BY -ln(random()) / (cr.weight * CASE', chr(10),
'        WHEN s.rank > mine THEN game_config_value(''rogue_overmatch_weight'')', chr(10),
'        ELSE power(game_config_value(''rogue_rank_falloff''), mine - s.rank)', chr(10),
'    END)');

    swap := concat(
'      AND COALESCE(s.immortal_rank, s.rank) <= mine + 1', chr(10),
'    ORDER BY -ln(random()) / (cr.weight * CASE', chr(10),
'        WHEN COALESCE(s.immortal_rank, s.rank) > mine', chr(10),
'            THEN game_config_value(''rogue_overmatch_weight'')', chr(10),
'        ELSE power(game_config_value(''rogue_rank_falloff''),', chr(10),
'                   mine - COALESCE(s.immortal_rank, s.rank))', chr(10),
'    END)');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'spawn_rogue';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'spawn_rogue no longer weighs a rogue where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Eighteen cultivators who did not come down
-- ---------------------------------------------------------------------------
--
-- Nine per heaven, one standing at each immortal realm, so whatever realm a
-- player is at there is someone their own size to be ambushed by. The two
-- heavens get different rosters and different Paths - Black Heaven's are
-- demons and grave-robbers, White Heaven's are the Court's own deserters -
-- because the one complaint already outstanding about the heavens is that they
-- are the same place twice.
--
-- Sized off what already stands there: 0347 built the heavens' beasts at about
-- 2.9 billion HP for a Dewberry immortal to fight, so the Dewberry rogue opens
-- just under that and doubles each realm, the way a cultivator's own body
-- doubles each rank.
--
-- Attack climbs more slowly than health on purpose, and there is a hard reason
-- as well as a design one. `compute_creature_damage` still reads base_attack
-- into an INTEGER variable - 0347 widened the column to BIGINT and did not
-- widen that reader - so any creature past 2,147,483,647 attack raises
-- 'integer out of range' the moment it swings. The strongest rogue here lands
-- at about 0.7 billion, comfortably inside it. THE READER IS STILL A LATENT
-- BUG and is left alone rather than patched blind, because it is a damage path
-- every fight in the game runs through.

INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense,
     base_speed, description)
SELECT
    v.code, v.name, 9, v.realm, 'rogue',
    round(2000000000::numeric * power(2.0,  v.realm - 10))::bigint,
    round(  10000000::numeric * power(1.7,  v.realm - 10))::bigint,
    round(   3000000::numeric * power(1.8,  v.realm - 10))::bigint,
    45 + 3 * (v.realm - 10),
    v.description
FROM (VALUES
    -- Black Heaven: what crawled up out of it and stayed.
    ('rogue_ashen_vein_wanderer',   'Ashen Vein Wanderer',        10, 'shadow',
     'Came up through the ash and never washed it off.'),
    ('rogue_corpse_lantern_heretic','Corpse Lantern Heretic',     11, 'soul',
     'Carries a light that is somebody.'),
    ('rogue_sable_court_exile',     'Sable Court Exile',          12, 'poison',
     'Thrown out of a court that no longer admits it had one.'),
    ('rogue_grave_tide_revenant',   'Grave Tide Revenant',        13, 'bone',
     'Died at the right moment and declined the rest of it.'),
    ('rogue_marrow_feast_tyrant',   'Marrow Feast Tyrant',        14, 'blood',
     'Ate his way up the ladder. Literally, and then otherwise.'),
    ('rogue_eclipse_throne_usurper','Eclipse Throne Usurper',     15, 'illusion',
     'Sat on a throne for one afternoon and has been hunted since.'),
    ('rogue_abyssal_crown_devourer','Abyssal Crown Devourer',     16, 'enslavement',
     'Wears nine crowns and answers to none of the names on them.'),
    ('rogue_nightfall_sovereign',   'Nightfall Sovereign',        17, 'theft',
     'Everything he has, he took from someone who also took it.'),
    ('rogue_black_heaven_venerable','Black Heaven Demon Venerable',18,'transformation',
     'Went up alone, came back as something the histories argue about.'),

    -- White Heaven: the Court's own, with the register struck through.
    ('rogue_fallen_rites_ascetic',  'Fallen Rites Ascetic',       10, 'light',
     'Kept every rite but the one that mattered to the Court.'),
    ('rogue_cloud_register_deserter','Cloud Register Deserter',   11, 'wind',
     'Her name is still on the register, with a line through it.'),
    ('rogue_broken_mandate_envoy',  'Broken Mandate Envoy',       12, 'rule',
     'Delivered the mandate, read it on the way, and stopped.'),
    ('rogue_jade_tribunal_renegade','Jade Tribunal Renegade',     13, 'formation',
     'Judged the tribunal back. It did not take it well.'),
    ('rogue_star_charter_apostate', 'Star Charter Apostate',      14, 'star',
     'Charted a heaven that the Court insists is not there.'),
    ('rogue_radiant_decree_outcast','Radiant Decree Outcast',     15, 'wisdom',
     'Knew the decree was wrong and said so in the wrong room.'),
    ('rogue_empyrean_seal_breaker', 'Empyrean Seal Breaker',      16, 'space',
     'Opened something the Court had spent an age closing.'),
    ('rogue_immortal_court_fugitive','Immortal Court Fugitive',   17, 'time',
     'Has been three days ahead of the Court for four hundred years.'),
    ('rogue_white_heaven_rebel',    'White Heaven Rebel Venerable',18,'heaven',
     'The Court does not say this one''s name inside the Court.')
) AS v (code, name, realm, path, description);


INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path, TRUE
FROM (VALUES
    ('rogue_ashen_vein_wanderer','shadow'), ('rogue_corpse_lantern_heretic','soul'),
    ('rogue_sable_court_exile','poison'),   ('rogue_grave_tide_revenant','bone'),
    ('rogue_marrow_feast_tyrant','blood'),  ('rogue_eclipse_throne_usurper','illusion'),
    ('rogue_abyssal_crown_devourer','enslavement'), ('rogue_nightfall_sovereign','theft'),
    ('rogue_black_heaven_venerable','transformation'),
    ('rogue_fallen_rites_ascetic','light'), ('rogue_cloud_register_deserter','wind'),
    ('rogue_broken_mandate_envoy','rule'),  ('rogue_jade_tribunal_renegade','formation'),
    ('rogue_star_charter_apostate','star'), ('rogue_radiant_decree_outcast','wisdom'),
    ('rogue_empyrean_seal_breaker','space'),('rogue_immortal_court_fugitive','time'),
    ('rogue_white_heaven_rebel','heaven')
) AS v (code, path)
JOIN creature_species s ON s.code = v.code;


INSERT INTO creature_regions (species_id, region_code, weight)
SELECT s.species_id,
       CASE WHEN s.code IN (
           'rogue_ashen_vein_wanderer','rogue_corpse_lantern_heretic',
           'rogue_sable_court_exile','rogue_grave_tide_revenant',
           'rogue_marrow_feast_tyrant','rogue_eclipse_throne_usurper',
           'rogue_abyssal_crown_devourer','rogue_nightfall_sovereign',
           'rogue_black_heaven_venerable')
       THEN 'black_heaven' ELSE 'white_heaven' END,
       1
FROM creature_species s
WHERE s.immortal_rank IS NOT NULL;


-- What they were climbing on. One essence, their own realm's: the rank decides
-- WHICH, and the quantity is flat, so a Yellow Apricot rogue is worth two
-- hundred and forty-three million times a Dewberry one because of what it is
-- carrying rather than how much.
INSERT INTO creature_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT s.species_id, e.material_code, 0.65, 2, 5
FROM creature_species s
JOIN immortal_essences e ON e.rank = s.immortal_rank
WHERE s.immortal_rank IS NOT NULL;


-- ---------------------------------------------------------------------------
-- They are there, they are your size, and they are carrying the right thing
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n       INTEGER;
    bad     TEXT;
    who     BIGINT;
    mine    SMALLINT;
    got     BIGINT;
    hits    INTEGER := 0;
    own     INTEGER := 0;
    r       RECORD;
BEGIN
    -- Nine realms, both heavens, nobody missing and nobody doubled.
    SELECT string_agg(t.region_code || ' r' || t.realm, ', ') INTO bad
    FROM (
        SELECT cr.region_code, g.realm, count(s.species_id) AS have
        FROM (SELECT generate_series(10, 18) AS realm) g
        CROSS JOIN (VALUES ('black_heaven'), ('white_heaven')) AS cr (region_code)
        LEFT JOIN creature_species s ON s.immortal_rank = g.realm
        LEFT JOIN creature_regions x
               ON x.species_id = s.species_id AND x.region_code = cr.region_code
        GROUP BY 1, 2 HAVING count(x.species_id) <> 1
    ) t;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these heaven/realm pairs have no single rogue: %', bad;
    END IF;

    -- Each carries its own realm's essence and nothing else's.
    SELECT string_agg(s.code, ', ') INTO bad
    FROM creature_species s
    WHERE s.immortal_rank IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM creature_drops d
          JOIN immortal_essences e ON e.material_code = d.material_code
          WHERE d.species_id = s.species_id AND e.rank = s.immortal_rank);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these carry the wrong essence: %', bad;
    END IF;

    -- Nothing here can raise 'integer out of range' the first time it swings.
    SELECT string_agg(s.code, ', ') INTO bad
    FROM creature_species s WHERE s.base_attack > 2147483647;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these overflow compute_creature_damage: %', bad;
    END IF;

    -- A rogue past rank 7 now carries a page range that runs forwards. Driven
    -- rather than read: the old code handed mint_page lo=9, hi=7.
    SELECT s.species_id INTO got
    FROM creature_species s WHERE s.immortal_rank IS NOT NULL LIMIT 1;
    SELECT p.player_id INTO who FROM players p WHERE p.deleted_at IS NULL LIMIT 1;
    IF who IS NOT NULL THEN
        BEGIN
            PERFORM rogue_pages(who, got, 'black_heaven');
            RAISE EXCEPTION 'probe-ok';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE EXCEPTION 'a rank 9 rogue still cannot carry pages: %', SQLERRM;
            END IF;
        END;
    END IF;

    -- And the draw finds someone of the player's own standing. Measured, on
    -- the highest immortal in the game if there is one - the whole economy
    -- rests on a Dewberry not meeting a Yellow Apricot.
    SELECT pc.player_id, r2.rank INTO who, mine
    FROM player_cultivation pc
    JOIN realms r2 ON r2.realm_id = pc.realm_id
    WHERE r2.rank >= 10
    ORDER BY r2.rank DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to be ambushed yet - the draw is unmeasured';
    ELSE
        FOR i IN 1..400 LOOP
            got := spawn_rogue('black_heaven', who);
            IF got IS NOT NULL THEN
                hits := hits + 1;
                SELECT immortal_rank INTO n FROM creature_species WHERE species_id = got;
                IF n >= mine - 1 THEN own := own + 1; END IF;
            END IF;
        END LOOP;

        IF hits = 0 THEN
            RAISE EXCEPTION 'four hundred tries in Black Heaven and never an ambush';
        END IF;
        -- The falloff is 0.35 a realm, so all but a sliver should be within a
        -- realm of the player. This is the assertion that keeps the ladder.
        IF own::numeric / hits < 0.6 THEN
            RAISE EXCEPTION
                'only % of % ambushes were near the player''s own realm', own, hits;
        END IF;
        RAISE NOTICE
            '% ambushes in 400 tries, % of them within a realm of rank %',
            hits, own, mine;
    END IF;

    -- A mortal can never draw one, whatever region they stand in.
    SELECT count(*) INTO n
    FROM creature_species s
    WHERE s.immortal_rank IS NOT NULL AND s.immortal_rank <= 9;
    IF n > 0 THEN
        RAISE EXCEPTION '% immortal rogues sit inside the mortal ladder', n;
    END IF;

    FOR r IN
        SELECT x.region_code, s.immortal_rank AS realm, s.name,
               m.name AS carries, s.base_hp
        FROM creature_species s
        JOIN creature_regions x ON x.species_id = s.species_id
        JOIN creature_drops d ON d.species_id = s.species_id
        JOIN materials m ON m.code = d.material_code
        WHERE s.immortal_rank IS NOT NULL
        ORDER BY x.region_code, s.immortal_rank
    LOOP
        RAISE NOTICE '% r% % : % (% hp)',
            r.region_code, r.realm, r.name, r.carries, r.base_hp;
    END LOOP;
END;
$probe$;
