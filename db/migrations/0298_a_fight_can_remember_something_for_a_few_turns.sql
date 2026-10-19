-- 0298_a_fight_can_remember_something_for_a_few_turns
--
-- Every technique in this game is a name, a Path and a number. `base_power`
-- and the Path matchup are the only things `compute_technique_damage` reads
-- off one; `effects` is `{}` on all 205 and consulted by nothing, and so are
-- `cooldown_turns` and `accuracy`. 203 of the 205 are category 'attack' and
-- the category never branches combat anyway. There is no buff, no debuff, no
-- duration and no taunt, because there is nowhere to put one.
--
-- This is the nowhere. Nothing changes about combat yet - no lane reads this
-- table when the migration lands. It is the table and the four verbs, proved
-- on their own, so that the migration which does change the five combat lanes
-- is only about the lanes.
--
-- SCOPE, BECAUSE THERE ARE FIVE FIGHTS. A cultivator can be in a duel, a
-- dungeon and a tide at once, and a guard raised in one is not a guard raised
-- in another. Every lane already keys its people by exactly one id and the
-- player, so that pair is the address: ('dungeon', run_id, player_id).
--
-- MAGNITUDES ARE FRACTIONS, AND THEY ARE CAPPED PER KIND. `battle_effect_kinds`
-- carries the ceiling, and `effect_value` clamps the sum on the way out, so a
-- room stacking six guards cannot arrive at immunity. That ceiling lives with
-- the kind rather than at the call site for the same reason `gu_effects.cap`
-- does: one place to read it, one place to change it.
--
-- TURNS ARE SPENT BY THE LANE, NOT BY THE CLOCK. `effect_tick` is called once
-- per round by whatever is running the round. A fight nobody is taking turns
-- in does not quietly run its buffs out, and a fight that ends drops them all
-- with `effect_clear`.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE battle_effect_kinds (
    code        TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    cap         NUMERIC NOT NULL,
    description TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE battle_effect_kinds IS
    'The lasting things a technique can put on somebody, and the most each is allowed to be worth however it is stacked.';

INSERT INTO battle_effect_kinds (code, name, cap, description) VALUES
    ('attack_up', 'Rallied', 1.00,
     'Added to the damage multiplier on every blow you land while it lasts. '
     'The one effect worth spending a turn on in a room, because it is the '
     'only one that multiplies somebody else''s swing as readily as your own.'),
    ('defence_up', 'Warded', 0.60,
     'Added to Damage Reduction while it lasts. Stacks onto the same pile a '
     'cultivator''s own gear feeds, and the existing damage_reduction_ceiling '
     'still clamps that pile afterwards - so this is capped twice, on purpose.'),
    ('block_up', 'Set', 0.50,
     'Added to what a Guard turns aside, and only while guarding. A technique '
     'that rewards the turn you were going to spend defending anyway.'),
    ('taunt', 'Marked', 1.00,
     'How strongly a creature choosing whom to maul is pulled toward you. '
     'Only means anything where something CHOOSES - a dungeon room picking a '
     'raider. In a duel there is one of you and the choice is already made.'),
    ('regen', 'Mending', 0.25,
     'A fraction of your maximum health returned at the end of each round it '
     'lasts. Spread over turns rather than given at once, so a heal is a '
     'commitment to a long fight rather than an undo button.');


CREATE TABLE battle_effects (
    effect_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope        TEXT   NOT NULL,
    scope_id     BIGINT NOT NULL,
    player_id    BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    effect_code  TEXT   NOT NULL REFERENCES battle_effect_kinds(code) ON DELETE RESTRICT,
    magnitude    NUMERIC NOT NULL,
    turns_left   SMALLINT NOT NULL,
    from_technique BIGINT REFERENCES techniques(technique_id) ON DELETE SET NULL,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT battle_effects_scope_check
        CHECK (scope IN ('battle', 'dungeon', 'boss', 'horde', 'gauntlet')),
    CONSTRAINT battle_effects_magnitude_check CHECK (magnitude > 0),
    CONSTRAINT battle_effects_turns_check     CHECK (turns_left > 0)
);

COMMENT ON TABLE battle_effects IS
    'What is currently true of somebody in one particular fight, and for how many more rounds.';

CREATE INDEX battle_effects_live_idx
    ON battle_effects (scope, scope_id, player_id, effect_code);


-- ---------------------------------------------------------------------------
-- Four verbs
-- ---------------------------------------------------------------------------

CREATE FUNCTION effect_apply(
    p_scope TEXT, p_scope_id BIGINT, p_player_id BIGINT,
    p_code TEXT, p_magnitude NUMERIC, p_turns INTEGER,
    p_technique_id BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    made BIGINT;
BEGIN
    IF COALESCE(p_magnitude, 0) <= 0 OR COALESCE(p_turns, 0) <= 0 THEN
        RETURN NULL;
    END IF;

    -- Re-applying refreshes rather than stacks with itself. Two castings of
    -- the same guard by the same person is one guard that lasts longer, which
    -- is the reading that does not turn a cooldown-free technique into
    -- arbitrary numbers.
    UPDATE battle_effects
    SET magnitude  = GREATEST(magnitude, p_magnitude),
        turns_left = GREATEST(turns_left, p_turns)::smallint,
        applied_at = now()
    WHERE scope = p_scope AND scope_id = p_scope_id
      AND player_id = p_player_id AND effect_code = p_code
      AND from_technique IS NOT DISTINCT FROM p_technique_id
    RETURNING effect_id INTO made;

    IF made IS NOT NULL THEN
        RETURN made;
    END IF;

    INSERT INTO battle_effects
        (scope, scope_id, player_id, effect_code, magnitude, turns_left,
         from_technique)
    VALUES (p_scope, p_scope_id, p_player_id, p_code, p_magnitude,
            p_turns::smallint, p_technique_id)
    RETURNING effect_id INTO made;

    RETURN made;
END;
$$;

COMMENT ON FUNCTION effect_apply(TEXT, BIGINT, BIGINT, TEXT, NUMERIC, INTEGER, BIGINT) IS
    'Puts a lasting effect on somebody in one fight. The same technique cast again refreshes it rather than stacking with itself.';


CREATE FUNCTION effect_value(
    p_scope TEXT, p_scope_id BIGINT, p_player_id BIGINT, p_code TEXT
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
AS $$
    -- Different sources stack, and the kind's own ceiling clamps the total.
    SELECT LEAST(
        (SELECT k.cap FROM battle_effect_kinds k WHERE k.code = p_code),
        COALESCE((SELECT sum(e.magnitude) FROM battle_effects e
                  WHERE e.scope = p_scope AND e.scope_id = p_scope_id
                    AND e.player_id = p_player_id AND e.effect_code = p_code
                    AND e.turns_left > 0), 0)
    );
$$;

COMMENT ON FUNCTION effect_value(TEXT, BIGINT, BIGINT, TEXT) IS
    'What one effect is currently worth to somebody in one fight, capped by its kind.';


CREATE FUNCTION effect_tick(p_scope TEXT, p_scope_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER;
BEGIN
    -- What is on its last round goes FIRST, then the rest are spent. The
    -- other order decrements a row to zero and the table's own CHECK refuses
    -- it mid-statement - and rightly: a row in here is something with turns
    -- left, so zero is not a state it should ever be able to hold.
    DELETE FROM battle_effects
    WHERE scope = p_scope AND scope_id = p_scope_id AND turns_left <= 1;
    GET DIAGNOSTICS gone = ROW_COUNT;

    UPDATE battle_effects
    SET turns_left = turns_left - 1
    WHERE scope = p_scope AND scope_id = p_scope_id;

    RETURN gone;
END;
$$;

COMMENT ON FUNCTION effect_tick(TEXT, BIGINT) IS
    'Spends one round off everything in a fight and clears what ran out. Called by whatever is running the round.';


CREATE FUNCTION effect_clear(p_scope TEXT, p_scope_id BIGINT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER;
BEGIN
    DELETE FROM battle_effects
    WHERE scope = p_scope AND scope_id = p_scope_id;
    GET DIAGNOSTICS gone = ROW_COUNT;
    RETURN gone;
END;
$$;

COMMENT ON FUNCTION effect_clear(TEXT, BIGINT) IS
    'Drops everything a finished fight was carrying.';


-- ---------------------------------------------------------------------------
-- Nothing reads it yet, which is the point of landing it on its own
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    reader TEXT;
BEGIN
    SELECT string_agg(proname, ' ') INTO reader
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND prosrc LIKE '%battle_effects%'
      AND proname NOT IN ('effect_apply', 'effect_value', 'effect_tick',
                          'effect_clear');

    IF reader IS NOT NULL THEN
        RAISE EXCEPTION
            'something already reads the effects table and should not yet: %',
            reader;
    END IF;
END;
$$;


-- ---------------------------------------------------------------------------
-- The four verbs do what they say
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    who   BIGINT;
    cap   NUMERIC;
    left1 INTEGER;
BEGIN
    SELECT player_id INTO who FROM players
    WHERE deleted_at IS NULL AND discord_id > 0 LIMIT 1;

    IF who IS NULL THEN
        RAISE NOTICE 'no cultivator to test on; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- Applying, and reading it back.
        PERFORM effect_apply('battle', -1, who, 'defence_up', 0.20, 3);
        IF effect_value('battle', -1, who, 'defence_up') <> 0.20 THEN
            RAISE EXCEPTION 'an effect that was applied is not worth anything';
        END IF;

        -- A different fight is a different fight.
        IF effect_value('dungeon', -1, who, 'defence_up') <> 0 THEN
            RAISE EXCEPTION 'an effect leaked between two fights';
        END IF;

        -- The same technique again refreshes rather than stacks.
        PERFORM effect_apply('battle', -1, who, 'defence_up', 0.20, 3);
        IF effect_value('battle', -1, who, 'defence_up') <> 0.20 THEN
            RAISE EXCEPTION 'the same guard cast twice stacked with itself';
        END IF;

        -- Different sources do stack, and the cap holds them.
        PERFORM effect_apply('battle', -1, who, 'defence_up', 0.50, 3,
                             (SELECT technique_id FROM techniques LIMIT 1));
        SELECT k.cap INTO cap FROM battle_effect_kinds k WHERE k.code = 'defence_up';
        IF effect_value('battle', -1, who, 'defence_up') <> cap THEN
            RAISE EXCEPTION
                'two sources summed to % against a cap of %',
                effect_value('battle', -1, who, 'defence_up'), cap;
        END IF;

        -- Turns are spent, and what runs out goes.
        PERFORM effect_tick('battle', -1);
        PERFORM effect_tick('battle', -1);
        SELECT min(turns_left) INTO left1 FROM battle_effects
        WHERE scope = 'battle' AND scope_id = -1;
        IF left1 <> 1 THEN
            RAISE EXCEPTION 'three turns less two is %, not 1', left1;
        END IF;

        PERFORM effect_tick('battle', -1);
        IF effect_value('battle', -1, who, 'defence_up') <> 0 THEN
            RAISE EXCEPTION 'an effect outlasted its turns';
        END IF;

        -- And a finished fight drops what is left.
        PERFORM effect_apply('battle', -1, who, 'attack_up', 0.30, 5);
        IF effect_clear('battle', -1) < 1 THEN
            RAISE EXCEPTION 'clearing a fight cleared nothing';
        END IF;
        IF EXISTS (SELECT 1 FROM battle_effects
                   WHERE scope = 'battle' AND scope_id = -1) THEN
            RAISE EXCEPTION 'a cleared fight is still carrying something';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$$;
