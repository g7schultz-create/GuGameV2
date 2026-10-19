-- 0278_a_hatched_beast_is_not_an_egg
--
-- Four things 0276 and 0277 got wrong, all of them visible the first time an
-- egg was actually hatched.
--
-- IT WAS CALLED AN EGG. `beast_egg_name` returns "Dull Storm Eagle Egg",
-- which is the right name for the thing in your bag and the wrong one for the
-- thing walking beside you. A hatched beast is a Dull Storm Eagle.
--
-- IT HAD TWO PATHS AND PICKED ONE AT RANDOM. `creature_paths` carries
-- `is_primary` with a unique index behind it, and both `pet_blow` and the
-- shelf were taking whichever row came back first - so a Storm Eagle was Wind
-- or Lightning depending on the planner, and the shelf listed it twice.
--
-- AND THE NUMBERS DID NOT WORK AT EITHER END. A pet's strength comes from its
-- egg's tier; its owner's comes from realm and gear, and the two are not
-- connected. Measured against the actual roster:
--
--     clearwest       22,446,739 a blow      a tier 8 pet is 1% of it
--     luckymate0_0        13,069 a blow      the same pet is 1,750% of it
--
-- One scale cannot serve both. So there are two dials now and they do
-- different jobs: `pet_attack_scale` sets what a beast is worth on its own,
-- raised so a deep egg is felt beside a strong cultivator; and
-- `pet_share_cap` stops it ever being more than a quarter of the blow it
-- joined, so nobody's beast fights the battle for them.
--
-- The cap lives in `player_swing`, because that is the only place that knows
-- both numbers at once.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 2.5,
    description =
        'What a hatched beast hits for, against what a creature of its tier '
        'would. Set so a tier 9 beast is about a fifth of the deepest blow on '
        'the server; `pet_share_cap` is what keeps it from being everything '
        'to a cultivator who cannot hit that hard.'
WHERE key = 'pet_attack_scale';

INSERT INTO game_config (key, value, description) VALUES
    ('pet_share_cap', 0.25,
     'The most of one blow that may come from the beast at heel. A pet''s '
     'strength tracks the egg it hatched from and its owner''s tracks realm '
     'and gear, so without this a deep egg in a shallow cultivator''s hands '
     'fights the battle for them.');


-- ---------------------------------------------------------------------------
-- Its own name, and its own Path
-- ---------------------------------------------------------------------------

CREATE FUNCTION hatched_beast_name(p_species_id BIGINT, p_rarity TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(q.word || ' ', '') || cs.name
    FROM creature_species cs
    LEFT JOIN egg_qualities q ON q.rarity = p_rarity
    WHERE cs.species_id = p_species_id;
$$;

COMMENT ON FUNCTION hatched_beast_name(BIGINT, TEXT) IS
    'What the beast is called once it is out. `beast_egg_name` names the egg, which is a different thing and stops being true the moment it hatches.';


CREATE FUNCTION pet_path(p_beast_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    -- The primary, which `creature_paths` has a unique index for. Taking
    -- whichever row came back first made a two-Path beast's matchup depend on
    -- the planner.
    SELECT cp.path_code
    FROM player_beasts b
    JOIN creature_paths cp ON cp.species_id = b.species_id
    WHERE b.beast_id = p_beast_id
    ORDER BY cp.is_primary DESC, cp.path_code
    LIMIT 1;
$$;

COMMENT ON FUNCTION pet_path(BIGINT) IS
    'The Path a beast fights on: its species'' primary one, chosen rather than whichever row the planner returned first.';


UPDATE player_beasts b
SET name = hatched_beast_name(b.species_id, b.rarity)
WHERE b.name <> hatched_beast_name(b.species_id, b.rarity);


DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'hatch_egg';

    old := '            beast_egg_name(egg.species_id, egg.rarity),';
    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'hatch_egg no longer names what it hatches';
    END IF;
    src := replace(src, old,
'            hatched_beast_name(egg.species_id, egg.rarity),');
    EXECUTE src;
END;
$$;


CREATE OR REPLACE FUNCTION pet_blow(
    p_beast_id BIGINT, p_defender_species_id BIGINT, p_defense BIGINT DEFAULT 0
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    atk     NUMERIC;
    mine    TEXT;
    matchup NUMERIC := 0;
    their   SMALLINT;
    scale   NUMERIC;
BEGIN
    atk := pet_attack(p_beast_id);
    IF atk IS NULL THEN
        RETURN 0;
    END IF;

    mine := pet_path(p_beast_id);

    IF mine IS NOT NULL THEN
        SELECT COALESCE(mi.damage_modifier, 0) INTO matchup
        FROM creature_incoming_paths ci
        JOIN matchup_interactions mi ON mi.code = ci.interaction
        WHERE ci.species_id = p_defender_species_id AND ci.path_code = mine;
    END IF;

    -- Immunity is a rule about the Path, the same as it is for a cultivator.
    IF matchup <= -1 THEN
        RETURN 0;
    END IF;

    SELECT COALESCE(cs.rank, 1) INTO their
    FROM creature_species cs WHERE cs.species_id = p_defender_species_id;

    scale := game_config_value('defense_scale')
             * power(game_config_value('creature_defense_scale_per_rank'),
                     GREATEST(0, COALESCE(their, 1) - 1));

    RETURN GREATEST(1, round(
        atk * (1 + COALESCE(matchup, 0))
        * scale / (scale + GREATEST(p_defense, 0))))::bigint;
END;
$$;


-- One row per beast. The shelf joined `creature_paths` and listed a two-Path
-- species twice.
CREATE OR REPLACE VIEW player_beast_shelf AS
SELECT b.beast_id, b.owner_id, b.name, b.tier, b.rarity, b.at_heel,
       b.hatched_at,
       cs.name AS species, cs.rank AS species_rank, cs.kind AS species_kind,
       q.emoji, q.word AS shell,
       r.sort_order AS rarity_order,
       p.name AS path_name, p.emoji AS path_emoji,
       round(pet_attack(b.beast_id)) AS attack,
       reg.name AS found_in_name
FROM player_beasts b
JOIN creature_species cs ON cs.species_id = b.species_id
JOIN rarities r ON r.code = b.rarity
LEFT JOIN egg_qualities q ON q.rarity = b.rarity
LEFT JOIN paths p ON p.code = pet_path(b.beast_id)
LEFT JOIN player_beast_eggs e ON e.egg_id = b.egg_id
LEFT JOIN regions reg ON reg.code = e.found_in;


-- ---------------------------------------------------------------------------
-- No beast fights the battle for its owner
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src
    FROM pg_proc WHERE proname = 'player_swing';

    old := '        beast_hit := pet_blow(beast, p_species_id, eff_def);
        IF beast_hit > 0 THEN
            beast_hit := LEAST(beast_hit, left_hp);';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'player_swing no longer lets the beast swing';
    END IF;

    src := replace(src, old,
'        beast_hit := pet_blow(beast, p_species_id, eff_def);

        -- Never more than a share of what its owner just did. A pet''s
        -- strength comes from its egg and its owner''s from realm and gear,
        -- and a deep egg in a shallow cultivator''s hands would otherwise
        -- deal seventeen times what they do.
        IF out_dmg > 0 THEN
            beast_hit := LEAST(beast_hit, GREATEST(1, round(
                out_dmg * game_config_value(''pet_share_cap''))))::bigint;
        END IF;

        IF beast_hit > 0 THEN
            beast_hit := LEAST(beast_hit, left_hp);');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- Both ends of the roster
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    strong  BIGINT;
    weak    BIGINT;
    egg     BIGINT;
    beast   BIGINT;
    target  BIGINT;
    swung   RECORD;
    cap     NUMERIC := game_config_value('pet_share_cap');
BEGIN
    SELECT cs.species_id INTO target
    FROM creature_species cs WHERE cs.kind = 'beast' ORDER BY cs.rank DESC LIMIT 1;

    -- The hardest hitter on the server, and somebody who barely hits at all.
    SELECT p.player_id INTO strong FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY (SELECT c.final_damage FROM compute_technique_damage(
                  p.player_id, dungeon_default_move(p.player_id), target, 1, 0) c) DESC
    LIMIT 1;

    SELECT p.player_id INTO weak FROM players p
    WHERE p.deleted_at IS NULL AND p.discord_id <> 0
      AND dungeon_default_move(p.player_id) IS NOT NULL
    ORDER BY (SELECT c.final_damage FROM compute_technique_damage(
                  p.player_id, dungeon_default_move(p.player_id), target, 1, 0) c) ASC
    LIMIT 1;

    IF strong IS NULL OR weak IS NULL OR strong = weak THEN
        RAISE NOTICE 'not two cultivators to compare; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- Give the WEAK one the deepest egg on the server. This is the case
        -- that was broken: a beast worth seventeen times its owner.
        SELECT e.egg_id INTO egg FROM player_beast_eggs e
        WHERE e.hatched_at IS NULL ORDER BY e.tier DESC LIMIT 1;

        IF egg IS NULL THEN
            RAISE NOTICE 'no eggs to hatch; the tests carry this';
            RAISE EXCEPTION 'probe-ok';
        END IF;

        UPDATE player_beast_eggs SET owner_id = weak WHERE egg_id = egg;
        beast := hatch_egg(weak, egg);

        IF (SELECT name FROM player_beasts WHERE beast_id = beast) LIKE '%Egg' THEN
            RAISE EXCEPTION 'the hatched beast is still called an egg';
        END IF;

        IF (SELECT count(*) FROM player_beast_shelf WHERE beast_id = beast) <> 1 THEN
            RAISE EXCEPTION 'the shelf lists one beast more than once';
        END IF;

        SELECT * INTO swung FROM player_swing(
            weak, dungeon_default_move(weak), target,
            99999999999::bigint, 0::bigint, NULL, NULL, 0);

        IF swung.pet_dealt > swung.dealt * cap THEN
            RAISE EXCEPTION
                'the beast dealt % of a blow of %, past its share',
                swung.pet_dealt, swung.dealt;
        END IF;
        IF swung.pet_dealt < 1 THEN
            RAISE EXCEPTION 'the beast contributed nothing at all';
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
