-- 0029_starter_split
--
-- A starter manual's 6% is split the same way for everyone.
--
-- 0028 rolled the split between attack and cultivation, which made one
-- player's issued book quietly better than another's - and made a twelve-hour
-- idle payout unquotable, because the cultivation bonus feeding it was
-- different per character.
--
-- Luck belongs on what you find, not on what you are handed. The Path, the
-- technique and the name still roll; the numbers no longer do. 4% attack and
-- 2% cultivation is also exactly how the seeded Tier 1 offensive manual
-- (Crimson Palm Canon) spends its budget, so every Tier 1 offensive manual in
-- the game now agrees with every other.
--
-- Forward-only. Do not edit once applied.


CREATE OR REPLACE FUNCTION grant_starter_manual(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    chosen_path TEXT;
    chosen_tech BIGINT;
    budget      NUMERIC;
    attack      NUMERIC;
    new_name    TEXT;
    new_manual  BIGINT;
    free_slot   SMALLINT;
BEGIN
    IF EXISTS (SELECT 1 FROM player_manuals pm WHERE pm.player_id = p_player_id) THEN
        RETURN NULL;
    END IF;

    -- Which Paths can arm a beginner is a question about the technique table,
    -- so it is asked there rather than answered by a list somebody has to
    -- remember to extend. Single-Path moves only: a first book teaches one
    -- thing, and a dual-typed move belongs to neither of its Paths cleanly.
    SELECT tp.path_code, t.technique_id
    INTO chosen_path, chosen_tech
    FROM techniques t
    JOIN technique_paths tp ON tp.technique_id = t.technique_id
    WHERE t.created_by IS NULL
      AND t.rank = 1
      AND t.category = 'attack'
      AND t.base_power > 0
      AND tp.weight = 1
    ORDER BY random()
    LIMIT 1;

    IF chosen_tech IS NULL THEN
        RAISE EXCEPTION 'no rank 1 attack technique exists to write a starter manual around';
    END IF;

    SELECT mt.bonus_budget INTO budget FROM manual_tiers mt WHERE mt.tier = 1;

    -- Two thirds to hitting things, one third to the breathing practice that
    -- makes hitting them survivable.
    attack   := round(budget * 2 / 3, 4);
    new_name := refined_manual_name(chosen_path, 'offensive', 0::smallint, 1::smallint);

    INSERT INTO manuals
        (name, tier, required_rank, archetype, created_by, description)
    VALUES (new_name, 1, 1, 'offensive', p_player_id,
            'The book a cultivator is handed on their way out the door. '
            'One technique, stated plainly, and enough breathing practice to '
            'make the technique survivable.')
    RETURNING manual_id INTO new_manual;

    PERFORM apply_manual_bonus(new_manual, 'attack_bonus', attack);
    PERFORM apply_manual_bonus(new_manual, 'cultivation_rate_bonus', budget - attack);

    INSERT INTO manual_paths (manual_id, path_code, weight)
    VALUES (new_manual, chosen_path, 1);

    INSERT INTO manual_techniques (manual_id, technique_id)
    VALUES (new_manual, chosen_tech);

    INSERT INTO player_manuals (player_id, manual_id)
    VALUES (p_player_id, new_manual);

    -- Equipped, not merely owned: a book in a bag teaches nobody anything, and
    -- the whole point is that /hunt works the moment the character exists.
    SELECT s.i INTO free_slot
    FROM generate_series(0, 1) AS s (i)
    WHERE NOT EXISTS (
        SELECT 1 FROM player_manual_slots ms
        WHERE ms.player_id = p_player_id AND ms.slot_index = s.i
    )
    ORDER BY s.i
    LIMIT 1;

    IF free_slot IS NOT NULL THEN
        INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
        VALUES (p_player_id, free_slot, new_manual);

        -- HP, defense and strength are a function of (level, traits, manuals),
        -- so equipping recomputes them. Nothing here spends on the body today;
        -- the call is what keeps that from being load-bearing.
        PERFORM apply_physique_xp(p_player_id, 0)
        WHERE EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p_player_id);
    END IF;

    RETURN new_manual;
END;
$$;


-- The books already handed out under the rolled split, brought into line. A
-- starter manual is identified by what it is - Tier 1, made for a player,
-- never refined - rather than by a flag, because that is the same predicate
-- everything else in the game uses to recognise one.

UPDATE manuals m
SET attack_bonus           = round((SELECT bonus_budget FROM manual_tiers WHERE tier = 1) * 2 / 3, 4),
    cultivation_rate_bonus = (SELECT bonus_budget FROM manual_tiers WHERE tier = 1)
                             - round((SELECT bonus_budget FROM manual_tiers WHERE tier = 1) * 2 / 3, 4)
WHERE m.tier = 1
  AND m.created_by IS NOT NULL
  AND m.harmony IS NULL;
