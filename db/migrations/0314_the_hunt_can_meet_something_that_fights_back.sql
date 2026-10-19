-- 0314_the_hunt_can_meet_something_that_fights_back
--
-- Every beast in this game is rank 1 or rank 2. Thirty-eight at rank 1, two
-- at rank 2, and nothing above - so the deepest cultivators on the server hunt
-- the same boars a newcomer does. m_i_y_u_k_i. swings for 250,000,000 at a
-- Stone Hide Boar holding 1,298.
--
-- That is not only a dull hunt, it is why the beast at your heel does nothing
-- there. `player_swing` lets the pet swing only if the target survived your
-- own blow, and against 1,298 health nothing ever does - so /fight is the one
-- lane where a pet contributes exactly zero, for every player on the server.
-- Beasts that survive a blow fix the hunt and the pet in the same stroke.
--
-- FOURTEEN NEW BEASTS, RANKS 3 TO 9, two a rank. Stats follow the curve the
-- game already uses everywhere - roughly four times the rank below, which is
-- the same multiple the dungeon bosses climb on. A rank 9 beast holds about
-- 19 million, which is under a rank 9 dungeon boss at 56 million and well
-- under the world beast, so the ladder stays in order.
--
-- DROPS 3 TO 7, BY RANK. `LEAST(7, rank)` entries each: a rank 3 drops three
-- kinds of material, a rank 7 or better drops seven. Against the 3 entries
-- and ~2 expected items a rank 1 gives today, that is the reason to walk
-- further out. The deeper the beast the further up the rarity ladder its
-- table reaches - rank 3 sees commons, rank 9 sees beast cores and dragon
-- scale - which also feeds the forge and body tempering, both of which eat
-- beast parts and have had only rank 1 and 2 corpses to eat.
--
-- AND A PICKER THAT KNOWS WHO IS ASKING. This is the dangerous half. The
-- hunt draws ANY non-rogue creature in the region weighted by how common it
-- is, with no regard for the cultivator - the comment in `world.py` still
-- records the time a Leviathan sat in the Eastern Sea draw and put Qi
-- Condensation cultivators in front of an unkillable wall they could not
-- leave. Adding rank 9 beasts to that draw unchanged would repeat it exactly.
--
-- So `spawn_beast` copies `spawn_rogue`, which solved this in 0198: the
-- region weight still decides WHICH beast of a rank turns up, and a falloff
-- decides how far below the cultivator the game reaches. One rank above is
-- allowed and rare.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('beast_rank_falloff', 0.40,
     'How sharply a hunt prefers beasts at the cultivator''s own rank over '
     'weaker ones. The beast twin of rogue_rank_falloff.'),
    ('beast_overmatch_weight', 0.20,
     'How often a hunt reaches one rank ABOVE the cultivator. Rare, and the '
     'only way a hunt is ever frightening.');


-- ---------------------------------------------------------------------------
-- What walks out of the deep country
-- ---------------------------------------------------------------------------

WITH spec (code, name, rank, hp, atk, def, region, weight, descr) AS (VALUES
  ('ash_maned_lion','Ash-Maned Lion',3,4600,310,110,'southern',0.9,
   'It hunts what hunts. The mane is not ash, it is what the mane has been through.'),
  ('grey_silt_crocodile','Grey Silt Crocodile',3,5100,280,140,'eastern',0.9,
   'Older than the river it lies in, and it has outlasted two courses of it.'),

  ('nine_lined_tiger','Nine-Lined Tiger',4,18400,1240,440,'western',0.7,
   'Nine stripes, and the ninth is counted after it has already begun.'),
  ('bronze_shell_tortoise','Bronze-Shell Tortoise',4,22000,980,700,'central',0.7,
   'It does not flee and it does not hurry. Neither has ever been necessary.'),

  ('frost_maw_wolf','Frost Maw Wolf',5,73700,4950,1750,'northern',0.55,
   'Runs down what is already cold. The running is a courtesy it extends to nothing.'),
  ('cinder_plume_hawk','Cinder Plume Hawk',5,68000,5400,1400,'southern',0.55,
   'Nests in vents. What comes down from it arrives lit.'),

  ('stone_sinew_ape','Stone Sinew Ape',6,295000,19800,7000,'western',0.4,
   'It has learned which rocks are worth throwing, and it is not sentimental about the difference.'),
  ('drowned_bell_eel','Drowned Bell Eel',6,320000,17500,8200,'eastern',0.4,
   'The ringing is its hunting call. By the time it is loud you are inside it.'),

  ('thunder_horn_bull','Thunder Horn Bull',7,1180000,79200,28000,'northern',0.28,
   'The horn draws the sky down. The bull is merely what the sky lands behind.'),
  ('hollow_mountain_bear','Hollow Mountain Bear',7,1350000,71000,33000,'central',0.28,
   'Something dug the cave out. It was not there before the bear.'),

  ('sky_scaled_python','Sky-Scaled Python',8,4720000,317000,112000,'eastern',0.18,
   'Long enough that the head and the tail are weather in two different provinces.'),
  ('ember_bone_rhinoceros','Ember-Bone Rhinoceros',8,5400000,289000,131000,'southern',0.18,
   'The bone glows through. It has been burning from the inside for a century and is not done.'),

  ('primordial_dragon_whale','Primordial Dragon Whale',9,18900000,1270000,450000,'eastern',0.09,
   'It does not belong to this era. Nobody has explained the arrangement to it.'),
  ('sovereign_ninetail_fox','Sovereign Nine-Tail Fox',9,17200000,1390000,410000,'western',0.09,
   'Eight tails is a very old fox. The ninth is a different kind of thing entirely.')
), made AS (
    INSERT INTO creature_species
        (code, name, kind, rank, base_hp, base_attack, base_defense, description)
    SELECT s.code, s.name, 'beast', s.rank::smallint, s.hp, s.atk, s.def, s.descr
    FROM spec s
    RETURNING species_id, code
)
INSERT INTO creature_regions (species_id, region_code, weight)
SELECT m.species_id, s.region, s.weight::numeric
FROM made m JOIN spec s ON s.code = m.code;


-- ---------------------------------------------------------------------------
-- What they leave behind: LEAST(7, rank) kinds, richer the deeper it was
-- ---------------------------------------------------------------------------

WITH tiered (rank, pos, material, chance, lo, hi) AS (VALUES
  -- Positions 1-3 are the common spine every new beast drops.
  (0,1,'beast_blood',0.95,2,5),
  (0,2,'bone_fragment',0.90,2,4),
  (0,3,'beast_horn',0.85,1,3),
  -- 4 and 5 open at rank 4 and 5: uncommon.
  (0,4,'tortoise_shell_plate',0.70,1,3),
  (0,5,'thunder_horn',0.60,1,2),
  -- 6 and 7 open at rank 6 and 7: the rare end.
  (0,6,'beast_core',0.45,1,2),
  (0,7,'iron_bone',0.35,1,2)
), picked AS (
    SELECT cs.species_id, t.material, t.chance, t.lo, t.hi
    FROM creature_species cs
    CROSS JOIN tiered t
    WHERE cs.kind = 'beast' AND cs.rank >= 3
      AND t.pos <= LEAST(7, cs.rank)
)
INSERT INTO creature_drops
    (species_id, material_code, chance, min_quantity, max_quantity)
SELECT p.species_id, p.material, p.chance::numeric,
       -- A deeper beast of the same kind gives more of it.
       p.lo, p.hi + (SELECT rank FROM creature_species WHERE species_id = p.species_id) / 3
FROM picked p;


-- ---------------------------------------------------------------------------
-- A hunt that knows who is hunting
-- ---------------------------------------------------------------------------

CREATE FUNCTION spawn_beast(p_region TEXT, p_player_id BIGINT DEFAULT NULL)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    found BIGINT;
    mine  SMALLINT;
BEGIN
    SELECT COALESCE(r.rank, 1) INTO mine
    FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.player_id = p_player_id;

    mine := COALESCE(mine, 1);

    -- The region weight still decides WHICH beast of a rank turns up; the
    -- falloff decides how far below the cultivator the hunt reaches. One rank
    -- above is allowed and rare - the only way a hunt is ever frightening.
    SELECT s.species_id INTO found
    FROM creature_regions cr
    JOIN creature_species s ON s.species_id = cr.species_id
    WHERE cr.region_code = p_region
      AND s.kind NOT IN ('rogue', 'world', 'boss')
      AND s.rank <= mine + 1
    ORDER BY -ln(random()) / (cr.weight * CASE
        WHEN s.rank > mine THEN game_config_value('beast_overmatch_weight')
        ELSE power(game_config_value('beast_rank_falloff'), mine - s.rank)
    END)
    LIMIT 1;

    -- A region holding nothing at or below the cultivator must still offer a
    -- hunt rather than silently refusing one.
    IF found IS NULL THEN
        SELECT s.species_id INTO found
        FROM creature_regions cr
        JOIN creature_species s ON s.species_id = cr.species_id
        WHERE cr.region_code = p_region
          AND s.kind NOT IN ('rogue', 'world', 'boss')
        ORDER BY s.rank, -ln(random()) / cr.weight
        LIMIT 1;
    END IF;

    RETURN found;
END;
$$;

COMMENT ON FUNCTION spawn_beast(TEXT, BIGINT) IS
    'The beast a hunt turns up in a region, drawn near the hunter''s own rank the way spawn_rogue draws an ambush.';


-- ---------------------------------------------------------------------------
-- The ladder is in order and every new beast pays
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    bad TEXT;
    n   INTEGER;
BEGIN
    -- Nothing hunted may outweigh a dungeon boss of its rank.
    SELECT string_agg(b.name || ' (' || b.base_hp || ')', ', ') INTO bad
    FROM creature_species b
    JOIN creature_species d ON d.kind = 'dungeon' AND d.rank = b.rank
    WHERE b.kind = 'beast' AND b.base_hp >= d.base_hp;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'these hunt beasts outweigh their dungeon boss: %', bad;
    END IF;

    -- Every new beast drops exactly LEAST(7, rank) kinds.
    SELECT string_agg(cs.name || ' drops ' || d.n || ' at rank ' || cs.rank, ', ')
    INTO bad
    FROM creature_species cs
    JOIN LATERAL (SELECT count(*) AS n FROM creature_drops
                  WHERE species_id = cs.species_id) d ON TRUE
    WHERE cs.kind = 'beast' AND cs.rank >= 3 AND d.n <> LEAST(7, cs.rank);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'wrong number of drops: %', bad;
    END IF;

    -- And every one of them is somewhere a hunt can reach.
    SELECT count(*) INTO n FROM creature_species cs
    WHERE cs.kind = 'beast' AND cs.rank >= 3
      AND NOT EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.species_id = cs.species_id);
    IF n > 0 THEN
        RAISE EXCEPTION '% new beasts live in no region', n;
    END IF;

    RAISE NOTICE 'beasts now run rank 1 to %',
        (SELECT max(rank) FROM creature_species WHERE kind = 'beast');
END;
$$;


-- ---------------------------------------------------------------------------
-- A newcomer does not meet a dragon whale
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    weak  BIGINT;
    deep  BIGINT;
    got   SMALLINT;
    worst SMALLINT := 0;
    best  SMALLINT := 0;
    i     INTEGER;
BEGIN
    SELECT pc.player_id INTO weak FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    ORDER BY r.rank LIMIT 1;

    SELECT pc.player_id INTO deep FROM player_cultivation pc
    JOIN realms r ON r.realm_id = pc.realm_id
    ORDER BY r.rank DESC LIMIT 1;

    IF weak IS NULL OR deep IS NULL THEN
        RAISE NOTICE 'no cultivators to draw for; the tests carry this';
        RETURN;
    END IF;

    -- Forty hunts for the shallowest cultivator on the server.
    FOR i IN 1..40 LOOP
        SELECT s.rank INTO got FROM creature_species s
        WHERE s.species_id = spawn_beast('eastern', weak);
        worst := GREATEST(worst, COALESCE(got, 0));
    END LOOP;

    -- And forty for the deepest.
    FOR i IN 1..40 LOOP
        SELECT s.rank INTO got FROM creature_species s
        WHERE s.species_id = spawn_beast('eastern', deep);
        best := GREATEST(best, COALESCE(got, 0));
    END LOOP;

    IF worst > (SELECT r.rank + 1 FROM player_cultivation pc
                JOIN realms r ON r.realm_id = pc.realm_id
                WHERE pc.player_id = weak) THEN
        RAISE EXCEPTION
            'the shallowest cultivator was shown a rank % beast', worst;
    END IF;

    RAISE NOTICE
        'shallowest met up to rank %, deepest up to rank %', worst, best;
END;
$$;
