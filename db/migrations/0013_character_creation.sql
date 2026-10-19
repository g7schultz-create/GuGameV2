-- 0013_character_creation
--
-- Ties Race, Root and Physique to a player, and replaces the session-based
-- training model with continuous passive accrual.
--
-- On the model change. 0006 built `training_sessions` as a claim on a span of
-- time, settled on return, and 0009 built the payout for it. Cultivation is
-- now idle instead: it accrues from the clock, settled whenever the player
-- touches the game. `player_cultivation.last_tick_at` was put there in 0006
-- for exactly this and has been waiting for it.
--
-- The training tables and `resolve_training_session` are deliberately left in
-- place rather than dropped. They are the right shape for a timed activity -
-- expeditions, seclusion, secret realms - and dropping a table to reclaim
-- nothing is how you lose a design decision you will want back. What *is*
-- reused is the rest of 0009: `apply_cultivation_xp`, `apply_physique_xp` and
-- `grant_path_insight` are what the passive tick calls.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
-- PLACEHOLDER rates, same as the training figures they replace so the curve
-- does not shift underneath anyone.

INSERT INTO game_config (key, value, description) VALUES
    ('passive_cultivation_per_hour', 100,
     'PLACEHOLDER - cultivation accrued per hour of elapsed time, before trait bonuses.'),
    ('passive_physique_per_hour', 80,
     'PLACEHOLDER - physique XP accrued per hour, before trait bonuses.'),
    ('passive_insight_per_hour', 60,
     'PLACEHOLDER - insight per hour into the focus Path. Zero without one.'),
    ('passive_cap_hours', 24,
     'Elapsed time is capped at this before being paid. Stops a month away paying a month.'),
    ('character_root_rerolls', 2,
     'Rerolls of the Root offered during character creation.'),
    ('character_physique_rerolls', 2,
     'Rerolls of the Physique offered during character creation.');


-- ---------------------------------------------------------------------------
-- player_character
-- ---------------------------------------------------------------------------
-- The two creation traits that do not already have a home. The physique lives
-- on `player_physique` where the body pillar's state is, rather than being
-- copied here - one physique, one place.
--
-- `confirmed_at NULL` is a character mid-creation: rolled but not committed.
-- That state lives in the database rather than in the lifetime of a Discord
-- view, so a restart, a timeout or a closed client resumes where it left off
-- instead of stranding a half-made character.

CREATE TABLE player_character (
    player_id             BIGINT PRIMARY KEY REFERENCES players (player_id) ON DELETE CASCADE,

    race_code             TEXT NOT NULL REFERENCES races (code) ON DELETE RESTRICT,
    root_code             TEXT NOT NULL REFERENCES roots (code) ON DELETE RESTRICT,

    -- A chosen name, distinct from the Discord handle, which changes.
    character_name        TEXT,

    -- Counted down, not up: "2 rerolls left" is what the button has to say.
    root_rerolls_left     SMALLINT NOT NULL DEFAULT 0 CHECK (root_rerolls_left >= 0),
    physique_rerolls_left SMALLINT NOT NULL DEFAULT 0 CHECK (physique_rerolls_left >= 0),

    -- How many times each has been rolled in total, for the footer line.
    root_rolls            SMALLINT NOT NULL DEFAULT 1 CHECK (root_rolls >= 1),
    physique_rolls        SMALLINT NOT NULL DEFAULT 1 CHECK (physique_rolls >= 1),

    confirmed_at          TIMESTAMPTZ,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER player_character_set_updated_at
    BEFORE UPDATE ON player_character
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX player_character_race_idx ON player_character (race_code);
CREATE INDEX player_character_root_idx ON player_character (root_code);

-- "Who else rolled a Unique?" - the question a rare roll immediately creates.
CREATE INDEX player_character_confirmed_idx
    ON player_character (confirmed_at)
    WHERE confirmed_at IS NOT NULL;

COMMENT ON TABLE player_character IS
    'Race and Root, plus creation state. confirmed_at NULL means rolled but not committed.';


-- ---------------------------------------------------------------------------
-- The focus Path
-- ---------------------------------------------------------------------------
-- Idle cultivation with a focus set trades raw cultivation for insight into
-- that Path - the same bargain the focused training session used to offer,
-- carried across to the new model and using the same configured rate.

ALTER TABLE player_cultivation
    ADD COLUMN focus_path TEXT REFERENCES paths (code) ON DELETE RESTRICT;

CREATE INDEX player_cultivation_focus_idx ON player_cultivation (focus_path);

COMMENT ON COLUMN player_cultivation.focus_path IS
    'Path idle cultivation feeds insight into. NULL is pure cultivation: full rate, no insight.';


-- ---------------------------------------------------------------------------
-- Rolling
-- ---------------------------------------------------------------------------
-- Weighted sampling in one pass: dividing a band's weight among its members
-- gives each member its share, and ordering by -ln(random())/weight draws one
-- with probability proportional to that share. A band with no members simply
-- contributes nothing and the rest renormalise, which is what makes it safe to
-- ship `mythic` with no roots in it yet.
--
-- An evolved form is not rollable, and that is derived rather than flagged:
-- if something evolves *into* it, it is not a starting root.

CREATE FUNCTION roll_root()
RETURNS TEXT
LANGUAGE sql VOLATILE
AS $$
    SELECT code FROM (
        SELECT r.code,
               ra.roll_weight / count(*) OVER (PARTITION BY r.rarity) AS weight
        FROM roots r
        JOIN rarities ra ON ra.code = r.rarity
        WHERE ra.roll_weight > 0
          AND NOT EXISTS (SELECT 1 FROM roots e WHERE e.evolves_into = r.code)
    ) candidates
    ORDER BY -ln(random()) / weight
    LIMIT 1;
$$;

CREATE FUNCTION roll_physique()
RETURNS SMALLINT
LANGUAGE sql VOLATILE
AS $$
    SELECT physique_id FROM (
        SELECT p.physique_id,
               ra.roll_weight / count(*) OVER (PARTITION BY p.tier) AS weight
        FROM physiques p
        JOIN rarities ra ON ra.code = p.tier
        WHERE p.rollable AND ra.roll_weight > 0
    ) candidates
    ORDER BY -ln(random()) / weight
    LIMIT 1;
$$;

COMMENT ON FUNCTION roll_root() IS
    'One root, weighted by rarity band and uniform within it. Evolved forms are excluded by being the target of an evolution.';


-- ---------------------------------------------------------------------------
-- Trait aggregation
-- ---------------------------------------------------------------------------
-- Race, Root and Physique all grant the same kinds of bonus, and every one of
-- them is read on every accrual. This view sums the flat ones once so the
-- accrual is a single lookup rather than five joins repeated per rate.
--
-- Everything here is additive: three sources of +10% make +30%, not +33.1%.
-- Multiplying independent percentage bonuses is how a game ends up with a
-- build that is accidentally 40x everything else.

CREATE VIEW player_trait_rates AS
SELECT
    pc.player_id,

    1 + COALESCE(ra.cultivation_rate_bonus, 0)
      + COALESCE(ro.cultivation_rate_bonus, 0)
      + COALESCE(ph.cultivation_rate_bonus, 0)   AS cultivation_multiplier,

    1 + COALESCE(ra.physique_rate_bonus, 0)
      + COALESCE(ro.physique_rate_bonus, 0)
      + COALESCE(ph.physique_rate_bonus, 0)      AS physique_multiplier,

    -- The all-Path component. Per-Path bonuses are added on top of this by
    -- player_attainment_rate(), which needs to know which Path is being asked
    -- about and so cannot live in a view keyed only by player.
    1 + COALESCE(ra.attainment_rate_bonus, 0)
      + COALESCE(ro.attainment_rate_bonus, 0)
      + COALESCE(ph.attainment_rate_bonus, 0)    AS attainment_multiplier,

    -- The physique's own stat multipliers, with the race and root fractions
    -- folded in. This is the one place the two conventions meet.
    COALESCE(ph.hp_multiplier, 1)
        * (1 + COALESCE(ra.hp_bonus, 0) + COALESCE(ro.hp_bonus, 0))       AS hp_multiplier,
    COALESCE(ph.defense_multiplier, 1)
        * (1 + COALESCE(ra.defense_bonus, 0) + COALESCE(ro.defense_bonus, 0)) AS defense_multiplier,
    COALESCE(ph.strength_multiplier, 1)
        * (1 + COALESCE(ra.strength_bonus, 0) + COALESCE(ro.strength_bonus, 0)) AS strength_multiplier

FROM player_cultivation pc
LEFT JOIN player_character pchar ON pchar.player_id = pc.player_id
LEFT JOIN races ra              ON ra.code = pchar.race_code
LEFT JOIN roots ro              ON ro.code = pchar.root_code
LEFT JOIN player_physique pp    ON pp.player_id = pc.player_id
LEFT JOIN physiques ph          ON ph.physique_id = pp.physique_id;

COMMENT ON VIEW player_trait_rates IS
    'Race + Root + Physique summed into one multiplier per rate. Additive by design: three +10% sources make +30%.';


-- ---------------------------------------------------------------------------
-- player_attainment_rate
-- ---------------------------------------------------------------------------
-- How fast one player gains insight in one Path. The all-Path multiplier plus
-- every per-Path bonus from the three traits, plus the physique's affinity
-- where it matches.
--
-- `affinity_bonus` is a multiplier (1.5) while everything else is a fraction,
-- so it is folded in as `affinity_bonus - 1`. That keeps one addition rule
-- rather than two, at the cost of this comment.

CREATE FUNCTION player_attainment_rate(p_player_id BIGINT, p_path_code TEXT)
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
    FROM player_trait_rates tr
    WHERE tr.player_id = p_player_id;
$$;

COMMENT ON FUNCTION player_attainment_rate(BIGINT, TEXT) IS
    'Insight multiplier for one player in one Path: all-Path bonuses plus every per-Path bonus from Race, Root and Physique.';


-- ---------------------------------------------------------------------------
-- player_external_multiplier
-- ---------------------------------------------------------------------------
-- 0008 left `p_external_multiplier` on compute_technique_damage as the hook
-- for "Dao Marks, equipment and buffs", to be passed 1 until those existed.
-- The three traits' damage bonuses are the first thing to arrive through it.
--
-- Weighted by the technique's own Path weights, so a Sword/Fire move gets half
-- of a Sword bonus - the same weighting `technique_attainment_bonus` uses, for
-- the same reason: a dual-Path technique is half of each, not both in full.

CREATE FUNCTION player_external_multiplier(p_player_id BIGINT, p_technique_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT 1 + COALESCE(SUM(tp.weight * (
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
    )), 0)
    FROM technique_paths tp
    WHERE tp.technique_id = p_technique_id;
$$;

COMMENT ON FUNCTION player_external_multiplier(BIGINT, BIGINT) IS
    'The external hook on compute_technique_damage, filled by Race/Root/Physique damage bonuses, weighted by the technique typing.';


-- ---------------------------------------------------------------------------
-- apply_physique_xp, replaced
-- ---------------------------------------------------------------------------
-- Same function as 0009 with one change: the stat multipliers now come from
-- player_trait_rates, so a race or root that grants +5% HP actually grants it.
-- Replaced rather than added alongside, so there is still exactly one
-- definition of what a body level is worth.

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    hp_rate   NUMERIC := game_config_value('physique_hp_per_level');
    def_rate  NUMERIC := game_config_value('physique_defense_per_level');
    str_rate  NUMERIC := game_config_value('physique_strength_per_level');

    row_before  player_physique%ROWTYPE;
    mult_hp     NUMERIC := 1;
    mult_def    NUMERIC := 1;
    mult_str    NUMERIC := 1;
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

    mult_hp  := COALESCE(mult_hp, 1);
    mult_def := COALESCE(mult_def, 1);
    mult_str := COALESCE(mult_str, 1);

    new_level  := 1 + floor((row_before.physique_xp + p_xp) / per_level);
    new_max_hp := greatest(1, round((base_hp + hp_rate * (new_level - 1)) * mult_hp));
    hp_gained  := greatest(0, new_max_hp - row_before.max_hp);

    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level,
        max_hp      = new_max_hp,
        current_hp  = least(row_before.current_hp + hp_gained, new_max_hp),
        defense     = round(def_rate * (new_level - 1) * mult_def),
        strength    = round(str_rate * (new_level - 1) * mult_str)
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;


-- ---------------------------------------------------------------------------
-- settle_passive_cultivation
-- ---------------------------------------------------------------------------
-- The whole idle model, in one call.
--
-- Called at the top of every command that displays progress, which is what
-- makes the bar appear to fill continuously: it is never actually ticking, it
-- is computed from `last_tick_at` at the moment somebody looks. No scheduler,
-- nothing to fall behind, and a bot that was offline for a day still owes
-- exactly what that day was worth.
--
-- `last_tick_at` is advanced by the time actually *paid*, not to now(). When
-- the cap bites, the unpaid remainder is dropped rather than banked - and
-- moving the marker forward only by what was paid is what keeps a capped
-- player from accumulating a silent debt that pays out later.

CREATE FUNCTION settle_passive_cultivation(p_player_id BIGINT)
RETURNS TABLE (
    hours              NUMERIC,
    capped             BOOLEAN,
    cultivation_gained BIGINT,
    physique_gained    BIGINT,
    insight_gained     BIGINT,
    focus_path         TEXT,
    realm_before       SMALLINT,
    realm_after        SMALLINT,
    level_before       SMALLINT,
    level_after        SMALLINT,
    tier_before        SMALLINT,
    tier_after         SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult          player_cultivation%ROWTYPE;
    rates         player_trait_rates%ROWTYPE;
    baseline      NUMERIC := game_config_value('training_aptitude_baseline');
    cap_hours     NUMERIC := game_config_value('passive_cap_hours');
    elapsed       NUMERIC;
    paid          NUMERIC;
    was_capped    BOOLEAN;
    cult_gain     BIGINT;
    phys_gain     BIGINT;
    insight_gain  BIGINT := 0;
    r_before      SMALLINT;
    r_after       SMALLINT;
    l_before      SMALLINT;
    l_after       SMALLINT;
    t_before      SMALLINT;
    t_after       SMALLINT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    elapsed    := EXTRACT(EPOCH FROM (now() - cult.last_tick_at)) / 3600.0;
    was_capped := elapsed > cap_hours;
    paid       := LEAST(elapsed, cap_hours);

    SELECT * INTO rates FROM player_trait_rates WHERE player_id = p_player_id;

    SELECT pc.realm_id INTO r_before FROM player_cultivation pc WHERE pc.player_id = p_player_id;
    SELECT pp.body_level INTO l_before FROM player_physique pp WHERE pp.player_id = p_player_id;
    SELECT COALESCE(a.tier, 0) INTO t_before
    FROM (SELECT 1) _
    LEFT JOIN player_path_attainment a
        ON a.player_id = p_player_id AND a.path_code = cult.focus_path;

    cult_gain := round(
        paid
        * game_config_value('passive_cultivation_per_hour')
        * COALESCE(rates.cultivation_multiplier, 1)
        * (cult.aptitude / baseline)
        * CASE WHEN cult.focus_path IS NULL THEN 1
               ELSE game_config_value('path_cultivation_xp_rate') END
    );

    phys_gain := round(
        paid
        * game_config_value('passive_physique_per_hour')
        * COALESCE(rates.physique_multiplier, 1)
    );

    IF cult.focus_path IS NOT NULL THEN
        insight_gain := round(
            paid
            * game_config_value('passive_insight_per_hour')
            * player_attainment_rate(p_player_id, cult.focus_path)
        );
    END IF;

    r_after := apply_cultivation_xp(p_player_id, cult_gain);
    l_after := apply_physique_xp(p_player_id, phys_gain);

    IF cult.focus_path IS NOT NULL THEN
        t_after := grant_path_insight(
            p_player_id, cult.focus_path, insight_gain, round(paid * 3600)::bigint, 0
        );
    ELSE
        t_after := t_before;
    END IF;

    UPDATE player_cultivation
    SET last_tick_at = last_tick_at + make_interval(secs => paid * 3600)
    WHERE player_id = p_player_id;

    RETURN QUERY SELECT
        round(paid, 4), was_capped,
        cult_gain, phys_gain, insight_gain, cult.focus_path,
        r_before, r_after, l_before, l_after, t_before, t_after;
END;
$$;

COMMENT ON FUNCTION settle_passive_cultivation(BIGINT) IS
    'Pays out elapsed idle time and advances last_tick_at by what was paid. Safe to call on every command; a zero-elapsed call grants zero.';
