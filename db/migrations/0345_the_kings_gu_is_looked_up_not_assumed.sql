-- 0345_the_kings_gu_is_looked_up_not_assumed
--
-- 0344 put the signature Gu on `creature_species` and then read it off
-- `owed`, which is a `boss_encounters` row:
--
--     record "owed" has no field "signature_gu_type_id"
--
-- PL/pgSQL does not notice that until the line runs, so the migration applied
-- cleanly, its own probes passed - they check the data, not the payout - and
-- the first thing to break was every test that settles a boss. Five of them,
-- all at once, none of them about Black Heaven.
--
-- Which is the useful part: `claim_boss_reward` is how EVERY boss in the game
-- pays out, so a column that does not exist on the record it was read from
-- broke the Void Ash Revenant and the Heaven Scourge Leviathan too. A
-- migration that touches a shared payout is not a Black Heaven change, and
-- the probes I wrote for it were looking the wrong way.
--
-- The species is fetched by the id the encounter already carries.
--
-- Forward-only. Do not edit once applied.


DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    anchor := concat(
'        -- What this one was known for. Not a roll: a King has exactly one', chr(10),
'        -- of these and the person who brought it down gets it.', chr(10),
'        IF owed.signature_gu_type_id IS NOT NULL THEN', chr(10),
'            PERFORM grant_gu(p_player_id, owed.signature_gu_type_id,', chr(10),
'                             owed.region_code);', chr(10),
'        END IF;');

    swap := concat(
'        -- What this one was known for. Not a roll: a King has exactly one', chr(10),
'        -- of these and the person who brought it down gets it.', chr(10),
'        --', chr(10),
'        -- Both halves are fetched rather than read off `owed`, which is not', chr(10),
'        -- the encounter row - it is a six column SELECT of encounter_id,', chr(10),
'        -- species_id, status, slayer_id, name and damage, and carries', chr(10),
'        -- neither the signature nor the region. 0344 assumed one and 0345''''s', chr(10),
'        -- first draft assumed the other.', chr(10),
'        DECLARE', chr(10),
'            crest BIGINT;', chr(10),
'            found TEXT;', chr(10),
'        BEGIN', chr(10),
'            SELECT cs.signature_gu_type_id, e.region_code', chr(10),
'            INTO crest, found', chr(10),
'            FROM boss_encounters e', chr(10),
'            JOIN creature_species cs ON cs.species_id = e.species_id', chr(10),
'            WHERE e.encounter_id = owed.encounter_id;', chr(10),
chr(10),
'            IF crest IS NOT NULL THEN', chr(10),
'                PERFORM grant_gu(p_player_id, crest, found);', chr(10),
'            END IF;', chr(10),
'        END;');

    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc WHERE proname = 'claim_boss_reward';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'the signature Gu is no longer granted where 0344 put it';
    END IF;
    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every boss in the game can still pay out
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    who    BIGINT;
    spot   BIGINT;
    kind   RECORD;
BEGIN
    SELECT p.player_id INTO who FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM player_cultivation pc WHERE pc.player_id = p.player_id)
    LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'nobody to pay - the patch stands on the test suite';
        RETURN;
    END IF;

    -- Every kind of boss, including the one that carries a signature Gu and
    -- the two that do not. Rolled back; this is a rehearsal, not a spawn.
    FOR kind IN
        SELECT cs.species_id, cs.name, cs.signature_gu_type_id,
               COALESCE((SELECT cr.region_code FROM creature_regions cr
                         WHERE cr.species_id = cs.species_id LIMIT 1), 'central') AS where_at
        FROM creature_species cs WHERE cs.kind IN ('world', 'boss')
    LOOP
        INSERT INTO boss_encounters
            (species_id, region_code, max_hp, current_hp, status, closes_at, ended_at)
        VALUES (kind.species_id, kind.where_at, 1000, 0, 'slain',
                now() + interval '1 hour', now())
        RETURNING encounter_id INTO spot;

        INSERT INTO boss_strikes (encounter_id, player_id, damage)
        VALUES (spot, who, 1000)
        ON CONFLICT (encounter_id, player_id) DO UPDATE SET damage = 1000;

        -- The point is that it RUNS. 0344's fault was a column that does not
        -- exist on the record it was read from, which PL/pgSQL only discovers
        -- when the line executes.
        PERFORM claim_boss_reward(who, spot);

        DELETE FROM boss_strikes WHERE encounter_id = spot;
        DELETE FROM boss_encounters WHERE encounter_id = spot;
    END LOOP;

    RAISE NOTICE 'every boss in the game pays out again';
END;
$probe$;
