-- 0028_starter_manual
--
-- Every cultivator begins with a book.
--
-- THE PROBLEM. A new character knew no techniques at all, so `pick_technique`
-- returned nothing and /hunt met every creature in the world with "you cannot
-- fight". The first thing the game asked of a player was to go and /learn
-- something before any of it worked, which is a tutorial step disguised as a
-- dead end.
--
-- A manual rather than a learned technique, because manuals are already the
-- thing that teaches moves - handing out a `player_techniques` row instead
-- would make the starter move the one move in the game that came from nowhere,
-- and the equipment page would open empty on a character who demonstrably owns
-- a book.
--
-- IT IS GENERATED, NOT SEEDED. Ten more rank 1 attack techniques ship here so
-- the roll has somewhere to go: before this, the only rank 1 moves that dealt
-- damage were Blood and Fire, and "randomly generated" across two options is
-- not random. Twelve Paths can now arm a beginner, and which Paths those are
-- is DERIVED - any rank 1 attack technique added later becomes a possible
-- starter with no edit to the roller.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- Ten more rank 1 attacks
-- ---------------------------------------------------------------------------
-- One per Path a beginner might plausibly walk, in the same power band as
-- Crimson Palm (120) and Ember Lash (130) so no starter Path is the good one.
-- The spread is in accuracy and qi cost: the heavy Paths hit harder and miss
-- more, which is the same trade the rank 3 moves make.

INSERT INTO techniques
    (code, name, rank, category, base_power, qi_cost_pct, accuracy, cooldown_turns, description)
VALUES
    ('sunken_current_palm', 'Sunken Current Palm', 1, 'attack', 118, 0.0500, 1.0000, 0,
     'The palm does not push. It arrives where the water already was, and the water is not moved either.'),

    ('hoarfrost_needle', 'Hoarfrost Needle', 1, 'attack', 115, 0.0500, 1.0000, 0,
     'A splinter of ice, thrown badly on purpose. It is meant to break off inside.'),

    ('barbed_vine_snap', 'Barbed Vine Snap', 1, 'attack', 122, 0.0500, 0.9500, 0,
     'Any creeper will do. The technique is entirely in how fast you let go of it.'),

    ('crackling_finger', 'Crackling Finger', 1, 'attack', 132, 0.0600, 0.9000, 0,
     'One finger, one charge, no aiming worth the name. Beginners are told to point away from themselves.'),

    ('falling_gravel_fist', 'Falling Gravel Fist', 1, 'attack', 128, 0.0600, 0.9500, 0,
     'Not a boulder. A hillside''s worth of small stones, all arriving in the order they were loosened.'),

    ('iron_filings_volley', 'Iron Filings Volley', 1, 'attack', 125, 0.0600, 0.9500, 0,
     'A handful of swarf off a smith''s floor, given a direction. Cheap, and the wounds are filthy.'),

    ('first_form_draw', 'First Form: The Draw', 1, 'attack', 130, 0.0600, 0.9500, 0,
     'The first form of every sword school, and the only one most students ever need. The cut is the drawing of it.'),

    ('ox_shoulder', 'Ox Shoulder', 1, 'attack', 135, 0.0700, 0.9000, 0,
     'No Path in it at all, some would say. Those people have not been hit with it.'),

    ('blister_touch', 'Blister Touch', 1, 'attack', 112, 0.0500, 1.0000, 0,
     'Barely a strike. The blister comes up an hour later, and by then you are elsewhere.'),

    ('cutting_gale', 'Cutting Gale', 1, 'attack', 126, 0.0500, 0.9500, 0,
     'Wind sharpened to an edge it does not naturally hold, for about as long as you would expect.');

INSERT INTO technique_paths (technique_id, path_code)
SELECT t.technique_id, v.path_code
FROM (VALUES
    ('sunken_current_palm', 'water'),
    ('hoarfrost_needle',    'ice'),
    ('barbed_vine_snap',    'wood'),
    ('crackling_finger',    'lightning'),
    ('falling_gravel_fist', 'earth'),
    ('iron_filings_volley', 'metal'),
    ('first_form_draw',     'sword'),
    ('ox_shoulder',         'strength'),
    ('blister_touch',       'poison'),
    ('cutting_gale',        'wind')
) AS v (technique_code, path_code)
JOIN techniques t ON t.code = v.technique_code;


-- ---------------------------------------------------------------------------
-- A manual may have a maker without having been refined
-- ---------------------------------------------------------------------------
-- 0021's constraint tied created_by, refined_at and harmony together in one
-- knot: a manual either belonged to nobody and was never refined, or all
-- three were set. A starter manual is the case that knot has no room for - it
-- is made FOR one player, and it was not refined by them.
--
-- Leaving created_by NULL would have been the easy read, and wrong twice: the
-- row would outlive the player it was minted for, and roll_manual_drop treats
-- "created_by IS NULL" as "seeded content anyone may find" - so one player's
-- starter book would have started turning up on corpses for everybody else.
--
-- The rule that actually matters is kept: a manual that CLAIMS a refinement
-- must have a refiner and a time. What is dropped is the pretence that having
-- a maker means having been refined.

ALTER TABLE manuals DROP CONSTRAINT manuals_refinement_is_whole;

ALTER TABLE manuals ADD CONSTRAINT manuals_refinement_is_whole CHECK (
    (harmony IS NULL AND refined_at IS NULL)
    OR
    (harmony IS NOT NULL AND refined_at IS NOT NULL AND created_by IS NOT NULL)
);

COMMENT ON COLUMN manuals.created_by IS
    'The player this manual was made for. NULL means seeded content shared by everyone; set with a NULL harmony means made for them but not refined.';


-- ---------------------------------------------------------------------------
-- grant_starter_manual
-- ---------------------------------------------------------------------------
-- The book a character is handed at the moment they commit to a body.
--
-- Idempotent by ownership rather than by a flag column: a player who owns any
-- manual at all is not a beginner, so this can be called from a trigger, a
-- backfill and a test without any of them having to check first.
--
-- The whole Tier 1 budget goes to attack and cultivation. That is a design
-- choice, not an omission - the point of the book is that you can hurt
-- something with it, and a beginner's manual has no business tempering anyone's
-- body. It also means the split is the only randomness that touches a number:
-- the Path, the technique and the name are where a starter varies.

CREATE FUNCTION grant_starter_manual(p_player_id BIGINT)
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

    attack   := round(budget * (0.50 + random() * 0.25)::numeric, 4);
    new_name := refined_manual_name(chosen_path, 'offensive', 0::smallint, 1::smallint);

    INSERT INTO manuals
        (name, tier, required_rank, archetype, created_by, description)
    VALUES (new_name, 1, 1, 'offensive', p_player_id,
            'The book a cultivator is handed on their way out the door. '
            'One technique, stated plainly, and enough breathing practice to '
            'make the technique survivable.')
    RETURNING manual_id INTO new_manual;

    -- Through page_types' column mapping, exactly as refinement does, so a
    -- starter manual is spent the same way everything else is.
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

COMMENT ON FUNCTION grant_starter_manual(BIGINT) IS
    'The Tier 1 manual every character begins with, rolled and equipped. Returns NULL for a player who already owns one, so it is safe to call twice.';


-- ---------------------------------------------------------------------------
-- Handed over at the moment of commitment
-- ---------------------------------------------------------------------------
-- A trigger rather than a line in the bot's confirm handler, because "every
-- confirmed character owns a manual" is a rule about the data and there are
-- three ways in already: the setup screen, /dev reset, and the tests. A rule
-- enforced at one of the three doors is a rule that holds until somebody uses
-- a different door.
--
-- Not at registration: a character with no confirmed_at has not committed to a
-- body yet, and rerolling a Root should not accumulate books.

CREATE FUNCTION grant_starter_manual_on_confirm()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM grant_starter_manual(NEW.player_id);
    RETURN NULL;
END;
$$;

CREATE TRIGGER player_character_grants_a_starter_manual
    AFTER UPDATE OF confirmed_at ON player_character
    FOR EACH ROW
    WHEN (OLD.confirmed_at IS NULL AND NEW.confirmed_at IS NOT NULL)
    EXECUTE FUNCTION grant_starter_manual_on_confirm();


-- ---------------------------------------------------------------------------
-- Everyone who was already here
-- ---------------------------------------------------------------------------
-- The rule is "every cultivator begins with a book", and a character created
-- yesterday is no less a cultivator. The ownership guard inside the function
-- means anyone who has already found one keeps what they have.

DO $$
DECLARE
    target BIGINT;
BEGIN
    FOR target IN
        SELECT pc.player_id
        FROM player_character pc
        JOIN players p ON p.player_id = pc.player_id
        WHERE pc.confirmed_at IS NOT NULL
          AND p.deleted_at IS NULL
        ORDER BY pc.player_id
    LOOP
        PERFORM grant_starter_manual(target);
    END LOOP;
END;
$$;
