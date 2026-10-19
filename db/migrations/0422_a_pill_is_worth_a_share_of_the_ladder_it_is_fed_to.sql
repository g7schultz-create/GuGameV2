-- 0422_a_pill_is_worth_a_share_of_the_ladder_it_is_fed_to
--
-- `servant_feed` values a pill with `pill_cultivation_worth(p_player_id, ...)`
-- - the OWNER'S id. That function sizes a pill against
-- `cultivation_stage_gap` of whoever is asking, which is right for the person
-- swallowing it and catastrophic for the servant being handed it:
--
--     grafv is Dewberry Immortal, one stage = 6,250,000,000
--     their tier 7 pill is therefore worth  693,359,375
--     a servant at Qi Condensation needs             84 for the next realm
--
-- One pill was worth eight million of the servant's realms. `servant_feed`
-- climbs in a loop until the cultivation runs out or the owner's own realm
-- stops it, so a single Divine Distant Ascension Elixir took a servant from
-- the bottom of the ladder to standing beside their master in one press. The
-- feeding screen, the realm ladder and the whole point of `servant_realm_step`
-- were decoration.
--
-- WHAT IT IS WORTH NOW. The same SHARE of the servant's stage that it would
-- have been of yours. The pill above is 11.1 per cent of grafv's stage; it is
-- now 11.1 per cent of the servant's, which at the bottom of the ladder is
-- 9.32 of the 84 they need. Nine pills a realm down there, and the same nine
-- pills a realm at the top - because the servant's own gap grows with them.
--
-- Expressed as a ratio against the existing function rather than as a second
-- copy of its arithmetic. `pill_cultivation_worth` already knows what a grade,
-- a harmony and a potency are worth, and it is read by `take_pills` and the
-- alchemy screens; a servant-flavoured duplicate of that formula would have
-- been two places to change the day somebody retunes brewing, and they would
-- have diverged. This way the servant inherits every future change to what a
-- pill is worth, and inherits it scaled.
--
-- It also inherits the owner's `cultivation_intake_bonus`, which is correct
-- and worth saying out loud: a cultivator who has built for Breakthrough and
-- Essence pages is better at getting value out of a pill, and that should be
-- as true of the one they hand to a servant as the one they swallow.
--
-- AND A SECOND FAULT THE PROBE FOUND ON ITS WAY PAST. `servant_feed` spends a
-- pill like this:
--
--     UPDATE player_pills SET quantity = quantity - p_quantity ...
--     DELETE FROM player_pills WHERE ... AND quantity <= 0;
--
-- `player_pills` carries a CHECK that quantity is above zero, so the UPDATE
-- fails before the DELETE can tidy up: feeding a servant the LAST pill of a
-- stack raised a constraint violation rather than feeding them. Every other
-- pill in the game is spent the way `take_pill` spends one - delete the row
-- when the stack would empty, decrement when it would not - and this now does
-- the same. Nobody had hit it because nobody had yet fed their last pill.
--
-- Forward-only. Do not edit once applied.


CREATE FUNCTION servant_stage_gap(p_player_servant_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- What this servant still has to cross, on their own discounted ladder.
    -- `cultivation_stage_gap` said the same thing about a cultivator, and the
    -- shape is deliberately the same so the two read as one idea.
    SELECT GREATEST(1, COALESCE(
        (SELECT servant_realm_cost(above.realm_id)
                - COALESCE(servant_realm_cost(here.realm_id), 0)
         FROM player_servants ps
         JOIN realms here  ON here.realm_id  = ps.realm_id
         JOIN realms above ON above.realm_id = ps.realm_id + 1
         WHERE ps.player_servant_id = p_player_servant_id),
        -- At the end of the ladder, what the last step cost.
        (SELECT servant_realm_cost(here.realm_id)
                - COALESCE(servant_realm_cost(below.realm_id), 0)
         FROM player_servants ps
         JOIN realms here  ON here.realm_id  = ps.realm_id
         JOIN realms below ON below.realm_id = ps.realm_id - 1
         WHERE ps.player_servant_id = p_player_servant_id),
        1
    ))::bigint;
$$;

COMMENT ON FUNCTION servant_stage_gap(bigint) IS
    'What a servant still has to cross to their next realm. The servant''s answer to `cultivation_stage_gap`.';


CREATE FUNCTION servant_pill_worth(p_player_servant_id bigint, p_owner_id bigint,
                                   p_tier smallint, p_magnitude bigint,
                                   p_harmony smallint, p_potency numeric)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    -- The same share of the servant's stage that it would have been of their
    -- owner's. `pill_cultivation_worth` is asked rather than copied, so a
    -- servant inherits every later change to what a pill is worth.
    SELECT GREATEST(1, round(
        pill_cultivation_worth(p_owner_id, p_tier, p_magnitude,
                               p_harmony, p_potency)::numeric
        * servant_stage_gap(p_player_servant_id)
        / GREATEST(1, cultivation_stage_gap(p_owner_id))
    ))::bigint;
$$;

COMMENT ON FUNCTION servant_pill_worth(bigint, bigint, smallint, bigint, smallint, numeric) IS
    'What one pill is worth to a servant: the share of THEIR stage it would have been of their owner''s. Before 0422 they were handed the owner''s number outright, which was eight million of a new servant''s realms.';


-- ---------------------------------------------------------------------------
-- And the feeding asks the right question
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'servant_feed' AND pronamespace = 'public'::regnamespace;
    IF body IS NULL THEN
        RAISE EXCEPTION 'servant_feed is missing';
    END IF;

    -- Built with repeat() rather than typed. The continuation lines up under
    -- an opening paren at column 36 and counting that by eye is how two
    -- patches in this codebase have already had to be done twice.
    anchor := concat(
'    worth := pill_cultivation_worth(p_player_id, pill.tier, pill.magnitude,', chr(10),
repeat(' ', 36), 'pill.harmony, pill.potency) * p_quantity;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_feed no longer values its pill where it did';
    END IF;

    body := replace(body, anchor, concat(
'    -- The servant''s ladder, not their owner''s. See 0422: this used to hand', chr(10),
'    -- a servant the number the OWNER would have got, which at the bottom of', chr(10),
'    -- the ladder was eight million realms in one swallow.', chr(10),
'    worth := servant_pill_worth(p_player_servant_id, p_player_id, pill.tier,', chr(10),
repeat(' ', 32), 'pill.magnitude, pill.harmony,', chr(10),
repeat(' ', 32), 'pill.potency) * p_quantity;'));

    -- ---- and spending it the way every other pill is spent ----------------
    anchor := concat(
'    UPDATE player_pills SET quantity = quantity - p_quantity', chr(10),
'    WHERE pill_id = p_pill_id;', chr(10),
'    DELETE FROM player_pills WHERE pill_id = p_pill_id AND quantity <= 0;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'servant_feed no longer spends its pill where it did';
    END IF;

    EXECUTE replace(body, anchor, concat(
'    -- `player_pills` will not hold a zero, so the last of a stack is', chr(10),
'    -- deleted rather than decremented. The other order raised a check', chr(10),
'    -- violation on the UPDATE before the DELETE could tidy it away, which', chr(10),
'    -- is what `take_pill` has always known and this did not.', chr(10),
'    IF pill.quantity > p_quantity THEN', chr(10),
'        UPDATE player_pills SET quantity = quantity - p_quantity', chr(10),
'        WHERE pill_id = p_pill_id;', chr(10),
'    ELSE', chr(10),
'        DELETE FROM player_pills WHERE pill_id = p_pill_id;', chr(10),
'    END IF;'));
END;
$patch$;


-- ---------------------------------------------------------------------------
-- One pill is one pill's worth of progress
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_id    BIGINT;
    v_pill  RECORD;
    v_start SMALLINT;
    v_end   SMALLINT;
    v_share NUMERIC;
    r       RECORD;
BEGIN
    IF (SELECT prosrc FROM pg_proc
        WHERE proname = 'servant_feed'
          AND pronamespace = 'public'::regnamespace)
       LIKE '%pill_cultivation_worth(p_player_id%' THEN
        RAISE EXCEPTION 'servant_feed still values a pill by its owner''s ladder';
    END IF;

    BEGIN
        -- Somebody deep, holding a real pill: the case that was broken.
        SELECT pl.*, pl.owner_id AS who INTO v_pill
        FROM player_pills pl
        JOIN player_cultivation pc ON pc.player_id = pl.owner_id
        JOIN realms r2 ON r2.realm_id = pc.realm_id
        WHERE pl.kind IN ('cultivation', 'insight') AND pl.quantity > 0
        ORDER BY r2.rank DESC, pl.tier DESC LIMIT 1;

        IF v_pill.pill_id IS NULL THEN
            RAISE EXCEPTION 'probe-ok';          -- nobody holds one to try
        END IF;
        v_who := v_pill.who;

        INSERT INTO player_servants (player_id, servant_code, realm_id)
        SELECT v_who, s.servant_code, (SELECT min(realm_id) FROM realms)
        FROM servants s ORDER BY s.servant_code LIMIT 1
        RETURNING player_servant_id INTO v_id;

        SELECT r2.rank INTO v_start FROM player_servants ps
        JOIN realms r2 ON r2.realm_id = ps.realm_id
        WHERE ps.player_servant_id = v_id;

        -- The share of their own stage one pill is worth. This is the whole
        -- claim of the migration, so it is the thing asserted.
        v_share := servant_pill_worth(v_id, v_who, v_pill.tier, v_pill.magnitude,
                                      v_pill.harmony, v_pill.potency)::numeric
                   / servant_stage_gap(v_id);

        IF v_share > 1 THEN
            RAISE EXCEPTION
                'one pill is still worth % of a whole servant stage', v_share;
        END IF;

        -- Fed as the LAST of its stack on purpose: that is the path that
        -- used to raise a check violation.
        UPDATE player_pills SET quantity = 1 WHERE pill_id = v_pill.pill_id;
        PERFORM servant_feed(v_who, v_id, v_pill.pill_id, 1);

        IF EXISTS (SELECT 1 FROM player_pills WHERE pill_id = v_pill.pill_id) THEN
            RAISE EXCEPTION 'the last pill of a stack was not consumed';
        END IF;

        SELECT r2.rank INTO v_end FROM player_servants ps
        JOIN realms r2 ON r2.realm_id = ps.realm_id
        WHERE ps.player_servant_id = v_id;

        IF v_end > v_start + 1 THEN
            RAISE EXCEPTION
                'one pill carried a servant from rank % to rank %', v_start, v_end;
        END IF;

        RAISE NOTICE
            'one tier % pill is % of a new servant''s stage, and moved them rank % to %',
            v_pill.tier, round(v_share, 4), v_start, v_end;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT p.discord_name, r2.rank,
               cultivation_stage_gap(p.player_id) AS their_stage
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r2 ON r2.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND r2.rank >= 10
        ORDER BY r2.rank DESC LIMIT 3
    LOOP
        RAISE NOTICE '% at rank % crosses % a stage',
            rpad(r.discord_name, 14), r.rank, r.their_stage;
    END LOOP;
END;
$probe$;
