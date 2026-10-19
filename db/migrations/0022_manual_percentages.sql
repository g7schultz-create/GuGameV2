-- 0022_manual_percentages
--
-- Every manual bonus becomes a percentage, and the percentage a manual is
-- worth is decided by its tier.
--
-- WHY. 0021 gave manuals six bonus columns and left the other four page types
-- - attack, speed, breakthrough, essence - with nowhere to land, so a manual
-- refined from Attack pages would have had to express itself as a flat "+117
-- attack". Nothing in this game reads a flat attack stat, and a flat number is
-- worth less every realm you climb: +117 is decisive at body level 1 and
-- rounding error at body level 40. A percentage is worth the same fraction
-- forever, which is the only way a Tier 3 manual found early stays
-- interpretable later.
--
-- Every bonus in this schema was already an additive fraction - races, roots,
-- physiques - so this is manuals joining the convention rather than a new one.
--
-- THE TIER CURVE is a table, not an expression, for the same reason every
-- other balance number is a row: retuning it is an UPDATE in a later
-- migration. A manual's tier decides the TOTAL percentage it distributes; how
-- that total is split across stats is what its pages were.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- manual_tiers
-- ---------------------------------------------------------------------------
-- The budget a manual of each tier has to spend across its bonuses. Rising
-- faster than linearly, so the jump from Tier 7 (the best that drops) to Tier
-- 8 (the best that can only be refined) is worth the refining.

CREATE TABLE manual_tiers (
    tier         SMALLINT PRIMARY KEY CHECK (tier BETWEEN 1 AND 10),
    name         TEXT NOT NULL,

    -- Total additive fraction a manual of this tier distributes. 0.15 = 15%
    -- spread across however many stats its pages contributed.
    bonus_budget NUMERIC(6, 4) NOT NULL CHECK (bonus_budget > 0)
);

INSERT INTO manual_tiers (tier, name, bonus_budget) VALUES
    ( 1, 'Common mortal knowledge',      0.0600),
    ( 2, 'Improved mortal technique',    0.1000),
    ( 3, 'Skilled technique',            0.1500),
    ( 4, 'Sect-level technique',         0.2100),
    ( 5, 'High-grade mortal technique',  0.2800),
    ( 6, 'Rare inheritance technique',   0.3600),
    ( 7, 'Peak naturally obtainable',    0.4500),
    ( 8, 'Refined beyond the drop table',0.5600),
    ( 9, 'Extremely difficult refined',  0.6800),
    (10, 'Pinnacle Mortal World manual', 0.8200);

COMMENT ON TABLE manual_tiers IS
    'Total percentage a manual of each tier distributes. A TARGET, not a cap - harmony above 90 lets a refined manual retain more than 100% of its pages.';


-- ---------------------------------------------------------------------------
-- The four page types that had nowhere to go
-- ---------------------------------------------------------------------------
-- Attack, Speed, Breakthrough and Essence, plus Gathering and Refinement,
-- which the design lists as page types and 0021 had no column for.
--
-- Two of these are LIVE immediately: attack_bonus reaches the damage pipeline
-- through the same external hook Race/Root/Physique use, and gathering_bonus
-- multiplies a gather's yield. The other four are recorded and rendered but
-- consumed by nothing, because there is no speed system, no breakthrough roll,
-- no essence pool spend and no refinement skill yet. They are marked as such
-- in the bot rather than quietly doing nothing.

ALTER TABLE manuals
    ADD COLUMN attack_bonus       NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN speed_bonus        NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN breakthrough_bonus NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN essence_bonus      NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN gathering_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,
    ADD COLUMN refinement_bonus   NUMERIC(6, 4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN manuals.speed_bonus IS
    'Recorded but consumed by nothing: there is no turn-order system yet. creature_species.base_speed is waiting for the same one.';


-- ---------------------------------------------------------------------------
-- The seeded ten, redistributed onto their tier budgets
-- ---------------------------------------------------------------------------
-- 0021's numbers were hand-picked and not monotonic - the Tier 5 sword art
-- gave +10% cultivation where the Tier 4 scripture gave +12%. Each of these
-- now spends exactly its tier's budget, split the way its archetype implies.

UPDATE manuals SET cultivation_rate_bonus = 0.0200, attack_bonus = 0.0400
WHERE code = 'crimson_palm_canon';                                    -- T1, 6%

UPDATE manuals SET cultivation_rate_bonus = 0.0100, defense_bonus = 0.0300,
                   hp_bonus = 0.0200
WHERE code = 'rooted_mountain_method';                                -- T1, 6%

UPDATE manuals SET cultivation_rate_bonus = 0.0400, attack_bonus = 0.0600
WHERE code = 'scarlet_flame_breathing_method';                        -- T2, 10%

UPDATE manuals SET cultivation_rate_bonus = 0.0200, attainment_rate_bonus = 0.0200,
                   attack_bonus = 0.0600
WHERE code = 'venomous_jade_wood_scripture';                          -- T2, 10%

UPDATE manuals SET cultivation_rate_bonus = 0.0900, attainment_rate_bonus = 0.0400,
                   defense_bonus = 0.0200, hp_bonus = 0
WHERE code = 'azure_frost_lotus_scripture';                           -- T3, 15%

UPDATE manuals SET cultivation_rate_bonus = 0, physique_rate_bonus = 0.0700,
                   hp_bonus = 0.0400, defense_bonus = 0.0200, strength_bonus = 0.0200
WHERE code = 'iron_mountain_tyrant_body';                             -- T3, 15%

UPDATE manuals SET cultivation_rate_bonus = 0.0400, physique_rate_bonus = 0.0300,
                   speed_bonus = 0.0800
WHERE code = 'profound_thunder_steps';                                -- T3, 15%

UPDATE manuals SET cultivation_rate_bonus = 0.1300, attainment_rate_bonus = 0.0600,
                   breakthrough_bonus = 0.0200
WHERE code = 'thousand_thought_soul_canon';                           -- T4, 21%

UPDATE manuals SET cultivation_rate_bonus = 0.0600, attainment_rate_bonus = 0,
                   strength_bonus = 0.0400, attack_bonus = 0.1800
WHERE code = 'blazing_heaven_sword_art';                              -- T5, 28%

UPDATE manuals SET cultivation_rate_bonus = 0.0800, attainment_rate_bonus = 0,
                   strength_bonus = 0.0400, attack_bonus = 0.2400
WHERE code = 'blood_blade_scripture';                                 -- T6, 36%


-- ---------------------------------------------------------------------------
-- manual_total_bonus
-- ---------------------------------------------------------------------------
-- What a manual actually spends, for checking it against its tier's budget.
-- A function rather than a CHECK constraint, because a refined manual is
-- ALLOWED to exceed its budget - harmony above 90 retains more than 100% of
-- the pages' potential, and that is the reward for refining well.

CREATE FUNCTION manual_total_bonus(p_manual_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT cultivation_rate_bonus + physique_rate_bonus + attainment_rate_bonus
         + hp_bonus + defense_bonus + strength_bonus
         + attack_bonus + speed_bonus + breakthrough_bonus + essence_bonus
         + gathering_bonus + refinement_bonus
    FROM manuals WHERE manual_id = p_manual_id;
$$;


-- ---------------------------------------------------------------------------
-- player_manual_bonuses, widened
-- ---------------------------------------------------------------------------
-- Dropped and recreated rather than replaced, so the new columns sit in a
-- sensible order instead of trailing after `equipped`.

DROP VIEW player_manual_bonuses;

CREATE VIEW player_manual_bonuses AS
SELECT
    s.player_id,
    COALESCE(sum(m.cultivation_rate_bonus), 0) AS cultivation_rate_bonus,
    COALESCE(sum(m.physique_rate_bonus), 0)    AS physique_rate_bonus,
    COALESCE(sum(m.attainment_rate_bonus), 0)  AS attainment_rate_bonus,
    COALESCE(sum(m.hp_bonus), 0)               AS hp_bonus,
    COALESCE(sum(m.defense_bonus), 0)          AS defense_bonus,
    COALESCE(sum(m.strength_bonus), 0)         AS strength_bonus,
    COALESCE(sum(m.attack_bonus), 0)           AS attack_bonus,
    COALESCE(sum(m.speed_bonus), 0)            AS speed_bonus,
    COALESCE(sum(m.breakthrough_bonus), 0)     AS breakthrough_bonus,
    COALESCE(sum(m.essence_bonus), 0)          AS essence_bonus,
    COALESCE(sum(m.gathering_bonus), 0)        AS gathering_bonus,
    COALESCE(sum(m.refinement_bonus), 0)       AS refinement_bonus,
    count(*)                                   AS equipped
FROM player_manual_slots s
JOIN manuals m ON m.manual_id = s.manual_id
GROUP BY s.player_id;

COMMENT ON VIEW player_manual_bonuses IS
    'Equipped manuals summed. Every column is an additive fraction, matching races, roots and physiques.';


-- ---------------------------------------------------------------------------
-- attack_bonus reaches the damage pipeline
-- ---------------------------------------------------------------------------
-- Through the same external hook 0008 left for "Dao Marks, equipment and
-- buffs" and 0013 first filled with the three traits.
--
-- The trait half stays weighted by the technique's Path typing - a Sword/Fire
-- move gets half of a Sword bonus. The manual half is NOT weighted, because a
-- manual's attack bonus is a fact about how hard you hit, not about a Path.

CREATE OR REPLACE FUNCTION player_external_multiplier(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT 1
    + COALESCE((
        SELECT SUM(tp.weight * (
            COALESCE((SELECT rpb.damage_bonus
                      FROM player_character pc
                      JOIN race_path_bonuses rpb
                        ON rpb.race_code = pc.race_code AND rpb.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT rob.damage_bonus
                      FROM player_character pc
                      JOIN root_path_bonuses rob
                        ON rob.root_code = pc.root_code AND rob.path_code = tp.path_code
                      WHERE pc.player_id = p_player_id), 0)
          + COALESCE((SELECT ppb.damage_bonus
                      FROM player_physique pp
                      JOIN physique_path_bonuses ppb
                        ON ppb.physique_id = pp.physique_id AND ppb.path_code = tp.path_code
                      WHERE pp.player_id = p_player_id), 0)
        ))
        FROM technique_paths tp
        WHERE tp.technique_id = p_technique_id
    ), 0)
    + COALESCE((SELECT b.attack_bonus FROM player_manual_bonuses b
                WHERE b.player_id = p_player_id), 0);
$$;


-- ---------------------------------------------------------------------------
-- HP, defense and strength read the manuals too
-- ---------------------------------------------------------------------------
-- Same function as 0015 with the equipped manuals folded into the multipliers.
-- Additive with the trait fractions, so a +40% physique and a +4% manual make
-- x1.44, not x1.456.
--
-- Because the stats are a pure function of (level, traits, manuals), equipping
-- a manual has to recompute them - the bot calls apply_physique_xp(player, 0)
-- on equip, which is the same trick /dev physique uses.

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    base_def  NUMERIC := game_config_value('physique_base_defense');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    base_str  NUMERIC := game_config_value('physique_base_strength');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
    man_hp      NUMERIC := 0;
    man_def     NUMERIC := 0;
    man_str     NUMERIC := 0;
    new_level   SMALLINT;
    new_max_hp  BIGINT;
    hp_gained   BIGINT;
BEGIN
    SELECT * INTO row_before FROM player_physique WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    SELECT tr.hp_multiplier, tr.defense_multiplier, tr.strength_multiplier
    INTO mult_hp, mult_def, mult_str
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;

    SELECT b.hp_bonus, b.defense_bonus, b.strength_bonus
    INTO man_hp, man_def, man_str
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0);
    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0);
    mult_str := COALESCE(mult_str, 1) + COALESCE(man_str, 0);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = round((base_def + def_rate * (new_level - 1)) * mult_def),
        strength    = round((base_str + str_rate * (new_level - 1)) * mult_str)
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- Attainment reads the manuals
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION player_attainment_rate(p_player_id BIGINT, p_path_code TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(tr.attainment_multiplier, 1)
         + COALESCE((SELECT rpb.attainment_bonus
                     FROM player_character pc
                     JOIN race_path_bonuses rpb
                       ON rpb.race_code = pc.race_code AND rpb.path_code = p_path_code
                     WHERE pc.player_id = p_player_id), 0)
         + COALESCE((SELECT rob.attainment_bonus
                     FROM player_character pc
                     JOIN root_path_bonuses rob
                       ON rob.root_code = pc.root_code AND rob.path_code = p_path_code
                     WHERE pc.player_id = p_player_id), 0)
         + COALESCE((SELECT ppb.attainment_bonus
                     FROM player_physique pp
                     JOIN physique_path_bonuses ppb
                       ON ppb.physique_id = pp.physique_id AND ppb.path_code = p_path_code
                     WHERE pp.player_id = p_player_id), 0)
         + COALESCE((SELECT ph.affinity_bonus - 1
                     FROM player_physique pp
                     JOIN physiques ph ON ph.physique_id = pp.physique_id
                     WHERE pp.player_id = p_player_id
                       AND ph.affinity_path = p_path_code), 0)
         + COALESCE((SELECT b.attainment_rate_bonus FROM player_manual_bonuses b
                     WHERE b.player_id = p_player_id), 0)
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;
$$;


-- ---------------------------------------------------------------------------
-- Gathering reads the manuals
-- ---------------------------------------------------------------------------
-- A Gathering manual raises the yield rather than the frequency: the cooldown
-- is what paces foraging, and a manual that shortened it would be a manual
-- that made the pacing optional.

CREATE OR REPLACE FUNCTION gather(p_player_id BIGINT)
RETURNS TABLE (material_code TEXT, material_name TEXT, rarity TEXT, quantity BIGINT, held BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    here    TEXT;
    picked  TEXT;
    lo      NUMERIC := game_config_value('gather_yield_min');
    hi      NUMERIC := game_config_value('gather_yield_max');
    bonus   NUMERIC := 0;
    amount  BIGINT;
    total   BIGINT;
BEGIN
    SELECT region_code INTO here FROM player_location WHERE player_id = p_player_id;
    IF here IS NULL THEN
        RAISE EXCEPTION 'player % has no location', p_player_id;
    END IF;

    SELECT rm.material_code INTO picked
    FROM region_materials rm
    WHERE rm.region_code = here
    ORDER BY -ln(random()) / rm.weight
    LIMIT 1;

    IF picked IS NULL THEN
        RAISE EXCEPTION 'nothing grows in %', here USING ERRCODE = 'check_violation';
    END IF;

    SELECT b.gathering_bonus INTO bonus
    FROM player_manual_bonuses b WHERE b.player_id = p_player_id;

    amount := GREATEST(1, round(
        (lo + floor(random() * (hi - lo + 1))) * (1 + COALESCE(bonus, 0))
    ));
    total  := grant_material(p_player_id, picked, amount);

    RETURN QUERY
    SELECT m.code, m.name, m.rarity, amount, total
    FROM materials m WHERE m.code = picked;
END;
$$;
