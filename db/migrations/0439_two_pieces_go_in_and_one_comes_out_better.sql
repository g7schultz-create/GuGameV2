-- 0439_two_pieces_go_in_and_one_comes_out_better
--
-- Fusion. A duplicate stops being something to sell and becomes what a star
-- costs, which is the same bargain the servants have had since 0415 and the
-- reason a wide collection is worth keeping.
--
-- WHAT COUNTS AS A DUPLICATE: the same SLOT, the same LEVEL and the same RANK.
-- Not the same name - names are generated from the ore and the parts, so two
-- identical helms are routinely called different things and requiring the name
-- to match would make fusion almost impossible by accident rather than by
-- design. Rank must match because that is what makes the ladder a ladder: two
-- one-stars make a two-star, and a one-star cannot be thrown at a four-star to
-- skip the middle.
--
-- WHAT THE SURVIVOR KEEPS. The better of each, taken one field at a time:
--
--   STATS    the higher roll of each stat, then rescaled to the new rank.
--            Not summed. A base stat is already multiplied by the wearer's
--            realm, and summing at every star would compound into the caps
--            within three fuses - the same ceiling the percent-to-base-stat
--            work is currently undoing. Best-of means a duplicate with one
--            great roll is worth keeping FOR that one stat, which is the
--            interesting decision.
--   RARITY   the better of the two, and no better. A bench fed nothing above
--            Rare cannot hand back a Divine - that is the rule as given, and
--            it is what stops fusion laundering cheap gear into good gear.
--   QUALITY  the better of the two, for the same reason.
--   LEVEL    unchanged. Both had to match for the fuse to be allowed.
--
-- IT CAN FAIL, AND FAILURE COSTS THE FODDER. The chance of reaching a rank is
-- on `equipment_ranks.fuse_chance` - 90% for the second star down to 30% for
-- the fifth - plus the smith's level, because the spec says the smith's rank
-- matters and because a deep smith having no advantage at the anvil would be
-- strange. Clamped to 5%-95% at both ends: a fuse that cannot fail is not a
-- risk and one that cannot succeed is not an option.
--
-- On a failure the fodder is destroyed and the keeper is untouched. The
-- alternative - destroying both - was considered and rejected: losing the
-- piece you were trying to improve turns a 30% roll into something nobody
-- sane attempts, and the fodder alone is already a real cost.
--
-- NEITHER PIECE MAY BE WORN. An equipped piece is snapshotted into battles and
-- read by `player_stat`; changing its stats underneath that is the kind of
-- thing that surfaces three screens away. Take it off first, and the function
-- says so rather than quietly unequipping something mid-fight.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES (
    'fuse_chance_per_smith_level', 0.002,
    'Added to a fusion''s base chance for each level of Blacksmithing. At 0.002 a level 150 smith carries +30 points of chance, which turns the five-star fuse from a 30% gamble into a 60% one without ever making it certain.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What a fuse would cost and what it is worth, without committing to it
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fuse_chance(p_player_id bigint, p_to_rank smallint)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $fn$
    -- Clamped at both ends on purpose: a fuse that cannot fail is not a risk,
    -- and one that cannot succeed is not an option.
    SELECT GREATEST(0.05, LEAST(0.95,
        COALESCE((SELECT er.fuse_chance FROM equipment_ranks er
                  WHERE er.rank = p_to_rank), 0)
        + profession_level(p_player_id, 'blacksmithing')
          * game_config_value('fuse_chance_per_smith_level')
    ))::numeric;
$fn$;

COMMENT ON FUNCTION fuse_chance(bigint, smallint) IS
    'The odds of reaching a rank, for this smith. Harder every star and easier every level, which is the bargain the update asked for.';


-- ---------------------------------------------------------------------------
-- The fuse
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fuse_equipment(
    p_player_id bigint, p_keeper bigint, p_fodder bigint)
RETURNS TABLE(
    succeeded    boolean,
    chance       numeric,
    rank_before  smallint,
    rank_after   smallint,
    rarity_after text,
    quality_after text,
    name_after   text,
    improved     integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    keep    RECORD;
    feed    RECORD;
    top     SMALLINT;
    odds    NUMERIC;
    won     BOOLEAN;
    step_a  NUMERIC;
    step_b  NUMERIC;
    n_up    INTEGER := 0;
BEGIN
    SELECT * INTO keep FROM player_equipment WHERE equipment_id = p_keeper;
    IF NOT FOUND OR keep.owner_id <> p_player_id THEN
        RAISE EXCEPTION 'that piece is not yours to fuse'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO feed FROM player_equipment WHERE equipment_id = p_fodder;
    IF NOT FOUND OR feed.owner_id <> p_player_id THEN
        RAISE EXCEPTION 'the piece being fused in is not yours'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_keeper = p_fodder THEN
        RAISE EXCEPTION 'a piece cannot be fused into itself'
            USING ERRCODE = 'check_violation';
    END IF;

    IF keep.slot <> feed.slot THEN
        RAISE EXCEPTION 'a % cannot be fused into a %', feed.slot, keep.slot
            USING ERRCODE = 'check_violation';
    END IF;
    IF keep.level <> feed.level THEN
        RAISE EXCEPTION
            'these were forged for different realms - level % and level %',
            keep.level, feed.level USING ERRCODE = 'check_violation';
    END IF;
    IF keep.rank <> feed.rank THEN
        RAISE EXCEPTION
            'both pieces must be the same rank - this one is %s and that one is %s',
            keep.rank, feed.rank USING ERRCODE = 'check_violation';
    END IF;

    -- Worn gear is snapshotted into fights and summed by `player_stat`.
    IF EXISTS (SELECT 1 FROM player_equipped e
               WHERE e.equipment_id IN (p_keeper, p_fodder)) THEN
        RAISE EXCEPTION 'take it off before putting it on the anvil'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT l.max_rank INTO top FROM equipment_level_scales l
    WHERE l.level = keep.level;
    IF keep.rank + 1 > COALESCE(top, 1) THEN
        RAISE EXCEPTION
            'gear forged for realm % stops at %s stars', keep.level, top
            USING ERRCODE = 'check_violation';
    END IF;

    odds := fuse_chance(p_player_id, (keep.rank + 1)::smallint);
    won  := random() < odds;

    IF NOT won THEN
        -- The fodder is spent either way. That is the cost of the attempt.
        DELETE FROM player_equipment WHERE equipment_id = p_fodder;
        RETURN QUERY SELECT FALSE, odds, keep.rank, keep.rank,
                            keep.rarity, keep.quality, keep.name, 0;
        RETURN;
    END IF;

    -- The fodder is NOT deleted yet, and the order matters: `equipment_effects`
    -- cascades from `player_equipment`, so taking the piece out first takes its
    -- stats with it and the merge below finds an empty hand. The first run of
    -- this migration did exactly that and its own probe refused it.

    SELECT er.stat_step INTO step_a FROM equipment_ranks er WHERE er.rank = keep.rank;
    SELECT er.stat_step INTO step_b FROM equipment_ranks er WHERE er.rank = keep.rank + 1;

    -- Best of each stat, then rescaled to the new rank. Both pieces stood at
    -- the same rank, so their magnitudes are on the same footing and the
    -- larger of the two really is the better roll.
    -- `merged` rather than `both`, which is a reserved word - it is the BOTH
    -- of trim(both ...) and Postgres will not take it as a CTE name.
    WITH merged AS (
        SELECT effect_code, max(magnitude) AS best
        FROM equipment_effects
        WHERE equipment_id IN (p_keeper, p_fodder)
        GROUP BY effect_code
    ), written AS (
        INSERT INTO equipment_effects (equipment_id, effect_code, magnitude)
        SELECT p_keeper, b.effect_code,
               round(b.best * step_b / NULLIF(step_a, 0), 4)
        FROM merged b
        ON CONFLICT ON CONSTRAINT equipment_effects_pkey DO UPDATE
            SET magnitude = EXCLUDED.magnitude
        RETURNING 1
    )
    SELECT count(*)::integer INTO n_up FROM written;

    -- Now the fodder goes, with its stats already carried across.
    DELETE FROM player_equipment WHERE equipment_id = p_fodder;

    UPDATE player_equipment pe
    SET rank    = keep.rank + 1,
        -- The better of each, and no better. A bench fed nothing above Rare
        -- cannot hand back a Divine.
        rarity  = CASE WHEN (SELECT r1.sort_order FROM rarities r1 WHERE r1.code = feed.rarity)
                          >  (SELECT r2.sort_order FROM rarities r2 WHERE r2.code = keep.rarity)
                       THEN feed.rarity ELSE keep.rarity END,
        quality = CASE WHEN (SELECT q1.min_harmony FROM equipment_quality_bands q1 WHERE q1.code = feed.quality)
                          >  (SELECT q2.min_harmony FROM equipment_quality_bands q2 WHERE q2.code = keep.quality)
                       THEN feed.quality ELSE keep.quality END,
        harmony = GREATEST(keep.harmony, feed.harmony)
    WHERE pe.equipment_id = p_keeper;

    RETURN QUERY
    SELECT TRUE, odds, keep.rank, pe.rank, pe.rarity, pe.quality, pe.name, n_up
    FROM player_equipment pe WHERE pe.equipment_id = p_keeper;
END;
$fn$;

COMMENT ON FUNCTION fuse_equipment(bigint, bigint, bigint) IS
    'Eat a duplicate to raise a piece by one star. Best of each stat rather than the sum of them, because a base stat is already multiplied by the wearer''s realm and summing at every star compounds into the caps within three fuses.';


-- ---------------------------------------------------------------------------
-- It refuses what it should, and what survives is the better of the two
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who  BIGINT;
    v_a    BIGINT;
    v_b    BIGINT;
    v_said TEXT;
    r      RECORD;
BEGIN
    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL
        ORDER BY profession_level(p.player_id, 'blacksmithing') DESC LIMIT 1;
        IF v_who IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Two pieces that are duplicates of each other in the sense that
        -- matters: same slot, same level, same rank.
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, ore_code, level, rank, quality)
        VALUES (v_who, 'Probe Helm A', 'helm', 1, 'rare', 100, 'spirit_iron', 3, 1, 'fine')
        RETURNING equipment_id INTO v_a;
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, ore_code, level, rank, quality)
        VALUES (v_who, 'Probe Helm B', 'helm', 1, 'epic', 120, 'spirit_iron', 3, 1, 'superb')
        RETURNING equipment_id INTO v_b;

        INSERT INTO equipment_effects (equipment_id, effect_code, magnitude) VALUES
            (v_a, 'base_strength', 10), (v_a, 'crit_rate', 0.10),
            (v_b, 'base_strength',  4), (v_b, 'crit_damage', 0.20);

        -- A piece may not eat itself.
        BEGIN
            PERFORM fuse_equipment(v_who, v_a, v_a);
            RAISE EXCEPTION 'a piece was fused into itself';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- Nor may ranks be skipped. Push one to rank 2 by hand and try.
        UPDATE player_equipment SET rank = 2 WHERE equipment_id = v_b;
        BEGIN
            PERFORM fuse_equipment(v_who, v_a, v_b);
            RAISE EXCEPTION 'a rank 1 was fused into a rank 2';
        EXCEPTION WHEN check_violation THEN NULL;
        END;
        UPDATE player_equipment SET rank = 1 WHERE equipment_id = v_b;

        -- The real thing. Forced to succeed by asking for a rank whose odds
        -- are certain would be testing a different function, so it is run and
        -- BOTH outcomes are checked for being coherent.
        SELECT * INTO r FROM fuse_equipment(v_who, v_a, v_b);

        IF NOT EXISTS (SELECT 1 FROM player_equipment WHERE equipment_id = v_a) THEN
            RAISE EXCEPTION 'the keeper was destroyed';
        END IF;
        IF EXISTS (SELECT 1 FROM player_equipment WHERE equipment_id = v_b) THEN
            RAISE EXCEPTION 'the fodder survived, so the fuse cost nothing';
        END IF;

        IF r.succeeded THEN
            IF r.rank_after <> 2 THEN
                RAISE EXCEPTION 'a successful fuse left it at rank %', r.rank_after;
            END IF;
            -- Best of each, not the sum: 10 and 4 must give 10 (scaled), not 14.
            IF (SELECT magnitude FROM equipment_effects
                WHERE equipment_id = v_a AND effect_code = 'base_strength')
               <> round(10 * 1.25, 4) THEN
                RAISE EXCEPTION
                    'sinew came out at % rather than the better roll rescaled',
                    (SELECT magnitude FROM equipment_effects
                     WHERE equipment_id = v_a AND effect_code = 'base_strength');
            END IF;
            -- And a stat only the fodder had is carried across.
            IF NOT EXISTS (SELECT 1 FROM equipment_effects
                           WHERE equipment_id = v_a AND effect_code = 'crit_damage') THEN
                RAISE EXCEPTION 'a stat the fodder brought was dropped';
            END IF;
            -- The better rarity and quality, and no better.
            IF r.rarity_after <> 'epic' THEN
                RAISE EXCEPTION 'rarity came out % rather than the better of the two',
                    r.rarity_after;
            END IF;
            IF r.quality_after <> 'superb' THEN
                RAISE EXCEPTION 'quality came out %', r.quality_after;
            END IF;
        ELSE
            IF r.rank_after <> r.rank_before THEN
                RAISE EXCEPTION 'a failed fuse still moved the rank';
            END IF;
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT er.rank, er.stat_step, er.fuse_chance,
               round(GREATEST(0.05, LEAST(0.95, er.fuse_chance + 150 * 0.002)), 2) AS at_150
        FROM equipment_ranks er WHERE er.fuse_chance IS NOT NULL ORDER BY er.rank
    LOOP
        RAISE NOTICE 'to %s stars: base %, a level 150 smith %  (stats x%)',
            r.rank, r.fuse_chance, r.at_150, r.stat_step;
    END LOOP;
END;
$probe$;
