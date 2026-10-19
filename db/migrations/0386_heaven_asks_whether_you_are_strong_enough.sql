-- 0386_heaven_asks_whether_you_are_strong_enough
--
-- `breakthrough` has carried this line since it was written:
--
--     -- The tribulation goes here: a roll before this line, and an outcome
--     -- column on the way out. Everything below is what surviving one is worth.
--
-- It is a fight rather than a roll. A crossing between great realms now puts
-- something in front of you that has to be killed, and the cultivation total
-- stops being the only question asked at the door.
--
-- WHAT IT IS SIZED AGAINST, AND WHY NOT A SECOND HAND-TYPED CURVE. Every
-- tribulation is derived from the dungeon boss of the realm being LEFT - the
-- hardest thing the game already asked of somebody standing where they are
-- standing. 0362 and 0363 tuned that curve for all eighteen ranks; a second
-- curve typed out beside it would be a second thing to keep in step, and it
-- would fall out of step.
--
--     health  = that boss's health  x tribulation_hp_share
--     attack  = that boss's attack  x tribulation_attack_share
--     defence = that boss's defence x tribulation_attack_share
--
-- A dungeon boss is party content and a tribulation is faced alone, which is
-- the whole reason for the shares. Measured against the nine cultivators who
-- actually have somewhere to climb to:
--
--     clearwest  (10 -> 11)  kills it in about 11 rounds, taking half their body
--     shinonn    (10 -> 11)  about 10 rounds
--     m_i_y_u_k_i(11 -> 12)  3 rounds, barely scratched
--     pashu0     (13 -> 14)  2 rounds
--
-- Which is the shape that was asked for: real drama for somebody who has the
-- cultivation number and nothing else, a formality for somebody who built.
--
-- IT HAS NO PATH. `creature_paths` is left empty for all seventeen, so no
-- matchup applies in either direction. Heaven is not weak to Fire. Forty-four
-- beasts already have no Path, so the lane handles it.
--
-- FAILING COSTS THE FIGHT AND A WAIT. The damage is real and the crossing
-- stays shut for `tribulation_retry_hours`. Nothing is taken from what you
-- already earned - it is a door being checked, not a punishment - but the wait
-- is what stops it being rolled at until the dice land. Fleeing counts as
-- failing, because looking at heaven and walking away is the same information
-- and should cost the same.
--
-- WHAT IT DOES TO PEOPLE ALREADY PAST THOSE DOORS. Nothing. It gates the
-- crossing about to be made, and every crossing already made is already made.
--
-- Forward-only. Do not edit once applied.


INSERT INTO game_config (key, value, description) VALUES
    ('tribulation_hp_share', 0.35,
     'A tribulation''s health as a share of the dungeon boss of the realm being left. Well under 1 because a dungeon boss is party content and a tribulation is faced alone.'),
    ('tribulation_attack_share', 0.80,
     'A tribulation''s attack and defence as a share of the same boss''s. Nearer to 1 than the health share on purpose: the trial is meant to be short and frightening rather than long and grinding.'),
    ('tribulation_retry_hours', 8,
     'How long the sky stays shut after a failed or fled tribulation. The whole cost of failing, and enough that the answer is to go and get stronger rather than to try again immediately.');


-- ---------------------------------------------------------------------------
-- Something to fight
-- ---------------------------------------------------------------------------

ALTER TABLE creature_species DROP CONSTRAINT creature_species_kind_check;
ALTER TABLE creature_species ADD CONSTRAINT creature_species_kind_check
    CHECK (kind IN ('beast', 'elite', 'boss', 'world', 'rogue', 'dungeon',
                    'tribulation'));

ALTER TABLE battles DROP CONSTRAINT battles_kind_check;
ALTER TABLE battles ADD CONSTRAINT battles_kind_check
    CHECK (kind IN ('pve', 'duel', 'dungeon', 'tribulation'));


CREATE TABLE tribulations (
    rank        SMALLINT PRIMARY KEY CHECK (rank >= 2 AND rank <= 18),
    species_id  BIGINT NOT NULL REFERENCES creature_species(species_id),
    description TEXT NOT NULL DEFAULT ''
);

COMMENT ON TABLE tribulations IS
    'What stands in the door of each great realm. Keyed by the rank being crossed INTO, so rank 10 is the sky that has to be survived to become an immortal.';


-- The stats are computed from the departing realm's dungeon boss here rather
-- than typed out, so the seventeen of them cannot disagree with the curve they
-- claim to be a share of.
WITH named (into_rank, name, description) AS (VALUES
    ( 2::smallint, 'The First Thunder',
      'One bolt, out of a clear sky. Most cultivators never see a second.'),
    ( 3::smallint, 'The Cleansing Fire',
      'It burns off what you carried up from the village. Whether anything is left underneath is the question being asked.'),
    ( 4::smallint, 'The Wind That Strips the Bark',
      'Not loud. It simply does not stop, and a foundation with a seam in it comes apart along the seam.'),
    ( 5::smallint, 'Nine Bolts of the Azure Sky',
      'The first tribulation that counts itself out loud, so you know exactly how much is left and exactly how little that helps.'),
    ( 6::smallint, 'The Frost That Finds the Marrow',
      'It goes past the skin and past the muscle and asks the bone whether it was ever tempered at all.'),
    ( 7::smallint, 'The Heart Demon of the Middle Road',
      'It wears your face and makes your argument. Killing it is the only rebuttal the sky accepts.'),
    ( 8::smallint, 'The Judgement of Accumulated Years',
      'Every shortcut you took arrives at once, in order, with interest.'),
    ( 9::smallint, 'The Sky That Refuses a Dao',
      'The last mortal door. Heaven has noticed that you intend to stop dying, and disagrees.'),
    (10::smallint, 'The Immortal Ascension Tribulation',
      'The one that everything before it was practice for. Cross this and the years stop counting against you.'),
    (11::smallint, 'The Second Calamity',
      'An immortal is a thing the world now has an opinion about. This is the first time it says so.'),
    (12::smallint, 'The Third Calamity',
      'It comes down in water rather than light, and water does not need to be fast.'),
    (13::smallint, 'The Fourth Calamity',
      'It offers you the years back. Refusing is the fight.'),
    (14::smallint, 'The Fifth Calamity',
      'Nine deaths and one life, and the sky does not tell you which of the ten this is.'),
    (15::smallint, 'The Sixth Calamity',
      'It grows while you fight it. Everything you do not kill becomes root.'),
    (16::smallint, 'The Seventh Calamity',
      'A decree rather than a storm. It has already been decided; the fight is over whether it is carried out.'),
    (17::smallint, 'The Eighth Calamity',
      'Colourless, soundless, and it has been in the room for some time.'),
    (18::smallint, 'The Ninth Calamity',
      'The last door in the world. Nothing has been written about what is on the other side, because nobody who reached it came back to write.')
),
made AS (
    INSERT INTO creature_species
        (code, name, rank, immortal_rank, kind, base_hp, base_attack,
         base_defense, base_speed, description)
    SELECT 'tribulation_' || n.into_rank,
           n.name,
           boss.rank,
           boss.immortal_rank,
           'tribulation',
           GREATEST(1, round(boss.base_hp
                             * game_config_value('tribulation_hp_share')))::bigint,
           GREATEST(1, round(boss.base_attack
                             * game_config_value('tribulation_attack_share')))::bigint,
           GREATEST(0, round(boss.base_defense
                             * game_config_value('tribulation_attack_share')))::bigint,
           boss.base_speed,
           n.description
    FROM named n
    JOIN dungeons d ON d.realm_rank = n.into_rank - 1
    JOIN creature_species boss ON boss.species_id = d.species_id
    RETURNING species_id, code
)
INSERT INTO tribulations (rank, species_id, description)
SELECT n.into_rank, made.species_id, n.description
FROM named n
JOIN made ON made.code = 'tribulation_' || n.into_rank;


-- ---------------------------------------------------------------------------
-- What somebody has survived, and what they have not
-- ---------------------------------------------------------------------------

CREATE TABLE player_tribulations (
    attempt_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    player_id  BIGINT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    rank       SMALLINT NOT NULL REFERENCES tribulations(rank),
    battle_id  BIGINT REFERENCES battles(battle_id) ON DELETE SET NULL,
    status     TEXT NOT NULL DEFAULT 'facing'
               CHECK (status IN ('facing', 'passed', 'failed')),
    opened_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    settled_at TIMESTAMPTZ,
    CHECK ((status = 'facing') = (settled_at IS NULL))
);

-- A door is survived once. The index is the guarantee rather than the check in
-- `tribulation_face`, because a check races and an index does not.
CREATE UNIQUE INDEX player_tribulations_one_pass_idx
    ON player_tribulations (player_id, rank) WHERE status = 'passed';

-- And one sky at a time.
CREATE UNIQUE INDEX player_tribulations_one_facing_idx
    ON player_tribulations (player_id) WHERE status = 'facing';

CREATE UNIQUE INDEX player_tribulations_battle_idx
    ON player_tribulations (battle_id) WHERE battle_id IS NOT NULL;

CREATE INDEX player_tribulations_player_idx
    ON player_tribulations (player_id, rank, status);

COMMENT ON TABLE player_tribulations IS
    'Every tribulation anybody has walked into, and how it went. A log rather than a flag, so a failure leaves a mark that the retry wait can be measured from.';


CREATE FUNCTION tribulation_passed(p_player_id BIGINT, p_rank SMALLINT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM player_tribulations pt
                   WHERE pt.player_id = p_player_id AND pt.rank = p_rank
                     AND pt.status = 'passed');
$$;

COMMENT ON FUNCTION tribulation_passed(BIGINT, SMALLINT) IS
    'Whether this cultivator has already survived the sky guarding entry to that rank.';


-- ---------------------------------------------------------------------------
-- Where a cultivator stands with the sky
-- ---------------------------------------------------------------------------
--
-- One row, answering every question a screen has: is one owed, what is it,
-- has it been survived, is it open right now, and if not, why not. Written
-- once here so the screen that warns and the door that refuses read the same
-- sentence - the reason `breakthrough_gate` exists and the same discipline.

CREATE FUNCTION tribulation_standing(p_player_id BIGINT)
RETURNS TABLE (owed BOOLEAN, rank SMALLINT, realm_name TEXT, trial_name TEXT,
               trial_text TEXT, species_id BIGINT, passed BOOLEAN,
               facing_battle BIGINT, wait_seconds BIGINT, may_face BOOLEAN,
               blocked_by TEXT, trial_hp BIGINT, trial_attack BIGINT)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    cult    player_cultivation%ROWTYPE;
    was     realms%ROWTYPE;
    becomes realms%ROWTYPE;
    tri     RECORD;
    v_last  TIMESTAMPTZ;
    v_wait  BIGINT := 0;
    v_why   TEXT;
    v_open  BIGINT;
    v_pass  BOOLEAN;
BEGIN
    SELECT * INTO cult FROM player_cultivation WHERE player_id = p_player_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT * INTO was     FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    -- Nothing above, or the next step is only a stage: no sky is owed.
    IF becomes.realm_id IS NULL OR becomes.rank <= was.rank THEN
        RETURN QUERY SELECT FALSE, NULL::smallint, NULL::text, NULL::text,
                            NULL::text, NULL::bigint, FALSE, NULL::bigint,
                            0::bigint, FALSE, NULL::text,
                            NULL::bigint, NULL::bigint;
        RETURN;
    END IF;

    SELECT tb.rank AS at, cs.species_id AS sp, cs.name AS nm, tb.description AS txt,
           cs.base_hp AS hp, cs.base_attack AS atk
    INTO tri
    FROM tribulations tb
    JOIN creature_species cs ON cs.species_id = tb.species_id
    WHERE tb.rank = becomes.rank;

    IF tri.sp IS NULL THEN
        RAISE EXCEPTION 'rank % has no tribulation standing in its door',
            becomes.rank;
    END IF;

    v_pass := tribulation_passed(p_player_id, becomes.rank);

    SELECT pt.battle_id INTO v_open FROM player_tribulations pt
    WHERE pt.player_id = p_player_id AND pt.status = 'facing';

    SELECT max(pt.settled_at) INTO v_last FROM player_tribulations pt
    WHERE pt.player_id = p_player_id AND pt.rank = becomes.rank
      AND pt.status = 'failed';

    IF v_last IS NOT NULL THEN
        v_wait := GREATEST(0, ceil(extract(epoch FROM
            (v_last + make_interval(hours =>
                game_config_value('tribulation_retry_hours')::int)) - now())))::bigint;
    END IF;

    -- The first thing in the way, in the order a player would hit it.
    IF v_pass THEN
        v_why := NULL;
    ELSIF v_open IS NOT NULL THEN
        v_why := 'you are in it';
    ELSIF cult.cultivation < becomes.cultivation_required THEN
        v_why := 'cultivation';
    ELSE
        -- Everything else the door asks for, so nobody spends a tribulation
        -- they were going to be turned away from anyway. The tribulation's own
        -- row is excluded: it is what is being decided, not a prerequisite.
        SELECT g.need INTO v_why
        FROM breakthrough_gate(p_player_id) g
        WHERE NOT g.met AND g.need NOT IN ('Cultivation', 'Heavenly Tribulation')
        ORDER BY g.need LIMIT 1;

        IF v_why IS NULL AND v_wait > 0 THEN
            v_why := 'the sky has not settled';
        END IF;
    END IF;

    RETURN QUERY SELECT
        TRUE, becomes.rank, becomes.name, tri.nm, tri.txt, tri.sp, v_pass,
        v_open, v_wait, (NOT v_pass AND v_why IS NULL), v_why,
        tri.hp, tri.atk;
END;
$$;

COMMENT ON FUNCTION tribulation_standing(BIGINT) IS
    'Everything a screen needs to know about the sky over a cultivator: whether one is owed, what it is, whether it has been survived, and what is in the way if it has not.';


CREATE FUNCTION tribulation_face(p_player_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    here   RECORD;
    fight  BIGINT;
BEGIN
    SELECT * INTO here FROM tribulation_standing(p_player_id);

    IF here IS NULL OR NOT here.owed THEN
        RAISE EXCEPTION
            'no great realm is waiting for you - a stage is crossed with /breakthrough'
            USING ERRCODE = 'check_violation';
    END IF;

    IF here.passed THEN
        RAISE EXCEPTION
            'you have already survived the %. The door is open - /breakthrough',
            here.trial_name
            USING ERRCODE = 'check_violation';
    END IF;

    IF here.facing_battle IS NOT NULL THEN
        RAISE EXCEPTION 'you are already standing in it' USING ERRCODE = 'check_violation';
    END IF;

    IF here.wait_seconds > 0 THEN
        -- Spelled out here rather than handed to a formatter, because this
        -- schema has none and inventing one for a single sentence is a worse
        -- trade than the sentence.
        RAISE EXCEPTION
            'the sky has not settled - about %h % before it looks at you again',
            here.wait_seconds / 3600,
            lpad(((here.wait_seconds % 3600) / 60)::text, 2, '0') || 'm'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT here.may_face THEN
        RAISE EXCEPTION
            'the % is not open to you yet - you are short of %',
            here.trial_name, here.blocked_by
            USING ERRCODE = 'check_violation';
    END IF;

    -- Refuses on its own if the body is spent or another fight is open.
    fight := battle_open(p_player_id, here.species_id);
    UPDATE battles SET kind = 'tribulation' WHERE battle_id = fight;

    INSERT INTO player_tribulations (player_id, rank, battle_id, status)
    VALUES (p_player_id, here.rank, fight, 'facing');

    RETURN fight;
END;
$$;

COMMENT ON FUNCTION tribulation_face(BIGINT) IS
    'Walks into the sky guarding the next great realm. Opens an ordinary battle, which every existing lane already knows how to fight.';


-- ---------------------------------------------------------------------------
-- And it is settled wherever the fight ends
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'battle_conclude';

    IF body IS NULL THEN
        RAISE EXCEPTION 'battle_conclude is missing';
    END IF;

    anchor := '    DELETE FROM player_active_battle WHERE battle_id = p_battle_id;';

    swap := concat(
'    -- A tribulation is settled here rather than in the winning branch,', chr(10),
'    -- because this is the one line every ending passes through. A flight and', chr(10),
'    -- an expiry are failures as surely as a death: looking at heaven and', chr(10),
'    -- walking away is the same information and costs the same wait.', chr(10),
'    UPDATE player_tribulations pt', chr(10),
'    SET status     = CASE WHEN victory THEN ''passed'' ELSE ''failed'' END,', chr(10),
'        settled_at = now()', chr(10),
'    WHERE pt.battle_id = p_battle_id AND pt.status = ''facing'';', chr(10),
'', chr(10),
anchor);

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'battle_conclude no longer closes the active battle once';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- The door reports it, and the door refuses without it
-- ---------------------------------------------------------------------------
--
-- `breakthrough_gate` is the only thing that decides what a crossing asks for,
-- and `breakthrough` reads it. Both halves are patched so they cannot drift -
-- which is the reason that function exists at all.

DO $patch$
DECLARE
    body   TEXT;
    anchor TEXT;
    swap   TEXT;
BEGIN
    -- ---- what the screen shows --------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'breakthrough_gate';

    IF body IS NULL THEN
        RAISE EXCEPTION 'breakthrough_gate is missing';
    END IF;

    -- Before the `realm_gates` lookup on purpose: ranks 10 to 18 have no row
    -- there and the function returns early, so a tribulation announced after
    -- it would be invisible on exactly the crossings that matter most.
    anchor := concat(
'    SELECT * INTO gate FROM realm_gates WHERE rank = becomes.rank;', chr(10),
'    IF NOT FOUND THEN', chr(10),
'        RETURN;', chr(10),
'    END IF;');

    swap := concat(
'    -- The sky, on every great realm crossing. Announced before the',  chr(10),
'    -- `realm_gates` lookup because ranks 10 and up have no row there and',  chr(10),
'    -- this function returns when it finds none.',  chr(10),
'    RETURN QUERY SELECT',  chr(10),
'        ''Heavenly Tribulation''::text,',  chr(10),
'        (SELECT cs.name FROM tribulations tb',  chr(10),
'         JOIN creature_species cs ON cs.species_id = tb.species_id',  chr(10),
'         WHERE tb.rank = becomes.rank),',  chr(10),
'        CASE WHEN tribulation_passed(p_player_id, becomes.rank)',  chr(10),
'             THEN 1 ELSE 0 END::bigint,',  chr(10),
'        1::bigint,',  chr(10),
'        tribulation_passed(p_player_id, becomes.rank);',  chr(10),
'', chr(10),
anchor);

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'breakthrough_gate no longer looks up realm_gates where it did';
    END IF;
    EXECUTE replace(body, anchor, swap);

    -- ---- and what the door does -------------------------------------------
    SELECT pg_get_functiondef(oid) INTO body FROM pg_proc
    WHERE proname = 'breakthrough';

    IF body IS NULL THEN
        RAISE EXCEPTION 'breakthrough is missing';
    END IF;

    -- The shortage scan must stop picking the tribulation up, or it reports
    -- "you are short of Heavenly Tribulation" and, worse, masks a real
    -- shortage it sorts after alphabetically.
    anchor := '        WHERE NOT g.met AND g.need <> ''Cultivation''';
    swap   := '        WHERE NOT g.met AND g.need NOT IN (''Cultivation'', ''Heavenly Tribulation'')';
    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'breakthrough no longer scans the gate for a shortage';
    END IF;
    body := replace(body, anchor, swap);

    -- Checked after the material gates, so nobody is sent to fight for a door
    -- they were going to be turned away from anyway.
    anchor := concat(
'        IF short_of IS NOT NULL THEN', chr(10),
'            RAISE EXCEPTION', chr(10),
'                ''the door to % will not open - you are short of %'',', chr(10),
'                becomes.name, short_of', chr(10),
'                USING ERRCODE = ''check_violation'';', chr(10),
'        END IF;');

    swap := concat(anchor, chr(10),
'', chr(10),
'        -- And the sky. Last, because it is the only one you cannot buy.', chr(10),
'        IF NOT tribulation_passed(p_player_id, becomes.rank) THEN', chr(10),
'            RAISE EXCEPTION', chr(10),
'                ''% has not let you past - face it with /tribulation'',', chr(10),
'                (SELECT cs.name FROM tribulations tb', chr(10),
'                 JOIN creature_species cs ON cs.species_id = tb.species_id', chr(10),
'                 WHERE tb.rank = becomes.rank)', chr(10),
'                USING ERRCODE = ''check_violation'';', chr(10),
'        END IF;');

    IF (length(body) - length(replace(body, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION 'breakthrough no longer refuses a shortage where it did';
    END IF;

    EXECUTE replace(body, anchor, swap);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Seventeen doors, each harder than the last, and every one of them passable
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    r      RECORD;
    v_bad  TEXT;
    v_prev NUMERIC := 0;
BEGIN
    -- Every great realm crossing has something standing in it. A hole here is
    -- a rank that crosses for free while its neighbours do not.
    SELECT string_agg(g.rank::text, ', ') INTO v_bad
    FROM generate_series(2, 18) AS g(rank)
    WHERE NOT EXISTS (SELECT 1 FROM tribulations tb WHERE tb.rank = g.rank);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these great realms have no tribulation: %', v_bad;
    END IF;

    -- It gets harder every single rung, which is the thing that was asked for.
    FOR r IN
        SELECT tb.rank, cs.name, cs.base_hp, cs.base_attack, cs.base_defense,
               boss.base_hp AS boss_hp, boss.base_attack AS boss_atk
        FROM tribulations tb
        JOIN creature_species cs ON cs.species_id = tb.species_id
        JOIN dungeons d ON d.realm_rank = tb.rank - 1
        JOIN creature_species boss ON boss.species_id = d.species_id
        ORDER BY tb.rank
    LOOP
        IF r.base_hp <= v_prev THEN
            RAISE EXCEPTION
                'the tribulation at rank % is no harder than the one below it',
                r.rank;
        END IF;
        v_prev := r.base_hp;

        -- And it is the share of the departing boss it claims to be, rather
        -- than a number that drifted off that curve.
        IF abs(r.base_hp::numeric
               - round(r.boss_hp * game_config_value('tribulation_hp_share')))
           > 1 THEN
            RAISE EXCEPTION
                'rank % is % health against a boss of % - not the share it claims',
                r.rank, r.base_hp, r.boss_hp;
        END IF;
        IF abs(r.base_attack::numeric
               - round(r.boss_atk * game_config_value('tribulation_attack_share')))
           > 1 THEN
            RAISE EXCEPTION 'rank % does not attack for the share it claims', r.rank;
        END IF;

        -- Heaven has no Path, in either direction.
        IF EXISTS (SELECT 1 FROM creature_paths cp
                   JOIN tribulations t2 ON t2.species_id = cp.species_id
                   WHERE t2.rank = r.rank) THEN
            RAISE EXCEPTION 'the tribulation at rank % has a weakness', r.rank;
        END IF;

        -- Nothing falls off it.
        IF EXISTS (SELECT 1 FROM creature_drops cd
                   JOIN tribulations t2 ON t2.species_id = cd.species_id
                   WHERE t2.rank = r.rank) THEN
            RAISE EXCEPTION 'the sky at rank % left a corpse to loot', r.rank;
        END IF;

        -- And something can actually be swung at it: a species with no Path
        -- draws only the pathless moves, and a creature with no move at all
        -- stands there.
        IF roll_creature_intent(
               (SELECT t2.species_id FROM tribulations t2 WHERE t2.rank = r.rank)
           ) IS NULL THEN
            RAISE EXCEPTION 'the tribulation at rank % has no move to make', r.rank;
        END IF;
    END LOOP;

    RAISE NOTICE 'seventeen doors, each harder than the last';
END;
$probe$;


-- ---------------------------------------------------------------------------
-- And it is a fight somebody real can win, lose, and be held back by
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_who   BIGINT;
    v_rank  SMALLINT;
    v_fight BIGINT;
    v_here  RECORD;
    v_act   RECORD;
    v_move  BIGINT;
    v_turns INTEGER := 0;
BEGIN
    -- Somebody standing at a great realm door with the cultivation for it.
    SELECT pc.player_id INTO v_who
    FROM player_cultivation pc
    JOIN realms was ON was.realm_id = pc.realm_id
    JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1
    WHERE nxt.rank > was.rank
    ORDER BY was.rank DESC LIMIT 1;

    IF v_who IS NULL THEN
        RAISE NOTICE 'nobody stands at a great realm door; the tests carry this';
        RETURN;
    END IF;

    BEGIN
        -- Put them at the door with everything else the crossing wants, so
        -- the only thing left in the way is the sky.
        SELECT nxt.rank INTO v_rank
        FROM player_cultivation pc JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1
        WHERE pc.player_id = v_who;

        UPDATE player_cultivation pc
        SET cultivation = (SELECT nxt.cultivation_required FROM realms nxt
                           WHERE nxt.realm_id = pc.realm_id + 1)
        WHERE pc.player_id = v_who;

        PERFORM grant_material(v_who, 'spirit_stone', 1000000);

        -- The door refuses before the sky is faced.
        BEGIN
            PERFORM breakthrough(v_who);
            RAISE EXCEPTION 'the door opened without a tribulation';
        EXCEPTION
            WHEN check_violation THEN
                IF SQLERRM NOT LIKE '%tribulation%' THEN
                    RAISE NOTICE 'held back by something else: %', SQLERRM;
                END IF;
        END;

        -- And the screen says so, in the same words.
        IF EXISTS (SELECT 1 FROM breakthrough_gate(v_who) g
                   WHERE g.need = 'Heavenly Tribulation' AND g.met) THEN
            RAISE EXCEPTION 'the gate says a tribulation was already survived';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM breakthrough_gate(v_who) g
                       WHERE g.need = 'Heavenly Tribulation') THEN
            RAISE EXCEPTION 'the gate does not mention the tribulation at all';
        END IF;

        -- Walk into it.
        DELETE FROM player_active_battle WHERE player_id = v_who;
        UPDATE player_physique SET current_hp = max_hp WHERE player_id = v_who;

        v_fight := tribulation_face(v_who);
        IF (SELECT b.kind FROM battles b WHERE b.battle_id = v_fight)
           <> 'tribulation' THEN
            RAISE EXCEPTION 'the sky opened an ordinary fight';
        END IF;

        -- Fight it out with whatever they actually carry.
        SELECT u.technique_id INTO v_move
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = v_who AND t.category = 'attack'
        ORDER BY t.base_power DESC LIMIT 1;

        v_turns := 0;
        LOOP
            v_turns := v_turns + 1;
            EXIT WHEN v_turns > 200;
            SELECT * INTO v_act FROM battle_act(v_fight,
                CASE WHEN v_move IS NULL THEN 'guard' ELSE 'attack' END, v_move);
            EXIT WHEN v_act.finished;
        END LOOP;

        SELECT * INTO v_here FROM tribulation_standing(v_who);

        IF (SELECT pt.status FROM player_tribulations pt
            WHERE pt.battle_id = v_fight) = 'facing' THEN
            RAISE EXCEPTION 'the fight ended and the sky never settled';
        END IF;

        RAISE NOTICE
            'the tribulation at rank % ran % turns and ended %; the door is now %',
            v_rank, v_turns,
            (SELECT pt.status FROM player_tribulations pt
             WHERE pt.battle_id = v_fight),
            CASE WHEN v_here.passed THEN 'open' ELSE 'still shut' END;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM <> 'probe-ok' THEN
                RAISE;
            END IF;
    END;
END;
$probe$;
