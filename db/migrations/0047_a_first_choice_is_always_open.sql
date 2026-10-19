-- 0047_a_first_choice_is_always_open
--
-- 0046 locked the body path at Rank 2 and locked out everybody who was already
-- past it. The only character in this database is Rank 2 and has never had a
-- path to choose, because there were none to choose from until an hour ago —
-- so the rule as written said "you may not have the thing you never had".
--
-- The rule was aimed at the wrong event. What should set is CHANGING YOUR
-- MIND, not choosing at all:
--
--   * no path yet          -> always allowed. The choice is still owed.
--   * a path, at Rank 1    -> allowed. The body is still forming.
--   * a path, past Rank 1  -> refused. It has set.
--
-- Which is also the simpler sentence, and the one worth having: your first
-- choice is always yours, and changing it is free only while nothing is built
-- on top of it. A migration that arrives after players do has to be readable
-- by the players who were already here.
--
-- Forward-only. Do not edit once applied.

CREATE OR REPLACE FUNCTION enforce_body_path_sets()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.body_path IS NOT DISTINCT FROM OLD.body_path THEN
        RETURN NEW;
    END IF;

    -- A choice never made is still owed, whatever rank it is owed at.
    IF OLD.body_path IS NULL THEN
        RETURN NEW;
    END IF;

    IF body_rank_for_xp(OLD.physique_xp) > 1 THEN
        RAISE EXCEPTION
            'your body set as % at Rank %. That is not something you take back',
            (SELECT name FROM body_paths WHERE code = OLD.body_path),
            body_rank_for_xp(OLD.physique_xp)
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION enforce_body_path_sets() IS
    'Choosing is always allowed; changing your mind is allowed only at Rank 1. A body that could be swapped at will is a menu, not a decision.';

-- `path_still_open` has to answer the same question the trigger does, or the
-- screen offers a button the database refuses.
CREATE OR REPLACE VIEW player_body AS
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
    pp.body_path IS NULL OR here.rank = 1 AS path_still_open
FROM player_physique pp
CROSS JOIN LATERAL (SELECT body_rank_for_xp(pp.physique_xp) AS rank) here
JOIN body_rank_requirements cur   ON cur.rank = here.rank
LEFT JOIN body_rank_requirements nxt ON nxt.rank = here.rank + 1
LEFT JOIN body_paths bp           ON bp.code = pp.body_path
LEFT JOIN body_ranks mine         ON mine.path_code = pp.body_path AND mine.rank = here.rank
LEFT JOIN body_ranks ahead        ON ahead.path_code = pp.body_path AND ahead.rank = here.rank + 1
LEFT JOIN physiques ph            ON ph.physique_id = pp.physique_id;
