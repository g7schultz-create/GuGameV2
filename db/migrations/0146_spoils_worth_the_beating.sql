-- 0146_spoils_worth_the_beating
--
-- A world beast paid out of `creature_drops` - the same table a hunt rolls -
-- so the reward for the whole server bringing down a rank 9 leviathan was
-- three rare beast materials worth two or three Spirit Stones each. That is
-- the reward that is not one, and the same shape as refinement handing back a
-- technique the player could have bought.
--
-- THREE CHANGES.
--
-- `boss_drops` is a second table, boss-only, so a world beast can pay in
-- things nothing else in the game gives. It is deliberately not more rows in
-- `creature_drops`: that table is what a corpse yields to whoever killed it,
-- and a hunt must never be able to roll these.
--
-- What goes in it is deep ore. Golden Crow at tier 7 out of the Western
-- Desert, Sea God Adamant out of the Eastern Sea - each region-exclusive, each
-- about a hundred and ninety swings of /mine at full cap to gather nine of, so
-- a beast yielding two is a genuine prize and still not a substitute for
-- mining.
--
-- And one ore from SOMEWHERE ELSE each: the Revenant holds Soulstone out of
-- the Southern Border, the Leviathan holds Everwinter Adamant out of the
-- Northern Plains. A world beast is the only thing in the game that hands over
-- another region's deep seam, which is worth being the reason to fight one.
--
-- Bulk counts as a reward too - the Leviathan yields four to eight Dragon
-- Whale Bone on top of the two to five its corpse already gives - so the rule
-- for this table is that it must contain something exclusive, not that every
-- row must be.
--
-- A TECHNIQUE MANUAL, at a low chance and weighted hard by contribution. 0131
-- gave advanced techniques two routes - off an elite, or out of a good
-- refinement - and a world beast guarding a killer move is the third and the
-- most fitting. Slain only: a beast that escapes takes its book with it.
--
-- JADE FOR EVERYONE, ROLLED. It used to be fifteen to whoever landed the last
-- blow, which pays one person for the timing of their afternoon. Now every
-- cultivator who bled for it rolls their own, so turning up is the thing that
-- is rewarded and the amount is a small event of its own.
--
-- Forward-only. Do not edit once applied.


DELETE FROM game_config WHERE key = 'boss_jade_slayer';

INSERT INTO game_config (key, value, description) VALUES
    ('boss_jade_min', 4,
     'Least Spirit Jade a world beast pays a cultivator who struck it. Rolled per person, not split.'),
    ('boss_jade_max', 30,
     'Most Spirit Jade a world beast pays one cultivator. Rolled, so turning up is what is rewarded and the size of it is luck.'),
    ('boss_manual_chance', 0.20,
     'Chance a slain world beast was guarding a technique manual, before contribution weighting. The third route to an advanced technique.')
ON CONFLICT (key) DO UPDATE SET
    value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- boss_drops
-- ---------------------------------------------------------------------------

CREATE TABLE boss_drops (
    species_id    BIGINT   NOT NULL REFERENCES creature_species (species_id)
                  ON DELETE CASCADE,
    material_code TEXT     NOT NULL REFERENCES materials (code) ON DELETE RESTRICT,

    chance        NUMERIC(6, 4) NOT NULL CHECK (chance > 0 AND chance <= 1),
    min_quantity  SMALLINT NOT NULL DEFAULT 1 CHECK (min_quantity >= 1),
    max_quantity  SMALLINT NOT NULL DEFAULT 1,

    PRIMARY KEY (species_id, material_code),
    CONSTRAINT boss_drops_range CHECK (max_quantity >= min_quantity)
);

CREATE INDEX boss_drops_material_idx ON boss_drops (material_code);

COMMENT ON TABLE boss_drops IS
    'What a world beast yields on top of its own corpse. Separate from creature_drops so a hunt can never roll these, whatever else changes.';


INSERT INTO boss_drops (species_id, material_code, chance, min_quantity, max_quantity)
SELECT cs.species_id, v.material_code, v.chance, v.lo, v.hi
FROM (VALUES
    -- The Revenant holds the Western Desert's deep seams, and Soulstone out
    -- of the Southern Border, which suits what it is made of.
    ('void_ash_revenant',        'blazing_sunsteel',   0.4000, 1, 3),
    ('void_ash_revenant',        'golden_crow_ore',    0.1500, 1, 2),
    ('void_ash_revenant',        'soulstone_ore',      0.2500, 1, 2),
    ('void_ash_revenant',        'soul_crystal',       0.8000, 3, 6),
    ('void_ash_revenant',        'heroic_soul',        0.3500, 1, 2),

    -- The Leviathan holds the Eastern Sea's, and Everwinter out of the North.
    ('heaven_scourge_leviathan', 'dragon_whale_ore',   0.4500, 2, 4),
    ('heaven_scourge_leviathan', 'sea_god_adamant',    0.2000, 1, 3),
    ('heaven_scourge_leviathan', 'everwinter_adamant', 0.1000, 1, 2),
    ('heaven_scourge_leviathan', 'life_essence',       0.7000, 2, 4),
    ('heaven_scourge_leviathan', 'dragon_whale_bone',  1.0000, 4, 8)
) AS v (species_code, material_code, chance, lo, hi)
JOIN creature_species cs ON cs.code = v.species_code;


-- ---------------------------------------------------------------------------
-- claim_boss_reward, paying what a world beast should
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced: the returned row gains a `manual` column, and
-- CREATE OR REPLACE cannot change a return type.
DROP FUNCTION claim_boss_reward(BIGINT);

CREATE FUNCTION claim_boss_reward(p_player_id BIGINT)
RETURNS TABLE (
    encounter_id BIGINT,
    beast_name   TEXT,
    outcome      TEXT,
    my_damage    BIGINT,
    my_share     NUMERIC,
    stones       BIGINT,
    jade         BIGINT,
    spoils       JSONB,
    manual       TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    owed   RECORD;
    dealt  BIGINT;
    share  NUMERIC;
    weight NUMERIC;
    paid   BIGINT;
    coin   BIGINT := 0;
    d      RECORD;
    qty    INTEGER;
    loot   JSONB := '[]'::jsonb;
    book   BIGINT;
    book_name TEXT;
BEGIN
    SELECT e.encounter_id, e.species_id, e.status, e.slayer_id,
           cs.name, bs.damage
    INTO owed
    FROM boss_strikes bs
    JOIN boss_encounters e ON e.encounter_id = bs.encounter_id
    JOIN creature_species cs ON cs.species_id = e.species_id
    WHERE bs.player_id = p_player_id
      AND bs.rewarded_at IS NULL
      AND e.status <> 'open'
    ORDER BY e.ended_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'you have nothing owing from a world beast'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(sum(bs.damage), 0) INTO dealt
    FROM boss_strikes bs WHERE bs.encounter_id = owed.encounter_id;

    share  := CASE WHEN dealt > 0 THEN owed.damage::numeric / dealt ELSE 0 END;
    weight := LEAST(1, 0.35 + 0.65 * share);

    paid := GREATEST(1, round(owed.damage * game_config_value('boss_stones_per_hp')
                              * CASE WHEN owed.status = 'slain' THEN 1 ELSE 0.5 END));
    PERFORM grant_material(p_player_id, 'spirit_stone', paid);

    -- Everyone who struck it rolls their own, whether it fell or fled. Paying
    -- the last blow alone rewarded the timing of somebody's afternoon.
    coin := game_config_value('boss_jade_min')
            + floor(random() * (game_config_value('boss_jade_max')
                                - game_config_value('boss_jade_min') + 1));
    IF owed.status <> 'slain' THEN
        coin := GREATEST(1, round(coin / 2.0));
    END IF;
    PERFORM grant_jade(p_player_id, coin, 'world_beast');

    IF owed.status = 'slain' THEN
        FOR d IN
            SELECT x.material_code, x.chance, x.min_quantity, x.max_quantity,
                   m.name
            FROM (
                SELECT cd.material_code, cd.chance, cd.min_quantity, cd.max_quantity
                FROM creature_drops cd WHERE cd.species_id = owed.species_id
                UNION ALL
                SELECT bd.material_code, bd.chance, bd.min_quantity, bd.max_quantity
                FROM boss_drops bd WHERE bd.species_id = owed.species_id
            ) x
            JOIN materials m ON m.code = x.material_code
        LOOP
            IF random() < d.chance * weight THEN
                qty := d.min_quantity
                       + floor(random() * (d.max_quantity - d.min_quantity + 1));
                PERFORM grant_material(p_player_id, d.material_code, qty);
                loot := loot || jsonb_build_object(
                    'code', d.material_code, 'name', d.name, 'quantity', qty);
            END IF;
        END LOOP;

        -- What it was guarding. Weighted hard by contribution, and never one
        -- already owned - a duplicate is not a prize.
        IF random() < game_config_value('boss_manual_chance') * weight THEN
            SELECT m.manual_id, m.name INTO book, book_name
            FROM manuals m
            WHERE m.code IS NOT NULL
              AND m.archetype = 'technique'
              AND NOT EXISTS (
                  SELECT 1 FROM player_manuals pm
                  WHERE pm.player_id = p_player_id AND pm.manual_id = m.manual_id
              )
            ORDER BY random()
            LIMIT 1;

            IF book IS NOT NULL THEN
                INSERT INTO player_manuals (player_id, manual_id)
                VALUES (p_player_id, book)
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;
    END IF;

    UPDATE boss_strikes bs SET rewarded_at = now()
    WHERE bs.encounter_id = owed.encounter_id AND bs.player_id = p_player_id;

    RETURN QUERY SELECT owed.encounter_id, owed.name, owed.status,
                        owed.damage, round(share, 4), paid, coin, loot, book_name;
END;
$$;

COMMENT ON FUNCTION claim_boss_reward(BIGINT) IS
    'Pays one cultivator their share of a finished world beast, once: stones by contribution, rolled Jade for turning up, the beast''s own corpse and its boss-only spoils, and sometimes the manual it was guarding.';


DO $$
DECLARE
    ghost BIGINT;
    beast BIGINT;
    pay   RECORD;
    lean  INTEGER := 0;
BEGIN
    -- Every boss must have boss-only spoils, or this table is decoration.
    SELECT count(*) INTO lean
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
      AND NOT EXISTS (SELECT 1 FROM boss_drops bd
                      WHERE bd.species_id = cs.species_id);
    IF lean > 0 THEN
        RAISE EXCEPTION '% world beast(s) drop nothing a hunt could not', lean;
    END IF;

    -- Every beast must hold at least one thing a hunt could never roll. Bulk
    -- of what is already on the corpse is a fair reward and the first draft of
    -- this check forbade it, which would have left the table nothing but ore.
    SELECT count(*) INTO lean
    FROM creature_species cs
    WHERE cs.kind IN ('world', 'boss')
      AND NOT EXISTS (
          SELECT 1 FROM boss_drops bd
          WHERE bd.species_id = cs.species_id
            AND NOT EXISTS (
                SELECT 1 FROM creature_drops cd
                WHERE cd.species_id = bd.species_id
                  AND cd.material_code = bd.material_code
            )
      );
    IF lean > 0 THEN
        RAISE EXCEPTION
            '% world beast(s) hold nothing a hunt could not also yield', lean;
    END IF;

    -- It has to survive being called.
    INSERT INTO players (discord_id, discord_name)
    VALUES (-999146, 'migration 0146 probe') RETURNING player_id INTO ghost;

    INSERT INTO boss_encounters
        (species_id, region_code, max_hp, current_hp, status, closes_at, ended_at,
         slayer_id)
    SELECT cs.species_id, 'western', 100, 0, 'slain',
           now() + interval '1 day', now(), ghost
    FROM creature_species cs WHERE cs.kind = 'boss' LIMIT 1
    RETURNING encounter_id INTO beast;

    INSERT INTO boss_strikes (encounter_id, player_id, strikes, damage)
    VALUES (beast, ghost, 5, 100);

    SELECT * INTO pay FROM claim_boss_reward(ghost);

    IF pay.jade < game_config_value('boss_jade_min')
       OR pay.jade > game_config_value('boss_jade_max') THEN
        RAISE EXCEPTION 'the Jade roll came out at %, outside its own band', pay.jade;
    END IF;
    IF pay.stones <= 0 THEN
        RAISE EXCEPTION 'a share paid no stones';
    END IF;

    DELETE FROM boss_strikes WHERE encounter_id = beast;
    DELETE FROM boss_encounters WHERE encounter_id = beast;
    DELETE FROM player_manuals WHERE player_id = ghost;
    DELETE FROM player_materials WHERE player_id = ghost;
    DELETE FROM players WHERE player_id = ghost;
END;
$$;
