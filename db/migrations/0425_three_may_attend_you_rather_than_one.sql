-- 0425_three_may_attend_you_rather_than_one
--
-- 0417 made "only one attends you" a property of the schema rather than a rule
-- anybody had to remember: `player_servant_attending` was keyed on the player,
-- so a second call of `servant_attend` replaced the first by construction. That
-- was the roster document's own implementation note, and it was the right
-- default while nothing else had been decided.
--
-- Three now. The key becomes (player_id, player_servant_id) and the count is
-- held by `servant_attend_max` instead, so the number is a config line rather
-- than a migration next time it moves.
--
-- WHY THIS DOES NOT NEED A NEW SUM. `servant_stat` was already written as
-- `sum(...)` over the attending rows - there was simply never more than one of
-- them. It starts adding three together today without being touched, which is
-- the whole reason it was written that way instead of as a scalar subquery.
--
-- AND WHY IT CANNOT RUN AWAY. Everything a servant grants goes through
-- `player_stat`, which clamps the total of ALL sources at `gu_effects.cap`.
-- Three five-star Venerables of the same bonus are 0.36 of a cultivation
-- ceiling of 3.00, or 0.36 of a max_hp ceiling of 1.00 - real, and nowhere
-- near a number the rest of the game does not already have to survive from
-- Gu, manuals, equipment and physiques put together.
--
-- What it does change is the shape of a collection: the best three of a kind
-- now beat the best one, so a deep collection is worth more than it was this
-- morning. That is the point of the request and it is worth saying plainly
-- rather than discovering later - `servant_collection_bonus` was deliberately
-- pointed at farming in 0415 so that breadth could not out-stat the one you
-- chose, and this loosens that by exactly a factor of three.
--
-- DISMISSING BECOMES A THING PEOPLE DO. With one slot, calling somebody new
-- retired the old one silently and no screen needed a way to say no. With
-- three, a full bench has to be emptied on purpose, so `servant_dismiss` takes
-- an optional servant and sends that one home rather than all of them.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('servant_attend_max', 3,
     'How many servants may attend a cultivator at once, their passives summed and then clamped by `player_stat` like every other source. One until 0425.');


-- The key was the rule. Now the rule is the count.
ALTER TABLE player_servant_attending
    DROP CONSTRAINT player_servant_attending_pkey;

ALTER TABLE player_servant_attending
    ADD PRIMARY KEY (player_id, player_servant_id);

COMMENT ON TABLE player_servant_attending IS
    'The servants whose passives a cultivator feels. Up to `servant_attend_max` of them since 0425; the UNIQUE on player_servant_id still stops one servant attending twice.';


-- ---------------------------------------------------------------------------
-- Calling one, and sending one home
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION servant_attend(p_player_id bigint,
                                          p_player_servant_id bigint)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_name TEXT;
    v_have INTEGER;
BEGIN
    SELECT s.name INTO v_name
    FROM player_servants ps
    JOIN servants s ON s.servant_code = ps.servant_code
    WHERE ps.player_servant_id = p_player_servant_id
      AND ps.player_id = p_player_id;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'that is not one of your servants'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Already here. Said rather than silently counted again, because with more
    -- than one slot a player cannot tell by looking whether the press landed.
    IF EXISTS (SELECT 1 FROM player_servant_attending a
               WHERE a.player_servant_id = p_player_servant_id) THEN
        RETURN v_name || ' already attends you.';
    END IF;

    SELECT count(*)::integer INTO v_have
    FROM player_servant_attending a WHERE a.player_id = p_player_id;

    IF v_have >= game_config_value('servant_attend_max') THEN
        RAISE EXCEPTION
            '% may attend you at once, and % already do - send one home first',
            game_config_value('servant_attend_max'), v_have
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO player_servant_attending (player_id, player_servant_id)
    VALUES (p_player_id, p_player_servant_id);

    RETURN v_name || ' attends you.';
END;
$$;


-- The signature grows an argument, which CREATE OR REPLACE cannot do without
-- leaving an ambiguous one-argument overload behind it.
DROP FUNCTION servant_dismiss(bigint);

CREATE FUNCTION servant_dismiss(p_player_id bigint,
                                p_player_servant_id bigint DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    gone INTEGER;
BEGIN
    DELETE FROM player_servant_attending a
    WHERE a.player_id = p_player_id
      AND (p_player_servant_id IS NULL
           OR a.player_servant_id = p_player_servant_id);

    GET DIAGNOSTICS gone = ROW_COUNT;
    RETURN gone;
END;
$$;

COMMENT ON FUNCTION servant_dismiss(bigint, bigint) IS
    'Sends one attending servant home, or all of them when no servant is named. Returns how many were sent. A bench of three has to be emptied deliberately, which one of one never did.';


-- ---------------------------------------------------------------------------
-- Three are felt, a fourth is refused, and the ceiling still holds
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_code  TEXT;
    v_eff   TEXT;
    v_cap   NUMERIC;
    v_was   NUMERIC;
    v_one   NUMERIC;
    v_three NUMERIC;
    v_ids   BIGINT[] := '{}';
    v_id    BIGINT;
    r       RECORD;
BEGIN
    IF game_config_value('servant_attend_max') < 2 THEN
        RAISE EXCEPTION 'the bench still holds one';
    END IF;

    -- `servant_stat` must already sum rather than pick, or three attendants
    -- would quietly be worth one.
    IF (SELECT prosrc FROM pg_proc
        WHERE proname = 'servant_stat'
          AND pronamespace = 'public'::regnamespace) NOT LIKE '%sum(%' THEN
        RAISE EXCEPTION 'servant_stat does not add its attendants together';
    END IF;

    BEGIN
        SELECT p.player_id INTO v_who FROM players p
        WHERE p.deleted_at IS NULL ORDER BY p.player_id LIMIT 1;

        PERFORM servant_dismiss(v_who);

        -- A percentage bonus with a deep ceiling, so the sum is visible
        -- rather than clamped before it can be measured.
        SELECT s.servant_code, b.effect_code, ef.cap INTO v_code, v_eff, v_cap
        FROM servants s
        JOIN servant_bonuses b ON b.kind = s.bonus_kind
        JOIN gu_effects ef ON ef.code = b.effect_code
        WHERE s.tier = 7 AND NOT b.is_flat AND NOT b.is_strike
        ORDER BY ef.cap DESC LIMIT 1;

        v_was := player_stat(v_who, v_eff);

        FOR i IN 1..4 LOOP
            INSERT INTO player_servants (player_id, servant_code, realm_id)
            VALUES (v_who, v_code, (SELECT min(realm_id) FROM realms))
            RETURNING player_servant_id INTO v_id;
            v_ids := v_ids || v_id;
        END LOOP;

        PERFORM servant_attend(v_who, v_ids[1]);
        v_one := player_stat(v_who, v_eff);

        PERFORM servant_attend(v_who, v_ids[2]);
        PERFORM servant_attend(v_who, v_ids[3]);
        v_three := player_stat(v_who, v_eff);

        IF (SELECT count(*) FROM player_servant_attending
            WHERE player_id = v_who) <> 3 THEN
            RAISE EXCEPTION 'three were called and % are here',
                (SELECT count(*) FROM player_servant_attending
                 WHERE player_id = v_who);
        END IF;

        -- Three of a kind must be worth more than one of it, up to the cap.
        IF v_three <= v_one AND v_one < v_cap THEN
            RAISE EXCEPTION
                'three attendants (%) are worth no more than one (%)',
                v_three, v_one;
        END IF;

        -- And a fourth is refused rather than quietly replacing somebody.
        BEGIN
            PERFORM servant_attend(v_who, v_ids[4]);
            RAISE EXCEPTION 'a fourth servant walked onto a bench of three';
        EXCEPTION WHEN check_violation THEN
            NULL;
        END;

        -- Sending one home frees exactly one seat.
        IF servant_dismiss(v_who, v_ids[1]) <> 1 THEN
            RAISE EXCEPTION 'dismissing one servant sent a different number home';
        END IF;
        PERFORM servant_attend(v_who, v_ids[4]);

        IF (SELECT count(*) FROM player_servant_attending
            WHERE player_id = v_who) <> 3 THEN
            RAISE EXCEPTION 'the bench did not stay at three';
        END IF;

        RAISE NOTICE
            '% : one attendant gave %, three gave %, ceiling is %',
            v_eff, v_was, v_three, v_cap;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT p.discord_name,
               (SELECT count(*) FROM player_servant_attending a
                WHERE a.player_id = p.player_id) AS attending
        FROM players p
        WHERE EXISTS (SELECT 1 FROM player_servants x
                      WHERE x.player_id = p.player_id)
        ORDER BY 2 DESC, 1
    LOOP
        RAISE NOTICE '% has % of % seats filled',
            rpad(r.discord_name, 14), r.attending,
            game_config_value('servant_attend_max');
    END LOOP;
END;
$probe$;
