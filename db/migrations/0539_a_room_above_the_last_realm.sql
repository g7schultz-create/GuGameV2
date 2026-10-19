-- 0539_a_room_above_the_last_realm
--
-- Phase 2: the raid a Venerable opens. Eighteen rooms exist, one per rank,
-- ending at The Last Apricot - and until 0536 nothing above 18 could even be
-- written down, because `dungeons_realm_rank_check` stopped there and
-- `dungeon_open` read the realm instead of standing.
--
-- WHAT THIS REUSES RATHER THAN BUILDS. The dungeon already is most of what
-- was asked for: a leader opens it, invites, raiders pay a stake and join,
-- and the fight runs in ROUNDS WITH SIMULTANEOUS HIDDEN INTENTS
-- (`intent_id`, `chose_at`, `round_ends_at`, `still_choosing`). The boss
-- scales with party size through `dungeon_party_hp_step`, and since 0497
-- `dungeon_rehearse` sizes it by running the real party through
-- `player_swing` rather than trusting a formula - so a rank 19 room cannot be
-- mis-tuned the way flat numbers were. None of that is touched.
--
-- VENERABLE-LED, ANYONE MAY JOIN, which is already how the dungeon works and
-- its own comment says so: "The leader only: `dungeon_join` stays open so a
-- deep cultivator can bring shallower friends, which is the whole point of
-- the only group content in the game." At `realm_rank 19` and
-- `dungeon_realm_reach` 0, only somebody standing at 19 can open the door.
--
-- ITS OWN BOSS, not the region's. `longevity_heaven_warden` is the Heavenly
-- Court's WORLD boss - it rises on a timer, it is claimed through
-- `claim_boss_reward`, and 0512 gave it a crown. A dungeon pointing at the
-- same species would have two systems felling one creature and disagreeing
-- about what that means.
--
-- AND THE FICTION HAS TO CARRY THE BETRAYAL that comes in phase 4. A room
-- full of what dead Venerables left behind is a reason to go in together and
-- a reason to put a knife in somebody on the way out. The loot is the point,
-- which is exactly the pressure the backstab needs.
--
-- The stake is continued off the ladder rather than chosen: the last four
-- rungs grow 2.59, 2.55, 2.50, 2.57 times, so 19 is 3.6e9 x 2.55. Jade has
-- gone up 5 or 6 a rung and goes up 6.
--
-- Forward-only. Do not edit once applied.


INSERT INTO creature_species
    (code, name, rank, immortal_rank, kind, base_hp, base_attack, base_defense,
     base_speed, description, traits)
VALUES
    ('dao_that_outlived_its_master', 'The Dao That Outlived Its Master',
     9, 19, 'dungeon',
     -- Between the Court's Warden (2.25e12) and twice it. The figure matters
     -- less than it looks: `dungeon_boss_pool` resizes against whoever
     -- actually walked in.
     3200000000000, 940000000, 1150000000, 96,
     'Its cultivator is nine hundred years dead and it never noticed. A Dao '
     || 'does not need you once it knows what it is - it only needs somewhere '
     || 'to keep happening, and this vault has been somewhere for a long time.',
     '{}'::JSONB);


-- `dungeon_id` is a hand-assigned smallint rather than an identity, and the
-- eighteen rooms happen to be numbered by their rank. Continued off the max
-- rather than written as 19, so this is right whichever way the ladder grows.
INSERT INTO dungeons
    (dungeon_id, code, name, realm_rank, species_id, stone_cost, jade_cost,
     description)
SELECT (SELECT max(d2.dungeon_id) + 1 FROM dungeons d2),
       'vault_of_unclaimed_dao', 'The Vault of Unclaimed Dao', 19,
       cs.species_id, 9200000000, 48,
       'Every Venerable who died with nobody to inherit them left their Dao '
       || 'here, still turning. The ones that outlived their masters have had '
       || 'centuries to decide what they are. Bring people you trust, and '
       || 'remember that they were told the same.'
FROM creature_species cs WHERE cs.code = 'dao_that_outlived_its_master';


-- ---------------------------------------------------------------------------
-- Open it with a Venerable, and refuse everybody else
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_ven   BIGINT;
    v_peak  BIGINT;
    v_small BIGINT;
    v_path  TEXT;
    v_dg    SMALLINT;
    v_run   BIGINT;
    v_hp    BIGINT;
    v_diff  TEXT;
BEGIN
    SELECT dungeon_id INTO v_dg FROM dungeons
    WHERE code = 'vault_of_unclaimed_dao';
    IF v_dg IS NULL THEN
        RAISE EXCEPTION 'the room was not written down';
    END IF;

    -- The ladder has no hole in it and no rung twice.
    IF (SELECT count(DISTINCT realm_rank) FROM dungeons) <> 19
       OR (SELECT count(*) FROM dungeons) <> 19 THEN
        RAISE EXCEPTION
            'the dungeon ladder is % rooms across % ranks, wanted 19 of each',
            (SELECT count(*) FROM dungeons),
            (SELECT count(DISTINCT realm_rank) FROM dungeons);
    END IF;

    -- Its own boss, so two systems are not felling one creature. There is no
    -- `world_bosses` table - a world boss is a `creature_species` of kind
    -- 'world' that `boss_encounters` raises on a timer.
    IF (SELECT cs.kind FROM dungeons dg
        JOIN creature_species cs ON cs.species_id = dg.species_id
        WHERE dg.dungeon_id = v_dg) <> 'dungeon' THEN
        RAISE EXCEPTION
            'the raid points at a % rather than its own dungeon creature',
            (SELECT cs.kind FROM dungeons dg
             JOIN creature_species cs ON cs.species_id = dg.species_id
             WHERE dg.dungeon_id = v_dg);
    END IF;
    IF EXISTS (
        SELECT 1 FROM boss_encounters be
        JOIN dungeons dg ON dg.species_id = be.species_id
        WHERE dg.dungeon_id = v_dg
    ) THEN
        RAISE EXCEPTION 'the raid boss also rises as a world boss';
    END IF;

    SELECT dw.source_code INTO v_path FROM dao_words dw
    WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1;
    SELECT code INTO v_diff FROM dungeon_difficulties ORDER BY sort_order LIMIT 1;

    BEGIN
        -- Somebody at the peak of the realm ladder, and the same cultivator
        -- again after ascending - so the only difference is what the game
        -- thinks they are.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-974, 'raid-peak') RETURNING player_id INTO v_peak;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_peak, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_peak, (SELECT min(physique_id) FROM physiques),
                1000000000000, 1000000000000);
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (v_peak, v_path, 90000, 5);
        PERFORM grant_material(v_peak, 'spirit_stone', 20000000000);
        PERFORM grant_jade(v_peak, 500, 'raid probe');
        -- `dungeon_begin` refuses a party with anybody who cannot attack,
        -- because spoils are split by damage and somebody who deals none
        -- would have bought the run for everybody else.
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_peak, t.technique_id FROM techniques t
        WHERE t.base_power > 0 ORDER BY t.base_power DESC LIMIT 1
        ON CONFLICT DO NOTHING;

        -- 1. A RANK 18 CULTIVATOR CANNOT OPEN IT. `dungeon_realm_reach` is 0,
        -- so the peak of the realm ladder is one short.
        BEGIN
            PERFORM dungeon_open(v_peak, v_dg, v_diff);
            RAISE EXCEPTION 'the peak of rank 18 opened a Venerable room';
        EXCEPTION WHEN check_violation THEN
            IF SQLERRM NOT LIKE '%realm you have not reached%' THEN RAISE; END IF;
        END;

        -- 2. ASCEND, AND THE DOOR OPENS. Same cultivator, same stones.
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        VALUES (v_peak, 19, 'passed', now());
        PERFORM venerable_ascend(v_peak);
        v_ven := v_peak;

        v_run := dungeon_open(v_ven, v_dg, v_diff);
        IF v_run IS NULL THEN
            RAISE EXCEPTION 'a Venerable could not open the room either';
        END IF;

        -- 3. AND ANYONE MAY JOIN. A cultivator who could never open it.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-973, 'raid-small') RETURNING player_id INTO v_small;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_small, r.realm_id, 0 FROM realms r
        ORDER BY r.rank, r.realm_id LIMIT 1;
        INSERT INTO player_physique (player_id, physique_id, max_hp, current_hp)
        VALUES (v_small, (SELECT min(physique_id) FROM physiques), 100000, 100000);
        PERFORM grant_material(v_small, 'spirit_stone', 20000000000);
        PERFORM grant_jade(v_small, 500, 'raid probe');
        -- The weakest attack in the game, which is all a rank 1 cultivator
        -- can hold - and enough to be let in.
        INSERT INTO player_techniques (player_id, technique_id)
        SELECT v_small, t.technique_id FROM techniques t
        WHERE t.base_power > 0 AND t.rank = 1
        ORDER BY t.base_power LIMIT 1
        ON CONFLICT DO NOTHING;

        PERFORM dungeon_invite(v_run, v_ven, v_small);
        PERFORM dungeon_join(v_run, v_small);

        IF (SELECT count(*) FROM dungeon_raiders WHERE run_id = v_run) <> 2 THEN
            RAISE EXCEPTION
                'the party is % raiders, so a shallow cultivator was turned away',
                (SELECT count(*) FROM dungeon_raiders WHERE run_id = v_run);
        END IF;

        -- 4. AND THE FIGHT STARTS, sized against the party that actually
        -- walked in rather than off the species sheet - which is what 0497
        -- built `dungeon_rehearse` for.
        -- A key each, which is what `dungeon_begin` spends to start a run.
        PERFORM grant_material(v_ven, 'dungeon_key', 1);
        PERFORM grant_material(v_small, 'dungeon_key', 1);

        PERFORM dungeon_begin(v_run, v_ven);

        SELECT boss_hp INTO v_hp FROM dungeon_run_state WHERE run_id = v_run;
        IF COALESCE(v_hp, 0) <= 0 THEN
            RAISE EXCEPTION 'the room has nothing standing in it';
        END IF;
        IF (SELECT status FROM dungeon_runs WHERE run_id = v_run) <> 'fighting' THEN
            RAISE EXCEPTION
                'the run is % rather than fighting',
                (SELECT status FROM dungeon_runs WHERE run_id = v_run);
        END IF;

        RAISE NOTICE
            'two raiders in the Vault against % health', v_hp;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- Nobody living can open it yet, which is the honest state: no Dao is
    -- stamped, so nobody stands at 19.
    IF EXISTS (
        SELECT 1 FROM players p WHERE p.deleted_at IS NULL
          AND player_standing(p.player_id) >= 19
    ) THEN
        RAISE EXCEPTION 'somebody already stands at 19 and should not';
    END IF;

    RAISE NOTICE
        'the Vault of Unclaimed Dao is rank 19; % cultivators are one tribulation from it',
        (SELECT count(*) FROM players p
         WHERE p.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM tribulation_standing(p.player_id) s
                       WHERE s.owed AND s.rank = 19 AND s.may_face));
END;
$probe$;
