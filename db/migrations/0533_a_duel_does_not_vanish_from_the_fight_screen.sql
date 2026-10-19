-- 0533_a_duel_does_not_vanish_from_the_fight_screen
--
-- The last two readers in the battle path that assume the thing opposite a
-- cultivator is a creature. Both were found by audit rather than by a fight,
-- which is the only reason they are being fixed before anybody can start a
-- duel instead of after.
--
-- 1. `battle_overview` INNER JOINS `creature_species` on the far combatant's
--    `species_id`. In a duel that column is NULL, so the join matches nothing
--    and THE WHOLE FIGHT DISAPPEARS from the screen - no error, no row, just
--    a battle that exists in `battles` and cannot be looked at. The classic
--    shape of this codebase's recurring fault: a guard moved and a reader did
--    not.
--
-- 2. `battle_conclude` writes the fight's damage back to the body for
--    combatant 0 and only combatant 0:
--
--        WHERE pp.player_id = me.player_id
--
--    which is right for every creature fight, because side 1 has never been a
--    person. In a duel it means THE LOSER WALKS AWAY UNHURT - the whole fight
--    happens to a row in `battle_combatants` and nothing reaches their body.
--
-- AND THE CREATURE SPOILS ARE GUARDED rather than left to produce NULLs. The
-- victory branch looks a species up, counts a bestiary entry, reads
-- `species.kind` and walks `creature_drops`; with a NULL species most of that
-- quietly does nothing, but the purse and bounty arithmetic runs on
-- `species.rank` and would carry NULL into a reward. A duel pays nothing here
-- on purpose - what a betrayal is worth belongs to the raid's loot split, not
-- to the fight.
--
-- The HP writeback is deliberately the SAME expression for both sides, down
-- to the `opened_hp` fallback for battles opened before 0235 - two different
-- clamps on the two halves of one duel is exactly how the pools 0032 found
-- came to disagree in the first place.
--
-- NOTE FOR THE COG WORK: `bot/battle.py`'s `fetch_state` repeats the same
-- inner join on `creature_species` over the top of this view, so fixing the
-- view alone is not enough to make a duel visible. That belongs with the
-- commands, not here.
--
-- Forward-only. Do not edit once applied.


-- ---------------------------------------------------------------------------
-- The screen
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW battle_overview AS
SELECT b.battle_id,
    b.status,
    b.turn_number,
    b.winner_side,
    me.player_id,
    me.current_hp AS player_hp,
    me.max_hp AS player_max_hp,
    me.current_qi AS player_qi,
    (me.snapshot ->> 'max_qi'::text)::bigint AS player_max_qi,
    me.guarding,
    it.species_id,
    -- Whichever kind of thing is standing there. The column keeps its name
    -- because four cogs and a 583 line module read it, and what it means -
    -- "the name of the thing opposite you" - is the same either way.
    COALESCE(s.name, pl.discord_name) AS creature_name,
    COALESCE(s.rank, player_standing(it.player_id)) AS creature_rank,
    COALESCE(s.description,
             'A cultivator, which is the most dangerous thing there is.')
        AS creature_description,
    it.current_hp AS creature_hp,
    it.max_hp AS creature_max_hp,
    (SELECT r.name FROM realms r
     WHERE r.rank = COALESCE(s.rank, player_standing(it.player_id))
     ORDER BY r.realm_id LIMIT 1) AS creature_realm,
    -- A cultivator telegraphs nothing. What they are about to do is their
    -- own business, which is the whole difference between a duel and a beast.
    mv.name AS intent_name,
    mv.telegraph AS intent_text,
    mv.power_multiplier AS intent_power,
    -- Appended, so every existing reader is untouched.
    it.player_id AS foe_player_id,
    it.current_qi AS foe_qi,
    (it.snapshot ->> 'max_qi')::bigint AS foe_max_qi,
    it.guarding AS foe_guarding
FROM battles b
    JOIN battle_combatants me ON me.battle_id = b.battle_id AND me.combatant_no = 0
    JOIN battle_combatants it ON it.battle_id = b.battle_id AND it.combatant_no = 1
    -- LEFT, because the far side is a person in a duel. An inner join here
    -- hid the entire fight.
    LEFT JOIN creature_species s ON s.species_id = it.species_id
    LEFT JOIN players pl ON pl.player_id = it.player_id
    LEFT JOIN creature_moves mv ON mv.move_id = it.intent_move_id;


-- ---------------------------------------------------------------------------
-- The body on the other side
-- ---------------------------------------------------------------------------

DO $patch$
DECLARE
    src TEXT;
    one TEXT;
BEGIN
    src := pg_get_functiondef('battle_conclude(bigint,text)'::regprocedure);

    one := '    WHERE pp.player_id = me.player_id;';
    IF (length(src) - length(replace(src, one, ''))) / length(one) <> 1 THEN
        RAISE EXCEPTION
            'the health writeback in battle_conclude is not where 0235 left it';
    END IF;

    src := replace(src, one,
        one || chr(10) ||
        chr(10) ||
        '    -- AND THE SAME FOR A CULTIVATOR ON THE OTHER SIDE, which a duel' || chr(10) ||
        '    -- has and a creature fight never did. Without this the loser of a' || chr(10) ||
        '    -- duel walks away unhurt: the whole fight happens to a row in' || chr(10) ||
        '    -- `battle_combatants` and nothing reaches their body.' || chr(10) ||
        '    --' || chr(10) ||
        '    -- The identical expression, down to the `opened_hp` fallback. Two' || chr(10) ||
        '    -- different clamps on the two halves of one duel is how the pools' || chr(10) ||
        '    -- 0032 found came to disagree in the first place.' || chr(10) ||
        '    IF it.player_id IS NOT NULL THEN' || chr(10) ||
        '        UPDATE player_physique pp' || chr(10) ||
        '        SET current_hp = GREATEST(0, LEAST(pp.max_hp,' || chr(10) ||
        '            pp.current_hp' || chr(10) ||
        '            - (COALESCE((it.snapshot ->> ''opened_hp'')::bigint, it.current_hp)' || chr(10) ||
        '               - it.current_hp)))' || chr(10) ||
        '        WHERE pp.player_id = it.player_id;' || chr(10) ||
        '    END IF;');

    -- And the creature spoils only run when there was a creature.
    one := '    IF victory THEN';
    IF (length(src) - length(replace(src, one || chr(10), ''))) / length(one || chr(10)) <> 1 THEN
        RAISE EXCEPTION 'the victory branch in battle_conclude is not where I read it';
    END IF;

    src := replace(src, one || chr(10),
        '    -- A duel pays nothing here. The bestiary, the drops, the purse and' || chr(10) ||
        '    -- the bounty are all read off the species, and with a NULL one most' || chr(10) ||
        '    -- of it quietly does nothing while `species.rank` carries NULL into' || chr(10) ||
        '    -- the arithmetic. What a betrayal is worth belongs to the raid''s' || chr(10) ||
        '    -- loot split rather than to the fight.' || chr(10) ||
        '    IF victory AND it.species_id IS NOT NULL THEN' || chr(10));

    EXECUTE src;
END;
$patch$;


-- ---------------------------------------------------------------------------
-- Open a duel by hand and look at it
-- ---------------------------------------------------------------------------

DO $probe$
DECLARE
    v_a    BIGINT;
    v_b    BIGINT;
    v_bid  BIGINT;
    v_sp   BIGINT;
    v_row  RECORD;
    v_n    INTEGER;
    v_hp_a BIGINT;
    v_hp_b BIGINT;
BEGIN
    -- Nothing that fights a creature lost its row. Checked first, because the
    -- view feeds every fight in the game.
    SELECT count(*) INTO v_n FROM battle_overview;
    IF v_n <> (SELECT count(*) FROM battles b
               WHERE EXISTS (SELECT 1 FROM battle_combatants c
                             WHERE c.battle_id = b.battle_id AND c.combatant_no = 0)
                 AND EXISTS (SELECT 1 FROM battle_combatants c
                             WHERE c.battle_id = b.battle_id AND c.combatant_no = 1)) THEN
        RAISE EXCEPTION
            'the view shows % battles of the % that have two combatants',
            v_n, (SELECT count(*) FROM battles b
                  WHERE EXISTS (SELECT 1 FROM battle_combatants c
                                WHERE c.battle_id = b.battle_id AND c.combatant_no = 0)
                    AND EXISTS (SELECT 1 FROM battle_combatants c
                                WHERE c.battle_id = b.battle_id AND c.combatant_no = 1));
    END IF;

    -- And every creature fight still names its creature.
    SELECT count(*) INTO v_n FROM battle_overview o
    WHERE o.species_id IS NOT NULL AND o.creature_name IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION '% creature fights lost their name', v_n;
    END IF;

    BEGIN
        -- Two cultivators and a hand-built duel, since `duel_open` does not
        -- exist yet. This is exactly the shape it will insert.
        INSERT INTO players (discord_id, discord_name)
        VALUES (-986, 'duellist-a') RETURNING player_id INTO v_a;
        INSERT INTO players (discord_id, discord_name)
        VALUES (-985, 'duellist-b') RETURNING player_id INTO v_b;

        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_b, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1;

        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        VALUES (v_a, (SELECT min(physique_id) FROM physiques),
                1000000, 1000000, 100, 1000),
               (v_b, (SELECT min(physique_id) FROM physiques),
                1000000, 1000000, 100, 1000);

        INSERT INTO battles (kind, status, rng_seed)
        VALUES ('duel', 'active', 1) RETURNING battle_id INTO v_bid;

        INSERT INTO battle_combatants
            (battle_id, combatant_no, side, player_id, snapshot,
             max_hp, current_hp, current_qi)
        VALUES
            (v_bid, 0, 0, v_a,
             jsonb_build_object('max_qi', 1000, 'opened_hp', 1000000),
             1000000, 1000000, 1000),
            (v_bid, 1, 1, v_b,
             jsonb_build_object('max_qi', 1000, 'opened_hp', 1000000),
             1000000, 1000000, 1000);

        -- 1. THE FIGHT IS VISIBLE. This is what an inner join hid.
        SELECT * INTO v_row FROM battle_overview o WHERE o.battle_id = v_bid;
        IF v_row IS NULL THEN
            RAISE EXCEPTION 'a duel does not appear on the fight screen at all';
        END IF;
        IF v_row.creature_name <> 'duellist-b' THEN
            RAISE EXCEPTION
                'the duel names its opponent "%"', v_row.creature_name;
        END IF;
        IF v_row.foe_player_id <> v_b THEN
            RAISE EXCEPTION 'the screen cannot tell who the opponent is';
        END IF;
        IF v_row.creature_rank IS NULL OR v_row.creature_realm IS NULL THEN
            RAISE EXCEPTION
                'a duel shows no standing or realm for the person opposite';
        END IF;
        IF v_row.intent_name IS NOT NULL THEN
            RAISE EXCEPTION
                'a cultivator telegraphed their move, which only beasts do';
        END IF;

        -- 2. A DUEL SOMEBODY WALKED AWAY FROM. Side 1 is wounded but alive,
        -- so nobody won it - and both bodies must still carry what happened.
        UPDATE battle_combatants SET current_hp = 250000
        WHERE battle_id = v_bid AND combatant_no = 1;

        PERFORM battle_conclude(v_bid, 'fled');

        SELECT pp.current_hp INTO v_hp_a FROM player_physique pp
        WHERE pp.player_id = v_a;
        SELECT pp.current_hp INTO v_hp_b FROM player_physique pp
        WHERE pp.player_id = v_b;

        IF v_hp_b <> 250000 THEN
            RAISE EXCEPTION
                'the wounded duellist walked away with % of 250,000', v_hp_b;
        END IF;
        IF v_hp_a <> 1000000 THEN
            RAISE EXCEPTION
                'the other one lost health they never lost: %', v_hp_a;
        END IF;
        IF (SELECT b.winner_side FROM battles b WHERE b.battle_id = v_bid)
           IS NOT NULL THEN
            RAISE EXCEPTION 'a duel nobody finished recorded a winner';
        END IF;

        -- 3. AND ONE THAT ENDED. A second duel, taken to the floor, because
        -- `battle_conclude` reads who won off whether side 1 is standing -
        -- so the two endings cannot be checked in one fight.
        INSERT INTO battles (kind, status, rng_seed)
        VALUES ('duel', 'active', 2) RETURNING battle_id INTO v_bid;
        INSERT INTO battle_combatants
            (battle_id, combatant_no, side, player_id, snapshot,
             max_hp, current_hp, current_qi)
        VALUES
            (v_bid, 0, 0, v_a,
             jsonb_build_object('max_qi', 1000, 'opened_hp', 1000000),
             1000000, 1000000, 1000),
            (v_bid, 1, 1, v_b,
             jsonb_build_object('max_qi', 1000, 'opened_hp', 250000),
             1000000, 0, 1000);

        PERFORM battle_conclude(v_bid, 'complete');

        IF (SELECT b.winner_side FROM battles b WHERE b.battle_id = v_bid) <> 0 THEN
            RAISE EXCEPTION 'the duel did not record who won';
        END IF;
        IF (SELECT pp.current_hp FROM player_physique pp
            WHERE pp.player_id = v_b) <> 0 THEN
            RAISE EXCEPTION
                'the cultivator who was felled is still standing at %',
                (SELECT pp.current_hp FROM player_physique pp
                 WHERE pp.player_id = v_b);
        END IF;

        -- And the winner got no bestiary credit for killing a person.
        IF EXISTS (SELECT 1 FROM player_bestiary WHERE player_id = v_a) THEN
            RAISE EXCEPTION 'a duel wrote a bestiary entry';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    -- A creature fight still concludes the way it always did, driven rather
    -- than assumed - the guard above sits in the one function every ending
    -- passes through.
    BEGIN
        INSERT INTO players (discord_id, discord_name)
        VALUES (-984, 'pve-conclude-probe') RETURNING player_id INTO v_a;
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT v_a, r.realm_id, 0 FROM realms r ORDER BY r.rank, r.realm_id LIMIT 1;
        INSERT INTO player_physique
            (player_id, physique_id, max_hp, current_hp, defense, strength)
        VALUES (v_a, (SELECT min(physique_id) FROM physiques),
                1000000, 1000000, 10, 100000);

        SELECT cs.species_id INTO v_sp FROM creature_species cs
        WHERE cs.kind = 'beast' ORDER BY cs.species_id LIMIT 1;

        v_bid := battle_open(v_a, v_sp);
        UPDATE battle_combatants SET current_hp = 0
        WHERE battle_id = v_bid AND combatant_no = 1;
        PERFORM battle_conclude(v_bid, 'complete');

        IF NOT EXISTS (SELECT 1 FROM player_bestiary
                       WHERE player_id = v_a AND species_id = v_sp
                         AND times_defeated > 0) THEN
            RAISE EXCEPTION
                'felling a beast no longer records it - the guard caught the creature path too';
        END IF;

        RAISE EXCEPTION 'probe-ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'probe-ok' THEN RAISE; END IF;
    END;

    RAISE NOTICE
        'a duel is visible, both bodies feel it, and a beast still pays out';
END;
$probe$;
