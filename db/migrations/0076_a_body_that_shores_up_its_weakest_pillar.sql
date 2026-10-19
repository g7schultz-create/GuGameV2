-- 0076_a_body_that_shores_up_its_weakest_pillar
--
-- Celestial Emperor Body, and the one clause 0073 said needed a decision
-- rather than a consumer.
--
-- THE CLAUSE WAS UNBUILDABLE AS WRITTEN. "At encounter start, the lowest
-- foundation stat gains 7%" compares HP against defence against strength -
-- 120 against 20 against 35 - so "lowest" always meant defence and the
-- sentence stopped meaning what it said. The fix is to compare the
-- MULTIPLIERS rather than the values: this body is 1.18 HP, 1.18 defence and
-- 1.08 strength, and there "worst at" is unambiguous.
--
-- AND IT STACKS, ON THE CROSSING RATHER THAN THE ENCOUNTER. A permanent
-- growth that always goes into whichever pillar is currently lowest is
-- self-limiting by construction: the moment a stat stops being the lowest it
-- stops receiving, so the three CONVERGE instead of one running away. There is
-- no number to tune to stop it spiking, because the shape cannot spike. Over
-- the twenty-six crossings this world has, 1.5% each is about +39% in total
-- and roughly +13% on each of three stats - which is a Legendary body's worth,
-- and not a Legendary body's worth concentrated into one number.
--
-- IT IS AN EFFECT, NOT A PHYSIQUE SPECIAL. `realm_tempering` already grants
-- physique XP on a breakthrough and is read in the same place. This is its
-- targeted sibling: XP raises all three pillars together, this raises the one
-- that needs it. A root, a Gu or a crown can grant it later without any of
-- this being touched.
--
-- WHAT IT DELIBERATELY DOES NOT COUNT. The comparison reads the body's own
-- balance - race, root, physique and what it has already accumulated - and not
-- equipment. A permanent decision must not be steered by a sword that can be
-- taken off the next morning.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The word
-- ---------------------------------------------------------------------------

INSERT INTO gu_effects (code, name, description, cap, is_live, emoji, sort_order, step) VALUES
    ('realm_foundation', 'Founding',
     'Crossing a realm permanently raises whichever of HP, defence and strength this body is currently worst at.',
     0.1000, TRUE, '🏛️', 270, 0.0011);


-- ---------------------------------------------------------------------------
-- player_foundation_bonuses
-- ---------------------------------------------------------------------------
-- Sparse rows, at most three per player, for the same reason cooldowns and
-- attainment are sparse rows: a stat that has never been raised has nothing to
-- say, and a column each would be three columns on `player_physique` that are
-- zero for everybody in the game but one body.

CREATE TABLE player_foundation_bonuses (
    player_id BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    stat      TEXT   NOT NULL CHECK (stat IN ('hp', 'defense', 'strength')),

    bonus     NUMERIC(6, 4) NOT NULL DEFAULT 0 CHECK (bonus >= 0),

    PRIMARY KEY (player_id, stat)
);

COMMENT ON TABLE player_foundation_bonuses IS
    'Permanent, per-stat foundation growth. Distinct from physique XP, which deliberately moves all three pillars at once.';

CREATE FUNCTION foundation_bonus(p_player_id BIGINT, p_stat TEXT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE((SELECT b.bonus FROM player_foundation_bonuses b
                     WHERE b.player_id = p_player_id AND b.stat = p_stat), 0);
$$;


-- ---------------------------------------------------------------------------
-- weakest_foundation
-- ---------------------------------------------------------------------------
-- Which pillar this body is worst at, by multiplier rather than by value.
-- Ties resolve in a fixed order so that two identical bodies grow identically.

CREATE FUNCTION weakest_foundation(p_player_id BIGINT)
RETURNS TEXT
LANGUAGE sql STABLE
AS $$
    SELECT v.stat
    FROM player_trait_rates tr
    CROSS JOIN LATERAL (VALUES
        ('hp',       tr.hp_multiplier       + foundation_bonus(p_player_id, 'hp')),
        ('defense',  tr.defense_multiplier  + foundation_bonus(p_player_id, 'defense')),
        ('strength', tr.strength_multiplier + foundation_bonus(p_player_id, 'strength'))
    ) AS v (stat, total)
    WHERE tr.player_id = p_player_id
    ORDER BY v.total, v.stat
    LIMIT 1;
$$;

COMMENT ON FUNCTION weakest_foundation(BIGINT) IS
    'The pillar with the lowest multiplier, counting the body and what it has already grown - and not counting equipment, which comes off.';


-- ---------------------------------------------------------------------------
-- apply_physique_xp, from 0066_gear_reaches_combat
-- ---------------------------------------------------------------------------
-- One more term in a sum that has been a sum since 0046. Every command
-- settles, and every settle recomputes here, so a bonus granted on a
-- breakthrough is felt on the next thing the player does.

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
    path_hp     NUMERIC := 0;
    path_def    NUMERIC := 0;
    path_str    NUMERIC := 0;
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

    SELECT bp.hp_bonus, bp.defense_bonus, bp.strength_bonus
    INTO path_hp, path_def, path_str
    FROM body_paths bp WHERE bp.code = row_before.body_path;

    mult_hp  := COALESCE(mult_hp, 1)  + COALESCE(man_hp, 0)
                + COALESCE(path_hp, 0) + player_stat(p_player_id, 'max_hp')
                + foundation_bonus(p_player_id, 'hp');
    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0)
                + COALESCE(path_def, 0)
                + foundation_bonus(p_player_id, 'defense');
    mult_str := COALESCE(mult_str, 1) + COALESCE(man_str, 0)
                + COALESCE(path_str, 0)
                + foundation_bonus(p_player_id, 'strength');

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = greatest(0, round((base_def + def_rate * (new_level - 1)) * mult_def)),
        strength    = greatest(0, round((base_str + str_rate * (new_level - 1)) * mult_str))
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;

-- ---------------------------------------------------------------------------
-- breakthrough, from 0072_a_realm_crossed_tempers_the_body
-- ---------------------------------------------------------------------------
-- Two more columns rather than a silent grant, for the third time: 0045,
-- 0058 and 0072 all say a function reports what it banked.

DROP FUNCTION breakthrough(BIGINT);

CREATE FUNCTION breakthrough(p_player_id BIGINT)
RETURNS TABLE (
    realm_before     SMALLINT,
    realm_after      SMALLINT,
    name_before      TEXT,
    name_after       TEXT,
    rank_before      SMALLINT,
    rank_after       SMALLINT,
    stage_after      TEXT,
    cultivation      BIGINT,
    next_ceiling     BIGINT,
    qi_capacity      BIGINT,
    essence_capacity BIGINT,
    gu_capacity      SMALLINT,
    aperture_gained  SMALLINT,
    techniques_freed INTEGER,
    tempering_gained BIGINT,
    body_levels      SMALLINT,
    founded_stat     TEXT,
    founded_by       NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult      player_cultivation%ROWTYPE;
    was       realms%ROWTYPE;
    becomes   realms%ROWTYPE;
    tempering BIGINT := 0;
    body_was  SMALLINT;
    body_now  SMALLINT;
    founding  NUMERIC := 0;
    weakest   TEXT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    SELECT * INTO was FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    IF becomes.realm_id IS NULL THEN
        RAISE EXCEPTION 'there is nothing above % in this world', was.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF cult.cultivation < becomes.cultivation_required THEN
        RAISE EXCEPTION
            'you hold % of the % needed to break into %',
            cult.cultivation, becomes.cultivation_required, becomes.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.
    UPDATE player_cultivation pc
    SET realm_id = becomes.realm_id
    WHERE pc.player_id = p_player_id;

    -- A body that grows on the crossing itself. Measured in body levels
    -- because that is the currency the promise is written in - "foundation
    -- stats rise permanently" is what a body level IS.
    SELECT pp.body_level INTO body_was
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    tempering := round(player_stat(p_player_id, 'realm_tempering')
                       * game_config_value('physique_xp_per_level'));

    -- Whichever pillar is currently lowest, and only that one. Read BEFORE
    -- the grant, so a body does not measure itself against the growth it is
    -- about to receive.
    founding := player_stat(p_player_id, 'realm_foundation');
    IF founding > 0 THEN
        weakest := weakest_foundation(p_player_id);
        INSERT INTO player_foundation_bonuses (player_id, stat, bonus)
        VALUES (p_player_id, weakest, founding)
        ON CONFLICT (player_id, stat) DO UPDATE
            SET bonus = player_foundation_bonuses.bonus + EXCLUDED.bonus;
    END IF;

    -- Unconditional, and zero XP is a no-op that still recomputes: the
    -- founding above has to reach the stored stats before this function
    -- reports what the body became.
    PERFORM apply_physique_xp(p_player_id, tempering);

    SELECT pp.body_level INTO body_now
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    RETURN QUERY
    SELECT was.realm_id, becomes.realm_id,
           was.name, becomes.name,
           was.rank, becomes.rank, becomes.stage,
           cult.cultivation,
           (SELECT after.cultivation_required FROM realms after
            WHERE after.realm_id = becomes.realm_id + 1),
           becomes.qi_capacity, becomes.essence_capacity,
           becomes.gu_capacity,
           (becomes.gu_capacity - was.gu_capacity)::smallint,
           (SELECT count(*)::integer FROM techniques t
            WHERE t.created_by IS NULL
              AND t.rank > was.rank AND t.rank <= becomes.rank),
           tempering,
           COALESCE(body_now - body_was, 0)::smallint,
           weakest,
           founding;
END;
$$;

-- ---------------------------------------------------------------------------
-- The body it was written for
-- ---------------------------------------------------------------------------

INSERT INTO physique_effects (physique_id, effect_code, magnitude)
SELECT p.physique_id, 'realm_foundation', round(e.step * pw.ranks, 4)
FROM physiques p
JOIN physique_power pw ON pw.tier = p.tier
JOIN gu_effects e      ON e.code = 'realm_foundation'
WHERE p.code = 'celestial_emperor_body';

UPDATE physiques SET
    special_text = 'Whatever this body is worst at, it does not stay worst at. Every realm it crosses, the weakest of its three pillars comes up to meet the others.',
    unmodelled   = '{}'::jsonb
WHERE code = 'celestial_emperor_body';

COMMENT ON FUNCTION breakthrough(BIGINT) IS
    'Takes the next realm, tempers the body on the way through, and founds whichever pillar is weakest. The only thing that moves realm_id - which is what leaves room for a tribulation to stand in the way of it.';

