-- 0248_a_realm_is_worth_four_of_you
--
-- A major realm was worth about 1.5x. It should be worth four.
--
-- Stats were linear in body level - `base + rate x (level - 1)` - and the
-- level bands per body rank are 3, 5, 9, 15, 24, 34, 50, 70 levels wide. That
-- makes each rank about 1.5x the last, so a Nascent Soul cultivator and a Core
-- Formation one are the same fight with different names. Nothing in the
-- setting works that way: a realm is supposed to be a wall.
--
-- FOUR TIMES PER MAJOR REALM, SPLIT ACROSS THE TWO LADDERS. Body tempering and
-- cultivation are separate ranks and a cultivator advances both, so each is
-- worth 2x and advancing both is the 4x. A player who only tempers or only
-- cultivates gets half the curve, which is the correct pressure - neither
-- ladder is decoration.
--
--     stat = base x multipliers x 2 ^ (body progress) x 2 ^ (realm rank - 1)
--
-- The level term is GONE. Progress through a body rank is now a fraction of
-- that rank's own band, so a rank doubles you smoothly however wide its band
-- is - and `physique_hp_per_level` and its two siblings are deleted rather
-- than left sitting there meaning nothing. Keeping a linear term as well would
-- have double-counted: the wide upper bands would have made a late rank worth
-- twelve times its own start on top of the doubling.
--
-- CREATURES AND TECHNIQUES MOVE WITH IT, or the composition of a fight changes
-- with rank rather than its size. Creature health, attack and defence were
-- climbing about 2.2x a rank and technique power a very consistent 2.5x; both
-- are rescaled to 4x, keeping every individual's ratio to its own rank's mean
-- so a tough rank 3 beast stays a tough rank 3 beast. Without this, Strength
-- at 4x would have swallowed technique power entirely by the Immortal realms
-- and the manuals people spend fortunes on would have stopped mattering.
--
-- AND DEFENCE HOLDS ITS VALUE. `creature_defense_scale_per_rank` was 2 while
-- defence grew 1.5x, so a defence stat decayed from 80% of a rank 1 blow to
-- 1.6% of a rank 9 one. It is 4 now, matching what defence actually does per
-- rank, and `defense_scale` drops 100 to 60 so the stat soaks about a quarter
-- of an equal-rank blow at EVERY rank instead of evaporating up the ladder.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The dials
-- ---------------------------------------------------------------------------

INSERT INTO game_config (key, value, description) VALUES
    ('stat_step_per_rank', 2,
     'What one rank of one ladder multiplies a cultivator by. Body tempering '
     'and cultivation each pay it, so a major realm crossed on both is the '
     'square - four times the cultivator you were.');

UPDATE game_config SET value = 60,
    description = 'The divisor a blow is softened by. Set so a defence stat '
                  'soaks about a quarter of an equal-rank blow; it rises with '
                  'the attacker''s rank at the same rate defence does.'
WHERE key = 'defense_scale';

UPDATE game_config SET value = 4,
    description = 'How much harder a rank is to defend against. Matches what a '
                  'cultivator''s defence actually grows by per rank, so the '
                  'stat holds its value up the ladder instead of decaying.'
WHERE key = 'creature_defense_scale_per_rank';

-- The level term is gone, so these describe nothing.
DELETE FROM game_config WHERE key IN (
    'physique_hp_per_level', 'physique_defense_per_level',
    'physique_strength_per_level');


-- ---------------------------------------------------------------------------
-- Where a cultivator stands on both ladders
-- ---------------------------------------------------------------------------

CREATE FUNCTION body_rank_progress(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT (pp.body_rank - 1) + LEAST(1.0, GREATEST(0.0,
        (pp.body_level - band.first_level)::numeric
        / GREATEST(1, band.next_level - band.first_level)))
    FROM player_physique pp
    JOIN LATERAL (
        SELECT (1 + floor(r.xp_required / game_config_value('physique_xp_per_level')))::int
                   AS first_level,
               -- The top rank has no ceiling, so it is given the width of the
               -- one below rather than a progress that can never finish.
               COALESCE(
                 (1 + floor(n.xp_required / game_config_value('physique_xp_per_level')))::int,
                 (1 + floor(r.xp_required / game_config_value('physique_xp_per_level')))::int
                 + 70) AS next_level
        FROM body_rank_requirements r
        LEFT JOIN body_rank_requirements n ON n.rank = r.rank + 1
        WHERE r.rank = pp.body_rank
    ) band ON TRUE
    WHERE pp.player_id = p_player_id;
$$;

COMMENT ON FUNCTION body_rank_progress(BIGINT) IS
    'How far up the tempering ladder a body is, counted in ranks with the fraction through the current one. A rank doubles a cultivator smoothly however wide its level band happens to be.';


CREATE FUNCTION player_power_multiple(p_player_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
    SELECT power(game_config_value('stat_step_per_rank'),
                 COALESCE(body_rank_progress(p_player_id), 0))
         * power(game_config_value('stat_step_per_rank'),
                 COALESCE((SELECT r.rank - 1 FROM player_cultivation pc
                           JOIN realms r ON r.realm_id = pc.realm_id
                           WHERE pc.player_id = p_player_id), 0));
$$;

COMMENT ON FUNCTION player_power_multiple(BIGINT) IS
    'Everything a cultivator has climbed, on both ladders, as one number. A major realm crossed on both is four times what you were.';


-- ---------------------------------------------------------------------------
-- The body
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION apply_physique_xp(p_player_id BIGINT, p_xp BIGINT)
RETURNS SMALLINT
LANGUAGE plpgsql
AS $$
DECLARE
    per_level NUMERIC := game_config_value('physique_xp_per_level');
    base_hp   NUMERIC := game_config_value('physique_base_hp');
    base_def  NUMERIC := game_config_value('physique_base_defense');
    base_str  NUMERIC := game_config_value('physique_base_strength');

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
    climbed     NUMERIC;
    new_max_hp  BIGINT;
    kept        NUMERIC;
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

    -- Written before the stats are read back, because the multiple is computed
    -- from where the body stands and the body has just moved.
    UPDATE player_physique
    SET physique_xp = row_before.physique_xp + p_xp,
        body_level  = new_level
    WHERE player_id = p_player_id;

    climbed := player_power_multiple(p_player_id);

    new_max_hp := GREATEST(1, round(base_hp * mult_hp * climbed));

    -- The share of the body that was still standing, kept across the change.
    -- A cultivator whose maximum leaps a hundredfold must not find themselves
    -- at one percent of it.
    kept := CASE WHEN row_before.max_hp > 0
                 THEN LEAST(1.0, row_before.current_hp::numeric / row_before.max_hp)
                 ELSE 1.0 END;

    UPDATE player_physique
    SET max_hp     = new_max_hp,
        current_hp = GREATEST(0, LEAST(new_max_hp, round(new_max_hp * kept))),
        defense    = GREATEST(0, round(base_def * mult_def * climbed)),
        strength   = GREATEST(0, round(base_str * mult_str * climbed))
    WHERE player_id = p_player_id;

    RETURN new_level;
END;
$$;


-- A realm crossing now moves the body, so the body has to be told.
DO $$
DECLARE
    src TEXT;
    old TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO src FROM pg_proc WHERE proname = 'breakthrough';

    old := '    tempering := round(player_stat(p_player_id, ''realm_tempering'')
                       * game_config_value(''physique_xp_per_level''));';

    IF position(old IN src) = 0 THEN
        RAISE EXCEPTION 'breakthrough no longer tempers the old way';
    END IF;

    EXECUTE replace(src, old,
        '    tempering := round(player_stat(p_player_id, ''realm_tempering'')
                       * game_config_value(''physique_xp_per_level''));

    -- 0248 put the realm into the body''s own arithmetic, so crossing one has
    -- to recompute it even when no tempering XP is granted. Zero XP is a
    -- recalculation, not a no-op.
    PERFORM apply_physique_xp(p_player_id, 0);');

    EXECUTE src;
END;
$$;


-- ---------------------------------------------------------------------------
-- The roster climbs the same ladder
-- ---------------------------------------------------------------------------
-- Ratio-preserving: every species keeps its standing within its own rank, and
-- the rank's mean is moved onto the 4x curve. A tough rank 3 beast stays a
-- tough rank 3 beast.

DO $$
DECLARE
    step NUMERIC := power(game_config_value('stat_step_per_rank'), 2);
    r    RECORD;
    hp0  NUMERIC;
    at0  NUMERIC;
    df0  NUMERIC;
BEGIN
    SELECT avg(base_hp), avg(base_attack), avg(base_defense)
    INTO hp0, at0, df0
    FROM creature_species WHERE rank = 1 AND kind IN ('beast', 'elite');

    IF hp0 IS NULL THEN
        RAISE NOTICE 'no rank 1 roster to anchor on; the tests carry it';
        RETURN;
    END IF;

    FOR r IN
        SELECT cs.rank,
               avg(cs.base_hp) AS hp, avg(cs.base_attack) AS atk,
               avg(cs.base_defense) AS def
        FROM creature_species cs GROUP BY cs.rank
    LOOP
        UPDATE creature_species cs
        SET base_hp      = GREATEST(1, round(cs.base_hp
                              * (hp0 * power(step, r.rank - 1)) / GREATEST(r.hp, 1))),
            base_attack  = GREATEST(1, round(cs.base_attack
                              * (at0 * power(step, r.rank - 1)) / GREATEST(r.atk, 1))),
            base_defense = GREATEST(0, round(cs.base_defense
                              * (df0 * power(step, r.rank - 1)) / GREATEST(r.def, 1)))
        WHERE cs.rank = r.rank;
    END LOOP;
END;
$$;


-- And so do the techniques, or Strength swallows them by the Immortal realms.
DO $$
DECLARE
    step NUMERIC := power(game_config_value('stat_step_per_rank'), 2);
    r    RECORD;
    p0   NUMERIC;
BEGIN
    SELECT avg(base_power) INTO p0 FROM techniques
    WHERE rank = 1 AND created_by IS NULL AND base_power > 0;

    IF p0 IS NULL THEN
        RAISE NOTICE 'no rank 1 techniques to anchor on; the tests carry it';
        RETURN;
    END IF;

    FOR r IN
        SELECT t.rank, avg(t.base_power) AS power
        FROM techniques t
        WHERE t.created_by IS NULL AND t.base_power > 0
        GROUP BY t.rank
    LOOP
        UPDATE techniques t
        SET base_power = GREATEST(1, round(t.base_power
                             * (p0 * power(step, r.rank - 1)) / GREATEST(r.power, 1)))
        WHERE t.rank = r.rank AND t.created_by IS NULL AND t.base_power > 0;
    END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- Every living cultivator, recomputed onto the new curve
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who  BIGINT;
    n    INTEGER := 0;
BEGIN
    FOR who IN
        SELECT pp.player_id FROM player_physique pp
        JOIN players p ON p.player_id = pp.player_id
        WHERE p.deleted_at IS NULL
    LOOP
        PERFORM apply_physique_xp(who, 0);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'recomputed % bodies', n;
END;
$$;


DO $$
DECLARE
    broken TEXT;
    soak   NUMERIC;
BEGIN
    -- Nobody came out of this with nothing.
    SELECT string_agg(p.discord_name, ', ') INTO broken
    FROM player_physique pp JOIN players p ON p.player_id = pp.player_id
    WHERE p.deleted_at IS NULL
      AND (pp.max_hp < 1 OR pp.current_hp < 0 OR pp.current_hp > pp.max_hp
           OR pp.defense < 0 OR pp.strength < 0);
    IF broken IS NOT NULL THEN
        RAISE EXCEPTION 'these cultivators came out broken: %', broken;
    END IF;

    -- A major realm on both ladders is four times the cultivator.
    IF abs(power(game_config_value('stat_step_per_rank'), 2) - 4) > 0.001 THEN
        RAISE EXCEPTION 'a realm on both ladders is not worth four';
    END IF;

    -- And defence soaks about a quarter of an equal-rank blow, at every rank.
    FOR soak IN
        SELECT (game_config_value('physique_base_defense')
                * power(4, r - 1))
             / ((game_config_value('defense_scale')
                 * power(game_config_value('creature_defense_scale_per_rank'), r - 1))
                + game_config_value('physique_base_defense') * power(4, r - 1))
        FROM generate_series(1, 9) r
    LOOP
        IF soak < 0.20 OR soak > 0.32 THEN
            RAISE EXCEPTION 'defence soaks % of an equal-rank blow',
                round(100 * soak)::text || ' pct';
        END IF;
    END LOOP;
END;
$$;
