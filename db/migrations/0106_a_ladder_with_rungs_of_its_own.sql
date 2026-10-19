-- 0106_a_ladder_with_rungs_of_its_own
--
-- Professions take longer to finish, and nobody loses what they already have.
--
-- THE PROBLEM. Every profession ladder was `base + floor(level / N)`: evenly
-- spaced rungs, so the last one arrives as quickly as the first. A Miner is
-- finished at level 24 and a Forager at 16, which is a few hundred swings -
-- and two players are at mining 103 and foraging 92, hundreds of levels past
-- anything that changes. The number goes up and buys nothing.
--
-- WHY NOT JUST RAISE `levels_per`. Because an even ladder can only be
-- stretched from the bottom. Doubling `mining_levels_per_tier` moves the cap
-- from 24 to 48 and simultaneously demotes the Miner at level 13 from tier 4
-- to tier 2 - it takes depth away from somebody who earned it, to slow down
-- somebody who has not started. The two effects cannot be separated while the
-- spacing is a single number.
--
-- SO THE RUNGS BECOME ROWS. `profession_steps` holds the level each rung
-- wants, and a ladder may space its rungs however it likes. That buys the
-- thing an even ladder cannot: rungs that ACCELERATE. The early ones stay
-- exactly where they were, so no current cultivator moves; the later ones
-- spread out, so the climb from useful to finished is two to three times what
-- it was.
--
-- Mining, rung by rung: 4, 8, 13, 26, 44, 66 - where it used to be every 4.
-- A Miner at 13 still works tier 4 veins this morning, and tier 7 is now 66
-- levels away instead of 24.
--
-- EXPLORING IS DELIBERATELY UNTOUCHED. Its benefit is linear rather than
-- stepped - fortune is `level * 0.02` - so there are no rungs to respace and
-- any slowing demotes every Explorer below the cap at once. It is also the
-- one ladder that was already long, at 38.
--
-- CHECKED AGAINST THE LIVE SHELF. Every rung below is placed so that all six
-- cultivators keep precisely what they hold now; the test that asserts it is
-- in test_schema.py and reads the players, not a fixture.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE profession_steps (
    ladder         TEXT     NOT NULL,
    step           SMALLINT NOT NULL CHECK (step >= 1),
    level_required SMALLINT NOT NULL CHECK (level_required >= 1),
    PRIMARY KEY (ladder, step)
);

COMMENT ON TABLE profession_steps IS
    'One row per rung of a profession ladder. Spacing is data, so a ladder can accelerate - which is the only way to lengthen a climb without shortening somebody else''s.';

-- A rung must not sit below the one before it: an out-of-order ladder would
-- still "work" (the functions count rows) while reading as nonsense.
CREATE FUNCTION profession_steps_ascend() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM profession_steps a
        JOIN profession_steps b ON b.ladder = a.ladder AND b.step = a.step + 1
        WHERE a.ladder = NEW.ladder AND b.level_required < a.level_required
    ) THEN
        RAISE EXCEPTION 'ladder % has a rung below the one before it', NEW.ladder
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER profession_steps_are_in_order
    AFTER INSERT OR UPDATE ON profession_steps
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION profession_steps_ascend();


INSERT INTO profession_steps (ladder, step, level_required) VALUES
    -- Miner: tier 2..7. Was every 4, finishing at 24.
    ('mining_tier',      1,  4),
    ('mining_tier',      2,  8),
    ('mining_tier',      3, 13),
    ('mining_tier',      4, 26),
    ('mining_tier',      5, 44),
    ('mining_tier',      6, 66),

    -- Forager: 2 and 3 draws. Was every 8, finishing at 16.
    ('forage_draws',     1, 12),
    ('forage_draws',     2, 32),

    -- Alchemist: 3..6 herbs. Was every 5, finishing at 20.
    ('alchemy_herbs',    1,  5),
    ('alchemy_herbs',    2, 12),
    ('alchemy_herbs',    3, 26),
    ('alchemy_herbs',    4, 44),

    -- Blacksmith depth: tier 3..7. Was every 4, finishing at 20.
    ('forge_tier',       1,  6),
    ('forge_tier',       2, 14),
    ('forge_tier',       3, 26),
    ('forge_tier',       4, 42),
    ('forge_tier',       5, 60),

    -- Blacksmith anvil: 2..4 beast materials. Was every 4, finishing at 12.
    ('forge_parts',      1,  5),
    ('forge_parts',      2, 15),
    ('forge_parts',      3, 30),

    -- Gu Refiner bench: 3..8 auxiliaries. Was every 4, finishing at 24.
    ('gu_refine_aux',    1,  5),
    ('gu_refine_aux',    2, 12),
    ('gu_refine_aux',    3, 22),
    ('gu_refine_aux',    4, 34),
    ('gu_refine_aux',    5, 48),
    ('gu_refine_aux',    6, 64),

    -- Refinement: 4..8 pages. Was every 10, finishing at 50.
    ('refinement_pages', 1, 12),
    ('refinement_pages', 2, 26),
    ('refinement_pages', 3, 42),
    ('refinement_pages', 4, 60),
    ('refinement_pages', 5, 80);


-- ---------------------------------------------------------------------------
-- Reading a ladder
-- ---------------------------------------------------------------------------

CREATE FUNCTION ladder_steps(p_ladder TEXT, p_level SMALLINT)
RETURNS INTEGER
LANGUAGE sql STABLE
AS $$
    SELECT count(*)::integer FROM profession_steps s
    WHERE s.ladder = p_ladder AND s.level_required <= p_level;
$$;

COMMENT ON FUNCTION ladder_steps(TEXT, SMALLINT) IS
    'How many rungs of this ladder a level has passed. The whole of what replaced floor(level / N).';

CREATE FUNCTION ladder_next_at(p_ladder TEXT, p_level SMALLINT)
RETURNS SMALLINT
LANGUAGE sql STABLE
AS $$
    SELECT min(s.level_required) FROM profession_steps s
    WHERE s.ladder = p_ladder AND s.level_required > p_level;
$$;

COMMENT ON FUNCTION ladder_next_at(TEXT, SMALLINT) IS
    'The level of the next rung, or NULL at the top - which is how a screen can finally say "this is as far as it goes".';


-- ---------------------------------------------------------------------------
-- The six ladders, rewired
-- ---------------------------------------------------------------------------
-- Same signatures, same caps, same bases. Only the spacing moved.

CREATE OR REPLACE FUNCTION mining_tier_cap(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(7, game_config_value('mining_base_tier')
                    + ladder_steps('mining_tier', p_level))::smallint;
$$;

-- INTEGER, not SMALLINT: that is what 0082 declared and CREATE OR REPLACE
-- cannot change a return type. The value is a small count either way.
CREATE OR REPLACE FUNCTION forage_draws(p_level SMALLINT)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT GREATEST(1, LEAST(
        game_config_value('forage_max_draws'),
        game_config_value('forage_base_draws')
        + ladder_steps('forage_draws', p_level)))::integer;
$$;

CREATE OR REPLACE FUNCTION alchemy_herb_slots(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(
        game_config_value('alchemy_max_herbs'),
        game_config_value('alchemy_base_herbs')
        + ladder_steps('alchemy_herbs', p_level))::smallint;
$$;

CREATE OR REPLACE FUNCTION smith_tier_cap(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(7, game_config_value('forge_base_tier')
                    + ladder_steps('forge_tier', p_level))::smallint;
$$;

CREATE OR REPLACE FUNCTION smith_part_slots(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(
        game_config_value('forge_max_parts'),
        game_config_value('forge_base_parts')
        + ladder_steps('forge_parts', p_level))::smallint;
$$;

CREATE OR REPLACE FUNCTION gu_refine_aux_slots(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(
        8, game_config_value('gu_refine_aux_base')
           + ladder_steps('gu_refine_aux', p_level))::smallint;
$$;

CREATE OR REPLACE FUNCTION refinement_max_pages(p_level SMALLINT)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    SELECT LEAST(
        game_config_value('refinement_max_pages'),
        game_config_value('refinement_base_pages')
        + ladder_steps('refinement_pages', p_level))::smallint;
$$;


-- ---------------------------------------------------------------------------
-- The dials that no longer turn anything
-- ---------------------------------------------------------------------------
-- A config key nothing reads is a lie with a number on it: somebody will
-- change `mining_levels_per_tier` one day and wonder why nothing moved.

DELETE FROM game_config WHERE key IN (
    'mining_levels_per_tier',
    'forage_levels_per_draw',
    'alchemy_herbs_per_levels',
    'forge_tier_per_levels',
    'forge_parts_per_levels',
    'gu_refine_aux_per_levels',
    'refinement_pages_per_levels'
);
