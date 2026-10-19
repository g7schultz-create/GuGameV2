-- 0452_the_trial_itself_tells_you_what_is_coming
--
-- The fight. A Peer Trial announces what it is about to do, the party chooses
-- at the same time without seeing each other, and the round either answers the
-- threat or does not. That difference is the whole content: a party that reads
-- the telegraph and covers it should win, and one that does not should lose,
-- without a die deciding either.
--
-- NO LOOT. Deliberately: the greed axis is the step after this one, and it is
-- no fun until the fight underneath it is already tense. A cleared Trial today
-- says so and gives nothing.
--
-- IT BORROWS ITS MONSTER. Every realm already has exactly one dungeon, so a
-- Trial of realm N faces that realm's creature rather than needing a bestiary
-- of its own. The thing that makes it a Trial is the threat loop, not a new
-- species list.
--
-- AND IT BORROWS THE SWING. `player_swing` already resolves a whole build -
-- criticals, extra strikes, penetration, lifesteal - and calls
-- `technique_cast_effects`, so a support technique used in a round writes its
-- regen into `battle_effects` at this run's scope. That is what lets the
-- round ASK what the party did rather than being told: the answers are read
-- back out of the effects the party actually applied.
--
-- THE FOUR ANSWERS are the four the party screen already reports, so what
-- `/party` warns you about is exactly what the room will ask for:
--
--     pull    somebody applied taunt
--     harden  somebody applied defence_up or block_up
--     mend    somebody applied regen
--     strike  the party took a real bite out of it this round
--
-- AN UNANSWERED THREAT STILL ONLY HURTS. Nothing here one-shots a party from
-- full: the consequences are shares of a raider's own maximum, so a wipe is
-- always the third or fourth mistake rather than the first. A fight that can
-- end before anybody has learned the rules teaches nothing.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_round_cap', 20,
     'Rounds before the Trial simply wins. Shorter than a dungeon''s forty because a Trial is answered rather than ground down.'),
    ('trial_round_seconds', 90,
     'How long a round waits for everybody to choose before it resolves with what it has. Longer than a dungeon''s sixty: there is more to read.'),
    ('trial_boss_hp_scale', 2.4,
     'What a Trial''s creature carries over the same creature in a dungeon on Normal.'),
    ('trial_party_hp_step', 0.55,
     'How much more the creature carries for each peer past the first.'),
    ('trial_strike_share', 0.08,
     'The share of the creature''s whole health a party must take in one round for that round to count as having struck.'),
    ('trial_answered_share', 0.2,
     'What a threat still costs when it IS answered. Not nothing: answering turns a disaster into a cost, which is what keeps the health bar meaningful.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- What the thing can do, and what covers it
-- ---------------------------------------------------------------------------

CREATE TABLE trial_threats (
    code         TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    telegraph    TEXT NOT NULL,
    answers_with TEXT NOT NULL,
    hits         TEXT NOT NULL,
    share        NUMERIC(5,3) NOT NULL,
    adds_stack   BOOLEAN NOT NULL DEFAULT FALSE,
    weight       NUMERIC(5,2) NOT NULL,
    missed_line  TEXT NOT NULL,
    CHECK (answers_with IN ('pull', 'harden', 'mend', 'strike', 'none')),
    CHECK (hits IN ('weakest', 'all', 'none')),
    CHECK (share >= 0 AND share <= 1),
    CHECK (weight > 0)
);

COMMENT ON TABLE trial_threats IS
    'What a Peer Trial announces and what covers it. `share` is of a raider''s OWN maximum, so a threat costs the same proportion of everybody regardless of realm - the content is the reading, not the arithmetic.';

CREATE INDEX trial_threats_answer_idx ON trial_threats (answers_with);

INSERT INTO trial_threats
    (code, name, telegraph, answers_with, hits, share, adds_stack, weight, missed_line) VALUES
    ('fixes_on_one', 'It fixes on one of you',
     'Its attention settles, and does not move. Something is about to be struck once, hard.',
     'pull', 'weakest', 0.55, FALSE, 1.00,
     'Nobody stood in the way. The blow lands where it was aimed.'),

    ('wide_sweep', 'It draws breath',
     'The air goes out of the room. Whatever comes next will reach all of you.',
     'harden', 'all', 0.30, FALSE, 1.00,
     'It sweeps, and there was nothing between it and anybody.'),

    ('ritual', 'Something is building',
     'A shape is forming behind it that was not there before. It will finish soon.',
     'strike', 'none', 0.00, TRUE, 0.85,
     'The shape completes. Whatever comes next will cost more.'),

    ('drain', 'The air thins',
     'Breathing is harder than it was. This will not stop on its own.',
     'mend', 'all', 0.14, FALSE, 0.85,
     'It keeps drawing. Nobody falls this round, which is how this one kills.'),

    ('turns_away', 'It turns its back',
     'Something else has its attention. For one round it is not thinking about you.',
     'none', 'none', 0.00, FALSE, 0.55,
     'Nothing happens, which is its own kind of answer.');


-- ---------------------------------------------------------------------------
-- A run, and who is in it
-- ---------------------------------------------------------------------------

CREATE TABLE trial_runs (
    run_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id    BIGINT NOT NULL REFERENCES trial_parties(party_id) ON DELETE CASCADE,
    species_id  BIGINT NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    realm_rank  SMALLINT NOT NULL,
    boss_max_hp BIGINT NOT NULL,
    boss_hp     BIGINT NOT NULL,
    round_no    INTEGER NOT NULL DEFAULT 1,
    stacks      SMALLINT NOT NULL DEFAULT 0,
    coming      TEXT REFERENCES trial_threats(code) ON DELETE RESTRICT,
    status      TEXT NOT NULL DEFAULT 'fighting',
    outcome     TEXT,
    opened_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at    TIMESTAMPTZ,
    CHECK (status IN ('fighting', 'done')),
    CHECK (outcome IS NULL OR outcome IN ('cleared', 'wiped', 'outlasted')),
    CHECK ((status = 'done') = (ended_at IS NOT NULL)),
    CHECK ((status = 'done') = (outcome IS NOT NULL))
);

CREATE INDEX trial_runs_party_idx ON trial_runs (party_id);
CREATE INDEX trial_runs_species_idx ON trial_runs (species_id);
CREATE INDEX trial_runs_live_idx ON trial_runs (status) WHERE status = 'fighting';
CREATE INDEX trial_runs_coming_idx ON trial_runs (coming);

COMMENT ON COLUMN trial_runs.coming IS
    'The threat ALREADY announced, which the round about to be resolved must answer. Told one round ahead on purpose: a telegraph nobody can act on is just damage.';


CREATE TABLE trial_raiders (
    run_id       BIGINT NOT NULL REFERENCES trial_runs(run_id) ON DELETE CASCADE,
    player_id    BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    max_hp       BIGINT NOT NULL,
    current_hp   BIGINT NOT NULL,
    intent_id    BIGINT REFERENCES techniques(technique_id) ON DELETE SET NULL,
    chose_at     TIMESTAMPTZ,
    damage_dealt BIGINT NOT NULL DEFAULT 0,
    damage_taken BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (run_id, player_id),
    CHECK ((intent_id IS NULL) = (chose_at IS NULL))
);

CREATE INDEX trial_raiders_player_idx ON trial_raiders (player_id);
CREATE INDEX trial_raiders_intent_idx ON trial_raiders (intent_id);


-- ---------------------------------------------------------------------------
-- Drawing what comes next
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_draw_threat()
RETURNS TEXT
LANGUAGE sql
VOLATILE
AS $fn$
    -- Weighted without replacement bias: the same exponential trick the
    -- servant tiers use, so a heavy threat is likelier without ever being
    -- certain and a light one is never impossible.
    SELECT t.code FROM trial_threats t
    ORDER BY -ln(random()) / t.weight
    LIMIT 1;
$fn$;


CREATE OR REPLACE FUNCTION trial_of(p_player_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    SELECT r.run_id FROM trial_raiders x
    JOIN trial_runs r ON r.run_id = x.run_id
    WHERE x.player_id = p_player_id AND r.status = 'fighting'
    LIMIT 1;
$fn$;


-- ---------------------------------------------------------------------------
-- Setting out
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_begin(p_player_id bigint)
RETURNS TABLE(run_id bigint, boss_hp bigint, coming text, raiders integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party   BIGINT;
    v_rank    SMALLINT;
    v_species BIGINT;
    v_count   INTEGER;
    v_pool    BIGINT;
    v_run     BIGINT;
    v_threat  TEXT;
BEGIN
    v_party := trial_party_of(p_player_id);
    IF v_party IS NULL THEN
        RAISE EXCEPTION 'you are not in a party' USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT p.status FROM trial_parties p WHERE p.party_id = v_party) <> 'sealed' THEN
        RAISE EXCEPTION 'the party has not set out yet'
            USING ERRCODE = 'check_violation';
    END IF;

    IF EXISTS (SELECT 1 FROM trial_runs r
               WHERE r.party_id = v_party AND r.status = 'fighting') THEN
        RAISE EXCEPTION 'you are already in there' USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.realm_rank INTO v_rank FROM trial_parties p WHERE p.party_id = v_party;

    -- The realm's own creature. Every rank has exactly one dungeon, so a
    -- Trial never needs a bestiary of its own.
    SELECT dg.species_id INTO v_species FROM dungeons dg
    WHERE dg.realm_rank = v_rank LIMIT 1;
    IF v_species IS NULL THEN
        RAISE EXCEPTION 'nothing stands at realm % to be tried against', v_rank
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO v_count FROM trial_party_members m WHERE m.party_id = v_party;

    SELECT GREATEST(1, round(
        s.base_hp
        * game_config_value('trial_boss_hp_scale')
        * (1 + game_config_value('trial_party_hp_step') * GREATEST(0, v_count - 1))
    ))::bigint INTO v_pool
    FROM creature_species s WHERE s.species_id = v_species;

    v_threat := trial_draw_threat();

    INSERT INTO trial_runs
        (party_id, species_id, realm_rank, boss_max_hp, boss_hp, coming)
    VALUES (v_party, v_species, v_rank, v_pool, v_pool, v_threat)
    RETURNING trial_runs.run_id INTO v_run;

    -- Everybody enters at the body they actually have.
    INSERT INTO trial_raiders (run_id, player_id, max_hp, current_hp)
    SELECT v_run, m.player_id,
           GREATEST(1, COALESCE(pp.max_hp, 1)),
           GREATEST(1, COALESCE(pp.current_hp, COALESCE(pp.max_hp, 1)))
    FROM trial_party_members m
    LEFT JOIN player_physique pp ON pp.player_id = m.player_id
    WHERE m.party_id = v_party;

    RETURN QUERY SELECT v_run, v_pool, v_threat, v_count;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_choose(p_player_id bigint, p_technique_id bigint)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_run BIGINT;
BEGIN
    v_run := trial_of(p_player_id);
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'you are not in a trial' USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM player_techniques pt
                   WHERE pt.player_id = p_player_id
                     AND pt.technique_id = p_technique_id) THEN
        RAISE EXCEPTION 'you do not know that one' USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT x.current_hp FROM trial_raiders x
        WHERE x.run_id = v_run AND x.player_id = p_player_id) <= 0 THEN
        RAISE EXCEPTION 'you are down' USING ERRCODE = 'check_violation';
    END IF;

    UPDATE trial_raiders
    SET intent_id = p_technique_id, chose_at = now()
    WHERE trial_raiders.run_id = v_run AND trial_raiders.player_id = p_player_id;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- The round
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_resolve_round(p_run_id bigint)
RETURNS TABLE(
    answered     boolean,
    threat       text,
    threat_name  text,
    said         text,
    boss_hp      bigint,
    dealt        bigint,
    status       text,
    outcome      text,
    coming       text,
    lines        jsonb)
LANGUAGE plpgsql
AS $fn$
DECLARE
    run     RECORD;
    thr     RECORD;
    one     RECORD;
    swung   RECORD;
    move    BIGINT;
    v_dealt BIGINT := 0;
    v_lines JSONB := '[]'::jsonb;
    v_ok    BOOLEAN;
    v_said  TEXT;
    v_hurt  BIGINT;
    v_share NUMERIC;
    v_left  INTEGER;
    v_next  TEXT;
BEGIN
    SELECT * INTO run FROM trial_runs r
    WHERE r.run_id = p_run_id AND r.status = 'fighting'
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT * INTO thr FROM trial_threats t WHERE t.code = run.coming;

    -- ---- the party acts ---------------------------------------------------
    -- Everything is applied BEFORE the threat is judged, because the threat
    -- asks what the party did and the party has not done it yet.
    FOR one IN
        SELECT x.player_id, x.intent_id, x.current_hp, x.max_hp, p.discord_name
        FROM trial_raiders x
        JOIN players p ON p.player_id = x.player_id
        WHERE x.run_id = p_run_id AND x.current_hp > 0
        ORDER BY x.player_id
    LOOP
        move := COALESCE(one.intent_id, dungeon_default_move(one.player_id));
        IF move IS NULL THEN
            v_lines := v_lines || jsonb_build_object(
                'who', one.discord_name, 'kind', 'idle',
                'text', 'stands with nothing to throw');
            CONTINUE;
        END IF;

        -- The whole build, and `technique_cast_effects` inside it writes this
        -- round's taunt, regen or hardening into the scope below - which is
        -- how the threat is answered at all.
        SELECT * INTO swung FROM player_swing(
            one.player_id, move, run.species_id, run.boss_hp,
            (SELECT s.base_defense FROM creature_species s
             WHERE s.species_id = run.species_id)::bigint,
            one.current_hp, one.max_hp, run.round_no, 'trial', p_run_id);

        v_dealt := v_dealt + GREATEST(0, swung.dealt);

        IF swung.healed > 0 THEN
            UPDATE trial_raiders x
            SET current_hp = LEAST(x.max_hp, x.current_hp + swung.healed)
            WHERE x.run_id = p_run_id AND x.player_id = one.player_id;
        END IF;

        UPDATE trial_raiders x
        SET damage_dealt = x.damage_dealt + GREATEST(0, swung.dealt)
        WHERE x.run_id = p_run_id AND x.player_id = one.player_id;

        v_lines := v_lines || jsonb_build_object(
            'who', one.discord_name, 'kind', 'swing',
            'dealt', GREATEST(0, swung.dealt),
            'technique', (SELECT t.name FROM techniques t WHERE t.technique_id = move),
            'chosen', one.intent_id IS NOT NULL);
    END LOOP;

    UPDATE trial_runs r SET boss_hp = GREATEST(0, r.boss_hp - v_dealt)
    WHERE r.run_id = p_run_id;
    SELECT * INTO run FROM trial_runs r WHERE r.run_id = p_run_id;

    -- ---- was it answered --------------------------------------------------
    -- Read back out of what the party actually applied, rather than from
    -- anybody declaring a role.
    v_ok := CASE thr.answers_with
        WHEN 'none' THEN TRUE
        WHEN 'strike' THEN
            v_dealt >= run.boss_max_hp * game_config_value('trial_strike_share')
        ELSE EXISTS (
            SELECT 1 FROM battle_effects b
            WHERE b.scope = 'trial' AND b.scope_id = p_run_id
              AND b.effect_code = ANY (CASE thr.answers_with
                  WHEN 'pull'   THEN ARRAY['taunt']
                  WHEN 'mend'   THEN ARRAY['regen']
                  WHEN 'harden' THEN ARRAY['defence_up', 'block_up']
                  END))
    END;

    -- ---- and what it costs ------------------------------------------------
    v_share := thr.share
             * (1 + run.stacks * game_config_value('trial_answered_share'))
             * CASE WHEN v_ok THEN game_config_value('trial_answered_share')
                    ELSE 1 END;

    IF thr.hits = 'weakest' AND v_share > 0 THEN
        UPDATE trial_raiders x
        SET current_hp = GREATEST(0, x.current_hp - GREATEST(1, round(x.max_hp * v_share))::bigint),
            damage_taken = x.damage_taken + GREATEST(1, round(x.max_hp * v_share))::bigint
        WHERE x.run_id = p_run_id AND x.player_id = (
            SELECT y.player_id FROM trial_raiders y
            WHERE y.run_id = p_run_id AND y.current_hp > 0
            ORDER BY y.current_hp LIMIT 1);
    ELSIF thr.hits = 'all' AND v_share > 0 THEN
        UPDATE trial_raiders x
        SET current_hp = GREATEST(0, x.current_hp - GREATEST(1, round(x.max_hp * v_share))::bigint),
            damage_taken = x.damage_taken + GREATEST(1, round(x.max_hp * v_share))::bigint
        WHERE x.run_id = p_run_id AND x.current_hp > 0;
    END IF;

    IF thr.adds_stack AND NOT v_ok THEN
        UPDATE trial_runs r SET stacks = r.stacks + 1 WHERE r.run_id = p_run_id;
    END IF;

    v_said := CASE WHEN v_ok THEN
        CASE thr.answers_with
            WHEN 'none' THEN thr.missed_line
            ELSE 'Covered. It costs you, and it does not break you.'
        END
        ELSE thr.missed_line END;

    -- ---- effects age, and the round turns ---------------------------------
    PERFORM effect_tick('trial', p_run_id);

    UPDATE trial_raiders x SET intent_id = NULL, chose_at = NULL
    WHERE x.run_id = p_run_id;

    SELECT count(*) INTO v_left FROM trial_raiders x
    WHERE x.run_id = p_run_id AND x.current_hp > 0;

    SELECT * INTO run FROM trial_runs r WHERE r.run_id = p_run_id;

    IF run.boss_hp <= 0 THEN
        UPDATE trial_runs r SET status = 'done', outcome = 'cleared',
            ended_at = now(), coming = NULL
        WHERE r.run_id = p_run_id;
    ELSIF v_left = 0 THEN
        UPDATE trial_runs r SET status = 'done', outcome = 'wiped',
            ended_at = now(), coming = NULL
        WHERE r.run_id = p_run_id;
    ELSIF run.round_no >= game_config_value('trial_round_cap') THEN
        UPDATE trial_runs r SET status = 'done', outcome = 'outlasted',
            ended_at = now(), coming = NULL
        WHERE r.run_id = p_run_id;
    ELSE
        v_next := trial_draw_threat();
        UPDATE trial_runs r
        SET round_no = r.round_no + 1, coming = v_next
        WHERE r.run_id = p_run_id;
    END IF;

    -- The room is cleared of this fight's effects when the fight is over, so
    -- nothing leaks into the next one.
    SELECT * INTO run FROM trial_runs r WHERE r.run_id = p_run_id;
    IF run.status = 'done' THEN
        PERFORM effect_clear('trial', p_run_id);
    END IF;

    RETURN QUERY SELECT v_ok, thr.code, thr.name, v_said, run.boss_hp, v_dealt,
                        run.status, run.outcome, run.coming, v_lines;
END;
$fn$;


-- ---------------------------------------------------------------------------
-- A telegraph can be answered, and an ignored one costs
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_party BIGINT;
    v_run   BIGINT;
    v_a     BIGINT;
    v_b     BIGINT;
    v_got   RECORD;
    v_hp    BIGINT;
    r       RECORD;
BEGIN
    -- Every threat must be answerable by something a party could actually do,
    -- and every answer must be one the party screen reports. A threat covered
    -- by nothing is a threat that always lands.
    IF EXISTS (SELECT 1 FROM trial_threats t
               WHERE t.answers_with NOT IN ('pull','harden','mend','strike','none')) THEN
        RAISE EXCEPTION 'a threat asks for an answer nobody can give';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trial_threats WHERE answers_with = 'none') THEN
        RAISE EXCEPTION
            'there is no safe round, so looting will only ever be a punishment';
    END IF;

    -- The draw reaches every threat. A weight that can never come up is a
    -- threat nobody will ever see.
    FOR r IN SELECT t.code FROM trial_threats t LOOP
        IF NOT EXISTS (
            SELECT 1 FROM generate_series(1, 400) g
            WHERE trial_draw_threat() = r.code
        ) THEN
            RAISE EXCEPTION 'the draw never returns %', r.code;
        END IF;
    END LOOP;

    BEGIN
        SELECT p.player_id INTO v_a FROM players p
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
          AND EXISTS (SELECT 1 FROM dungeons dg WHERE dg.realm_rank = player_realm_rank(p.player_id))
        ORDER BY p.player_id LIMIT 1;

        SELECT p.player_id INTO v_b FROM players p
        WHERE p.deleted_at IS NULL AND p.player_id <> v_a
          AND player_realm_rank(p.player_id) = player_realm_rank(v_a)
          AND trial_party_of(p.player_id) IS NULL
          AND EXISTS (SELECT 1 FROM player_physique pp WHERE pp.player_id = p.player_id)
        LIMIT 1;

        IF v_a IS NULL OR v_b IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        v_party := trial_party_open(v_a);
        PERFORM trial_party_invite(v_a, v_b);
        PERFORM trial_party_answer(v_b, v_party, TRUE);

        -- Sealed by hand: the minimum is three and this probe has two, and
        -- what is under test is the ROUND rather than the door.
        UPDATE trial_parties SET status = 'sealed', sealed_at = now()
        WHERE party_id = v_party;

        SELECT * INTO v_got FROM trial_begin(v_a);
        v_run := v_got.run_id;

        IF v_got.coming IS NULL THEN
            RAISE EXCEPTION 'the trial began without telling anybody what is coming';
        END IF;
        IF (SELECT count(*) FROM trial_raiders x WHERE x.run_id = v_run) <> 2 THEN
            RAISE EXCEPTION 'the party did not all go in';
        END IF;

        -- A second run on one party is refused.
        BEGIN
            PERFORM trial_begin(v_a);
            RAISE EXCEPTION 'a party opened two trials';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- Force the one threat whose cost is certain, and leave it unanswered.
        UPDATE trial_runs SET coming = 'wide_sweep' WHERE run_id = v_run;
        SELECT min(x.current_hp) INTO v_hp FROM trial_raiders x WHERE x.run_id = v_run;

        SELECT * INTO v_got FROM trial_resolve_round(v_run);

        IF v_got.answered THEN
            RAISE EXCEPTION
                'a sweep was answered by a party that applied nothing';
        END IF;
        IF (SELECT min(x.current_hp) FROM trial_raiders x WHERE x.run_id = v_run)
           >= v_hp THEN
            RAISE EXCEPTION 'an unanswered sweep cost nobody anything';
        END IF;
        IF v_got.coming IS NULL AND v_got.status = 'fighting' THEN
            RAISE EXCEPTION 'the round turned without announcing the next threat';
        END IF;

        -- And the safe round costs nothing at all.
        UPDATE trial_runs SET coming = 'turns_away' WHERE run_id = v_run;
        SELECT min(x.current_hp) INTO v_hp FROM trial_raiders x
        WHERE x.run_id = v_run AND x.current_hp > 0;
        SELECT * INTO v_got FROM trial_resolve_round(v_run);
        IF NOT v_got.answered THEN
            RAISE EXCEPTION 'the round it spends looking away counted as missed';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    FOR r IN
        SELECT t.name, t.answers_with, t.hits, t.share, t.weight
        FROM trial_threats t ORDER BY t.weight DESC, t.code
    LOOP
        RAISE NOTICE '% : answered by %, hits %, % of a body',
            rpad(r.name, 24), rpad(r.answers_with, 7), rpad(r.hits, 8), r.share;
    END LOOP;
END;
$probe$;
