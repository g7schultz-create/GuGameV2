-- 0540_a_room_may_hold_more_than_one_thing
--
-- Phase 3, first half. "No longer quite a horde but a few very strong monsters
-- that require teamwork."
--
-- A dungeon run holds exactly one creature today: `dungeons.species_id`, and
-- `dungeon_runs.boss_hp` as its pool. Every raider swings at that pool and it
-- answers once a round. Three things make a room of several foes a different
-- fight - who to focus, who answers, and who is left standing - and none of
-- them can exist against a single number.
--
-- THE TABLES GO IN FIRST AND CHANGE NOTHING. The round loop is 201 lines and
-- rewriting it is the risky half, so this migration only records what is in a
-- room and proves the recording is faithful. `dungeon_resolve_round` still
-- reads `boss_hp` and behaves exactly as it did; the next migration moves it
-- onto the foes.
--
-- EVERY EXISTING ROOM IS A LINEUP OF ONE. That is the safety property the
-- whole design rests on: eighteen rooms keep one boss, so the loop that is
-- written next cannot change them even in principle. Only the Vault has
-- three.
--
-- AND `boss_hp` STAYS THE ROOM'S TOTAL rather than being replaced. The bot
-- draws a bar from it, `dungeon_run_state` exposes it, `dungeon_begin` returns
-- it and the winning condition is `pool <= 0`. Keeping it as the sum of what
-- is still standing means all of that keeps working and keeps meaning the
-- same thing - how much room is left.
--
-- THE SHARE IS NOT A THIRD EACH. Three foes dividing one pool would be the
-- same fight with more bars. `dungeon_foe_lineups.hp_share` is what each one
-- is worth relative to the room, and the Vault's three sum to 1.60 - so a
-- room of three is 60% more health than a room of one, which is what makes a
-- party necessary rather than decorative. 0497's rehearsal still decides what
-- the room is worth in total, measured against the party that walked in.
--
-- Forward-only. Do not edit once applied.


CREATE TABLE dungeon_foe_lineups (
    dungeon_id  SMALLINT NOT NULL REFERENCES dungeons(dungeon_id) ON DELETE CASCADE,
    foe_no      SMALLINT NOT NULL,
    species_id  BIGINT   NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    hp_share    NUMERIC(4,2) NOT NULL,
    PRIMARY KEY (dungeon_id, foe_no),
    CONSTRAINT dungeon_foe_lineups_foe_no_check CHECK (foe_no >= 0 AND foe_no <= 5),
    CONSTRAINT dungeon_foe_lineups_share_check  CHECK (hp_share > 0 AND hp_share <= 2)
);

CREATE INDEX dungeon_foe_lineups_species_idx ON dungeon_foe_lineups (species_id);

COMMENT ON TABLE dungeon_foe_lineups IS
    'What stands in a room. One row per room for the eighteen that hold a single boss; several for a room that holds a few. hp_share is what each foe is worth against the room''s rehearsed pool, and the shares deliberately sum to MORE than 1 for a crowded room - three foes dividing one pool would be the same fight with more bars.';

COMMENT ON COLUMN dungeon_foe_lineups.foe_no IS
    'Position in the room, 0 upward. What a raider names when they choose a target.';


CREATE TABLE dungeon_foes (
    run_id      BIGINT   NOT NULL REFERENCES dungeon_runs(run_id) ON DELETE CASCADE,
    foe_no      SMALLINT NOT NULL,
    species_id  BIGINT   NOT NULL REFERENCES creature_species(species_id) ON DELETE RESTRICT,
    max_hp      BIGINT   NOT NULL,
    current_hp  BIGINT   NOT NULL,
    felled_at   TIMESTAMPTZ,
    PRIMARY KEY (run_id, foe_no),
    CONSTRAINT dungeon_foes_max_hp_check CHECK (max_hp > 0),
    CONSTRAINT dungeon_foes_hp_in_range  CHECK (current_hp >= 0 AND current_hp <= max_hp),
    CONSTRAINT dungeon_foes_felled_when_down
        CHECK ((current_hp = 0) = (felled_at IS NOT NULL))
);

CREATE INDEX dungeon_foes_species_idx ON dungeon_foes (species_id);
CREATE INDEX dungeon_foes_standing_idx ON dungeon_foes (run_id) WHERE current_hp > 0;

COMMENT ON TABLE dungeon_foes IS
    'What is still standing in a run, and on how much. `dungeon_runs.boss_hp` is kept as the SUM of these so every existing reader - the bot''s bar, dungeon_run_state, the pool <= 0 that wins the room - keeps working and keeps meaning "how much room is left".';


-- ---------------------------------------------------------------------------
-- Every room that exists, as a lineup
-- ---------------------------------------------------------------------------

-- The eighteen below rank 19 hold exactly what they always held.
INSERT INTO dungeon_foe_lineups (dungeon_id, foe_no, species_id, hp_share)
SELECT dg.dungeon_id, 0, dg.species_id, 1.00
FROM dungeons dg
WHERE dg.code <> 'vault_of_unclaimed_dao';


-- And the Vault holds three. The Dao that outlived its master, and the two
-- that have been keeping it company - a room where focusing one thing down
-- and a room where spreading the damage are different decisions.
INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense,
     base_speed, description, traits)
VALUES
    ('dao_of_the_unnamed_heir', 'The Dao of the Unnamed Heir',
     9, 19, 'dungeon',
     1900000000000, 780000000, 820000000, 104,
     'Somebody was meant to inherit this. It has spent four hundred years '
     || 'deciding that anybody will do, and it is not fussy about consent.',
     '{}'::JSONB),
    ('dao_that_forgot_its_name', 'The Dao That Forgot Its Name',
     9, 19, 'dungeon',
     1500000000000, 1060000000, 540000000, 88,
     'It still knows how to kill. That is usually the last thing to go.',
     '{}'::JSONB);

INSERT INTO dungeon_foe_lineups (dungeon_id, foe_no, species_id, hp_share)
SELECT dg.dungeon_id, x.foe_no, cs.species_id, x.share
FROM dungeons dg
CROSS JOIN (VALUES
    -- The room's own name, and the heaviest of the three.
    (0::SMALLINT, 'dao_that_outlived_its_master', 0.70::NUMERIC),
    (1::SMALLINT, 'dao_of_the_unnamed_heir',      0.50::NUMERIC),
    -- Lightest, hits hardest. The one a party should probably kill first,
    -- which is a decision rather than a rule.
    (2::SMALLINT, 'dao_that_forgot_its_name',     0.40::NUMERIC)
) AS x(foe_no, code, share)
JOIN creature_species cs ON cs.code = x.code
WHERE dg.code = 'vault_of_unclaimed_dao';


-- ---------------------------------------------------------------------------
-- Rolling a lineup out for a run
-- ---------------------------------------------------------------------------

CREATE FUNCTION dungeon_set_the_room(p_run_id BIGINT, p_pool BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql AS $fn$
DECLARE
    v_total BIGINT;
BEGIN
    DELETE FROM dungeon_foes WHERE run_id = p_run_id;

    -- Each foe's share of the pool 0497's rehearsal measured against the
    -- party that actually walked in. GREATEST(1, ...) because a share of a
    -- tiny pool must still be a creature rather than a corpse.
    INSERT INTO dungeon_foes (run_id, foe_no, species_id, max_hp, current_hp)
    SELECT p_run_id, l.foe_no, l.species_id,
           GREATEST(1, round(p_pool * l.hp_share))::bigint,
           GREATEST(1, round(p_pool * l.hp_share))::bigint
    FROM dungeon_runs r
    JOIN dungeon_foe_lineups l ON l.dungeon_id = r.dungeon_id
    WHERE r.run_id = p_run_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'run % is in a room with nothing written in it', p_run_id;
    END IF;

    SELECT sum(f.max_hp) INTO v_total
    FROM dungeon_foes f WHERE f.run_id = p_run_id;

    RETURN v_total;
END;
$fn$;

COMMENT ON FUNCTION dungeon_set_the_room(BIGINT, BIGINT) IS
    'Stand the room''s lineup up against a rehearsed pool, and return what the room is worth in total - which is what `dungeon_runs.boss_hp` is kept at.';


-- ---------------------------------------------------------------------------
-- `dungeon_begin` stands them up
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('dungeon_begin(bigint,bigint)'::regprocedure);

    one := '    UPDATE dungeon_runs r' || chr(10) ||
           '    SET status = ''fighting'',' || chr(10) ||
           '        boss_max_hp = pool,' || chr(10) ||
           '        boss_hp = pool,';

    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION 'the pool is not set in dungeon_begin where I read it';
    END IF;

    src := replace(src, one,
        '    -- The room''s lineup, against the pool 0497 rehearsed. For the' || chr(10) ||
        '    -- eighteen rooms that hold one boss this is one foe at the whole' || chr(10) ||
        '    -- pool and nothing changes; a crowded room comes out worth more' || chr(10) ||
        '    -- than the pool, because its shares sum past 1.' || chr(10) ||
        '    pool := dungeon_set_the_room(p_run_id, pool);' || chr(10) ||
        chr(10) ||
        one);

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Every room still holds what it held, and the Vault holds three
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_bad   TEXT;
    v_ven   BIGINT;
    v_path  TEXT;
    v_dg    SMALLINT;
    v_run   BIGINT;
    v_diff  TEXT;
    v_pool  BIGINT;
    v_foes  INTEGER;
    v_sum   BIGINT;
BEGIN
    -- 1. EVERY ROOM HAS A LINEUP, or a run in it would stand nothing up.
    SELECT string_agg(dg.code, ', ') INTO v_bad
    FROM dungeons dg
    WHERE NOT EXISTS (SELECT 1 FROM dungeon_foe_lineups l
                      WHERE l.dungeon_id = dg.dungeon_id);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these rooms hold nothing: %', v_bad;
    END IF;

    -- 2. AND EVERY LINEUP STILL LEADS WITH THE ROOM'S OWN BOSS at foe 0, so
    -- `dungeon_run_state.boss_name` and the rehearsal both still describe the
    -- thing the room is named for.
    SELECT string_agg(dg.code, ', ') INTO v_bad
    FROM dungeons dg
    JOIN dungeon_foe_lineups l
      ON l.dungeon_id = dg.dungeon_id AND l.foe_no = 0
    WHERE l.species_id <> dg.species_id;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION
            'these rooms lead with something other than their own boss: %', v_bad;
    END IF;

    -- 3. THE EIGHTEEN OLD ROOMS ARE A LINEUP OF ONE, AT THE WHOLE POOL. This
    -- is the property that makes the next migration safe.
    SELECT string_agg(dg.code || ' (' || x.n || ' foes, share ' || x.s || ')', ', ')
    INTO v_bad
    FROM dungeons dg
    CROSS JOIN LATERAL (
        SELECT count(*) AS n, sum(l.hp_share) AS s
        FROM dungeon_foe_lineups l WHERE l.dungeon_id = dg.dungeon_id) x
    WHERE dg.realm_rank <= 18 AND (x.n <> 1 OR x.s <> 1.00);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'these old rooms changed: %', v_bad;
    END IF;

    -- 4. And the Vault is a crowd worth more than one boss.
    SELECT count(*), sum(l.hp_share) INTO v_foes, v_sum
    FROM dungeon_foe_lineups l
    JOIN dungeons dg ON dg.dungeon_id = l.dungeon_id
    WHERE dg.code = 'vault_of_unclaimed_dao';
    IF v_foes <> 3 THEN
        RAISE EXCEPTION 'the Vault holds % things, not three', v_foes;
    END IF;
    IF v_sum <= 1.00 THEN
        RAISE EXCEPTION
            'the Vault''s three share % of a room - a crowd must be worth more than one boss',
            v_sum;
    END IF;

    -- 5. AND A RUN STANDS THEM UP. Driven through `dungeon_begin`, because a
    -- lineup nothing reads is a table and not a room.
    SELECT dungeon_id INTO v_dg FROM dungeons WHERE code = 'vault_of_unclaimed_dao';
    SELECT code INTO v_diff FROM dungeon_difficulties ORDER BY sort_order LIMIT 1;
    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-972, 'room-probe') RETURNING player_id INTO v_ven;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_ven, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_ven, (SELECT min(physique_id) FROM physiques),
                1000000000000, 1000000000000);
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_ven, v_path, 90000, 5);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_ven, t.technique_id FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1;
        PERFORM grant_material(v_ven, 'spirit_stone', 20000000000);
        PERFORM grant_material(v_ven, 'dungeon_key', 1);
        PERFORM grant_jade(v_ven, 500, 'room probe');
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_ven, 19, 'passed', now());
        PERFORM venerable_ascend(v_ven);

        v_run := dungeon_open(v_ven, v_dg, v_diff);
        PERFORM dungeon_begin(v_run, v_ven);

        SELECT count(*), sum(f.max_hp) INTO v_foes, v_sum
        FROM dungeon_foes f WHERE f.run_id = v_run;
        SELECT boss_hp INTO v_pool FROM dungeon_runs WHERE run_id = v_run;

        IF v_foes <> 3 THEN
            RAISE EXCEPTION 'the run stood up % foes, not three', v_foes;
        END IF;
        IF v_pool <> v_sum THEN
            RAISE EXCEPTION
                'the room reports % health against % standing in it',
                v_pool, v_sum;
        END IF;
        IF EXISTS (SELECT 1 FROM dungeon_foes f
                   WHERE f.run_id = v_run AND f.current_hp <> f.max_hp) THEN
            RAISE EXCEPTION 'something walked in already wounded';
        END IF;

        RAISE NOTICE
            'the Vault stood up % foes worth % together', v_foes, v_sum;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- 6. AND AN OLD ROOM STANDS UP EXACTLY ONE, on the whole pool.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-971, 'old-room-probe') RETURNING player_id INTO v_ven;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_ven, r.realm_id, r.cultivation_required
        FROM realms r WHERE r.rank = 4 ORDER BY r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_ven, (SELECT min(physique_id) FROM physiques), 50000, 50000);
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_ven, t.technique_id FROM techniques t
        WHERE t.base_power > 0 AND t.rank = 1 ORDER BY t.base_power LIMIT 1;
        PERFORM grant_material(v_ven, 'spirit_stone', 90000000);
        PERFORM grant_material(v_ven, 'dungeon_key', 1);
        PERFORM grant_jade(v_ven, 100, 'room probe');

        SELECT dungeon_id INTO v_dg FROM dungeons WHERE realm_rank = 4;
        v_run := dungeon_open(v_ven, v_dg, v_diff);
        PERFORM dungeon_begin(v_run, v_ven);

        SELECT count(*) INTO v_foes FROM dungeon_foes f WHERE f.run_id = v_run;
        IF v_foes <> 1 THEN
            RAISE EXCEPTION
                'a rank 4 room stood up % things, not one', v_foes;
        END IF;
        IF (SELECT f.max_hp FROM dungeon_foes f WHERE f.run_id = v_run)
           <> (SELECT r.boss_hp FROM dungeon_runs r WHERE r.run_id = v_run) THEN
            RAISE EXCEPTION
                'the one boss in an old room is not worth the whole room';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nothing leaked, and no live run was touched - the table is new, so any
    -- row in it came from a probe.
    IF EXISTS (SELECT 1 FROM dungeon_foes) THEN
        RAISE EXCEPTION 'a probe run survived the migration';
    END IF;

    RAISE NOTICE
        'nineteen rooms have a lineup; eighteen hold one thing and the Vault holds three';
END;
$probe$;
