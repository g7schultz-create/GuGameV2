-- 0347_black_heaven_is_sized_for_immortals
--
-- 0339 sized the fifteen against the hardest MORTAL in the game, because when
-- it was written that was the only kind there was. Measured against the kind
-- that can actually get in, they are not immortal-grade at all:
--
--     Dao Realm - Peak         24,933,040 hp   2,804,941 def   113,819,867 a turn
--     Dewberry Immortal Early  49,866,080 hp   5,609,882 def   163,324,671 a turn
--
-- Crossing into rank 10 doubles the body and the armour outright. So the
-- weakest thing in Black Heaven - a Nether Shadow Wolf at 150,000,000 - dies
-- inside a SINGLE turn to the weakest immortal who can walk through the door,
-- and hits back for four tenths of one percent of them. The door asks for an
-- immortal and the room behind it was stocked for a mortal.
--
-- EVERY ONE OF THEM IS NOW PITCHED AT A DEWBERRY IMMORTAL, which is the floor
-- of the tier and the right thing to aim the floor of the region at:
--
--     the dark      3.5 - 6 turns to fell,   4-5% of the body a bite
--     Ancient       8 - 12 turns,            6-7%
--     Immemorial    14 - 18 turns,           8-10%
--     the King      20 turns,                12%
--
-- Turns AND bite together, because either alone is a lie. A beast that takes
-- twenty turns and cannot hurt you is a long walk, not a fight; the product
-- is what decides whether a hunt is survivable, and at the Immemorial end it
-- comes to rather more than one full body - which is what healing, guarding
-- and a beast at your heel are for.
--
-- `base_hp` BECOMES A BIGINT, and so do attack and defence. 0339 noted the
-- integer ceiling of 2,147,483,647 as the reason the Immemorial tier stopped
-- where it did; that was the column talking, not the design. It is the only
-- place in the creature tables still holding a 32-bit number -
-- `boss_encounters.max_hp` has been a bigint all along - and the immortal
-- tier has eight more ranks above Dewberry to grow into.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE creature_species
    ALTER COLUMN base_hp      TYPE BIGINT,
    ALTER COLUMN base_attack  TYPE BIGINT,
    ALTER COLUMN base_defense TYPE BIGINT;


UPDATE creature_species cs
SET base_hp = v.hp, base_attack = v.atk, base_defense = v.def
FROM (VALUES
    -- The dark: a fight a new immortal wins, and feels.
    ('nether_shadow_wolf',              570000000::bigint,  4900000::bigint, 1520000::bigint),
    ('ghost_lantern_beast',             660000000,  5200000, 1610000),
    ('black_eclipse_serpent',           750000000,  5500000, 1710000),
    ('night_terror_beast',              860000000,  5800000, 1800000),
    ('abyssal_bone_beast',              980000000,  6100000, 1890000),

    -- Ancient: a fight a new immortal has to think about.
    ('ancient_ghost_emperor_beast',    1300000000,  7300000, 2260000),
    ('ancient_nether_dragon',          1450000000,  7700000, 2390000),
    ('ancient_eclipse_wolf',           1600000000,  8100000, 2510000),
    ('ancient_night_terror_beast',     1800000000,  8500000, 2640000),
    ('ancient_abyssal_serpent',        2000000000,  8900000, 2760000),

    -- Immemorial: a fight a new immortal loses without help.
    ('immemorial_nether_shadow_beast', 2300000000,  9700000, 3010000),
    ('immemorial_black_heaven_dragon', 2450000000, 10300000, 3190000),
    ('immemorial_ghost_emperor_beast', 2600000000, 11000000, 3410000),
    ('immemorial_eternal_night_beast', 2750000000, 11600000, 3600000),
    ('immemorial_abyssal_demon_beast', 2900000000, 12200000, 3780000),

    ('shadow_demon_king',              3300000000, 14600000, 4530000)
) AS v (code, hp, atk, def)
WHERE cs.code = v.code;


-- ---------------------------------------------------------------------------
-- Measured against an actual Dewberry Immortal, not against the idea of one
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    body   BIGINT;
    armour BIGINT;
    turn   BIGINT;
    weakest RECORD;
    bad    TEXT;
BEGIN
    SELECT pc.player_id INTO who
    FROM player_cultivation pc
    JOIN players p ON p.player_id = pc.player_id
    WHERE pc.realm_id = 35 AND p.deleted_at IS NULL
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody stands at the top of the mortal ladder to promote';
        RETURN;
    END IF;

    -- Promote one, measure what an immortal IS, and put them back. The
    -- assignments survive the rollback; the breakthrough does not.
    BEGIN
        PERFORM breakthrough(who);
        SELECT pp.max_hp, pp.defense INTO body, armour
        FROM player_physique pp WHERE pp.player_id = who;
        turn := horde_walker_burst(
            who, (SELECT species_id FROM creature_species WHERE code = 'nether_shadow_wolf'));
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE 'a Dewberry Immortal: % hp, % defence, % a turn', body, armour, turn;

    -- Nothing in the room dies to one swing of the weakest immortal who can
    -- enter it. Three turns is the floor.
    SELECT string_agg(cs.name || ' (' || round(cs.base_hp::numeric / turn, 1) || ' turns)', ', ')
    INTO bad
    FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'black_heaven' AND cs.base_hp < turn * 3;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these fall in under three turns: %', bad;
    END IF;

    -- And nothing in the room is harmless. Three percent of the body a bite.
    SELECT cs.name,
           (SELECT b.final_damage FROM compute_creature_damage(
                cs.species_id, who, 1, armour) b) AS bite
    INTO weakest
    FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
    WHERE cr.region_code = 'black_heaven'
    ORDER BY (SELECT b.final_damage FROM compute_creature_damage(
                  cs.species_id, who, 1, armour) b)
    LIMIT 1;

    IF weakest.bite < body * 0.03 THEN
        RAISE EXCEPTION
            'the % bites for % against a % body - under three percent',
            weakest.name, weakest.bite, body;
    END IF;

    RAISE NOTICE
        'the softest thing in Black Heaven takes % turns and bites % percent',
        (SELECT round(min(cs.base_hp)::numeric / turn, 1)
         FROM creature_regions cr JOIN creature_species cs ON cs.species_id = cr.species_id
         WHERE cr.region_code = 'black_heaven'),
        round(weakest.bite * 100.0 / body, 1);
END;
$probe$;
