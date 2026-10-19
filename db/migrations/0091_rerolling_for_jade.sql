-- 0091_rerolling_for_jade
--
-- Buying more chances at the two traits you did not choose.
--
-- THREE JADE A ROLL, and the number is derived rather than picked. The roll
-- table is `rarities.roll_weight`, so the expected number of rolls to reach a
-- band or better is arithmetic, and multiplying it by the price gives what
-- each band actually costs:
--
--     rare or better        4 rolls      12 Jade
--     epic or better        8 rolls      24 Jade
--     legendary or better  18 rolls      54 Jade
--     mythic or better     50 rolls     150 Jade
--     divine or better    168 rolls     504 Jade
--     unique             1005 rolls   3,015 Jade
--
-- The economy document sets out its own ladder - 5 Jade a minor expense, 50
-- meaningful, 500 major, 5,000 a fortune - and at three a roll the bands land
-- on it almost exactly. That is the whole justification for the number; if the
-- faucets move, this moves with them.
--
-- A RACE IS CHOSEN, NOT ROLLED. 0011 was explicit: a race "is the one trait
-- the player states about their character rather than receives", and it has no
-- rarity at all. So there is nothing to reroll - changing it is a flat fee for
-- a service, which is precisely the kind of sink the economy document asks
-- for, and it is priced as one.
--
-- THE LAST ROLL IS THE ONE YOU KEEP. This is what stops it being a shop. A
-- batch stops the instant it meets the target, but a batch that runs out of
-- rolls or Jade first leaves you holding whatever came up last - which may be
-- worse than what you started with. Buying a Divine root outright would be the
-- "guaranteed best-in-slot purchase" the document forbids; buying a hundred
-- chances at one is a gamble, and the difference is the risk.
--
-- WHY THIS IS THE RIGHT SINK ANYWAY. It has unbounded demand and no guaranteed
-- outcome, which is exactly what a reserve currency needs pulling against it.
-- Protection is optional and small; without something a wealthy player
-- genuinely wants, Jade accumulates and every price on the auction house
-- drifts upward.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('reroll_jade_cost', 3,
     'Spirit Jade per reroll of a root or a physique. Derived from the roll table: at three, a legendary costs about 54 and a divine about 504.'),
    ('reroll_max_batch', 100,
     'Most rolls one press may make. A batch stops early on the target or on an empty purse.'),
    ('race_change_jade_cost', 25,
     'Spirit Jade to change race. A flat fee rather than a roll, because a race is chosen.');


-- ---------------------------------------------------------------------------
-- What the odds actually are
-- ---------------------------------------------------------------------------
-- Published rather than hidden. A player about to spend three Jade a pull is
-- entitled to the same numbers the roll uses, and they come from the same
-- weights rather than from a second table somebody has to remember to update.

CREATE VIEW reroll_odds AS
WITH pools AS (
    SELECT 'root' AS trait, r.rarity, ra.roll_weight, ra.sort_order
    FROM roots r
    JOIN rarities ra ON ra.code = r.rarity
    WHERE ra.roll_weight > 0
      AND NOT EXISTS (SELECT 1 FROM roots e WHERE e.evolves_into = r.code)
    GROUP BY r.rarity, ra.roll_weight, ra.sort_order

    UNION ALL

    SELECT 'physique', p.tier, ra.roll_weight, ra.sort_order
    FROM physiques p
    JOIN rarities ra ON ra.code = p.tier
    WHERE p.rollable AND ra.roll_weight > 0
    GROUP BY p.tier, ra.roll_weight, ra.sort_order
),
totals AS (
    SELECT trait, sum(roll_weight) AS whole FROM pools GROUP BY trait
)
SELECT
    p.trait,
    p.rarity,
    p.sort_order,
    round(p.roll_weight / t.whole, 6) AS chance,
    round((SELECT sum(q.roll_weight) FROM pools q
           WHERE q.trait = p.trait AND q.sort_order >= p.sort_order) / t.whole, 6)
        AS or_better,
    ceil(t.whole / (SELECT sum(q.roll_weight) FROM pools q
                    WHERE q.trait = p.trait AND q.sort_order >= p.sort_order))::integer
        AS expected_rolls
FROM pools p JOIN totals t ON t.trait = p.trait;

COMMENT ON VIEW reroll_odds IS
    'The real chance of each band and the expected rolls to reach it, off the same weights the roll uses. What a reroll screen is obliged to show.';


-- ---------------------------------------------------------------------------
-- reroll_root
-- ---------------------------------------------------------------------------

CREATE FUNCTION reroll_root(
    p_player_id BIGINT,
    p_target    TEXT,
    p_rolls     INTEGER
)
RETURNS TABLE (
    rolls_made  INTEGER,
    spent       BIGINT,
    root_code   TEXT,
    root_name   TEXT,
    rarity      TEXT,
    hit_target  BOOLEAN,
    jade_left   BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cost   BIGINT := game_config_value('reroll_jade_cost');
    most   INTEGER := LEAST(GREATEST(1, p_rolls),
                            game_config_value('reroll_max_batch')::integer);
    want   SMALLINT;
    got    TEXT;
    band   SMALLINT;
    made   INTEGER := 0;
    paid   BIGINT := 0;
BEGIN
    SELECT ra.sort_order INTO want FROM rarities ra WHERE ra.code = p_target;
    IF want IS NULL THEN
        RAISE EXCEPTION 'there is no % band', p_target USING ERRCODE = 'check_violation';
    END IF;

    LOOP
        EXIT WHEN made >= most;
        -- Stop rather than fail: a batch that runs dry has done what it could.
        EXIT WHEN jade_held(p_player_id) < cost;

        PERFORM spend_jade(p_player_id, cost, 'reroll_root');
        paid := paid + cost;
        made := made + 1;

        got := roll_root();
        UPDATE player_character SET root_code = got, root_rolls = root_rolls + 1
        WHERE player_id = p_player_id;

        SELECT ra.sort_order INTO band
        FROM roots r JOIN rarities ra ON ra.code = r.rarity WHERE r.code = got;

        EXIT WHEN band >= want;
    END LOOP;

    RETURN QUERY
    SELECT made, paid, r.code, r.name, r.rarity, band >= want, jade_held(p_player_id)
    FROM roots r
    JOIN player_character pc ON pc.root_code = r.code
    WHERE pc.player_id = p_player_id;
END;
$$;

COMMENT ON FUNCTION reroll_root(BIGINT, TEXT, INTEGER) IS
    'Rolls until the target band, the batch, or the purse runs out - whichever comes first. Whatever came up last is what you keep.';


-- ---------------------------------------------------------------------------
-- reroll_physique
-- ---------------------------------------------------------------------------

CREATE FUNCTION reroll_physique(
    p_player_id BIGINT,
    p_target    TEXT,
    p_rolls     INTEGER
)
RETURNS TABLE (
    rolls_made   INTEGER,
    spent        BIGINT,
    physique_id  SMALLINT,
    physique_name TEXT,
    rarity       TEXT,
    hit_target   BOOLEAN,
    jade_left    BIGINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cost   BIGINT := game_config_value('reroll_jade_cost');
    most   INTEGER := LEAST(GREATEST(1, p_rolls),
                            game_config_value('reroll_max_batch')::integer);
    want   SMALLINT;
    got    SMALLINT;
    band   SMALLINT;
    made   INTEGER := 0;
    paid   BIGINT := 0;
BEGIN
    SELECT ra.sort_order INTO want FROM rarities ra WHERE ra.code = p_target;
    IF want IS NULL THEN
        RAISE EXCEPTION 'there is no % band', p_target USING ERRCODE = 'check_violation';
    END IF;

    LOOP
        EXIT WHEN made >= most;
        EXIT WHEN jade_held(p_player_id) < cost;

        PERFORM spend_jade(p_player_id, cost, 'reroll_physique');
        paid := paid + cost;
        made := made + 1;

        got := roll_physique();
        UPDATE player_physique SET physique_id = got WHERE player_id = p_player_id;
        UPDATE player_character SET physique_rolls = physique_rolls + 1
        WHERE player_id = p_player_id;

        SELECT ra.sort_order INTO band
        FROM physiques p JOIN rarities ra ON ra.code = p.tier
        WHERE p.physique_id = got;

        EXIT WHEN band >= want;
    END LOOP;

    -- A body is stats, and the stored ones are now a different body's.
    IF made > 0 THEN
        PERFORM apply_physique_xp(p_player_id, 0);
    END IF;

    RETURN QUERY
    SELECT made, paid, p.physique_id, p.name, p.tier, band >= want,
           jade_held(p_player_id)
    FROM physiques p
    JOIN player_physique pp ON pp.physique_id = p.physique_id
    WHERE pp.player_id = p_player_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- change_race
-- ---------------------------------------------------------------------------
-- Not a roll. A flat fee for a service, which is what the economy document
-- most wants Jade spent on.

CREATE FUNCTION change_race(p_player_id BIGINT, p_race TEXT)
RETURNS TABLE (race_code TEXT, race_name TEXT, spent BIGINT, jade_left BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    cost BIGINT := game_config_value('race_change_jade_cost');
    was  TEXT;
BEGIN
    SELECT pc.race_code INTO was FROM player_character pc WHERE pc.player_id = p_player_id;
    IF was IS NULL THEN
        RAISE EXCEPTION 'you have no character yet' USING ERRCODE = 'check_violation';
    END IF;
    IF was = p_race THEN
        RAISE EXCEPTION 'you are already that' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM races WHERE code = p_race) THEN
        RAISE EXCEPTION 'there is no such race' USING ERRCODE = 'check_violation';
    END IF;

    PERFORM spend_jade(p_player_id, cost, 'change_race');

    UPDATE player_character SET race_code = p_race WHERE player_id = p_player_id;

    -- Race carries HP and defence fractions, so the body is re-derived.
    PERFORM apply_physique_xp(p_player_id, 0);

    RETURN QUERY
    SELECT r.code, r.name, cost, jade_held(p_player_id)
    FROM races r WHERE r.code = p_race;
END;
$$;
