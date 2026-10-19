-- 0362_nine_doors_that_open_on_the_immortal_ladder
--
-- There are nine dungeons, one per mortal realm, and the deepest of them is a
-- joke to the people who play this game now. Measured rather than guessed:
-- First Burrow's boss holds 56,623,104 health, and the five immortals on this
-- server swing for between 125 and 772 MILLION through `player_swing`. Every
-- one of them one-shots the last door in the game. Coming the other way it
-- hits for about a million against forty-odd million of health - sixty-nine
-- rounds to kill the weakest of them.
--
-- Nine more doors, one per immortal realm, sized off those measurements.
--
-- WHY THE BOSSES ARE RANK 9 WITH AN `immortal_rank`. Same reason 0359's rogues
-- are: `creature_species_rank_check` stops at 9, and rank is wired into damage
-- in a way that does not survive being pushed past it. The realm a thing
-- stands at is its own column, and 0359 already added it.
--
-- WHICH EXPOSED A REAL HOLE, AND IT IS THE INTERESTING PART OF THIS MIGRATION.
-- `compute_creature_damage` softens a creature's blow by
--
--     dscale = defense_scale x creature_defense_scale_per_rank ^ (rank - 1)
--
-- and then multiplies by dscale / (dscale + your defence). That term exists so
-- defence keeps mattering as the numbers inflate - creature defence quadruples
-- per rank, and against a flat divisor it would be immunity by rank 5.
--
-- With every immortal creature pinned at rank 9, dscale is FROZEN at 3.93
-- million while a cultivator's defence keeps doubling every realm. At Dewberry
-- that ratio is 0.44 and a blow mostly lands. At Yellow Apricot, defence is
-- around 1.28 billion and the ratio is 0.003 - a rank 9 creature would be
-- doing a three-hundredth of its damage. Not hard. Harmless.
--
-- So the divisor reads the rank the thing actually STANDS at, the same way the
-- ambush draw does. That is one substitution, and it is the difference between
-- nine hard rooms and nine long ones. It touches the rogues from 0359 too,
-- which is correct - a Yellow Apricot rogue should not be a formality either.
-- Nothing without an immortal_rank changes by a single point.
--
-- HOW HARD, EXACTLY. Health is set so a room takes around a dozen rounds
-- solo at its own realm, and attack so the boss kills an unprepared cultivator
-- in six to nine. Both scale with the ladder: health x2.1 a realm against a
-- cultivator's x2, so the climb is felt, and attack x2.0 so time-to-die stays
-- flat instead of the deep rooms quietly becoming safe.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE dungeons DROP CONSTRAINT dungeons_realm_rank_check;
ALTER TABLE dungeons ADD CONSTRAINT dungeons_realm_rank_check
    CHECK (realm_rank >= 1 AND realm_rank <= 18);


-- ---------------------------------------------------------------------------
-- A blow is softened by the rank the thing stands at
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    dscale := game_config_value(''defense_scale'')', chr(10),
'              * power(game_config_value(''creature_defense_scale_per_rank''), rank_of - 1);');

    swap := concat(
'    -- The rank a creature STANDS at, not the one the bestiary files it', chr(10),
'    -- under. Every immortal creature is rank 9 because the rank column stops', chr(10),
'    -- there, and freezing this divisor at rank 9 while a cultivator''s', chr(10),
'    -- defence keeps doubling makes an immortal harmless rather than hard.', chr(10),
'    -- Mortal creatures have no immortal_rank and are untouched.', chr(10),
'    dscale := game_config_value(''defense_scale'')', chr(10),
'              * power(game_config_value(''creature_defense_scale_per_rank''),', chr(10),
'                      COALESCE((SELECT cs.immortal_rank FROM creature_species cs', chr(10),
'                                WHERE cs.species_id = p_attacker_species_id),', chr(10),
'                               rank_of) - 1);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_creature_damage';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_creature_damage no longer softens a blow where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- What is behind the nine new doors
-- ---------------------------------------------------------------------------
--
-- Attack tops out at 2,048,000,000 for the Yellow Apricot room, which is
-- deliberate and tight: `compute_creature_damage` still reads base_attack into
-- an INTEGER variable, so 2,147,483,647 is a wall, and this sits at 95 percent
-- of it. A tenth realm above Yellow Apricot cannot be built on this curve
-- without widening that reader first.

INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense,
     base_speed, description)
SELECT
    v.code, v.name, 9, v.realm, 'dungeon',
    round(4000000000::numeric * power(2.1, v.realm - 10))::bigint,
    round(   8000000::numeric * power(2.0, v.realm - 10))::bigint,
    round(   6000000::numeric * power(2.0, v.realm - 10))::bigint,
    60 + 4 * (v.realm - 10),
    v.description
FROM (VALUES
    ('dungeon_orchard_keeper',   'The Keeper Who Does Not Age',  10,
     'It has tended this orchard since before the orchard.'),
    ('dungeon_fate_severer',     'The Severer of Fates',         11,
     'It cuts the thread first and asks whose it was afterwards.'),
    ('dungeon_drowned_sovereign','Drowned Sovereign',            12,
     'Crowned, and then the sea closed over the coronation.'),
    ('dungeon_peach_refusing',   'The Peach That Will Not Fall', 13,
     'Ripe for four thousand years and still holding on.'),
    ('dungeon_cherry_tyrant',    'Tyrant of Nine Deaths',        14,
     'It has died eight times. It is unbothered by the ninth.'),
    ('dungeon_vine_sovereign',   'The Vine Sovereign',           15,
     'Every death on this vine fed the one above it.'),
    ('dungeon_date_magistrate',  'Magistrate of the Withering',  16,
     'It presides over a court where the sentence is always the same.'),
    ('dungeon_pale_seed',        'The Pale Seed',                17,
     'Something is inside it, and it has not finished becoming.'),
    ('dungeon_last_apricot',     'The Last Apricot',             18,
     'When this one falls there is nothing above it. It has not fallen.')
) AS v (code, name, realm, description);


INSERT INTO creature_paths (species_id, path_code, is_primary)
SELECT s.species_id, v.path, TRUE
FROM (VALUES
    ('dungeon_orchard_keeper','wood'),   ('dungeon_fate_severer','rule'),
    ('dungeon_drowned_sovereign','water'), ('dungeon_peach_refusing','time'),
    ('dungeon_cherry_tyrant','blood'),   ('dungeon_vine_sovereign','poison'),
    ('dungeon_date_magistrate','soul'),  ('dungeon_pale_seed','transformation'),
    ('dungeon_last_apricot','heaven')
) AS v (code, path)
JOIN creature_species s ON s.code = v.code;


INSERT INTO dungeons
    (dungeon_id, code, name, realm_rank, species_id, stone_cost, jade_cost,
     description)
SELECT
    (9 + (v.realm - 9))::smallint, v.code, v.name, v.realm, s.species_id,
    v.stones, v.jade, v.description
FROM (VALUES
    ('sunless_orchard',   'The Sunless Orchard',      10, 'dungeon_orchard_keeper',
        2000000::bigint,    10, 'Fruit grows here without light, and something picks it.'),
    ('severed_fates',     'Vault of Severed Fates',   11, 'dungeon_fate_severer',
        5000000::bigint,    12, 'A room full of threads, all of them cut, none of them dead.'),
    ('mulberry_sea',      'The Mulberry Sea',         12, 'dungeon_drowned_sovereign',
       13000000::bigint,    15, 'The sea turned to mulberry fields, and then thought better of it.'),
    ('undying_orchard',   'Orchard of the Undying',   13, 'dungeon_peach_refusing',
       33000000::bigint,    18, 'Everything here is ripe. Nothing here falls.'),
    ('crimson_recursion', 'The Crimson Recursion',    14, 'dungeon_cherry_tyrant',
       85000000::bigint,    22, 'The same hour, bleeding, over and over.'),
    ('thousand_deaths',   'Vine of a Thousand Deaths',15, 'dungeon_vine_sovereign',
      220000000::bigint,    26, 'It grows one length for every cultivator it takes.'),
    ('withering_court',   'The Withering Court',      16, 'dungeon_date_magistrate',
      560000000::bigint,    31, 'Judgement was passed on this place and it is still being served.'),
    ('pale_seed_hall',    'Hall of the Pale Seed',    17, 'dungeon_pale_seed',
     1400000000::bigint,    36, 'Something is germinating in here and it should not be.'),
    ('last_apricot',      'The Last Apricot',         18, 'dungeon_last_apricot',
     3600000000::bigint,    42, 'The top of the ladder, with something already sitting on it.')
) AS v (code, name, realm, boss, stones, jade, description)
JOIN creature_species s ON s.code = v.boss;


-- ---------------------------------------------------------------------------
-- An immortal room pays an immortal
-- ---------------------------------------------------------------------------
--
-- Two things, both small, both because a room that is harder than the one
-- below it and pays worse is a broken room rather than a hard one:
--
--   * ESSENCE, of the room's own realm. It is the only currency the immortal
--     ladder spends and until 0359 nothing in the game handed it over. A clear
--     on Normal is worth a few units against the twenty a stage asks for, so a
--     room is a meaningful fraction of a stage and not a shortcut past it.
--   * TIER 8 GEAR. `dungeon_mint_equipment` clamps the grade at 7 and tier 8
--     equipment and ore both exist. The clamp stays exactly where it is for
--     every mortal room and lifts by one for the immortal ones.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '    grade   SMALLINT := LEAST(GREATEST(p_rank, 1), 7);';
    swap := concat(
'    -- Tier 8 exists in both equipment_tiers and ores and no room could ever', chr(10),
'    -- reach it. The immortal rooms can; every mortal room is unchanged.', chr(10),
'    grade   SMALLINT := LEAST(GREATEST(p_rank, 1),', chr(10),
'                              CASE WHEN p_rank >= 10 THEN 8 ELSE 7 END);');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_mint_equipment';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_mint_equipment no longer grades a piece where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := '    ceiling := game_config_value(''gu_max_droppable_rank'')::smallint;';

    swap := concat(
'    -- ---- essence -------------------------------------------------------', chr(10),
'    -- The room''s own realm, and only in a room past the mortal ladder. What', chr(10),
'    -- the immortal ladder actually runs on, so a hard door is worth opening.', chr(10),
'    IF p_rank >= 10 THEN', chr(10),
'        DECLARE', chr(10),
'            ess  TEXT;', chr(10),
'            many BIGINT;', chr(10),
'        BEGIN', chr(10),
'            SELECT e.material_code INTO ess', chr(10),
'            FROM immortal_essences e WHERE e.rank = p_rank;', chr(10),
'            IF ess IS NOT NULL THEN', chr(10),
'                many := GREATEST(1, round(3 * p_scale))::bigint;', chr(10),
'                PERFORM grant_material(p_player_id, ess, many);', chr(10),
'                got := got || jsonb_build_object(''essence'',', chr(10),
'                    many || ''x '' || material_name(ess));', chr(10),
'            END IF;', chr(10),
'        END;', chr(10),
'    END IF;', chr(10),
chr(10),
anchor);

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'dungeon_spoils_for';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'dungeon_spoils_for no longer reads the Gu ceiling where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Eighteen doors, and the deep ones are dangerous rather than merely long
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    n       INTEGER;
    bad     TEXT;
    who     BIGINT;
    hp      BIGINT;
    def     BIGINT;
    boss    BIGINT;
    swing   BIGINT;
    dealt   BIGINT;
    tech    BIGINT;
    r       RECORD;
BEGIN
    SELECT count(*) INTO n FROM dungeons;
    IF n <> 18 THEN
        RAISE EXCEPTION 'there are % doors, wanted 18', n;
    END IF;

    -- Every realm on the ladder has exactly one, none missing, none doubled.
    SELECT string_agg(g.rank::text, ', ') INTO bad
    FROM generate_series(1, 18) AS g(rank)
    WHERE NOT EXISTS (SELECT 1 FROM dungeons d WHERE d.realm_rank = g.rank);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'no door for realm: %', bad;
    END IF;

    -- Nothing can raise 'integer out of range' the first time it swings.
    SELECT string_agg(s.code || ' (' || s.base_attack || ')', ', ') INTO bad
    FROM creature_species s WHERE s.base_attack > 2147483647;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these overflow compute_creature_damage: %', bad;
    END IF;

    -- The costs only ever climb, so a deeper room is never the cheap one.
    SELECT string_agg(d.code, ', ') INTO bad
    FROM dungeons d JOIN dungeons prev ON prev.realm_rank = d.realm_rank - 1
    WHERE d.stone_cost <= prev.stone_cost;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these cost no more than the room above: %', bad;
    END IF;

    -- And the health does too, measured off the boss rather than the row.
    SELECT string_agg(d.code, ', ') INTO bad
    FROM dungeons d
    JOIN creature_species s ON s.species_id = d.species_id
    JOIN dungeons prev ON prev.realm_rank = d.realm_rank - 1
    JOIN creature_species ps ON ps.species_id = prev.species_id
    WHERE s.base_hp <= ps.base_hp;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these are no tougher than the room above: %', bad;
    END IF;

    -- ---- the claim that this is HARD, driven rather than argued ----------
    SELECT pc.player_id, pp.max_hp, pp.defense INTO who, hp, def
    FROM player_cultivation pc
    JOIN realms r2 ON r2.realm_id = pc.realm_id
    JOIN player_physique pp ON pp.player_id = pc.player_id
    WHERE r2.rank >= 10
    ORDER BY pp.max_hp DESC LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to measure a room against';
        RETURN;
    END IF;

    SELECT d.species_id INTO boss FROM dungeons d WHERE d.realm_rank = 10;

    -- Coming the other way, the Dewberry room must actually threaten. Before
    -- this migration the deepest boss in the game needed sixty-nine rounds to
    -- kill this cultivator, which is not a fight, it is a wait.
    SELECT final_damage INTO dealt
    FROM compute_creature_damage(boss, who, 1, def);

    IF dealt <= 0 OR hp / GREATEST(dealt, 1) > 20 THEN
        RAISE EXCEPTION
            'the Dewberry room needs % rounds to kill a cultivator - that is not hard',
            hp / GREATEST(dealt, 1);
    END IF;
    RAISE NOTICE
        'the Dewberry room kills the toughest immortal in % rounds (% a hit)',
        hp / GREATEST(dealt, 1), dealt;

    -- And the freeze is genuinely gone: the deepest room hits harder than the
    -- shallowest, which is the whole point of the dscale patch. With the old
    -- frozen divisor these two numbers converged instead.
    SELECT d.species_id INTO boss FROM dungeons d WHERE d.realm_rank = 18;
    SELECT final_damage INTO swing
    FROM compute_creature_damage(boss, who, 1, def);
    IF swing <= dealt THEN
        RAISE EXCEPTION
            'the Yellow Apricot room hits for % against the Dewberry room''s %',
            swing, dealt;
    END IF;

    FOR r IN
        SELECT d.realm_rank, d.name, s.base_hp, s.base_attack
        FROM dungeons d JOIN creature_species s ON s.species_id = d.species_id
        WHERE d.realm_rank >= 10 ORDER BY d.realm_rank
    LOOP
        RAISE NOTICE 'r% % : % hp, % attack',
            r.realm_rank, r.name, r.base_hp, r.base_attack;
    END LOOP;
END;
$probe$;
