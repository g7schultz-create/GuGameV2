-- 0364_the_divisor_was_only_fixed_on_one_side
--
-- 0362 found that `compute_creature_damage` freezes its softening divisor at
-- the bestiary rank, so an immortal creature - always rank 9, because the rank
-- column stops there - goes harmless against a cultivator whose defence keeps
-- doubling. It patched that function to read the rank the creature STANDS at.
--
-- It patched exactly one of the two functions that do this.
--
-- `compute_technique_damage` has the identical divisor pointing the other way,
-- and the comment sitting directly above it already states the failure mode:
--
--     'Creature defence quadruples per rank; against a flat divisor that is
--      not defence, it is an immunity by rank 5.'
--
-- That reasoning does not stop at rank 9, and neither does the arithmetic. The
-- Yellow Apricot boss carries a billion points of defence against a divisor
-- frozen at 3.93 million, which is not heavy armour, it is a wall: the schema
-- suite caught a fresh cultivator dealing ONE POINT OF DAMAGE to The Last
-- Apricot, which is the exact thing that check exists to catch.
--
-- So the same substitution, on the same divisor, in the other function. Both
-- sides of every immortal fight now agree about what rank the thing is.
--
-- AND THE ROOMS ARE RE-TUNED, BECAUSE THIS MAKES THEM EASIER. Defence that
-- stops being immunity is defence that stops eating damage: measured against
-- the median immortal, the Dewberry room went from eleven rounds to eight.
-- Health goes 2.2 -> 3.0 billion to put the race back where 0363 set it.
-- Attack is untouched - the blow landing is what 0362 already fixed.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'    SELECT COALESCE(cs.rank, 1) INTO their_rank', chr(10),
'    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;');

    swap := concat(
'    -- The rank it STANDS at. Every immortal creature is filed at rank 9', chr(10),
'    -- because the rank column stops there, and a divisor frozen at rank 9', chr(10),
'    -- against defence that keeps doubling is the immunity the comment above', chr(10),
'    -- is describing. Mortal creatures have no immortal_rank and are', chr(10),
'    -- untouched.', chr(10),
'    SELECT COALESCE(cs.immortal_rank, cs.rank, 1) INTO their_rank', chr(10),
'    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'compute_technique_damage';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'compute_technique_damage no longer reads the defender rank where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


UPDATE creature_species s
SET base_hp = round(3000000000::numeric * power(2.1, s.immortal_rank - 10))::bigint
WHERE s.kind = 'dungeon' AND s.immortal_rank IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Nothing is immune, and the race survived the fix
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who     BIGINT;
    hp      BIGINT;
    def     BIGINT;
    tech    BIGINT;
    boss    BIGINT;
    bhp     BIGINT;
    bdef    BIGINT;
    sw      RECORD;
    tot     BIGINT := 0;
    swings  INTEGER := 60;
    per     BIGINT;
    to_kill NUMERIC;
    to_die  NUMERIC;
    dealt   BIGINT;
    bad     TEXT;
BEGIN
    -- The half the suite caught: defence must not be a wall for ANYTHING in
    -- the roster, measured the way that check measures it.
    SELECT string_agg(s.name, ', ') INTO bad
    FROM creature_species s
    WHERE s.immortal_rank IS NOT NULL
      AND (SELECT final_damage FROM compute_technique_damage(
              (SELECT pc.player_id FROM player_cultivation pc
               JOIN realms r ON r.realm_id = pc.realm_id
               WHERE r.rank >= 10 ORDER BY r.rank DESC LIMIT 1),
              (SELECT t.technique_id FROM techniques t
               WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1),
              s.species_id, 1, s.base_defense)) <= 1;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'defence is still an immunity on: %', left(bad, 300);
    END IF;

    SELECT pc.player_id, pp.max_hp, pp.defense INTO who, hp, def
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    JOIN player_physique pp ON pp.player_id = pc.player_id
    WHERE r.rank >= 10
    ORDER BY pp.max_hp
    OFFSET (SELECT count(*) / 2 FROM player_cultivation pc2
            JOIN realms r2 ON r2.realm_id = pc2.realm_id WHERE r2.rank >= 10)
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no immortal to race - the tuning is unmeasured';
        RETURN;
    END IF;

    SELECT u.technique_id INTO tech FROM player_usable_techniques u
    JOIN techniques t ON t.technique_id = u.technique_id
    WHERE u.player_id = who ORDER BY t.base_power DESC LIMIT 1;

    SELECT d.species_id, s.base_hp, s.base_defense INTO boss, bhp, bdef
    FROM dungeons d JOIN creature_species s ON s.species_id = d.species_id
    WHERE d.realm_rank = 10;

    IF tech IS NULL THEN
        RAISE NOTICE 'that immortal has no technique to swing';
        RETURN;
    END IF;

    BEGIN
        FOR i IN 1..swings LOOP
            SELECT * INTO sw FROM player_swing(
                who, tech, boss, bhp, bdef, hp, hp, 1, 'dungeon', 0::bigint);
            tot := tot + GREATEST(0, sw.dealt);
        END LOOP;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    per     := GREATEST(1, tot / swings);
    to_kill := ceil(bhp::numeric / per);
    SELECT final_damage INTO dealt FROM compute_creature_damage(boss, who, 1, def);
    to_die  := floor(hp::numeric / GREATEST(dealt, 1));

    RAISE NOTICE 'Dewberry room: kill in %, die in % (% a swing, % a blow)',
        to_kill, to_die, per, dealt;

    IF to_kill + 3 > to_die THEN
        RAISE EXCEPTION 'the Dewberry room is a loss again: % to kill, % to die',
            to_kill, to_die;
    END IF;
    IF to_kill < 6 THEN
        RAISE EXCEPTION 'the Dewberry room falls in % rounds', to_kill;
    END IF;
END;
$probe$;
