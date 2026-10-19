-- 0521_the_door_above_the_last_realm
--
-- Nothing in the game can move a cultivator above rank 18. `breakthrough`
-- walks `realms` by realm_id + 1 and refuses, and `tribulation_standing`
-- decides a sky is owed by reading that same next row - so at the top of the
-- ladder (realm_id 71, Yellow Apricot Immortal - Peak, with no 72 above it) it
-- reports nothing owed and `tribulation_face` says no great realm is waiting.
--
-- THE TRIBULATION MACHINERY ITSELF IS ALREADY BUILT, which the spec's phase 6
-- did not credit: `tribulations` carries 17 rows for ranks 2 to 18,
-- `tribulation_face` opens the fight, `battle_conclude` settles it either way,
-- and the retry wait is already enforced. So this adds a door and a crossing
-- rather than a system.
--
-- WHY NOT JUST ADD A REALMS ROW. Because `breakthrough` would then walk into
-- it and demand `cultivation_required` from somebody whose meter is
-- understanding - the exact thing the Venerable ranks replace. The two ladders
-- are separate on purpose: `realms` to 18, `venerable_ranks` from 19.
--
-- So the door is SYNTHESISED in `tribulation_standing`: at the top of the
-- realm ladder, with a Dao not yet stamped, the next rank is Venerable Rank 1
-- and its tribulation is owed. Everything downstream - the fight, the retry
-- wait, the settling - then works untouched, because all of it reads
-- `becomes.rank`. Only rank 18's PEAK has a NULL row above it; the middle and
-- late stages still find their next realm, so the door cannot open early.
--
-- AND CULTIVATION IS NOT THE GATE. The spec says rank 19 is "gated on
-- surviving rather than on cultivation alone", so the synthesised door asks
-- for none: standing at the peak of the realm ladder already means having paid
-- every rung of it. What stops you is the sky.
--
-- THE CROSSING IS ITS OWN FUNCTION. `venerable_ascend` requires the
-- tribulation survived, then STAMPS THE DAO - which is what 0490 built
-- `dao_stamp` for and left with no caller but an owner command. Stamping IS
-- the ascension: it freezes the aspects and takes the baseline every later
-- rung is measured from.
--
-- AND STAMPING IS VENERABLE RANK 1. `venerable_rank_of` derived every rung
-- from understanding, which would have left somebody who had just crossed
-- holding zero understanding, meeting no rung, and reading a standing of 18 -
-- they would have ascended into nothing. The tribulation grants the first
-- rung; understanding carries them from the second. One floor, in the one
-- function that decides a rung.
--
-- Forward-only. Do not edit once applied.


ALTER TABLE tribulations DROP CONSTRAINT tribulations_rank_check;
ALTER TABLE tribulations ADD CONSTRAINT tribulations_rank_check
    CHECK (rank >= 2 AND rank <= 27);


-- ---------------------------------------------------------------------------
-- What stands in the door
-- ---------------------------------------------------------------------------

-- Continued off rank 18's own row rather than transcribed: 17 to 18 multiplies
-- the body by 2.10, the attack by 2.06 and the armour by 2.05, and adds 4 to
-- speed. `immortal_rank` sits one below the tribulation's rank throughout, so
-- 19's calamity stands at 18 - a peer of the cultivator facing it, which is
-- what `creature_peer_share` then reads to size its bite.
INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense,
     base_speed, description, traits)
SELECT 'tribulation_19', 'The Sovereign Calamity', 9, 18, 'tribulation',
       round(cs.base_hp      * 2.10)::BIGINT,
       round(cs.base_attack  * 2.06)::BIGINT,
       round(cs.base_defense * 2.05)::BIGINT,
       cs.base_speed + 4,
       'The sky has run out of calamities and sends itself. Everything '
       || 'before this was heaven correcting a cultivator; this is heaven '
       || 'arguing with one.',
       '{}'::JSONB
FROM tribulations tb
JOIN creature_species cs ON cs.species_id = tb.species_id
WHERE tb.rank = 18;

INSERT INTO tribulations (rank, species_id, description)
SELECT 19, cs.species_id,
       'Nothing is asked of your cultivation here - you have spent all of it '
       || 'reaching this door. What is asked is whether the thing you spent '
       || 'it becoming is a thing heaven has to live with.'
FROM creature_species cs WHERE cs.code = 'tribulation_19';


-- ---------------------------------------------------------------------------
-- The door
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src    TEXT;
    anchor TEXT;
BEGIN
    src := pg_get_functiondef('tribulation_standing(bigint)'::regprocedure);

    anchor := '    -- Nothing above, or the next step is only a stage: no sky is owed.';

    IF (length(src) - length(replace(src, anchor, ''))) / length(anchor) <> 1 THEN
        RAISE EXCEPTION
            'the "nothing above" guard in tribulation_standing is not where I left it';
    END IF;

    src := replace(src, anchor,
        '    -- THE VENERABLE DOOR. There is nothing above rank 18 in `realms`' || chr(10) ||
        '    -- on purpose, so the row describing the next rank does not exist' || chr(10) ||
        '    -- and has to be synthesised. At the PEAK of the realm ladder, with' || chr(10) ||
        '    -- a Dao not yet stamped, the next rank is the first Venerable rung.' || chr(10) ||
        '    -- Cultivation is not asked for: standing here already means having' || chr(10) ||
        '    -- paid every rung below. The realm_id is a sentinel - there is no' || chr(10) ||
        '    -- such realm, and `breakthrough` must never find one.' || chr(10) ||
        '    IF becomes.realm_id IS NULL' || chr(10) ||
        '       AND was.rank = (SELECT max(r2.rank) FROM realms r2)' || chr(10) ||
        '       AND NOT EXISTS (SELECT 1 FROM player_dao d' || chr(10) ||
        '                       WHERE d.player_id = p_player_id)' || chr(10) ||
        '    THEN' || chr(10) ||
        '        SELECT -1, v.rank, v.name, 0' || chr(10) ||
        '        INTO becomes.realm_id, becomes.rank, becomes.name,' || chr(10) ||
        '             becomes.cultivation_required' || chr(10) ||
        '        FROM venerable_ranks v WHERE v.venerable_tier = 1;' || chr(10) ||
        '    END IF;' || chr(10) ||
        chr(10) ||
        anchor);

    EXECUTE src;
END;
$patch$;


-- The door-is-open message would have sent a Venerable to `/breakthrough`,
-- which walks `realms` and would tell them there is nothing above them - a
-- dead end at the single most important moment in the game.
DO $patch$
DECLARE
    src   TEXT;
    old   TEXT;
    new   TEXT;
BEGIN
    src := pg_get_functiondef('tribulation_face(bigint)'::regprocedure);

    -- Matched as the message AND its argument together, so the two cannot
    -- drift apart: the replacement supplies both.
    old := '            ''you have already survived the %. The door is open - /breakthrough'','
           || chr(10) || '            here.trial_name';

    new := '            ''you have already survived the %. The door is open - %'','
           || chr(10) || '            here.trial_name,'
           || chr(10) || '            CASE WHEN here.rank > (SELECT max(r2.rank) FROM realms r2)'
           || chr(10) || '                 THEN ''/ascend'' ELSE ''/breakthrough'' END';

    IF (length(src) - length(replace(src, old, ''))) / length(old) <> 1 THEN
        RAISE EXCEPTION
            'the door-is-open message in tribulation_face is not where I left it';
    END IF;

    EXECUTE replace(src, old, new);
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Stamping is the first rung
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION venerable_rank_of(p_player_id BIGINT)
RETURNS SMALLINT
LANGUAGE sql STABLE AS $fn$
    -- The highest rung whose three demands are all met, and never less than
    -- the FIRST rung once a Dao is stamped.
    --
    -- Without that floor somebody who had just crossed the tribulation held
    -- zero understanding, met no rung, read NULL here and stood at 18 to the
    -- rest of the game - they would have ascended into nothing. The
    -- tribulation grants Venerable Rank 1; understanding carries a cultivator
    -- from the second rung up.
    --
    -- Still NULL for anybody unstamped: both halves sit behind the same
    -- EXISTS, and GREATEST of two NULLs is NULL.
    SELECT GREATEST(
        (SELECT max(v.rank)
         FROM venerable_ranks v
         WHERE EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id)
           AND dao_understanding_total(p_player_id) >= v.understanding_required
           AND (SELECT count(*) FROM dao_understanding(p_player_id) u
                WHERE u.understanding >= v.per_aspect_required) >= v.aspects_required),
        (SELECT min(v.rank)
         FROM venerable_ranks v
         WHERE EXISTS (SELECT 1 FROM player_dao WHERE player_id = p_player_id))
    );
$fn$;


-- ---------------------------------------------------------------------------
-- The crossing
-- ---------------------------------------------------------------------------

CREATE FUNCTION venerable_ascend(p_player_id BIGINT)
RETURNS TABLE (dao_name TEXT, venerable_rank SMALLINT, tier SMALLINT,
               title TEXT, aperture_gained SMALLINT, aspects INTEGER)
LANGUAGE plpgsql AS $fn$
DECLARE
    v_door   RECORD;
    v_rung   RECORD;
    v_before SMALLINT;
    v_name   TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM player_dao d WHERE d.player_id = p_player_id) THEN
        RAISE EXCEPTION 'you are already a Venerable'
            USING ERRCODE = 'check_violation';
    END IF;

    -- Read BEFORE the stamp, because stamping shuts this door behind them.
    SELECT * INTO v_door FROM tribulation_standing(p_player_id);

    IF v_door IS NULL OR NOT v_door.owed THEN
        RAISE EXCEPTION
            'the last realm is still above you - there is no Venerable door here'
            USING ERRCODE = 'check_violation';
    END IF;

    IF NOT v_door.passed THEN
        RAISE EXCEPTION
            'the % has not been survived - /tribulation', v_door.trial_name
            USING ERRCODE = 'check_violation';
    END IF;

    v_before := gu_capacity_of(p_player_id);

    -- The ascension IS the stamp: it freezes the aspects and takes the
    -- baseline every rung after this is measured from.
    v_name := dao_stamp(p_player_id);

    SELECT v.rank AS rk, v.venerable_tier AS tr, v.name AS nm
    INTO v_rung
    FROM venerable_ranks v WHERE v.rank = venerable_rank_of(p_player_id);

    IF v_rung.rk IS NULL THEN
        RAISE EXCEPTION
            'the Dao stamped but no rung took them - venerable_rank_of read %',
            venerable_rank_of(p_player_id);
    END IF;

    RETURN QUERY SELECT
        v_name, v_rung.rk, v_rung.tr, v_rung.nm,
        (gu_capacity_of(p_player_id) - v_before)::SMALLINT,
        (SELECT count(*)::INTEGER FROM player_dao_aspects a
         WHERE a.player_id = p_player_id);
END;
$fn$;

COMMENT ON FUNCTION venerable_ascend(BIGINT) IS
    'Cross from the top of the realm ladder onto the Venerable one. Requires the rank 19 tribulation survived; stamps the Dao, which is what makes the crossing permanent and what every later rung is measured against. Not `breakthrough`, because that walks `realms` and would demand cultivation from somebody whose meter is understanding.';


-- ---------------------------------------------------------------------------
-- Walk somebody through the door
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_pid   BIGINT;
    v_door  RECORD;
    v_cross RECORD;
    v_path  TEXT;
    v_n     INTEGER;
BEGIN
    -- The calamity stands above the one below it, on every axis.
    IF EXISTS (
        SELECT 1
        FROM (SELECT cs.* FROM tribulations tb JOIN creature_species cs USING (species_id)
              WHERE tb.rank = 19) nw
        CROSS JOIN (SELECT cs.* FROM tribulations tb JOIN creature_species cs USING (species_id)
                    WHERE tb.rank = 18) od
        WHERE nw.base_hp <= od.base_hp OR nw.base_attack <= od.base_attack
           OR nw.base_defense <= od.base_defense OR nw.base_speed <= od.base_speed
           OR nw.immortal_rank <= od.immortal_rank) THEN
        RAISE EXCEPTION 'the rank 19 calamity is not above the rank 18 one';
    END IF;

    -- And the ladder of tribulations has no hole in it.
    SELECT count(*) INTO v_n FROM generate_series(2, 19) g
    WHERE NOT EXISTS (SELECT 1 FROM tribulations WHERE rank = g);
    IF v_n > 0 THEN
        RAISE EXCEPTION '% ranks between 2 and 19 have no tribulation', v_n;
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;

    BEGIN
        -- Somebody at the very peak of the realm ladder.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-999, 'ascend-probe') RETURNING player_id INTO v_pid;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_pid, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id)
        VALUES (v_pid, (SELECT min(physique_id) FROM physiques));
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_pid, v_path, 90000, 5);

        -- 1. THE DOOR EXISTS NOW. Before this migration it reported nothing.
        SELECT * INTO v_door FROM tribulation_standing(v_pid);
        IF v_door IS NULL OR NOT v_door.owed THEN
            RAISE EXCEPTION 'no door above the last realm';
        END IF;
        IF v_door.rank <> 19 THEN
            RAISE EXCEPTION 'the door above rank 18 leads to rank %', v_door.rank;
        END IF;
        IF v_door.trial_name IS NULL OR v_door.species_id IS NULL THEN
            RAISE EXCEPTION 'the door has nothing standing in it';
        END IF;
        IF v_door.trial_hp IS NULL OR v_door.trial_hp < 1 THEN
            RAISE EXCEPTION 'the door reports no body to cut';
        END IF;

        -- Cultivation is not what stops them - it is the meter rank 19
        -- replaces, and they have already paid all of it.
        IF v_door.blocked_by = 'cultivation' THEN
            RAISE EXCEPTION
                'the Venerable door asks for cultivation, which is the meter it replaces';
        END IF;

        -- 2. CROSSING IS REFUSED UNTIL THE SKY IS SURVIVED.
        BEGIN
            PERFORM venerable_ascend(v_pid);
            RAISE EXCEPTION 'crossed without facing anything';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%has not been survived%' THEN RAISE; END IF;
        END;

        -- 3. SURVIVE IT, and cross.
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_pid, 19, 'passed', now());

        -- The message that used to send them to /breakthrough, which walks
        -- `realms` and would have told them nothing is above them.
        BEGIN
            PERFORM tribulation_face(v_pid);
            RAISE EXCEPTION 'faced a tribulation already survived';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%/ascend%' THEN
                RAISE EXCEPTION
                    'a survived Venerable tribulation still says: %', SQLERRM;
            END IF;
        END;

        SELECT * INTO v_cross FROM venerable_ascend(v_pid);

        IF v_cross.dao_name IS NULL OR v_cross.dao_name = '' THEN
            RAISE EXCEPTION 'crossed without a Dao';
        END IF;
        IF v_cross.venerable_rank <> 19 OR v_cross.tier <> 1 THEN
            RAISE EXCEPTION
                'crossed into rank % tier %, wanted 19 and 1',
                v_cross.venerable_rank, v_cross.tier;
        END IF;
        IF v_cross.aspects < 1 THEN
            RAISE EXCEPTION 'a stamped Dao has no aspects';
        END IF;

        -- 4. AND THE WHOLE GAME NOW SEES THEM ABOVE 18.
        IF player_standing(v_pid) <> 19 THEN
            RAISE EXCEPTION
                'a Venerable stands at % to the rest of the game',
                player_standing(v_pid);
        END IF;
        IF v_cross.aperture_gained <= 0 THEN
            RAISE EXCEPTION 'crossing granted no aperture';
        END IF;
        IF gu_capacity_of(v_pid)
           <= (SELECT r.gu_capacity FROM realms r
               WHERE r.rank = 18 AND r.stage = 'peak') THEN
            RAISE EXCEPTION
                'a Venerable carries % aperture, no more than the rank 18 they were',
                gu_capacity_of(v_pid);
        END IF;
        -- The lid 0519 moved onto standing actually rises, which is the whole
        -- reason that sweep happened.
        IF gu_effect_cap('crit_damage', v_pid)
           <= (SELECT GREATEST(e.cap, e.cap_per_rank * 18)
               FROM gu_effects e WHERE e.code = 'crit_damage') THEN
            RAISE EXCEPTION 'a Venerable''s crit lid is still frozen at rank 18';
        END IF;

        -- 5. And they cannot cross twice.
        BEGIN
            PERFORM venerable_ascend(v_pid);
            RAISE EXCEPTION 'crossed twice';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%already a Venerable%' THEN RAISE; END IF;
        END;

        -- 6. The door is shut behind them rather than offering itself again,
        -- so /tribulation does not ask them to fight the same sky for ever.
        SELECT * INTO v_door FROM tribulation_standing(v_pid);
        IF v_door.owed THEN
            RAISE EXCEPTION 'the Venerable door is still open to a Venerable';
        END IF;

        RAISE NOTICE
            'crossed as % into % (V%) with % aperture and % aspects',
            v_cross.dao_name, v_cross.title, v_cross.tier,
            gu_capacity_of(v_pid), v_cross.aspects;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody living was ascended by this migration.
    IF EXISTS (SELECT 1 FROM player_dao) THEN
        RAISE EXCEPTION 'somebody was ascended by this migration';
    END IF;

    SELECT count(*) INTO v_n
    FROM players p
    WHERE p.deleted_at IS NULL
      AND EXISTS (SELECT 1 FROM tribulation_standing(p.player_id) s
                  WHERE s.owed AND s.rank = 19);
    RAISE NOTICE '% cultivators now have the Venerable door open to them', v_n;
END;
$probe$;
