-- 0092_a_roll_you_can_refuse
--
-- Nothing changes until you say so, and that is worth paying for.
--
-- 0091 replaced the trait on every roll, so a batch that ran out of Jade left
-- you holding whatever came up last - possibly worse than you started. That
-- was the risk, and the risk was the argument for this not being a shop.
--
-- Offering the choice removes the risk entirely: a roll can now only ever
-- improve you or be refused. So the price rises with it, from three to five.
--
-- WHAT THE PRICE CHANGE IS AND IS NOT. The expected number of rolls to SEE a
-- band is unchanged - it is 1/P and no decision affects it - so raising the
-- price does not make a Divine root rarer. What changed is that every roll is
-- now strictly non-negative, and a roll with no downside is simply worth more
-- than one that can cost you an Epic root. At five:
--
--     rare or better        4 rolls      20 Jade
--     epic or better        9 rolls      45 Jade
--     legendary or better  19 rolls      95 Jade
--     mythic or better     51 rolls     255 Jade
--     divine or better    168 rolls     840 Jade
--     unique             1005 rolls   5,025 Jade
--
-- which still sits on the economy document's own ladder - meaningful, major,
-- a fortune - with Unique landing almost exactly on its 5,000.
--
-- THE OFFER IS A ROW, NOT VIEW STATE. Somebody who has spent eight hundred
-- Jade and is looking at a Divine root must not lose it to a bot restart or a
-- timed-out message. This is the same reasoning `player_action_tries` was
-- given in 0081, and the stakes here are higher.
--
-- ROLLING AGAIN CANNOT LOSE THE OFFER. A batch compares every roll against
-- what is already pending and keeps the best of all of it, so pressing Roll
-- with a Divine offer standing can only improve it. The alternative - refusing
-- to roll until you decide - is a trap the first time somebody presses it out
-- of habit.
--
-- AND THE BATCH KEEPS THE BEST, NOT THE LAST. Rolling a hundred times, hitting
-- Legendary on the fortieth and being offered the hundredth would be absurd.
--
-- Forward-only. Do not edit once applied.


UPDATE game_config SET value = 5,
    description = 'Spirit Jade per roll. Five rather than three because 0092 made a roll refusable: the odds are unchanged, but a roll with no downside is worth more than one that can cost you the root you had.'
WHERE key = 'reroll_jade_cost';


-- ---------------------------------------------------------------------------
-- player_reroll_offers
-- ---------------------------------------------------------------------------
-- One standing offer per trait. Sparse rows keyed by trait, like the cooldowns
-- and the action tries beside them.

CREATE TABLE player_reroll_offers (
    player_id   BIGINT NOT NULL REFERENCES players (player_id) ON DELETE CASCADE,
    trait       TEXT   NOT NULL CHECK (trait IN ('root', 'physique')),

    root_code   TEXT     REFERENCES roots (code) ON DELETE CASCADE,
    physique_id SMALLINT REFERENCES physiques (physique_id) ON DELETE CASCADE,

    rolls_made  INTEGER NOT NULL DEFAULT 0 CHECK (rolls_made >= 0),
    jade_spent  BIGINT  NOT NULL DEFAULT 0 CHECK (jade_spent >= 0),
    rolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (player_id, trait),

    CONSTRAINT reroll_offer_matches_its_trait CHECK (
        (trait = 'root')     = (root_code IS NOT NULL)
        AND (trait = 'physique') = (physique_id IS NOT NULL)
    )
);

CREATE INDEX player_reroll_offers_root_idx ON player_reroll_offers (root_code);
CREATE INDEX player_reroll_offers_phys_idx ON player_reroll_offers (physique_id);

COMMENT ON TABLE player_reroll_offers IS
    'A rolled trait waiting to be accepted or refused. A row rather than view state, because an offer somebody paid eight hundred Jade for must survive a restart.';


-- ---------------------------------------------------------------------------
-- reroll_root
-- ---------------------------------------------------------------------------
-- Rolls, keeps the best, and changes nothing.

DROP FUNCTION reroll_root(BIGINT, TEXT, INTEGER);

CREATE FUNCTION reroll_root(
    p_player_id BIGINT,
    p_target    TEXT,
    p_rolls     INTEGER
)
RETURNS TABLE (
    rolls_made   INTEGER,
    spent        BIGINT,
    offer_code   TEXT,
    offer_name   TEXT,
    offer_rarity TEXT,
    held_code    TEXT,
    held_name    TEXT,
    held_rarity  TEXT,
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
    best   TEXT;
    rank   SMALLINT := -1;
    got    TEXT;
    band   SMALLINT;
    made   INTEGER := 0;
    paid   BIGINT := 0;
BEGIN
    SELECT ra.sort_order INTO want FROM rarities ra WHERE ra.code = p_target;
    IF want IS NULL THEN
        RAISE EXCEPTION 'there is no % band', p_target USING ERRCODE = 'check_violation';
    END IF;

    -- A standing offer is a candidate like any other, so pressing Roll again
    -- can only improve it. Anything else is a trap.
    SELECT o.root_code, ra.sort_order INTO best, rank
    FROM player_reroll_offers o
    JOIN roots r ON r.code = o.root_code
    JOIN rarities ra ON ra.code = r.rarity
    WHERE o.player_id = p_player_id AND o.trait = 'root';

    LOOP
        EXIT WHEN made >= most;
        EXIT WHEN jade_held(p_player_id) < cost;

        PERFORM spend_jade(p_player_id, cost, 'reroll_root');
        paid := paid + cost;
        made := made + 1;

        got := roll_root();
        SELECT ra.sort_order INTO band
        FROM roots r JOIN rarities ra ON ra.code = r.rarity WHERE r.code = got;

        -- Ties go to the newer one: two roots of a band are different roots,
        -- and being shown the one you have already seen is not an offer.
        IF band >= COALESCE(rank, -1) THEN
            best := got;
            rank := band;
        END IF;

        EXIT WHEN band >= want;
    END LOOP;

    IF made > 0 OR best IS NOT NULL THEN
        INSERT INTO player_reroll_offers
            (player_id, trait, root_code, rolls_made, jade_spent)
        VALUES (p_player_id, 'root', best, made, paid)
        ON CONFLICT (player_id, trait) DO UPDATE
            SET root_code  = EXCLUDED.root_code,
                rolls_made = player_reroll_offers.rolls_made + EXCLUDED.rolls_made,
                jade_spent = player_reroll_offers.jade_spent + EXCLUDED.jade_spent,
                rolled_at  = now();
    END IF;

    RETURN QUERY
    SELECT made, paid,
           offered.code, offered.name, offered.rarity,
           mine.code, mine.name, mine.rarity,
           rank >= want, jade_held(p_player_id)
    FROM player_character pc
    JOIN roots mine ON mine.code = pc.root_code
    LEFT JOIN roots offered ON offered.code = best
    WHERE pc.player_id = p_player_id;
END;
$$;

COMMENT ON FUNCTION reroll_root(BIGINT, TEXT, INTEGER) IS
    'Rolls and keeps the best, changing nothing. What comes back is an OFFER; `reroll_take` is what accepts it.';


-- ---------------------------------------------------------------------------
-- reroll_physique
-- ---------------------------------------------------------------------------

DROP FUNCTION reroll_physique(BIGINT, TEXT, INTEGER);

CREATE FUNCTION reroll_physique(
    p_player_id BIGINT,
    p_target    TEXT,
    p_rolls     INTEGER
)
RETURNS TABLE (
    rolls_made   INTEGER,
    spent        BIGINT,
    offer_id     SMALLINT,
    offer_name   TEXT,
    offer_rarity TEXT,
    held_id      SMALLINT,
    held_name    TEXT,
    held_rarity  TEXT,
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
    best   SMALLINT;
    rank   SMALLINT := -1;
    got    SMALLINT;
    band   SMALLINT;
    made   INTEGER := 0;
    paid   BIGINT := 0;
BEGIN
    SELECT ra.sort_order INTO want FROM rarities ra WHERE ra.code = p_target;
    IF want IS NULL THEN
        RAISE EXCEPTION 'there is no % band', p_target USING ERRCODE = 'check_violation';
    END IF;

    SELECT o.physique_id, ra.sort_order INTO best, rank
    FROM player_reroll_offers o
    JOIN physiques p ON p.physique_id = o.physique_id
    JOIN rarities ra ON ra.code = p.tier
    WHERE o.player_id = p_player_id AND o.trait = 'physique';

    LOOP
        EXIT WHEN made >= most;
        EXIT WHEN jade_held(p_player_id) < cost;

        PERFORM spend_jade(p_player_id, cost, 'reroll_physique');
        paid := paid + cost;
        made := made + 1;

        got := roll_physique();
        SELECT ra.sort_order INTO band
        FROM physiques p JOIN rarities ra ON ra.code = p.tier
        WHERE p.physique_id = got;

        IF band >= COALESCE(rank, -1) THEN
            best := got;
            rank := band;
        END IF;

        EXIT WHEN band >= want;
    END LOOP;

    IF made > 0 OR best IS NOT NULL THEN
        INSERT INTO player_reroll_offers
            (player_id, trait, physique_id, rolls_made, jade_spent)
        VALUES (p_player_id, 'physique', best, made, paid)
        ON CONFLICT (player_id, trait) DO UPDATE
            SET physique_id = EXCLUDED.physique_id,
                rolls_made  = player_reroll_offers.rolls_made + EXCLUDED.rolls_made,
                jade_spent  = player_reroll_offers.jade_spent + EXCLUDED.jade_spent,
                rolled_at   = now();
    END IF;

    RETURN QUERY
    SELECT made, paid,
           offered.physique_id, offered.name, offered.tier,
           mine.physique_id, mine.name, mine.tier,
           rank >= want, jade_held(p_player_id)
    FROM player_physique pp
    JOIN physiques mine ON mine.physique_id = pp.physique_id
    LEFT JOIN physiques offered ON offered.physique_id = best
    WHERE pp.player_id = p_player_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- Deciding
-- ---------------------------------------------------------------------------

CREATE FUNCTION reroll_take(p_player_id BIGINT, p_trait TEXT)
RETURNS TABLE (name TEXT, rarity TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    it player_reroll_offers%ROWTYPE;
BEGIN
    SELECT * INTO it FROM player_reroll_offers
    WHERE player_id = p_player_id AND trait = p_trait
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'there is nothing on offer' USING ERRCODE = 'check_violation';
    END IF;

    IF p_trait = 'root' THEN
        UPDATE player_character
        SET root_code = it.root_code, root_rolls = root_rolls + it.rolls_made
        WHERE player_id = p_player_id;
    ELSE
        UPDATE player_physique SET physique_id = it.physique_id
        WHERE player_id = p_player_id;
        UPDATE player_character
        SET physique_rolls = physique_rolls + it.rolls_made
        WHERE player_id = p_player_id;
    END IF;

    -- Both of them move the body: a root carries HP and defence fractions,
    -- and a physique is the body.
    PERFORM apply_physique_xp(p_player_id, 0);

    DELETE FROM player_reroll_offers
    WHERE player_id = p_player_id AND trait = p_trait;

    RETURN QUERY
    SELECT r.name, r.rarity FROM roots r
    WHERE p_trait = 'root' AND r.code = it.root_code
    UNION ALL
    SELECT p.name, p.tier FROM physiques p
    WHERE p_trait = 'physique' AND p.physique_id = it.physique_id;
END;
$$;

CREATE FUNCTION reroll_discard(p_player_id BIGINT, p_trait TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- The rolls are not refunded. They were spent looking, and looking is what
    -- was bought.
    DELETE FROM player_reroll_offers
    WHERE player_id = p_player_id AND trait = p_trait;
END;
$$;

COMMENT ON FUNCTION reroll_discard(BIGINT, TEXT) IS
    'Refuses a standing offer. The Jade is not returned - it bought the look, and the look happened.';
