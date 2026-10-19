-- 0108_a_body_is_crossed_not_drifted_into
--
-- A body rank is taken, and it costs what you killed to take it.
--
-- 0046 derived the rank from lifetime physique XP, so a body "advanced" by
-- the same mechanism as everything else: waiting. That left the physique the
-- only pillar with nothing a player can DO to it, and the shelf shows the
-- result - professions at level 103 and bodies at level 4, because mining has
-- a button and the body did not.
--
-- 0044 solved this exact problem for cultivation. A realm stopped being what
-- your total happened to reach and became something `breakthrough()` takes on
-- purpose, with the total stopping at the door until you do. This is that,
-- for the body, with a price:
--
--   * `body_rank` is STORED. Nothing derives it any more.
--   * XP still accrues without limit, and `body_level` - which is what every
--     stat is computed from - stops at the level the current rank allows.
--   * `temper_body()` crosses one rank, and consumes beast material to do it.
--
-- WHY THE LEVEL AND NOT THE XP. Cultivation clamps the total and holds the
-- overflow in a reserve (0099). A body needs neither: `physique_xp` is a
-- lifetime figure that already keeps counting, so capping the LEVEL means the
-- work is banked in the total itself and arrives in full the moment the rank
-- crosses. Nothing is lost and there is no second place for it to sit.
--
-- WHAT IT COSTS. Weight, where a material's weight is its grade - a mythic
-- fang is worth six commons. The requirement is derived from the XP the rank
-- already asks for, divided by a dial, so retuning the ranks retunes the
-- price. Rank 2 wants 30 weight and rank 9 wants 2,100; the busiest hunter in
-- the world has 375 from 211 fights, so this is a real cost and not a toll.
--
-- NOBODY MOVES TODAY. `body_rank` is backfilled from the XP that used to
-- derive it, and every live body is below the ceiling its rank allows - the
-- closest is three levels into an allowance of four.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE player_physique
    ADD COLUMN body_rank SMALLINT NOT NULL DEFAULT 1
        REFERENCES body_rank_requirements (rank) ON DELETE RESTRICT;

-- What the XP used to say, written down once, so that nobody wakes up a rank
-- lower than they went to sleep.
UPDATE player_physique
SET body_rank = COALESCE(body_rank_for_xp(physique_xp), 1);

COMMENT ON COLUMN player_physique.body_rank IS
    'The rank this body has crossed into. Stored, not derived: it moves only in temper_body(), which is what leaves room for the crossing to cost something.';

INSERT INTO game_config (key, value, description) VALUES
    ('body_temper_weight_divisor', 50,
     'Physique XP per unit of beast material weight a rank crossing demands. Lower is dearer.');


-- ---------------------------------------------------------------------------
-- The price of a crossing
-- ---------------------------------------------------------------------------

CREATE FUNCTION body_rank_cost(p_rank SMALLINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    -- Derived from the XP the rank already asks for, so the two gates on a
    -- crossing are tuned by one number rather than drifting apart.
    SELECT GREATEST(1, round(r.xp_required
                             / game_config_value('body_temper_weight_divisor')))::bigint
    FROM body_rank_requirements r WHERE r.rank = p_rank;
$$;

COMMENT ON FUNCTION body_rank_cost(SMALLINT) IS
    'Beast material weight needed to cross INTO this rank. Weight is grade times quantity - a mythic fang is six commons.';


CREATE FUNCTION player_beast_weight(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(sum(pm.quantity * material_grade(m.rarity)), 0)::bigint
    FROM player_materials pm
    JOIN beast_parts bp ON bp.material_code = pm.material_code
    JOIN materials m ON m.code = pm.material_code
    WHERE pm.player_id = p_player_id AND pm.quantity > 0;
$$;

COMMENT ON FUNCTION player_beast_weight(BIGINT) IS
    'Everything a cultivator has stripped off a corpse, measured in grade. The other half of what a rank crossing wants.';


-- ---------------------------------------------------------------------------
-- The ceiling a rank puts on a body
-- ---------------------------------------------------------------------------

CREATE FUNCTION body_level_ceiling(p_rank SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    -- The level at which the NEXT rank begins is the first level this rank
    -- may not have. NULL at the top of the ladder, where nothing is held back.
    SELECT (1 + floor(r.xp_required
                      / game_config_value('physique_xp_per_level')))::smallint
    FROM body_rank_requirements r WHERE r.rank = p_rank + 1;
$$;

COMMENT ON FUNCTION body_level_ceiling(SMALLINT) IS
    'How far a body of this rank may be trained. NULL at rank 9, which is the only rank with no door above it.';


CREATE FUNCTION ready_to_temper(p_player_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(
        (SELECT pp.physique_xp >= r.xp_required
                AND player_beast_weight(p_player_id) >= body_rank_cost(r.rank)
         FROM player_physique pp
         JOIN body_rank_requirements r ON r.rank = pp.body_rank + 1
         WHERE pp.player_id = p_player_id),
        FALSE);
$$;

COMMENT ON FUNCTION ready_to_temper(BIGINT) IS
    'Both gates at once: the training done, and the material to pay for it.';


-- ---------------------------------------------------------------------------
-- apply_physique_xp, which now stops at the door
-- ---------------------------------------------------------------------------
-- 0076's function with two lines added. Everything else - the multipliers,
-- the foundation bonuses, the HP carried across - is untouched.

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
    ceiling     SMALLINT;
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

    -- The XP is always kept. The LEVEL is what waits for the rank, so a body
    -- trained past its door loses nothing and collects all of it at once when
    -- temper_body() opens the next one.
    ceiling   := body_level_ceiling(row_before.body_rank);
    new_level := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    IF ceiling IS NOT NULL THEN
        new_level := LEAST(new_level, ceiling);
    END IF;

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
-- temper_body
-- ---------------------------------------------------------------------------
-- One rank, taken on purpose and paid for.
--
-- The material is taken commonest-first. A cultivator's rare parts are what
-- the forge wants, and a crossing that helped itself to the dragon scale
-- while the boar tusks sat in the bag would be a trap rather than a price.

CREATE FUNCTION temper_body(p_player_id BIGINT)
RETURNS TABLE (
    rank_before   SMALLINT,
    rank_after    SMALLINT,
    name_before   TEXT,
    name_after    TEXT,
    level_before  SMALLINT,
    level_after   SMALLINT,
    weight_spent  BIGINT,
    hp_gained     BIGINT,
    spent         JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    body      player_physique%ROWTYPE;
    wants     body_rank_requirements%ROWTYPE;
    cost      BIGINT;
    held      BIGINT;
    remaining BIGINT;
    take      BIGINT;
    part      RECORD;
    taken     JSONB := '[]'::jsonb;
    hp_before BIGINT;
    lvl_before SMALLINT;
    l_after   SMALLINT;
BEGIN
    SELECT * INTO body FROM player_physique
    WHERE player_id = p_player_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no physique row', p_player_id;
    END IF;

    SELECT * INTO wants FROM body_rank_requirements WHERE rank = body.body_rank + 1;
    IF wants.rank IS NULL THEN
        RAISE EXCEPTION 'there is nothing above rank % for a body', body.body_rank
            USING ERRCODE = 'check_violation';
    END IF;

    IF body.physique_xp < wants.xp_required THEN
        RAISE EXCEPTION
            'you have tempered % of the % this rank asks for',
            body.physique_xp, wants.xp_required
            USING ERRCODE = 'check_violation';
    END IF;

    cost := body_rank_cost(wants.rank);
    held := player_beast_weight(p_player_id);
    IF held < cost THEN
        RAISE EXCEPTION
            'this crossing wants % of beast material and you carry %',
            cost, held
            USING ERRCODE = 'check_violation';
    END IF;

    hp_before  := body.max_hp;
    lvl_before := body.body_level;

    -- Commonest first, and only as much of the last one as is needed.
    remaining := cost;
    FOR part IN
        SELECT pm.material_code, pm.quantity, material_grade(m.rarity) AS grade,
               material_name(pm.material_code) AS name
        FROM player_materials pm
        JOIN beast_parts bp ON bp.material_code = pm.material_code
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = p_player_id AND pm.quantity > 0
        ORDER BY material_grade(m.rarity), pm.material_code
    LOOP
        EXIT WHEN remaining <= 0;
        take := LEAST(part.quantity, ceil(remaining::numeric / part.grade)::bigint);
        PERFORM spend_material(p_player_id, part.material_code, take);
        remaining := remaining - take * part.grade;
        taken := taken || jsonb_build_object(
            'code', part.material_code, 'name', part.name, 'quantity', take
        );
    END LOOP;

    UPDATE player_physique pp
    SET body_rank = wants.rank
    WHERE pp.player_id = p_player_id;

    -- Zero XP is how everything else in this schema says "recompute": the
    -- ceiling has moved, so every level the body already earned arrives now.
    l_after := apply_physique_xp(p_player_id, 0);

    RETURN QUERY
    SELECT body.body_rank, wants.rank,
           (SELECT br.name FROM body_ranks br
            WHERE br.path_code = body.body_path AND br.rank = body.body_rank),
           (SELECT br.name FROM body_ranks br
            WHERE br.path_code = body.body_path AND br.rank = wants.rank),
           lvl_before, l_after,
           cost,
           (SELECT pp.max_hp - hp_before FROM player_physique pp
            WHERE pp.player_id = p_player_id),
           taken;
END;
$$;

COMMENT ON FUNCTION temper_body(BIGINT) IS
    'Crosses one body rank, paid for in beast material taken commonest-first. The only thing that moves body_rank.';


-- ---------------------------------------------------------------------------
-- player_body, reading the rank that is now stored
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW player_body AS
SELECT pp.player_id,
    pp.physique_xp,
    pp.body_level,
    pp.max_hp,
    pp.current_hp,
    pp.defense,
    pp.strength,
    pp.regeneration,
    pp.body_path,
    here.rank AS body_rank,
    bp.name AS path_name,
    bp.emoji AS path_emoji,
    bp.temperament,
    bp.description AS path_description,
    bp.hp_bonus,
    bp.defense_bonus,
    bp.strength_bonus,
    mine.name AS rank_name,
    cur.xp_required AS rank_floor,
    nxt.xp_required AS next_floor,
    ahead.name AS next_rank_name,
    ph.name AS physique_name,
    ph.tier AS physique_rarity,
    ph.hp_multiplier,
    ph.defense_multiplier,
    ph.strength_multiplier,
    pp.body_path IS NULL OR here.rank = 1 AS path_still_open
   FROM player_physique pp
     CROSS JOIN LATERAL ( SELECT pp.body_rank AS rank) here
     JOIN body_rank_requirements cur ON cur.rank = here.rank
     LEFT JOIN body_rank_requirements nxt ON nxt.rank = (here.rank + 1)
     LEFT JOIN body_paths bp ON bp.code = pp.body_path
     LEFT JOIN body_ranks mine ON mine.path_code = pp.body_path AND mine.rank = here.rank
     LEFT JOIN body_ranks ahead ON ahead.path_code = pp.body_path AND ahead.rank = (here.rank + 1)
     LEFT JOIN physiques ph ON ph.physique_id = pp.physique_id;

COMMENT ON VIEW player_body IS
    'A body from its owner''s side. The rank is read from the row rather than from the XP: since 0108 it is crossed rather than drifted into.';
