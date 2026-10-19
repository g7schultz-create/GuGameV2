-- 0046_body_paths
--
-- The body gets a ladder and a direction.
--
-- 0006 built the physique pillar as a single unbounded `body_level` with no
-- name on it: "body level 7" tells a player how many times a number went up
-- and nothing about what they are becoming. The three ladders here are the
-- other half - nine ranks, and three different bodies to climb them as.
--
-- RANK IS THE NAME, LEVEL IS THE PROGRESS. Exactly the arrangement cultivation
-- already uses: a realm is a named band over a cumulative total, and the total
-- keeps its own finer granularity. `body_level` still drives every stat, so
-- nothing in the damage pipeline changes; `body_rank_for_xp` just says what to
-- call where you have got to.
--
-- THE REQUIREMENT IS TYPED ONCE. Nine rows in `body_rank_requirements`, not
-- twenty-seven: the climb is the same for all three paths and only the names
-- and the emphasis differ. Three copies of the same number are three chances
-- for them to drift.
--
-- THE PATH IS A TRADE, NOT A COSTUME. Demonic buys strength with defence and
-- health; Buddhist buys defence and health with strength; Taoist takes a
-- little of everything and is the safe answer. They fold into the existing
-- additive stack beside the physique's own multipliers, the manuals and the
-- Gu - a +10% race and a +45% Demonic body make +55%, never a product.
--
-- AND IT SETS. The path may be changed freely at Rank 1 and never again,
-- enforced by a trigger rather than by whichever command happens to write the
-- column. A body that could be swapped at will is a menu, not a decision.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- body_paths
-- ---------------------------------------------------------------------------

CREATE TABLE body_paths (
    code             TEXT PRIMARY KEY,
    name             TEXT NOT NULL UNIQUE,
    temperament      TEXT NOT NULL,

    -- Additive terms on the physique pillar's output, in the same currency as
    -- every other bonus in this game. PLACEHOLDER numbers.
    hp_bonus         NUMERIC(6, 4) NOT NULL DEFAULT 0,
    defense_bonus    NUMERIC(6, 4) NOT NULL DEFAULT 0,
    strength_bonus   NUMERIC(6, 4) NOT NULL DEFAULT 0,

    emoji            TEXT NOT NULL DEFAULT '🧘',
    description      TEXT NOT NULL DEFAULT '',
    sort_order       SMALLINT NOT NULL DEFAULT 0
);

INSERT INTO body_paths
    (code, name, temperament, hp_bonus, defense_bonus, strength_bonus, emoji, description, sort_order)
VALUES
    ('taoist', 'Taoist Path', 'Balanced',
     0.1000, 0.1000, 0.1000, '☯️',
     'The orthodox climb. Nothing given up, and nothing spectacular gained — a body that is never the reason you lost.',
     10),
    ('demonic', 'Demonic Path', 'Aggressive',
     -0.1000, -0.1500, 0.4500, '👹',
     'Everything spent forward. It hits harder than anything else on the ladder and it will not take a hit for you.',
     20),
    ('buddhist', 'Buddhist Path', 'Defensive',
     0.2500, 0.3000, -0.2500, '🪷',
     'A body built to still be standing. What it gives up is the speed at which a fight ends.',
     30);

COMMENT ON TABLE body_paths IS
    'How a cultivator builds a body. The bonuses are additive with the physique, the manuals and the Gu, never multiplied by them.';


-- ---------------------------------------------------------------------------
-- What a rank costs
-- ---------------------------------------------------------------------------
-- Cumulative, like `realms.cultivation_required`, so the rank is one indexed
-- range scan over a total that is never spent.

CREATE TABLE body_rank_requirements (
    rank        SMALLINT PRIMARY KEY CHECK (rank BETWEEN 1 AND 9),
    xp_required BIGINT   NOT NULL CHECK (xp_required >= 0)
);

-- PLACEHOLDER. At 80 XP an idle hour, Rank 2 is a day's absence and Rank 9 is
-- a season's - the shape is the point, not the digits.
INSERT INTO body_rank_requirements (rank, xp_required) VALUES
    (1,      0),
    (2,   1500),
    (3,   4000),
    (4,   8500),
    (5,  16000),
    (6,  28000),
    (7,  45000),
    (8,  70000),
    (9, 105000);

CREATE FUNCTION body_rank_for_xp(p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT max(rank)::smallint
    FROM body_rank_requirements
    WHERE xp_required <= p_xp;
$$;

COMMENT ON FUNCTION body_rank_for_xp(BIGINT) IS
    'The body rank a lifetime physique XP total has reached. The definition of what to call a body.';


-- ---------------------------------------------------------------------------
-- body_ranks
-- ---------------------------------------------------------------------------
-- The names. Twenty-seven rows and not one number among them: what a rank
-- COSTS lives next door, so a rebalance never touches the vocabulary.

CREATE TABLE body_ranks (
    path_code TEXT     NOT NULL REFERENCES body_paths (code) ON DELETE CASCADE,
    rank      SMALLINT NOT NULL REFERENCES body_rank_requirements (rank) ON DELETE RESTRICT,

    name      TEXT     NOT NULL,

    PRIMARY KEY (path_code, rank)
);

CREATE INDEX body_ranks_rank_idx ON body_ranks (rank);

INSERT INTO body_ranks (path_code, rank, name) VALUES
    ('taoist', 1, 'Qi Condensation'),
    ('taoist', 2, 'Foundation Establishment'),
    ('taoist', 3, 'Core Formation'),
    ('taoist', 4, 'Nascent Soul'),
    ('taoist', 5, 'Soul Transformation'),
    ('taoist', 6, 'Void Refining'),
    ('taoist', 7, 'Tribulation Transmutation'),
    ('taoist', 8, 'Mahayana Immortal'),
    ('taoist', 9, 'Dao Origin Immortal King'),

    ('demonic', 1, 'Demon Seed'),
    ('demonic', 2, 'Blood Refining'),
    ('demonic', 3, 'Asura Awakening'),
    ('demonic', 4, 'Devil Soul'),
    ('demonic', 5, 'Slaughter Domain'),
    ('demonic', 6, 'Earthly Fiend'),
    ('demonic', 7, 'Heavenly Demon Tyrant'),
    ('demonic', 8, 'Primordial Archdemon'),
    ('demonic', 9, 'Myriad Abyss Demon Venerable'),

    ('buddhist', 1, 'Pious Heart'),
    ('buddhist', 2, 'Vajra Body'),
    ('buddhist', 3, 'Relic Formation'),
    ('buddhist', 4, 'Arhat Attainment'),
    ('buddhist', 5, 'Zen Enlightenment'),
    ('buddhist', 6, 'Bodhisattva Will'),
    ('buddhist', 7, 'Holy Light Sanctuary'),
    ('buddhist', 8, 'Myriad Buddha Realm'),
    ('buddhist', 9, 'Supreme Nirvana Buddha Sovereignty');


-- ---------------------------------------------------------------------------
-- The choice, and the moment it sets
-- ---------------------------------------------------------------------------

ALTER TABLE player_physique ADD COLUMN body_path TEXT
    REFERENCES body_paths (code) ON DELETE RESTRICT;

CREATE INDEX player_physique_body_path_idx ON player_physique (body_path);

COMMENT ON COLUMN player_physique.body_path IS
    'Which body this cultivator is building. NULL until chosen; fixed once the body reaches Rank 2.';

CREATE FUNCTION enforce_body_path_sets()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.body_path IS NOT DISTINCT FROM OLD.body_path THEN
        RETURN NEW;
    END IF;

    IF body_rank_for_xp(OLD.physique_xp) > 1 THEN
        RAISE EXCEPTION
            'your body set at Rank %. A path is chosen while it is still forming',
            body_rank_for_xp(OLD.physique_xp)
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER player_physique_body_path_sets
    BEFORE UPDATE OF body_path ON player_physique
    FOR EACH ROW EXECUTE FUNCTION enforce_body_path_sets();

COMMENT ON FUNCTION enforce_body_path_sets() IS
    'A body that could be swapped at will is a menu, not a decision. Enforced here rather than in whichever command writes the column.';


-- ---------------------------------------------------------------------------
-- player_body
-- ---------------------------------------------------------------------------
-- Everything a body screen needs, in one row. The rank is computed once per
-- row and reused, rather than five calls to the same STABLE function.

CREATE VIEW player_body AS
SELECT
    pp.player_id,
    pp.physique_xp,
    pp.body_level,
    pp.max_hp, pp.current_hp, pp.defense, pp.strength, pp.regeneration,
    pp.body_path,
    here.rank                AS body_rank,
    bp.name                  AS path_name,
    bp.emoji                 AS path_emoji,
    bp.temperament,
    bp.description           AS path_description,
    bp.hp_bonus, bp.defense_bonus, bp.strength_bonus,
    mine.name                AS rank_name,
    cur.xp_required          AS rank_floor,
    nxt.xp_required          AS next_floor,
    ahead.name               AS next_rank_name,
    ph.name                  AS physique_name,
    ph.tier                  AS physique_rarity,
    ph.hp_multiplier, ph.defense_multiplier, ph.strength_multiplier,
    here.rank = 1            AS path_still_open
FROM player_physique pp
CROSS JOIN LATERAL (SELECT body_rank_for_xp(pp.physique_xp) AS rank) here
JOIN body_rank_requirements cur   ON cur.rank = here.rank
LEFT JOIN body_rank_requirements nxt ON nxt.rank = here.rank + 1
LEFT JOIN body_paths bp           ON bp.code = pp.body_path
LEFT JOIN body_ranks mine         ON mine.path_code = pp.body_path AND mine.rank = here.rank
LEFT JOIN body_ranks ahead        ON ahead.path_code = pp.body_path AND ahead.rank = here.rank + 1
LEFT JOIN physiques ph            ON ph.physique_id = pp.physique_id;

COMMENT ON VIEW player_body IS
    'A body in full: what it is called, what it is built for, and how far it has got.';


-- ---------------------------------------------------------------------------
-- The path reaches the stats
-- ---------------------------------------------------------------------------
-- Through the same additive stack 0036 added Gu to. A Mortal Body on the
-- Demonic path with a +6% strength manual is 1 + 0.45 + 0.06, never a product
-- of the three.

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
                + COALESCE(path_hp, 0) + gu_stat(p_player_id, 'max_hp');
    mult_def := COALESCE(mult_def, 1) + COALESCE(man_def, 0)
                + COALESCE(path_def, 0);
    mult_str := COALESCE(mult_str, 1) + COALESCE(man_str, 0)
                + COALESCE(path_str, 0);

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
