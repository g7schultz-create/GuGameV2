-- 0450_a_party_of_peers_and_a_room_of_their_own
--
-- The party layer for Peer Trials: cultivators of ONE realm invite each other,
-- see what the party can and cannot answer, and are given a channel of their
-- own that goes away when they are done with it.
--
-- The Trial itself is not here. This is the door and the room, built so the
-- fight can be hung on them without moving either.
--
-- SAME REALM, AND THIS IS A DEPARTURE. `dungeon_realm_reach` gates who may
-- OPEN a room and deliberately does not gate who may JOIN one - its own
-- description says "a deep cultivator bringing shallower friends is the thing
-- this game should want". A Peer Trial says the opposite on purpose: it is the
-- one place nobody can be carried, which is what makes clearing one mean
-- something about your own realm rather than about who you know. Both rules
-- are right for their own content and the two should not be reconciled.
--
-- ROLES ARE NOT DECLARED. There is no column here for tank or support, and
-- there should not be. A tank is whoever brought a taunt. Declaring a role
-- means enforcing it, and enforcing it means refusing a party of five friends
-- because none of them owns the right worm. `trial_party_roster` reports what
-- each member can ANSWER so the screen can say "no one here can pull a blow" -
-- information, not a gate.
--
-- AND THAT REPORT WILL READ BADLY TODAY, which is the honest state of things
-- rather than a fault in this migration: three cultivators in the game know a
-- support technique and one knows a defence technique, because no support or
-- defence technique has ever been forgeable. The roster will tell almost every
-- party that it cannot pull a blow. That is true, and seeing it is the point.
--
-- THE CHANNEL IS OPTIONAL. `channel_id` is nullable and the party is fully
-- usable without one: creating a Discord channel needs Manage Channels on the
-- bot's role, which is a deployment fact this schema cannot check and must not
-- depend on. A party whose channel could not be made still forms, still shows
-- its roster and still ends.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('trial_party_min', 3,
     'How many peers a Peer Trial needs before it may be sealed. Below this the party may form and talk, but not set out.'),
    ('trial_party_max', 5,
     'The ceiling on a Peer Trial party, matching dungeon_party_max so the two kinds of group content do not want different rooms.'),
    ('trial_invite_minutes', 20,
     'How long an unanswered invitation stands before it lapses. Short enough that a stale invite does not hold somebody out of another party all evening.')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, description = EXCLUDED.description;


-- ---------------------------------------------------------------------------
-- The party
-- ---------------------------------------------------------------------------

CREATE TABLE trial_parties (
    party_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    leader_id  BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    realm_rank SMALLINT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'forming',
    channel_id BIGINT,
    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    sealed_at  TIMESTAMPTZ,
    ended_at   TIMESTAMPTZ,
    CHECK (status IN ('forming', 'sealed', 'ended')),
    CHECK (realm_rank >= 1),
    -- A sealed party has set out; an ended one is over. Neither state can be
    -- reached without the stamp that says when, so "how long did that take"
    -- is answerable later without another table.
    CHECK ((status = 'forming') = (sealed_at IS NULL AND ended_at IS NULL)),
    CHECK ((status = 'ended') = (ended_at IS NOT NULL))
);

CREATE INDEX trial_parties_leader_idx ON trial_parties (leader_id);
CREATE INDEX trial_parties_live_idx ON trial_parties (status)
    WHERE status <> 'ended';
CREATE INDEX trial_parties_channel_idx ON trial_parties (channel_id)
    WHERE channel_id IS NOT NULL;

COMMENT ON COLUMN trial_parties.channel_id IS
    'The Discord channel made for this party, if one could be made. Nullable on purpose: creating one needs Manage Channels on the bot''s role, and a party whose channel failed still works.';


CREATE TABLE trial_party_members (
    party_id  BIGINT NOT NULL REFERENCES trial_parties(party_id) ON DELETE CASCADE,
    player_id BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (party_id, player_id)
);

CREATE INDEX trial_party_members_player_idx ON trial_party_members (player_id);


CREATE TABLE trial_party_invites (
    party_id    BIGINT NOT NULL REFERENCES trial_parties(party_id) ON DELETE CASCADE,
    player_id   BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    invited_by  BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    sent_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    answered_at TIMESTAMPTZ,
    accepted    BOOLEAN,
    PRIMARY KEY (party_id, player_id),
    CHECK ((answered_at IS NULL) = (accepted IS NULL))
);

CREATE INDEX trial_party_invites_player_idx
    ON trial_party_invites (player_id, answered_at);
CREATE INDEX trial_party_invites_by_idx ON trial_party_invites (invited_by);


-- ---------------------------------------------------------------------------
-- Where somebody stands
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION player_realm_rank(p_player_id bigint)
RETURNS SMALLINT
LANGUAGE sql
STABLE
AS $fn$
    -- One definition. Three places already dig this out of player_cultivation
    -- by hand, and a fourth would be a fourth thing to keep in step.
    SELECT COALESCE((SELECT r.rank FROM player_cultivation pc
                     JOIN realms r ON r.realm_id = pc.realm_id
                     WHERE pc.player_id = p_player_id), 1)::smallint;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_of(p_player_id bigint)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $fn$
    SELECT m.party_id FROM trial_party_members m
    JOIN trial_parties p ON p.party_id = m.party_id
    WHERE m.player_id = p_player_id AND p.status <> 'ended'
    LIMIT 1;
$fn$;


-- ---------------------------------------------------------------------------
-- What each of them can answer
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_party_roster(p_party_id bigint)
RETURNS TABLE(
    player_id   bigint,
    discord_name text,
    is_leader   boolean,
    realm_name  text,
    realm_rank  smallint,
    max_hp      bigint,
    strength    bigint,
    defense     bigint,
    can_pull    boolean,
    can_shield  boolean,
    can_mend    boolean,
    can_strike  boolean)
LANGUAGE sql
STABLE
AS $fn$
    -- What somebody can ANSWER, read off the techniques they actually know
    -- rather than off a role they picked. A tank is whoever brought a taunt.
    SELECT p.player_id, p.discord_name,
           (p.player_id = tp.leader_id) AS is_leader,
           r.name, r.rank,
           COALESCE(pp.max_hp, 0), COALESCE(pp.strength, 0), COALESCE(pp.defense, 0),
           EXISTS (SELECT 1 FROM player_techniques pt
                   JOIN techniques t ON t.technique_id = pt.technique_id,
                   jsonb_array_elements(t.effects->'apply') e
                   WHERE pt.player_id = p.player_id AND e->>'code' = 'taunt'),
           EXISTS (SELECT 1 FROM player_techniques pt
                   JOIN techniques t ON t.technique_id = pt.technique_id,
                   jsonb_array_elements(t.effects->'apply') e
                   WHERE pt.player_id = p.player_id
                     AND e->>'code' IN ('defence_up', 'block_up')),
           EXISTS (SELECT 1 FROM player_techniques pt
                   JOIN techniques t ON t.technique_id = pt.technique_id,
                   jsonb_array_elements(t.effects->'apply') e
                   WHERE pt.player_id = p.player_id AND e->>'code' = 'regen'),
           EXISTS (SELECT 1 FROM player_techniques pt
                   JOIN techniques t ON t.technique_id = pt.technique_id
                   WHERE pt.player_id = p.player_id AND t.base_power > 0)
    FROM trial_party_members m
    JOIN trial_parties tp ON tp.party_id = m.party_id
    JOIN players p ON p.player_id = m.player_id
    LEFT JOIN player_physique pp ON pp.player_id = p.player_id
    LEFT JOIN player_cultivation pc ON pc.player_id = p.player_id
    LEFT JOIN realms r ON r.realm_id = pc.realm_id
    WHERE m.party_id = p_party_id
    ORDER BY (p.player_id = tp.leader_id) DESC, m.joined_at;
$fn$;

COMMENT ON FUNCTION trial_party_roster(bigint) IS
    'Every peer, their body, and which of the four answers they can give. Reported rather than enforced: a party that cannot pull a blow should be told so and then allowed to try anyway.';


-- ---------------------------------------------------------------------------
-- Opening, inviting, answering, leaving
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trial_party_open(p_player_id bigint)
RETURNS BIGINT
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party BIGINT;
BEGIN
    IF trial_party_of(p_player_id) IS NOT NULL THEN
        RAISE EXCEPTION 'you are already in a party'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trial_parties (leader_id, realm_rank)
    VALUES (p_player_id, player_realm_rank(p_player_id))
    RETURNING party_id INTO v_party;

    INSERT INTO trial_party_members (party_id, player_id)
    VALUES (v_party, p_player_id);

    RETURN v_party;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_invite(
    p_player_id bigint, p_target bigint)
RETURNS TABLE(party_id bigint, realm_rank smallint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party BIGINT;
    v_rank  SMALLINT;
    v_here  INTEGER;
BEGIN
    v_party := trial_party_of(p_player_id);
    IF v_party IS NULL THEN
        RAISE EXCEPTION 'you have no party to invite anybody to'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.realm_rank INTO v_rank FROM trial_parties p WHERE p.party_id = v_party;

    IF (SELECT p.status FROM trial_parties p WHERE p.party_id = v_party) <> 'forming' THEN
        RAISE EXCEPTION 'that party has already set out'
            USING ERRCODE = 'check_violation';
    END IF;

    IF p_target = p_player_id THEN
        RAISE EXCEPTION 'you are already here' USING ERRCODE = 'check_violation';
    END IF;

    -- The rule the whole thing turns on. Said with both realms named, because
    -- "they are the wrong realm" is not enough to act on.
    IF player_realm_rank(p_target) <> v_rank THEN
        RAISE EXCEPTION
            'a Peer Trial is one realm - this party stands at %s and they stand at %s',
            v_rank, player_realm_rank(p_target)
            USING ERRCODE = 'check_violation';
    END IF;

    IF trial_party_of(p_target) IS NOT NULL THEN
        RAISE EXCEPTION 'they are already in a party'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO v_here FROM trial_party_members m WHERE m.party_id = v_party;
    IF v_here >= game_config_value('trial_party_max') THEN
        RAISE EXCEPTION 'a Peer Trial holds %s',
            game_config_value('trial_party_max')::integer
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trial_party_invites (party_id, player_id, invited_by)
    VALUES (v_party, p_target, p_player_id)
    ON CONFLICT ON CONSTRAINT trial_party_invites_pkey DO UPDATE
        SET invited_by = EXCLUDED.invited_by, sent_at = now(),
            answered_at = NULL, accepted = NULL;

    RETURN QUERY SELECT v_party, v_rank;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_answer(
    p_player_id bigint, p_party_id bigint, p_accept boolean)
RETURNS TABLE(joined boolean, party_id bigint, members integer)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_sent TIMESTAMPTZ;
    v_rank SMALLINT;
    v_here INTEGER;
BEGIN
    SELECT i.sent_at INTO v_sent FROM trial_party_invites i
    WHERE i.party_id = p_party_id AND i.player_id = p_player_id
      AND i.answered_at IS NULL
    FOR UPDATE;

    IF v_sent IS NULL THEN
        RAISE EXCEPTION 'you have no standing invitation to that party'
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_sent + make_interval(
           mins => game_config_value('trial_invite_minutes')::int) < now() THEN
        UPDATE trial_party_invites SET answered_at = now(), accepted = FALSE
        WHERE trial_party_invites.party_id = p_party_id AND trial_party_invites.player_id = p_player_id;
        RAISE EXCEPTION 'that invitation has gone cold'
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE trial_party_invites
    SET answered_at = now(), accepted = COALESCE(p_accept, FALSE)
    WHERE trial_party_invites.party_id = p_party_id AND trial_party_invites.player_id = p_player_id;

    IF NOT COALESCE(p_accept, FALSE) THEN
        RETURN QUERY SELECT FALSE, p_party_id, 0;
        RETURN;
    END IF;

    -- Everything is checked again on the way IN. The invitation was true when
    -- it was sent; the party may have filled, set out or ended since, and the
    -- realm is checked once more because a cultivator can break through while
    -- an invitation sits unanswered.
    IF (SELECT p.status FROM trial_parties p WHERE p.party_id = p_party_id)
       <> 'forming' THEN
        RAISE EXCEPTION 'that party has already set out'
            USING ERRCODE = 'check_violation';
    END IF;

    IF trial_party_of(p_player_id) IS NOT NULL THEN
        RAISE EXCEPTION 'you are already in a party'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.realm_rank INTO v_rank FROM trial_parties p WHERE p.party_id = p_party_id;
    IF player_realm_rank(p_player_id) <> v_rank THEN
        RAISE EXCEPTION
            'you stand at %s now and that party is a trial of %s',
            player_realm_rank(p_player_id), v_rank
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO v_here FROM trial_party_members m WHERE m.party_id = p_party_id;
    IF v_here >= game_config_value('trial_party_max') THEN
        RAISE EXCEPTION 'that party filled while you were deciding'
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO trial_party_members (party_id, player_id)
    VALUES (p_party_id, p_player_id);

    RETURN QUERY SELECT TRUE, p_party_id, v_here + 1;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_leave(p_player_id bigint)
RETURNS TABLE(party_id bigint, disbanded boolean, channel_id bigint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party  BIGINT;
    v_leader BIGINT;
    v_chan   BIGINT;
BEGIN
    v_party := trial_party_of(p_player_id);
    IF v_party IS NULL THEN
        RAISE EXCEPTION 'you are not in a party' USING ERRCODE = 'check_violation';
    END IF;

    SELECT p.leader_id, p.channel_id INTO v_leader, v_chan
    FROM trial_parties p WHERE p.party_id = v_party;

    -- The leader leaving takes the party with them. Passing the lead to
    -- whoever happens to be next is a rule nobody asked for, and a party
    -- whose leader has gone is usually a party that is over.
    IF v_leader = p_player_id THEN
        UPDATE trial_parties SET status = 'ended', ended_at = now()
        WHERE trial_parties.party_id = v_party;
        RETURN QUERY SELECT v_party, TRUE, v_chan;
        RETURN;
    END IF;

    DELETE FROM trial_party_members
    WHERE trial_party_members.party_id = v_party AND trial_party_members.player_id = p_player_id;

    RETURN QUERY SELECT v_party, FALSE, v_chan;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_seal(p_player_id bigint)
RETURNS TABLE(party_id bigint, members integer, realm_rank smallint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_party BIGINT;
    v_here  INTEGER;
    v_rank  SMALLINT;
BEGIN
    v_party := trial_party_of(p_player_id);
    IF v_party IS NULL THEN
        RAISE EXCEPTION 'you are not in a party' USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT p.leader_id FROM trial_parties p WHERE p.party_id = v_party)
       <> p_player_id THEN
        RAISE EXCEPTION 'only the one who opened the party may seal it'
            USING ERRCODE = 'check_violation';
    END IF;

    IF (SELECT p.status FROM trial_parties p WHERE p.party_id = v_party)
       <> 'forming' THEN
        RAISE EXCEPTION 'that party has already set out'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*), max(p.realm_rank) INTO v_here, v_rank
    FROM trial_party_members m
    JOIN trial_parties p ON p.party_id = m.party_id
    WHERE m.party_id = v_party;

    IF v_here < game_config_value('trial_party_min') THEN
        RAISE EXCEPTION
            'a Peer Trial wants %s peers and you are %s',
            game_config_value('trial_party_min')::integer, v_here
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE trial_parties SET status = 'sealed', sealed_at = now()
    WHERE trial_parties.party_id = v_party;

    -- Nobody may be invited into a sealed party, so the standing invitations
    -- are closed rather than left to go cold on somebody's screen.
    UPDATE trial_party_invites SET answered_at = now(), accepted = FALSE
    WHERE trial_party_invites.party_id = v_party AND answered_at IS NULL;

    RETURN QUERY SELECT v_party, v_here, v_rank;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_end(p_party_id bigint)
RETURNS TABLE(party_id bigint, channel_id bigint)
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_chan BIGINT;
BEGIN
    SELECT p.channel_id INTO v_chan FROM trial_parties p
    WHERE p.party_id = p_party_id AND p.status <> 'ended'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    UPDATE trial_parties SET status = 'ended', ended_at = now()
    WHERE trial_parties.party_id = p_party_id;

    UPDATE trial_party_invites SET answered_at = now(), accepted = FALSE
    WHERE trial_party_invites.party_id = p_party_id AND answered_at IS NULL;

    -- The channel id is handed back rather than cleared: the caller has to go
    -- and delete the actual room, and a party whose id was already forgotten
    -- would leave that room standing forever.
    RETURN QUERY SELECT p_party_id, v_chan;
END;
$fn$;


CREATE OR REPLACE FUNCTION trial_party_set_channel(
    p_party_id bigint, p_channel_id bigint)
RETURNS void
LANGUAGE sql
AS $fn$
    UPDATE trial_parties SET channel_id = p_channel_id
    WHERE trial_parties.party_id = p_party_id;
$fn$;


-- ---------------------------------------------------------------------------
-- One realm, one party each, and a room that is handed back to be closed
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a BIGINT; v_b BIGINT; v_c BIGINT;
    v_party BIGINT;
    v_got RECORD;
    r RECORD;
BEGIN
    BEGIN
        -- Three cultivators of one realm, and one of another.
        SELECT array_agg(x.player_id) INTO STRICT v_got FROM (
            SELECT p.player_id FROM players p
            JOIN player_cultivation pc ON pc.player_id = p.player_id
            WHERE p.deleted_at IS NULL LIMIT 0) x;
        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN NULL; END IF;
    END;

    BEGIN
        SELECT p.player_id INTO v_a FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms rr ON rr.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND trial_party_of(p.player_id) IS NULL
        ORDER BY rr.rank DESC, p.player_id LIMIT 1;

        IF v_a IS NULL THEN
            RAISE EXCEPTION 'probe-ok';
        END IF;

        -- Somebody of the SAME realm, and somebody of a different one.
        SELECT p.player_id INTO v_b FROM players p
        WHERE p.deleted_at IS NULL AND p.player_id <> v_a
          AND player_realm_rank(p.player_id) = player_realm_rank(v_a)
          AND trial_party_of(p.player_id) IS NULL
        LIMIT 1;

        SELECT p.player_id INTO v_c FROM players p
        WHERE p.deleted_at IS NULL AND p.player_id <> v_a
          AND player_realm_rank(p.player_id) <> player_realm_rank(v_a)
          AND trial_party_of(p.player_id) IS NULL
        LIMIT 1;

        v_party := trial_party_open(v_a);

        IF trial_party_of(v_a) <> v_party THEN
            RAISE EXCEPTION 'the leader is not in their own party';
        END IF;

        -- A second party is refused rather than quietly opened.
        BEGIN
            PERFORM trial_party_open(v_a);
            RAISE EXCEPTION 'a cultivator opened two parties';
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- The rule the content turns on.
        IF v_c IS NOT NULL THEN
            BEGIN
                PERFORM trial_party_invite(v_a, v_c);
                RAISE EXCEPTION 'a cultivator of another realm was invited';
            EXCEPTION WHEN check_violation THEN NULL;
            END;
        END IF;

        IF v_b IS NOT NULL THEN
            PERFORM trial_party_invite(v_a, v_b);
            SELECT * INTO v_got FROM trial_party_answer(v_b, v_party, TRUE);
            IF NOT v_got.joined THEN
                RAISE EXCEPTION 'a peer of the right realm was refused';
            END IF;
            IF trial_party_of(v_b) <> v_party THEN
                RAISE EXCEPTION 'they accepted and are not in the party';
            END IF;

            -- And a second answer to a spent invitation is refused.
            BEGIN
                PERFORM trial_party_answer(v_b, v_party, TRUE);
                RAISE EXCEPTION 'an invitation was answered twice';
            EXCEPTION WHEN check_violation THEN NULL;
            END;
        END IF;

        -- Sealing below the minimum is refused, and says the number.
        BEGIN
            PERFORM trial_party_seal(v_a);
            IF (SELECT count(*) FROM trial_party_members WHERE party_id = v_party)
               < game_config_value('trial_party_min') THEN
                RAISE EXCEPTION 'a party sealed below the minimum';
            END IF;
        EXCEPTION WHEN check_violation THEN NULL;
        END;

        -- The roster answers for everybody, and reports rather than gates.
        FOR r IN SELECT * FROM trial_party_roster(v_party) LOOP
            IF r.discord_name IS NULL THEN
                RAISE EXCEPTION 'the roster lost somebody''s name';
            END IF;
        END LOOP;
        IF NOT EXISTS (SELECT 1 FROM trial_party_roster(v_party) WHERE is_leader) THEN
            RAISE EXCEPTION 'the roster has no leader in it';
        END IF;

        -- Ending hands the room back so the caller can close it.
        PERFORM trial_party_set_channel(v_party, 123456789);
        SELECT * INTO v_got FROM trial_party_end(v_party);
        IF v_got.channel_id <> 123456789 THEN
            RAISE EXCEPTION 'the room was forgotten and will stand forever';
        END IF;
        IF trial_party_of(v_a) IS NOT NULL THEN
            RAISE EXCEPTION 'an ended party still holds its leader';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- What the roster will actually say today, which is the useful warning.
    RAISE NOTICE
        'of % live cultivators: % can pull a blow, % can mend, % can shield',
        (SELECT count(*) FROM players WHERE deleted_at IS NULL),
        (SELECT count(*) FROM players p WHERE p.deleted_at IS NULL AND EXISTS (
            SELECT 1 FROM player_techniques pt
            JOIN techniques t ON t.technique_id = pt.technique_id,
            jsonb_array_elements(t.effects->'apply') e
            WHERE pt.player_id = p.player_id AND e->>'code' = 'taunt')),
        (SELECT count(*) FROM players p WHERE p.deleted_at IS NULL AND EXISTS (
            SELECT 1 FROM player_techniques pt
            JOIN techniques t ON t.technique_id = pt.technique_id,
            jsonb_array_elements(t.effects->'apply') e
            WHERE pt.player_id = p.player_id AND e->>'code' = 'regen')),
        (SELECT count(*) FROM players p WHERE p.deleted_at IS NULL AND EXISTS (
            SELECT 1 FROM player_techniques pt
            JOIN techniques t ON t.technique_id = pt.technique_id,
            jsonb_array_elements(t.effects->'apply') e
            WHERE pt.player_id = p.player_id
              AND e->>'code' IN ('defence_up', 'block_up')));
END;
$probe$;
